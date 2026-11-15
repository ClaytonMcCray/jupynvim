//! The math kinds through the C boundary, called the way LuaJIT's FFI calls
//! them: `jnv_call`, `jnv_submit`, `jnv_poll` and `jnv_cancel` with raw
//! pointers.
//!
//! Every test holds `LOCK` for its whole run and checks at its end that
//! every buffer it was handed was freed (`jnv_live_buffers` is process-wide).

use std::ffi::c_char;
use std::ptr::null_mut;
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use jupynvim::abi::*;
use jupynvim::mathimage::{MAX_PRELUDE, MAX_TEX};
use jupynvim::*;

static LOCK: Mutex<()> = Mutex::new(());

/// SLEEP 2000 as a borrowed input that stays valid for the whole process.
static SLEEP_2000: [u8; 4] = 2000u32.to_le_bytes();

struct Live {
    _g: MutexGuard<'static, ()>,
    base: u64,
}

fn start() -> Live {
    let g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    Live { _g: g, base: jnv_live_buffers() }
}

impl Drop for Live {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            assert_eq!(jnv_live_buffers(), self.base, "a buffer was not freed");
        }
    }
}

/// A buffer's bytes, copied out, and the buffer freed.
unsafe fn take(b: *mut JnvBuf) -> Vec<u8> {
    assert!(!b.is_null(), "expected a buffer, got NULL");
    let v = {
        let r = &*b;
        assert!(!r.ptr.is_null(), "a buffer's pointer is never NULL");
        std::slice::from_raw_parts(r.ptr, r.len).to_vec()
    };
    jnv_buf_free(b);
    v
}

fn open(workers: u32) -> *mut JnvCtx {
    let ctx = unsafe { jnv_open(workers, null_mut()) };
    assert!(!ctx.is_null(), "jnv_open({workers})");
    ctx
}

/// `jnv_call`: the status and the result's bytes.
fn call(ctx: *mut JnvCtx, kind: u32, data: &[u8]) -> (i32, Vec<u8>) {
    let mut out: *mut JnvBuf = null_mut();
    let st = unsafe { jnv_call(ctx, kind, data.as_ptr() as *const c_char, data.len(), &mut out) };
    (st, unsafe { take(out) })
}

/// `jnv_submit` with a copy of `data`.
fn submit(ctx: *mut JnvCtx, kind: u32, data: &[u8]) -> u64 {
    let mut job = 0u64;
    let st = unsafe {
        jnv_submit(ctx, kind, PRIO_NORMAL | FLAG_COPY, data.as_ptr() as *const c_char, data.len(), &mut job)
    };
    assert_eq!(st, OK, "jnv_submit status");
    job
}

/// Poll until `n` jobs came back (`secs` limit): job, status, result bytes.
fn poll_n(ctx: *mut JnvCtx, n: usize, secs: u64) -> Vec<(u64, i32, Vec<u8>)> {
    let end = Instant::now() + Duration::from_secs(secs);
    let mut got = Vec::new();
    let empty = JnvDone { job: 0, kind: 0, status: -1, result: null_mut() };
    while got.len() < n {
        let mut out = [empty; 16];
        let k = unsafe { jnv_poll(ctx, out.as_mut_ptr(), out.len()) };
        for d in &out[..k] {
            got.push((d.job, d.status, unsafe { take(d.result) }));
        }
        if got.len() < n {
            assert!(Instant::now() < end, "only {} of {n} jobs came back in {secs} s", got.len());
            std::thread::sleep(Duration::from_millis(1));
        }
    }
    got
}

fn request(cell: (u32, u32), max: (u32, u32), prelude: &[u8], tex: &[u8]) -> Vec<u8> {
    let mut r = format!(
        "JNM 1\nfg #c0caf5\ncell {} {}\nscale 1\nmax {} {}\npre {}\ntex {}\n\n",
        cell.0,
        cell.1,
        max.0,
        max.1,
        prelude.len(),
        tex.len()
    )
    .into_bytes();
    r.extend_from_slice(prelude);
    r.extend_from_slice(tex);
    r
}

