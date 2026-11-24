//! Display math typeset to a PNG, and the terminal's cell size.
//!
//! `JNV_KIND_MATH` takes one LaTeX display formula (KaTeX's grammar, through
//! the RaTeX crates) with the macro source of the notebook's cells in front
//! of it, and answers a PNG sized to a whole number of terminal cells (see
//! [`wire`] for both texts). The pipeline is a pure function of its request:
//! no global state, no cache, no file, no clock.
//!
//! ```text
//! wire::parse_request → preprocess::prepare → engine::layout
//!   → raster::check_glyphs → raster::plan → raster::draw
//!   → pngenc::encode_rgba → wire::format_response
//! ```
//!
//! The TeX and the macro source are notebook content, so every stage treats
//! its input as hostile: the preprocessor is linear (its scans share a work
//! budget) and turns off RaTeX's chemistry parser (`\ce`, `\pu`), whose time
//! grows with the square of its input and cannot be cancelled
//! ([`preprocess::NO_CHEMISTRY`]), RaTeX bounds nesting, expansions and
//! layout work, every number of the layout is checked before it sizes
//! anything, the canvas and the ink drawn on it are capped, so is the
//! encoded image ([`MAX_PNG`]), buffers are reserved fallibly, and the
//! cancel flag is read between stages. A failure is a [`MathErr`]; the
//! caller then shows the formula as text.
//!
//! `JNV_KIND_MATH_CELL` reports the terminal's size in cells and pixels
//! ([`cell`]).

pub mod cell;
pub mod engine;
pub mod fonts;
pub mod pngenc;
pub mod preprocess;
pub mod raster;
pub mod wire;

use std::sync::atomic::{AtomicBool, Ordering};

use crate::jobs::{JobCx, JobErr};

/// Bytes of one formula.
pub const MAX_TEX: usize = 16 * 1024;
/// Bytes of macro source.
pub const MAX_PRELUDE: usize = 64 * 1024;
/// Rows or columns the placeholder protocol can name.
pub const MAX_GRID: u32 = 297;
/// Canvas area.
pub const MAX_PIXELS: u64 = 8_000_000;
/// Layout width, height or depth.
pub const MAX_BOX_EM: f64 = 10_000.0;
/// Smallest scale-to-fit factor.
pub const MIN_SHRINK: f64 = 0.5;
/// Bytes of one encoded PNG. A formula's image is a few kilobytes; one of
/// many coloured glyphs on a large canvas can pass a megabyte, which the
/// editor would keep and send to the terminal, so it is a `Size` error.
pub const MAX_PNG: usize = 1024 * 1024;

/// The most bytes of detail an error message carries.
const MAX_DETAIL: usize = 240;

/// Why a formula has no image.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MathErr {
    /// A malformed request (a bug on the caller's side).
    Request(String),
    /// The TeX or the prelude is too long or not UTF-8.
    Input(String),
    /// RaTeX's parser rejected the source, its limits included.
    Parse(String),
    /// RaTeX's layout limit.
    Layout(String),
    /// A glyph no embedded font has.
    Glyph(String),
    /// Too wide, too tall, too many pixels, too much ink, a box that is not
    /// finite, or an encoded image above [`MAX_PNG`].
    Size(String),
    /// Nothing to draw.
    Empty,
    /// The PNG encoder failed or memory ran out.
    Internal(String),
    /// The job's cancel flag was set.
    Cancelled,
}

impl MathErr {
    /// "request", "input", "parse", "layout", "glyph", "size", "empty",
    /// "internal", "cancelled".
    pub fn class(&self) -> &'static str {
        match self {
            MathErr::Request(_) => "request",
            MathErr::Input(_) => "input",
            MathErr::Parse(_) => "parse",
            MathErr::Layout(_) => "layout",
            MathErr::Glyph(_) => "glyph",
            MathErr::Size(_) => "size",
            MathErr::Empty => "empty",
            MathErr::Internal(_) => "internal",
            MathErr::Cancelled => "cancelled",
        }
    }

    /// "math: <class>: <detail>"; Empty is "math: empty: nothing to draw".
    ///
    /// The detail can quote the formula (a parse error names the token), so
    /// it is one line of printable text: control characters become spaces
    /// and it is cut to [`MAX_DETAIL`] bytes on a character boundary.
    pub fn message(&self) -> String {
        let detail = match self {
            MathErr::Request(d)
            | MathErr::Input(d)
            | MathErr::Parse(d)
            | MathErr::Layout(d)
            | MathErr::Glyph(d)
            | MathErr::Size(d)
            | MathErr::Internal(d) => d.as_str(),
            MathErr::Empty => "nothing to draw",
            MathErr::Cancelled => "the job was cancelled",
        };
        format!("math: {}: {}", self.class(), clean_detail(detail))
    }
}

