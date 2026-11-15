//! The texts of `JNV_KIND_MATH`. Lines end with one LF, never CR.
//!
//! Request:
//!
//! ```text
//! JNM 1
//! fg #c0caf5          foreground colour of the ink
//! cell 14 30          cell width and height in pixels: 4..256, 4..512
//! scale 1             math em per cell height: 0.25..4
//! max 100 60          most columns and rows: 1..297 each
//! pre 0               byte length of the prelude
//! tex 3               byte length of the TeX
//!                     one empty line ends the header
//! x^2                 exactly pre + tex bytes: the prelude, then the TeX
//! ```
//!
//! The six header lines come once each, in any order. Numbers are ASCII
//! digits (at most 9, no sign); `scale` is what `f64::from_str` accepts.
//!
//! Response (status OK), the lines in this order:
//!
//! ```text
//! JNM 1
//! size 378 60         PNG width and height in pixels
//! grid 27 2           columns and rows; size = grid * cell, exactly
//! base 40             baseline, pixels from the top of the PNG
//! em 30.000           pixels per math em, 3 decimals
//! shrunk 0            1 when the formula was scaled down to fit max cols
//! png 11176           byte length of the base64 text below
//!
//! iVBORw0KGgo...      the PNG, standard base64 with = padding, no LF
//! ```

use super::{MathErr, Typeset, MAX_GRID, MAX_PRELUDE, MAX_TEX};

/// One parsed request; the prelude and the TeX borrow the input.
#[derive(Debug, Clone, PartialEq)]
pub struct Request<'a> {
    pub fg: [u8; 3],
    pub cell_w: u32,
    pub cell_h: u32,
    pub scale: f64,
    pub max_cols: u32,
    pub max_rows: u32,
    pub prelude: &'a str,
    pub tex: &'a str,
}

const KEYS: [&str; 6] = ["fg", "cell", "scale", "max", "pre", "tex"];

fn bad(line: usize, what: impl std::fmt::Display) -> MathErr {
    MathErr::Request(format!("line {line}: {what}"))
}

/// ASCII digits, 1 to 9 of them.
fn uint(s: &str) -> Option<u32> {
    if s.is_empty() || s.len() > 9 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

/// Two UINTs separated by one space.
fn two(s: &str) -> Option<(u32, u32)> {
    let (a, b) = s.split_once(' ')?;
    Some((uint(a)?, uint(b)?))
}

fn hex6(s: &str) -> Option<[u8; 3]> {
    let h = s.strip_prefix('#')?;
    if h.len() != 6 || !h.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let byte = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).ok();
    Some([byte(0)?, byte(2)?, byte(4)?])
}

