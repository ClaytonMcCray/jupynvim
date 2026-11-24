//! The regression list of the math images: every display math of the
//! shared markdown fixture (`tests/fixtures/markdown/md-fixture.md`, read in
//! place) typeset at 10x20-pixel cells, scale 1, at most 297x60 cells, ink
//! `#c0caf5`, with the fixture's macro block as the prelude, and compared
//! line by line with `tests/fixtures/math/md_fixture.golden`:
//!
//! ```text
//! <index> ok <cols> <rows> <items>
//! <index> err <class>
//! ```
//!
//! `<index>` is the math's 1-based place among all the fixture's maths (as
//! the math grammar numbers its placeholders) and `<items>` the length of
//! its display list. No pixel hashes: anti-aliased bytes differ between
//! CPU architectures. A change of RaTeX shows here first.
//!
//! `JNV_MATH_GOLDEN=write` rewrites the golden file instead of comparing.
//! `JNV_MATH_PNG_DIR=<dir>` also writes each image there as `<index>.png`,
//! with a few samples (`sample-<name>.png`), to look at.

use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::time::Instant;

use jupynvim::mathgrammar::extract_math;
use jupynvim::mathimage::{engine, preprocess, typeset, wire::Request, MathErr, Typeset};

fn repo() -> PathBuf {
    PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../.."))
}

fn request<'a>(prelude: &'a str, tex: &'a str) -> Request<'a> {
    Request { fg: [0xc0, 0xca, 0xf5], cell_w: 10, cell_h: 20, scale: 1.0, max_cols: 297, max_rows: 60, prelude, tex }
}

fn run(prelude: &str, tex: &str) -> (Result<Typeset, MathErr>, usize) {
    let never = AtomicBool::new(false);
    let r = request(prelude, tex);
    let res = typeset(&r, &never);
    let items = match &res {
        Ok(_) => {
            let src = preprocess::prepare(prelude, tex).expect("it typeset");
            engine::layout(&src, r.fg).expect("it typeset").items.len()
        }
        Err(_) => 0,
    };
    (res, items)
}

const SAMPLES: [(&str, &str); 5] = [
    ("quadratic", r"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"),
    ("sum", r"\sum_{k=1}^{n} k^2 = \frac{n(n+1)(2n+1)}{6}"),
    ("matrix", r"A = \begin{pmatrix} a_{11} & a_{12} & a_{13} \\ a_{21} & a_{22} & a_{23} \\ a_{31} & a_{32} & a_{33} \end{pmatrix}"),
    ("aligned", r"\begin{aligned} f(x) &= (x + 1)^2 \\ &= x^2 + 2x + 1 \\ f'(x) &= 2x + 2 \end{aligned}"),
    ("user", r"I(t) \approx I'(t) = I_0 e^{t/\text{timeConstant}}"),
];

#[test]
fn the_fixture_formulas_match_the_golden_list() {
    let src = std::fs::read_to_string(repo().join("tests/fixtures/markdown/md-fixture.md")).expect("the fixture");
    let maths = extract_math(&src).maths;
    assert_eq!(maths.len(), 135, "the fixture's maths");
    let prelude = maths
        .iter()
        .find(|m| m.display && m.tex.contains(r"\newcommand{\RR}"))
        .map(|m| m.tex.clone())
        .expect("the macro block");
    let png_dir = std::env::var_os("JNV_MATH_PNG_DIR").map(PathBuf::from);

    let mut lines = Vec::new();
    let t = Instant::now();
    let mut count = 0u32;
    for (k, m) in maths.iter().enumerate() {
        if !m.display {
            continue;
        }
        count += 1;
        let (res, items) = run(&prelude, &m.tex);
        let index = k + 1;
        match res {
            Ok(ts) => {
                assert_eq!((ts.width, ts.height), (ts.cols * 10, ts.rows * 20), "{index}");
                lines.push(format!("{index} ok {} {} {items}", ts.cols, ts.rows));
                if let Some(dir) = &png_dir {
                    std::fs::write(dir.join(format!("{index}.png")), &ts.png).unwrap();
                }
            }
            Err(e) => lines.push(format!("{index} err {}", e.class())),
        }
    }
    let per = t.elapsed() / count.max(1);
    let text = lines.join("\n") + "\n";

    if let Some(dir) = &png_dir {
        for (name, tex) in SAMPLES {
            let t = Instant::now();
            let ts = run("", tex).0.unwrap_or_else(|e| panic!("{name}: {e:?}"));
            let el = t.elapsed();
            std::fs::write(dir.join(format!("sample-{name}.png")), &ts.png).unwrap();
            println!("sample {name}: {}x{} cells, {} bytes of PNG, {el:?}", ts.cols, ts.rows, ts.png.len());
        }
        println!("{count} display maths, {per:?} per formula (prelude, layout, drawing and PNG)");
    }

    let golden = repo().join("tests/fixtures/math/md_fixture.golden");
    if std::env::var("JNV_MATH_GOLDEN").as_deref() == Ok("write") {
        std::fs::write(&golden, &text).expect("writing the golden file");
    }
    let want = std::fs::read_to_string(&golden).expect("the golden file (JNV_MATH_GOLDEN=write makes it)");
    let (got, want): (Vec<&str>, Vec<&str>) = (text.lines().collect(), want.lines().collect());
    for (g, w) in got.iter().zip(&want) {
        assert_eq!(g, w, "a fixture formula typesets differently");
    }
    assert_eq!(got.len(), want.len(), "the number of display maths");

    // What the list must show whatever RaTeX does.
    let ok = got.iter().filter(|l| l.contains(" ok ")).count();
    assert!(ok >= 36, "only {ok} display maths typeset");
    let outcome = |needles: &[&str]| -> String {
        let k = maths
            .iter()
            .position(|m| m.display && needles.iter().all(|n| m.tex.contains(n)))
            .unwrap_or_else(|| panic!("{needles:?}"));
        let line = got.iter().find(|l| l.split(' ').next() == Some(&(k + 1).to_string())).unwrap();
        line.split_once(' ').unwrap().1.to_string()
    };
    assert_eq!(outcome(&[r"\newcommand{\RR}"]), "err empty", "the definitions block");
    assert_eq!(outcome(&[r"\begin{align}", r"\end{aligned}"]), "err parse", "the broken align/aligned pair");
    assert!(outcome(&[r"\label{eq:euler}"]).starts_with("ok "), "a numbered equation with a label");
    // The macros of the block carry to the (inline) maths that use them.
    for m in maths.iter().filter(|m| [r"\RR", r"\norm", r"\abs"].iter().any(|n| m.tex.contains(n)) && !m.display) {
        assert!(run(&prelude, &m.tex).0.is_ok(), "{} with the prelude", m.tex);
        assert_eq!(run("", &m.tex).0.map(|_| ()).unwrap_err().class(), "parse", "{} without", m.tex);
    }
}

#[test]
fn the_samples_typeset() {
    for (name, tex) in SAMPLES {
        let (res, items) = run("", tex);
        let ts = res.unwrap_or_else(|e| panic!("{name}: {e:?}"));
        assert!(items > 0 && ts.rows >= 1 && !ts.shrunk, "{name}");
    }
}