fn req(tex: &str) -> Vec<u8> {
    request((14, 30), (100, 60), b"", tex.as_bytes())
}

const EXAMPLE: &[u8] = b"JNM 1\nfg #c0caf5\ncell 14 30\nscale 1\nmax 100 60\npre 0\ntex 3\n\nx^2";

/// A response, checked line by line: (width, height, cols, rows, baseline, png).
fn parse_response(out: &[u8]) -> (u32, u32, u32, u32, u32, Vec<u8>) {
    let sep = out.windows(2).position(|w| w == b"\n\n").expect("a blank line");
    let head = std::str::from_utf8(&out[..sep]).expect("a text head");
    let body = &out[sep + 2..];
    let lines: Vec<&str> = head.lines().collect();
    assert_eq!(lines.len(), 7, "{head}");
    assert_eq!(lines[0], "JNM 1");
    let nums = |line: &str, key: &str| -> Vec<String> {
        let rest = line.strip_prefix(key).unwrap_or_else(|| panic!("{key:?} in {head}"));
        rest.split(' ').map(str::to_string).collect()
    };
    let two = |line: &str, key: &str| {
        let v = nums(line, key);
        assert_eq!(v.len(), 2, "{line}");
        (v[0].parse::<u32>().unwrap(), v[1].parse::<u32>().unwrap())
    };
    let (w, h) = two(lines[1], "size ");
    let (c, r) = two(lines[2], "grid ");
    let base: u32 = nums(lines[3], "base ")[0].parse().unwrap();
    let em = &nums(lines[4], "em ")[0];
    assert!(em.parse::<f64>().is_ok() && em.split('.').nth(1).map(str::len) == Some(3), "{em}");
    assert!(lines[5] == "shrunk 0" || lines[5] == "shrunk 1", "{head}");
    let n: usize = nums(lines[6], "png ")[0].parse().unwrap();
    assert_eq!(body.len(), n, "the png line counts the base64 text");
    assert!(body.iter().all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(b)), "base64 only");
    (w, h, c, r, base, base64_decode(body))
}

fn base64_decode(s: &[u8]) -> Vec<u8> {
    let val = |c: u8| -> u32 {
        match c {
            b'A'..=b'Z' => (c - b'A') as u32,
            b'a'..=b'z' => (c - b'a' + 26) as u32,
            b'0'..=b'9' => (c - b'0' + 52) as u32,
            b'+' => 62,
            b'/' => 63,
            _ => panic!("not base64: {c}"),
        }
    };
    assert_eq!(s.len() % 4, 0);
    let mut out = Vec::new();
    for q in s.chunks(4) {
        let pad = q.iter().filter(|&&c| c == b'=').count();
        let n = q.iter().take(4 - pad).enumerate().fold(0u32, |n, (i, &c)| n | val(c) << (18 - 6 * i));
        let bytes = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
        out.extend_from_slice(&bytes[..3 - pad]);
    }
    out
}

/// The PNG's size and RGBA pixels.
fn decode_png(png: &[u8]) -> (u32, u32, Vec<u8>) {
    let mut reader = png::Decoder::new(std::io::Cursor::new(png)).read_info().expect("a PNG");
    let mut buf = vec![0; reader.output_buffer_size().unwrap()];
    let info = reader.next_frame(&mut buf).unwrap();
    assert_eq!((info.color_type, info.bit_depth), (png::ColorType::Rgba, png::BitDepth::Eight));
    buf.truncate(info.buffer_size());
    (info.width, info.height, buf)
}