/// Parse a request. A malformed header or a body of the wrong length is
/// `Request` with the line; a prelude or TeX too long or not UTF-8 is
/// `Input`. An empty TeX parses; [`super::preprocess::prepare`] calls it
/// `Empty`.
pub fn parse_request(input: &[u8]) -> Result<Request<'_>, MathErr> {
    let mut pos = 0usize;
    let mut line_no = 0usize;
    let mut fg = None;
    let mut cell = None;
    let mut scale = None;
    let mut max = None;
    let mut pre = None;
    let mut tex = None;
    let mut seen = [false; 6];
    loop {
        line_no += 1;
        let Some(nl) = input[pos..].iter().position(|&b| b == b'\n') else {
            return Err(bad(line_no, "the header has no end (an empty line)"));
        };
        let raw = &input[pos..pos + nl];
        pos += nl + 1;
        let Ok(line) = std::str::from_utf8(raw) else {
            return Err(bad(line_no, "not UTF-8"));
        };
        if line_no == 1 {
            if line != "JNM 1" {
                return Err(bad(1, "wants JNM 1"));
            }
            continue;
        }
        if line.is_empty() {
            break;
        }
        let Some((key, value)) = line.split_once(' ') else {
            return Err(bad(line_no, "wants a key and a value"));
        };
        let Some(k) = KEYS.iter().position(|&x| x == key) else {
            return Err(bad(line_no, format_args!("unknown key {key}")));
        };
        if seen[k] {
            return Err(bad(line_no, format_args!("{key} is given twice")));
        }
        seen[k] = true;
        match key {
            "fg" => fg = Some(hex6(value).ok_or_else(|| bad(line_no, "fg wants #rrggbb"))?),
            "cell" => {
                let (w, h) = two(value).ok_or_else(|| bad(line_no, "cell wants two numbers"))?;
                if !(4..=256).contains(&w) || !(4..=512).contains(&h) {
                    return Err(bad(line_no, "cell wants a width of 4 to 256 and a height of 4 to 512"));
                }
                cell = Some((w, h));
            }
            "scale" => {
                let v: f64 = value.parse().map_err(|_| bad(line_no, "scale wants a number"))?;
                if !(v.is_finite() && (0.25..=4.0).contains(&v)) {
                    return Err(bad(line_no, "scale wants a number from 0.25 to 4"));
                }
                scale = Some(v);
            }
            "max" => {
                let (c, r) = two(value).ok_or_else(|| bad(line_no, "max wants two numbers"))?;
                if !(1..=MAX_GRID).contains(&c) || !(1..=MAX_GRID).contains(&r) {
                    return Err(bad(line_no, format_args!("max wants columns and rows of 1 to {MAX_GRID}")));
                }
                max = Some((c, r));
            }
            "pre" => pre = Some(uint(value).ok_or_else(|| bad(line_no, "pre wants a byte count"))?),
            _ => tex = Some(uint(value).ok_or_else(|| bad(line_no, "tex wants a byte count"))?),
        }
    }
    if let Some(k) = seen.iter().position(|&s| !s) {
        return Err(bad(line_no, format_args!("the header has no {} line", KEYS[k])));
    }
    let (Some(fg), Some((cell_w, cell_h)), Some(scale), Some((max_cols, max_rows)), Some(pre), Some(tex)) =
        (fg, cell, scale, max, pre, tex)
    else {
        return Err(bad(line_no, "the header is incomplete"));
    };
    let body = &input[pos..];
    let (pre, tex) = (pre as usize, tex as usize);
    if body.len() != pre + tex {
        return Err(bad(
            line_no + 1,
            format_args!("the body is {} bytes, pre + tex is {}", body.len(), pre + tex),
        ));
    }
    if pre > MAX_PRELUDE {
        return Err(MathErr::Input(format!("the prelude is {pre} bytes, at most {MAX_PRELUDE}")));
    }
    if tex > MAX_TEX {
        return Err(MathErr::Input(format!("the formula is {tex} bytes, at most {MAX_TEX}")));
    }
    let prelude = std::str::from_utf8(&body[..pre])
        .map_err(|e| MathErr::Input(format!("the prelude is not UTF-8 (byte {})", e.valid_up_to())))?;
    let tex = std::str::from_utf8(&body[pre..])
        .map_err(|e| MathErr::Input(format!("the formula is not UTF-8 (byte {})", e.valid_up_to())))?;
    Ok(Request { fg, cell_w, cell_h, scale, max_cols, max_rows, prelude, tex })
}