/// `d` as one printable line of at most [`MAX_DETAIL`] bytes.
fn clean_detail(d: &str) -> String {
    let mut out = String::with_capacity(d.len().min(MAX_DETAIL + 3));
    for c in d.chars() {
        let c = if c.is_control() { ' ' } else { c };
        if out.len() + c.len_utf8() > MAX_DETAIL {
            out.push_str("...");
            break;
        }
        out.push(c);
    }
    out
}

/// One typeset formula.
#[derive(Debug, Clone, PartialEq)]
pub struct Typeset {
    /// Pixels: `cols * cell_w` by `rows * cell_h`.
    pub width: u32,
    pub height: u32,
    /// Terminal cells the image fills.
    pub cols: u32,
    pub rows: u32,
    /// Pixels from the top of the image to the baseline.
    pub baseline: u32,
    /// Pixels per math em.
    pub ppem: f64,
    /// Scaled down to fit the most columns.
    pub shrunk: bool,
    /// 8-bit RGBA PNG, straight alpha, transparent background.
    pub png: Vec<u8>,
}

/// The whole pipeline for one request. Checks `cancel` between stages.
pub fn typeset(req: &wire::Request<'_>, cancel: &AtomicBool) -> Result<Typeset, MathErr> {
    let src = preprocess::prepare(req.prelude, req.tex)?;
    stop(cancel)?;
    let dl = engine::layout(&src, req.fg)?;
    stop(cancel)?;
    // Before any pixel is allocated.
    raster::check_glyphs(&dl)?;
    let cv = raster::plan(&dl, req.cell_w, req.cell_h, req.scale, req.max_cols, req.max_rows)?;
    let rgba = raster::draw(&dl, &cv, cancel)?;
    stop(cancel)?;
    let png = pngenc::encode_rgba(&rgba, cv.width, cv.height)?;
    check_png_len(png.len())?;
    Ok(Typeset {
        width: cv.width,
        height: cv.height,
        cols: cv.cols,
        rows: cv.rows,
        baseline: cv.baseline,
        ppem: cv.ppem,
        shrunk: cv.shrunk,
        png,
    })
}

/// An encoded image of `n` bytes is at most [`MAX_PNG`].
fn check_png_len(n: usize) -> Result<(), MathErr> {
    if n > MAX_PNG {
        Err(MathErr::Size(format!("the image is {n} bytes, at most {MAX_PNG}")))
    } else {
        Ok(())
    }
}

fn stop(c: &AtomicBool) -> Result<(), MathErr> {
    if c.load(Ordering::Relaxed) {
        Err(MathErr::Cancelled)
    } else {
        Ok(())
    }
}

fn job_err(e: MathErr) -> JobErr {
    match e {
        MathErr::Cancelled => JobErr::Cancelled,
        other => JobErr::Err(other.message()),
    }
}

/// JNV_KIND_MATH.
pub fn run_typeset(input: &[u8], cx: &JobCx) -> Result<Vec<u8>, JobErr> {
    let req = wire::parse_request(input).map_err(job_err)?;
    let t = typeset(&req, cx.cancel).map_err(job_err)?;
    wire::format_response(&t).map_err(job_err)
}