#[test]
fn call_typesets_the_example() {
    let _l = start();
    let ctx = open(1);
    let (st, out) = call(ctx, KIND_MATH, EXAMPLE);
    assert_eq!(st, OK, "{}", String::from_utf8_lossy(&out));
    let (w, h, c, r, base, png) = parse_response(&out);
    assert_eq!((w, h), (c * 14, r * 30));
    assert!(base > 0 && base <= h);
    let (pw, ph, px) = decode_png(&png);
    assert_eq!((pw, ph), (w, h));
    assert!(px.chunks_exact(4).any(|p| p[3] > 0), "some ink");
    assert!(px.chunks_exact(4).filter(|p| p[3] == 255).all(|p| p[..3] == [0xc0, 0xca, 0xf5]));

    // The same request again: the same bytes.
    let (st, again) = call(ctx, KIND_MATH, EXAMPLE);
    assert_eq!(st, OK);
    assert_eq!(again, out);
    unsafe { jnv_close(ctx) };
}

#[test]
fn every_error_class_through_the_boundary() {
    let _l = start();
    let ctx = open(1);
    let wide = "x+".repeat(200);
    let cases: Vec<(Vec<u8>, &str)> = vec![
        (b"x^2".to_vec(), "math: request: line 1: "),
        (EXAMPLE[..EXAMPLE.len() - 1].to_vec(), "math: request: line 9: the body is 2 bytes"),
        (req(&"x".repeat(MAX_TEX + 1)), "math: input: the formula is 16385 bytes"),
        (request((14, 30), (100, 60), b"", b"x\xff"), "math: input: the formula is not UTF-8"),
        (req(r"\undefinedcommand"), "math: parse: "),
        // Dashed column rules count one item per dash: past 65,536 items.
        (req(r"\begin{array}{:c}\rule{1em}{1000000000em}\end{array}"), "math: layout: Layout resource limit exceeded"),
        (req(r"\text{日本語}"), "math: glyph: U+65E5 has no font (CJK-Regular)"),
        (req(&wide), "math: size: too wide: "),
        (req(r"\label{eq:1}"), "math: empty: nothing to draw"),
        (req(r"\def\a{b}"), "math: empty: nothing to draw"),
    ];
    for (input, prefix) in cases {
        let (st, out) = call(ctx, KIND_MATH, &input);
        let msg = String::from_utf8_lossy(&out);
        assert_eq!(st, ERR, "{prefix}: {msg}");
        assert!(msg.starts_with(prefix), "wanted {prefix:?}, got {msg:?}");
    }
    unsafe { jnv_close(ctx) };
}

#[test]
fn submit_and_poll_give_what_call_gives() {
    let _l = start();
    let ctx = open(2);
    let (st, want) = call(ctx, KIND_MATH, EXAMPLE);
    assert_eq!(st, OK);
    let job = submit(ctx, KIND_MATH, EXAMPLE);
    let got = poll_n(ctx, 1, 5);
    assert_eq!((got[0].0, got[0].1), (job, OK));
    assert_eq!(got[0].2, want);
    let bad = submit(ctx, KIND_MATH, &req(r"\undefinedcommand"));
    let got = poll_n(ctx, 1, 5);
    assert_eq!((got[0].0, got[0].1), (bad, ERR));
    assert!(got[0].2.starts_with(b"math: parse: "));
    unsafe { jnv_close(ctx) };
}

#[test]
fn a_job_cancelled_before_it_runs_is_cancelled() {
    let _l = start();
    let ctx = open(1);
    let mut sleeper = 0u64;
    let st = unsafe {
        jnv_submit(ctx, KIND_SLEEP, PRIO_NORMAL, SLEEP_2000.as_ptr() as *const c_char, 4, &mut sleeper)
    };
    assert_eq!(st, OK);
    // Give the single worker time to take the sleeper.
    std::thread::sleep(Duration::from_millis(30));
    let queued = submit(ctx, KIND_MATH, EXAMPLE);
    assert_eq!(unsafe { jnv_cancel(ctx, queued) }, OK);
    assert_eq!(unsafe { jnv_cancel(ctx, sleeper) }, OK);
    let got = poll_n(ctx, 2, 5);
    for (job, status, result) in &got {
        assert_eq!(*status, CANCELLED, "job {job}");
        assert_eq!(result, b"cancelled");
    }
    assert!(got.iter().any(|g| g.0 == queued));
    unsafe { jnv_close(ctx) };
}