/// The response text for `t`. The buffer is reserved fallibly.
pub fn format_response(t: &Typeset) -> Result<Vec<u8>, MathErr> {
    let b64_len = t.png.len().div_ceil(3).checked_mul(4).ok_or_else(|| MathErr::Internal("the PNG is too large".into()))?;
    let head = format!(
        "JNM 1\nsize {} {}\ngrid {} {}\nbase {}\nem {:.3}\nshrunk {}\npng {}\n\n",
        t.width,
        t.height,
        t.cols,
        t.rows,
        t.baseline,
        t.ppem,
        u8::from(t.shrunk),
        b64_len
    );
    let mut out = Vec::new();
    out.try_reserve_exact(head.len() + b64_len)
        .map_err(|_| MathErr::Internal(format!("out of memory for a response of {} bytes", head.len() + b64_len)))?;
    out.extend_from_slice(head.as_bytes());
    base64_into(&mut out, &t.png);
    Ok(out)
}

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Append `data` as standard base64 (RFC 4648, `=` padding, no line breaks).
pub fn base64_into(out: &mut Vec<u8>, data: &[u8]) {
    let mut chunks = data.chunks_exact(3);
    for c in &mut chunks {
        let n = (c[0] as u32) << 16 | (c[1] as u32) << 8 | c[2] as u32;
        out.extend_from_slice(&[
            ALPHABET[(n >> 18) as usize & 63],
            ALPHABET[(n >> 12) as usize & 63],
            ALPHABET[(n >> 6) as usize & 63],
            ALPHABET[n as usize & 63],
        ]);
    }
    match *chunks.remainder() {
        [a] => {
            let n = (a as u32) << 16;
            out.extend_from_slice(&[ALPHABET[(n >> 18) as usize & 63], ALPHABET[(n >> 12) as usize & 63], b'=', b'=']);
        }
        [a, b] => {
            let n = (a as u32) << 16 | (b as u32) << 8;
            out.extend_from_slice(&[
                ALPHABET[(n >> 18) as usize & 63],
                ALPHABET[(n >> 12) as usize & 63],
                ALPHABET[(n >> 6) as usize & 63],
                b'=',
            ]);
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXAMPLE: &str = "JNM 1\nfg #c0caf5\ncell 14 30\nscale 1\nmax 100 60\npre 0\ntex 3\n\nx^2";

    fn request_err(input: &str) -> String {
        match parse_request(input.as_bytes()) {
            Err(MathErr::Request(m)) => m,
            other => panic!("expected a request error for {input:?}, got {other:?}"),
        }
    }

    #[test]
    fn the_example_parses() {
        let r = parse_request(EXAMPLE.as_bytes()).unwrap();
        assert_eq!(
            r,
            Request {
                fg: [0xc0, 0xca, 0xf5],
                cell_w: 14,
                cell_h: 30,
                scale: 1.0,
                max_cols: 100,
                max_rows: 60,
                prelude: "",
                tex: "x^2",
            }
        );
    }

    #[test]
    fn keys_in_another_order_and_a_prelude() {
        let r = parse_request(b"JNM 1\ntex 3\npre 4\nmax 297 297\nscale 0.25\ncell 256 512\nfg #ABCdef\n\n\\a{}x^2").unwrap();
        assert_eq!((r.prelude, r.tex), ("\\a{}", "x^2"));
        assert_eq!((r.cell_w, r.cell_h, r.max_cols, r.max_rows), (256, 512, 297, 297));
        assert_eq!(r.scale, 0.25);
        assert_eq!(r.fg, [0xab, 0xcd, 0xef]);
        let r = parse_request(b"JNM 1\nfg #000000\ncell 4 4\nscale 4\nmax 1 1\npre 0\ntex 0\n\n").unwrap();
        assert_eq!((r.tex, r.scale, r.max_cols), ("", 4.0, 1));
        let r = parse_request(b"JNM 1\nfg #000000\ncell 4 4\nscale 2.5e-1\nmax 1 1\npre 000\ntex 0\n\n").unwrap();
        assert_eq!(r.scale, 0.25);
    }

    #[test]
    fn malformed_requests_name_their_line() {
        let ok = |from: &str, to: &str| EXAMPLE.replacen(from, to, 1);
        let cases: Vec<(String, &str)> = vec![
            ("".into(), "line 1: the header has no end"),
            ("x^2".into(), "line 1: the header has no end"),
            ("JNM 2\n".into(), "line 1: wants JNM 1"),
            ("JNP 1\nkind dark\n".into(), "line 1: wants JNM 1"),
            ("JNM 1\r\nfg #000000\n".into(), "line 1: wants JNM 1"),
            (ok("fg #c0caf5", "fg c0caf5"), "line 2: fg wants #rrggbb"),
            (ok("fg #c0caf5", "fg #c0caf"), "line 2: fg wants #rrggbb"),
            (ok("fg #c0caf5", "fg #c0caf5\r"), "line 2: fg wants #rrggbb"),
            (ok("fg #c0caf5", "fg #g0caf5"), "line 2: fg wants #rrggbb"),
            (ok("cell 14 30", "cell 14"), "line 3: cell wants two numbers"),
            (ok("cell 14 30", "cell 14  30"), "line 3: cell wants two numbers"),
            (ok("cell 14 30", "cell -14 30"), "line 3: cell wants two numbers"),
            (ok("cell 14 30", "cell 3 30"), "line 3: cell wants a width"),
            (ok("cell 14 30", "cell 14 513"), "line 3: cell wants a width"),
            (ok("cell 14 30", "cell 1234567890 30"), "line 3: cell wants two numbers"),
            (ok("scale 1", "scale x"), "line 4: scale wants a number"),
            (ok("scale 1", "scale NaN"), "line 4: scale wants a number from"),
            (ok("scale 1", "scale inf"), "line 4: scale wants a number from"),
            (ok("scale 1", "scale 4.01"), "line 4: scale wants a number from"),
            (ok("scale 1", "scale 0.2"), "line 4: scale wants a number from"),
            (ok("max 100 60", "max 0 60"), "line 5: max wants columns"),
            (ok("max 100 60", "max 100 298"), "line 5: max wants columns"),
            (ok("pre 0", "pre +0"), "line 6: pre wants a byte count"),
            (ok("tex 3", "tex 3.0"), "line 7: tex wants a byte count"),
            (ok("tex 3", "tex"), "line 7: wants a key and a value"),
            (ok("tex 3", "tex 3\nfg #000000"), "line 8: fg is given twice"),
            (ok("tex 3", "tex 3\nsize 1 1"), "line 8: unknown key size"),
            (ok("tex 3\n", ""), "line 7: the header has no tex line"),
            (ok("fg #c0caf5\n", ""), "line 7: the header has no fg line"),
            (ok("\n\nx^2", "\n\nx^"), "line 9: the body is 2 bytes, pre + tex is 3"),
            (ok("\n\nx^2", "\n\nx^2 "), "line 9: the body is 4 bytes, pre + tex is 3"),
            (ok("pre 0", "pre 999999999"), "line 9: the body is 3 bytes, pre + tex is 1000000002"),
        ];
        for (input, want) in cases {
            let m = request_err(&input);
            assert!(m.starts_with(want), "{input:?}: {m}");
        }
        // Not UTF-8 in the header.
        match parse_request(b"JNM 1\nfg #c0caf5\xff\n") {
            Err(MathErr::Request(m)) => assert_eq!(m, "line 2: not UTF-8"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn long_or_invalid_bodies_are_input_errors() {
        let head = |pre: usize, tex: usize| format!("JNM 1\nfg #c0caf5\ncell 14 30\nscale 1\nmax 100 60\npre {pre}\ntex {tex}\n\n");
        let mut big = head(0, MAX_TEX + 1).into_bytes();
        big.extend(std::iter::repeat_n(b'x', MAX_TEX + 1));
        assert!(matches!(parse_request(&big), Err(MathErr::Input(m)) if m == "the formula is 16385 bytes, at most 16384"));
        let mut ok = head(0, MAX_TEX).into_bytes();
        ok.extend(std::iter::repeat_n(b'x', MAX_TEX));
        assert!(parse_request(&ok).is_ok());
        let mut big = head(MAX_PRELUDE + 1, 1).into_bytes();
        big.extend(std::iter::repeat_n(b'x', MAX_PRELUDE + 2));
        assert!(matches!(parse_request(&big), Err(MathErr::Input(m)) if m.starts_with("the prelude is 65537 bytes")));
        let mut bad = head(0, 3).into_bytes();
        bad.extend_from_slice(b"x\xffy");
        assert!(matches!(parse_request(&bad), Err(MathErr::Input(m)) if m == "the formula is not UTF-8 (byte 1)"));
        let mut bad = head(2, 1).into_bytes();
        bad.extend_from_slice(b"\xc3xy");
        assert!(matches!(parse_request(&bad), Err(MathErr::Input(m)) if m.starts_with("the prelude is not UTF-8")));
        // A character split between the prelude and the TeX is invalid in both.
        let mut split = head(1, 1).into_bytes();
        split.extend_from_slice("é".as_bytes());
        assert!(matches!(parse_request(&split), Err(MathErr::Input(_))));
        // NUL bytes are UTF-8: the request parses (RaTeX decides).
        let mut nul = head(0, 3).into_bytes();
        nul.extend_from_slice(b"x\0y");
        assert_eq!(parse_request(&nul).unwrap().tex, "x\0y");
    }

    #[test]
    fn the_response_of_a_fixed_typeset() {
        let t = Typeset {
            width: 378,
            height: 60,
            cols: 27,
            rows: 2,
            baseline: 40,
            ppem: 30.0,
            shrunk: false,
            png: b"foob".to_vec(),
        };
        assert_eq!(
            format_response(&t).unwrap(),
            b"JNM 1\nsize 378 60\ngrid 27 2\nbase 40\nem 30.000\nshrunk 0\npng 8\n\nZm9vYg==".to_vec()
        );
        let t = Typeset { ppem: 13.4567, shrunk: true, png: Vec::new(), ..t };
        assert_eq!(
            format_response(&t).unwrap(),
            b"JNM 1\nsize 378 60\ngrid 27 2\nbase 40\nem 13.457\nshrunk 1\npng 0\n\n".to_vec()
        );
    }

    #[test]
    fn base64_rfc4648_vectors() {
        for (input, want) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ] {
            let mut out = Vec::new();
            base64_into(&mut out, input.as_bytes());
            assert_eq!(out, want.as_bytes(), "{input:?}");
        }
        let mut out = b"x".to_vec();
        base64_into(&mut out, &[0xff, 0xfe, 0xfd, 0x00]);
        assert_eq!(out, b"x//79AA==");
    }
}
