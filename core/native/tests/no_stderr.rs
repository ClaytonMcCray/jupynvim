//! The library never writes to stderr or stdout, panics included (Neovim's
//! stderr reaches the terminal, so a printed panic would corrupt the
//! screen; in an embedded Neovim, stdout carries the RPC stream to the UI,
//! so a print there would break it).
//!
//! Its own binary without the test harness (`harness = false`): the harness
//! captures what a test thread's panics print, so a printing panic hook
//! would land in the capture buffer and never reach fd 2. Here nothing is
//! captured, as inside Neovim. fd 1 and fd 2 are each redirected to a pipe
//! around the library calls, and both pipes must stay empty. Two controls
//! then print with the same redirects in place, a line on fd 1 and a panic
//! outside any guard on fd 2, and must find it in their pipe, which proves
//! the checks can see a print.

use std::ffi::c_char;
use std::io::Write;
use std::process::exit;
use std::ptr::null_mut;
use std::time::{Duration, Instant};

use jupynvim::abi::*;
use jupynvim::*;

/// `fd` redirected to a pipe; holds the saved `fd` and the pipe's read end.
struct Redirect {
    fd: i32,
    saved: i32,
    rd: i32,
}

/// Send `fd` (1 or 2) to a new pipe. What the test itself printed before
/// is flushed first, so it stays out of the pipe.
fn redirect(fd: i32) -> Redirect {
    let _ = std::io::stdout().flush();
    let mut fds = [0i32; 2];
    unsafe {
        assert_eq!(libc::pipe(fds.as_mut_ptr()), 0, "pipe");
        // Read without blocking: nothing may hang if a write end survives.
        let fl = libc::fcntl(fds[0], libc::F_GETFL);
        assert!(fl >= 0 && libc::fcntl(fds[0], libc::F_SETFL, fl | libc::O_NONBLOCK) == 0);
        let saved = libc::dup(fd);
        assert!(saved >= 0, "dup({fd})");
        assert_eq!(libc::dup2(fds[1], fd), fd, "dup2 onto fd {fd}");
        libc::close(fds[1]);
        Redirect { fd, saved, rd: fds[0] }
    }
}

/// Put the descriptor back and return what the pipe received meanwhile.
fn restore(r: Redirect) -> Vec<u8> {
    let _ = std::io::stdout().flush();
    let mut got = Vec::new();
    unsafe {
        assert_eq!(libc::dup2(r.saved, r.fd), r.fd, "restore fd {}", r.fd);
        libc::close(r.saved);
        let mut buf = [0u8; 4096];
        loop {
            let n = libc::read(r.rd, buf.as_mut_ptr() as *mut libc::c_void, buf.len());
            if n > 0 {
                got.extend_from_slice(&buf[..n as usize]);
            } else if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            } else {
                break;
            }
        }
        libc::close(r.rd);
    }
    got
}

/// The library calls that can panic or fail, with fd 1 and fd 2
/// redirected. Returns a description of anything that went wrong besides
/// printing.
fn library_calls() -> Vec<String> {
    let mut problems = Vec::new();
    unsafe {
        // A failing open builds an error message.
        let mut err: *mut JnvBuf = null_mut();
        if !jnv_open(65, &mut err).is_null() {
            problems.push("jnv_open(65) did not fail".to_string());
        }
        jnv_buf_free(err);

        let ctx = jnv_open(1, null_mut());
        if ctx.is_null() {
            problems.push("jnv_open(1) failed".to_string());
            return problems;
        }

        // A panic on the calling thread.
        let d = b"sync boom";
        let mut out: *mut JnvBuf = null_mut();
        let st = jnv_call(ctx, KIND_PANIC, d.as_ptr() as *const c_char, d.len(), &mut out);
        if st != PANIC || out.is_null() {
            problems.push(format!("jnv_call PANIC gave status {st}"));
        }
        jnv_buf_free(out);

        // A panic on a worker thread.
        let d = b"async boom";
        let mut job = 0u64;
        let st = jnv_submit(ctx, KIND_PANIC, PRIO_NORMAL | FLAG_COPY, d.as_ptr() as *const c_char, d.len(), &mut job);
        if st != OK {
            problems.push(format!("jnv_submit PANIC gave status {st}"));
        } else {
            let end = Instant::now() + Duration::from_secs(5);
            let mut done = [JnvDone { job: 0, kind: 0, status: -1, result: null_mut() }; 4];
            loop {
                let k = jnv_poll(ctx, done.as_mut_ptr(), done.len());
                if k > 0 {
                    if k != 1 || done[0].job != job || done[0].status != PANIC {
                        problems.push(format!("the PANIC job came back as {:?}", &done[..k]));
                    }
                    for d in &done[..k] {
                        jnv_buf_free(d.result);
                    }
                    break;
                }
                if Instant::now() > end {
                    problems.push("the PANIC job did not come back in 5 s".to_string());
                    break;
                }
                std::thread::sleep(Duration::from_millis(1));
            }
        }

        // Math: success, each failure the dependencies could print on, and
        // chemistry (turned off: a parse error), on the calling thread and
        // then on a worker.
        let wide = "x+".repeat(200);
        let math = [
            (r"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}", OK),
            (r"\undefinedcommand", ERR),
            (r"\text{日本語}", ERR),
            (wide.as_str(), ERR),
            (r"\ce{H2O}", ERR),
            (r"\ce{\frac{", ERR),
            (r"\phase{x} \angl{n} \sout{abc} \cancel{\frac{1}{2}}", OK),
        ];
        for (tex, want) in math {
            let req = math_request(tex);
            let mut out: *mut JnvBuf = null_mut();
            let st = jnv_call(ctx, KIND_MATH, req.as_ptr() as *const c_char, req.len(), &mut out);
            if st != want || out.is_null() {
                problems.push(format!("jnv_call MATH {tex:?} gave status {st}"));
            }
            jnv_buf_free(out);
            let mut job = 0u64;
            let st = jnv_submit(ctx, KIND_MATH, PRIO_NORMAL | FLAG_COPY, req.as_ptr() as *const c_char, req.len(), &mut job);
            if st != OK {
                problems.push(format!("jnv_submit MATH {tex:?} gave status {st}"));
                continue;
            }
            match wait_one(ctx, job) {
                Ok(s) if s == want => {}
                Ok(s) => problems.push(format!("the MATH job {tex:?} came back with status {s}")),
                Err(e) => problems.push(e),
            }
        }
        let mut out: *mut JnvBuf = null_mut();
        let st = jnv_call(ctx, KIND_MATH_CELL, b"".as_ptr() as *const c_char, 0, &mut out);
        if (st != OK && st != ERR) || out.is_null() {
            problems.push(format!("jnv_call MATH_CELL gave status {st}"));
        }
        jnv_buf_free(out);
        jnv_close(ctx);
    }
    problems
}