#[test]
fn many_jobs_on_eight_workers_all_come_back_right() {
    let _l = start();
    let ctx = open(8);
    let formulas = [
        r"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}",
        r"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}",
        r"\begin{pmatrix} a & b \\ c & d \end{pmatrix}",
        r"I(t) \approx I'(t) = I_0 e^{t/\text{timeConstant}}",
        r"\int_0^\infty e^{-x^2} dx = \frac{\sqrt{\pi}}{2}",
        r"\undefinedcommand",
        r"\text{日本語}",
        r"\ce{H2O}",
    ];
    let want: Vec<(i32, Vec<u8>)> = formulas.iter().map(|f| call(ctx, KIND_MATH, &req(f))).collect();
    let mut jobs = Vec::new();
    for k in 0..64 {
        let f = k % formulas.len();
        jobs.push((submit(ctx, KIND_MATH, &req(formulas[f])), f));
    }
    let got = poll_n(ctx, 64, 30);
    for (job, status, result) in got {
        let f = jobs.iter().find(|j| j.0 == job).expect("a job we submitted").1;
        assert_eq!((status, &result), (want[f].0, &want[f].1), "{}", formulas[f]);
    }
    unsafe { jnv_close(ctx) };
}

#[test]
fn hostile_inputs_end_quickly_and_never_panic() {
    let _l = start();
    let ctx = open(1);
    let mut bomb = String::from(r"\def\a{x}");
    let names = ["b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u"];
    let mut prev = "a";
    for n in names {
        bomb.push_str(&format!(r"\def\{n}{{\{prev}\{prev}}}"));
        prev = n;
    }
    bomb.push_str(r"\u");
    let rows: String = "x&=y\\\\".repeat(2000);
    let matrix: String = (0..60)
        .map(|_| vec!["x"; 60].join(" & "))
        .collect::<Vec<_>>()
        .join(r" \\ ");
    let cases: Vec<(String, Vec<u8>)> = vec![
        ("16 KiB of {".into(), req(&"{".repeat(MAX_TEX))),
        ("16 KiB of \\frac{".into(), req(&r"\frac{".repeat(MAX_TEX / 6))),
        ("the macro bomb".into(), req(&bomb)),
        ("16 KiB of x+".into(), req(&"x+".repeat(MAX_TEX / 2))),
        ("2,000 aligned rows".into(), req(&format!(r"\begin{{aligned}}{rows}\end{{aligned}}"))),
        ("a 60x60 matrix".into(), request((10, 20), (297, 297), b"", format!(r"\begin{{matrix}}{matrix}\end{{matrix}}").as_bytes())),
        ("a huge rule".into(), req(r"\rule{100000em}{100000em}")),
        ("a huge raise".into(), req(r"\raisebox{10000000000000000em}{x}")),
        ("a huge kern".into(), req(r"x\kern100000em y")),
        ("an infinite rule".into(), req(r"\rule{1e400em}{1em}")),
        (
            "a dashed rule 1e300 em to the left".into(),
            req(&format!(r"x\rlap{{\kern-1{}em\begin{{array}}{{c}}\hdashline x\\\hdashline\end{{array}}}}", "0".repeat(300))),
        ),
        (
            "a dashed rule from 1.2e299 em to the left across the image".into(),
            req(&format!(
                r"x\rlap{{\kern-{z}em\begin{{array}}{{c}}\hdashline \kern3{z}em\\\hdashline\end{{array}}}}",
                z = "1234567891".repeat(30)
            )),
        ),
        (
            "a dashed rule 1e15 em to the left".into(),
            req(&format!(r"x\rlap{{\kern-1{}em\begin{{array}}{{c}}\hdashline x\\\hdashline\end{{array}}}}", "0".repeat(15))),
        ),
        ("three Huge".into(), req(r"\Huge\Huge\Huge x")),
        ("a large font size".into(), req(r"\htmlStyle{font-size:1e300em}{x}")),
        ("stacked giant glyphs".into(), req(&r"\rlap{\htmlStyle{font-size:40em}{\smash{M}}}".repeat(300))),
        ("a TeX too long".into(), req(&"x".repeat(MAX_TEX + 1))),
        ("a prelude too long".into(), request((14, 30), (100, 60), &vec![b'x'; MAX_PRELUDE + 1], b"x")),
        ("a self-recursive prelude".into(), request((14, 30), (100, 60), r"\def\a{\a}".repeat(MAX_PRELUDE / 10).as_bytes(), br"x + \a")),
        ("a prelude of nested definitions".into(), request((14, 30), (100, 60), r"\newcommand{\a}{".repeat(MAX_PRELUDE / 16).as_bytes(), b"x")),
        ("invalid UTF-8".into(), request((14, 30), (100, 60), b"", b"\xc3\x28")),
        ("an empty TeX".into(), req("")),
        ("NUL bytes".into(), req("x\0y\0")),
        ("too many pixels".into(), request((256, 512), (297, 297), b"", br"\rule{2em}{20em}")),
        ("a canvas of 5.5 million pixels".into(), request((256, 512), (297, 297), b"", br"\rule{10em}{2em}")),
        (
            "giant glyphs on the largest canvas, up to the ink budget".into(),
            request(
                (256, 512),
                (297, 297),
                b"",
                format!(r"\htmlStyle{{font-size:4em}}{{{}M}}", r"\rlap{M}".repeat(36)).as_bytes(),
            ),
        ),
        ("a deep eqnarray".into(), req(&format!("{}x{}", r"\begin{eqnarray}".repeat(500), r"\end{eqnarray}".repeat(500)))),
    ];
    for (name, input) in &cases {
        let t = Instant::now();
        let (st, out) = call(ctx, KIND_MATH, input);
        let el = t.elapsed();
        let msg = String::from_utf8_lossy(&out[..out.len().min(200)]);
        eprintln!("{name}: {el:?} {}", msg.lines().next().unwrap_or(""));
        assert!(st == OK || st == ERR, "{name}: status {st}: {msg}");
        assert!(el < Duration::from_secs(2), "{name}: {el:?}");
        if st == ERR {
            assert!(msg.starts_with("math: "), "{name}: {msg}");
        }
    }
    // The stroked paths draw.
    let (st, out) = call(ctx, KIND_MATH, &req(r"\phase{x} \angl{n} \sout{abc} \cancel{\frac{1}{2}}"));
    assert_eq!(st, OK, "{}", String::from_utf8_lossy(&out));
    unsafe { jnv_close(ctx) };
}

#[test]
fn cell_answers_or_says_no_terminal() {
    let _l = start();
    let ctx = open(1);
    let (st, out) = call(ctx, KIND_MATH_CELL, b"");
    let text = String::from_utf8(out).unwrap();
    if st == OK {
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 6, "{text}");
        assert_eq!(lines[0], "JNC 1");
        for (l, k) in lines[1..].iter().zip(["cols ", "rows ", "xpixel ", "ypixel ", "source "]) {
            assert!(l.starts_with(k), "{text}");
        }
    } else {
        assert_eq!((st, text.as_str()), (ERR, "math cell: no terminal"));
    }
    let (st, out) = call(ctx, KIND_MATH_CELL, b"x");
    assert_eq!((st, out.as_slice()), (ERR, &b"math cell: no input is expected"[..]));
    unsafe { jnv_close(ctx) };
}