/// JNV_KIND_MATH_CELL.
pub fn run_cell(input: &[u8]) -> Result<Vec<u8>, String> {
    cell::run(input)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classes_and_messages() {
        let all = [
            (MathErr::Request("line 3: x".into()), "math: request: line 3: x"),
            (MathErr::Input("i".into()), "math: input: i"),
            (MathErr::Parse("Undefined control sequence: \\foo".into()), "math: parse: Undefined control sequence: \\foo"),
            (MathErr::Layout("l".into()), "math: layout: l"),
            (MathErr::Glyph("g".into()), "math: glyph: g"),
            (MathErr::Size("s".into()), "math: size: s"),
            (MathErr::Empty, "math: empty: nothing to draw"),
            (MathErr::Internal("n".into()), "math: internal: n"),
            (MathErr::Cancelled, "math: cancelled: the job was cancelled"),
        ];
        for (e, want) in all {
            assert_eq!(e.message(), want);
            assert!(want.starts_with(&format!("math: {}: ", e.class())));
        }
    }

    #[test]
    fn a_message_is_one_short_printable_line() {
        let m = MathErr::Parse("a\nb\x1b[31mc\td".into()).message();
        assert_eq!(m, "math: parse: a b [31mc d");
        let long = "é".repeat(500);
        let m = MathErr::Parse(long).message();
        let detail = m.strip_prefix("math: parse: ").unwrap();
        assert!(detail.len() <= MAX_DETAIL + 3, "{}", detail.len());
        assert!(detail.ends_with("..."));
        assert!(detail.trim_end_matches("...").chars().all(|c| c == 'é'));
    }

    #[test]
    fn job_errors_map_cancelled_apart() {
        assert_eq!(job_err(MathErr::Cancelled), JobErr::Cancelled);
        assert_eq!(job_err(MathErr::Empty), JobErr::Err("math: empty: nothing to draw".into()));
    }

    fn request<'a>(prelude: &'a str, tex: &'a str) -> wire::Request<'a> {
        wire::Request {
            fg: [0xc0, 0xca, 0xf5],
            cell_w: 14,
            cell_h: 30,
            scale: 1.0,
            max_cols: 100,
            max_rows: 60,
            prelude,
            tex,
        }
    }

    #[test]
    fn typeset_gives_whole_cells_and_a_png() {
        let never = AtomicBool::new(false);
        let t = typeset(&request("", "E = mc^2"), &never).unwrap();
        assert_eq!((t.width, t.height), (t.cols * 14, t.rows * 30));
        assert_eq!(t.rows, 1, "{t:?}");
        assert!(t.baseline > 0 && t.baseline <= t.height);
        assert!(!t.shrunk);
        assert_eq!(t.ppem, 30.0);
        assert!(t.png.starts_with(b"\x89PNG\r\n\x1a\n"));
    }

    #[test]
    fn typeset_uses_the_prelude() {
        let never = AtomicBool::new(false);
        let req = request("text \\newcommand{\\RR}{\\mathbb{R}} more", "x \\in \\RR");
        assert!(typeset(&req, &never).is_ok());
        let err = typeset(&request("", "x \\in \\RR"), &never).unwrap_err();
        assert_eq!(err.class(), "parse", "{err:?}");
    }

    #[test]
    fn chemistry_is_a_parse_error() {
        let never = AtomicBool::new(false);
        let want = MathErr::Parse("Undefined control sequence: \\jnvnomhchem".into());
        assert_eq!(typeset(&request("", "\\ce{H2O}"), &never), Err(want.clone()));
        assert_eq!(typeset(&request("", "x + \\pu{1 kg}"), &never), Err(want.clone()));
        assert_eq!(typeset(&request("$\\newcommand{\\w}{\\ce{H2O}}$", "\\w"), &never), Err(want));
        // Formulas without it are untouched, a leading letter included.
        assert!(typeset(&request("", "ce + pu"), &never).is_ok());
        assert!(typeset(&request("\\def\\c{e}", "x\\c"), &never).is_ok());
    }

    #[test]
    fn an_encoded_image_above_the_cap_is_a_size_error() {
        assert_eq!(check_png_len(0), Ok(()));
        assert_eq!(check_png_len(MAX_PNG), Ok(()));
        assert_eq!(
            check_png_len(MAX_PNG + 1).unwrap_err().message(),
            "math: size: the image is 1048577 bytes, at most 1048576"
        );
    }

    #[test]
    fn a_set_cancel_flag_stops_the_pipeline() {
        let set = AtomicBool::new(true);
        assert_eq!(typeset(&request("", "x^2"), &set), Err(MathErr::Cancelled));
        let cx = JobCx { cancel: &set };
        let req = b"JNM 1\nfg #c0caf5\ncell 14 30\nscale 1\nmax 100 60\npre 0\ntex 3\n\nx^2";
        assert_eq!(run_typeset(req, &cx), Err(JobErr::Cancelled));
    }

    #[test]
    fn run_typeset_formats_the_response() {
        let never = AtomicBool::new(false);
        let cx = JobCx { cancel: &never };
        let req = b"JNM 1\nfg #c0caf5\ncell 14 30\nscale 1\nmax 100 60\npre 0\ntex 3\n\nx^2";
        let out = run_typeset(req, &cx).unwrap();
        assert!(out.starts_with(b"JNM 1\nsize "), "{}", String::from_utf8_lossy(&out));
        match run_typeset(b"x^2", &cx) {
            Err(JobErr::Err(m)) => assert!(m.starts_with("math: request: line 1: "), "{m}"),
            other => panic!("{other:?}"),
        }
    }
}