/// A math request for `tex` at 10x20 cells.
fn math_request(tex: &str) -> Vec<u8> {
    let mut r = format!("JNM 1\nfg #c0caf5\ncell 10 20\nscale 1\nmax 100 60\npre 0\ntex {}\n\n", tex.len()).into_bytes();
    r.extend_from_slice(tex.as_bytes());
    r
}

/// Wait up to 5 s for `job` (the only one in flight); its status.
unsafe fn wait_one(ctx: *mut JnvCtx, job: u64) -> Result<i32, String> {
    let end = Instant::now() + Duration::from_secs(5);
    let mut done = [JnvDone { job: 0, kind: 0, status: -1, result: null_mut() }; 4];
    loop {
        let k = jnv_poll(ctx, done.as_mut_ptr(), done.len());
        if k > 0 {
            let got = (done[0].job, done[0].status);
            for d in &done[..k] {
                jnv_buf_free(d.result);
            }
            return if k == 1 && got.0 == job { Ok(got.1) } else { Err(format!("job {job} came back as {:?}", &done[..k])) };
        }
        if Instant::now() > end {
            return Err(format!("job {job} did not come back in 5 s"));
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

fn main() {
    let mut failed = 0;

    let out = redirect(1);
    let err = redirect(2);
    let problems = library_calls();
    let printed_err = restore(err);
    let printed_out = restore(out);
    for p in &problems {
        println!("FAIL {p}");
        failed += 1;
    }
    for (printed, name) in [(&printed_err, "stderr"), (&printed_out, "stdout")] {
        if printed.is_empty() {
            println!("ok the library wrote nothing to {name} (sync panic, worker panic, failed open, math)");
        } else {
            println!(
                "FAIL the library wrote {} bytes to {name}:\n{}",
                printed.len(),
                String::from_utf8_lossy(printed)
            );
            failed += 1;
        }
    }

    // Controls. A line printed with fd 1 redirected reaches its pipe.
    let out = redirect(1);
    println!("no_stderr control line on fd 1");
    let printed = restore(out);
    let text = String::from_utf8_lossy(&printed);
    if text == "no_stderr control line on fd 1\n" {
        println!("ok control: a printed line reaches the redirected fd 1");
    } else {
        println!("FAIL control: the redirect did not see a printed line (got {text:?})");
        failed += 1;
    }
    // Outside any guard the hook defers to the default one, which prints
    // to fd 2; the same redirect must catch it.
    let r = redirect(2);
    let joined = std::thread::spawn(|| panic!("no_stderr control panic outside any guard")).join();
    let printed = restore(r);
    let text = String::from_utf8_lossy(&printed);
    if joined.is_err() && text.contains("no_stderr control panic outside any guard") {
        println!("ok control: an unguarded panic reaches the redirected fd 2");
    } else {
        println!("FAIL control: the redirect did not see an unguarded panic (got {text:?})");
        failed += 1;
    }

    if failed > 0 {
        println!("no_stderr: {failed} checks failed");
        exit(1);
    }
    println!("no_stderr: all checks passed");
}
