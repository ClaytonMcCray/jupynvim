# Math image fixtures

`md_fixture.golden` is the regression list of the library's math images (`JNV_KIND_MATH`). `core/native/tests/math_image_fixture.rs` reads the shared markdown fixture in place (`../markdown/md-fixture.md`; nothing is copied here), extracts its 135 maths with the math grammar, and typesets each display math through `mathimage::typeset` with:

- cells of 10x20 pixels, scale 1 (one em is one cell height), at most 297 columns and 60 rows;
- ink `#c0caf5`;
- the fixture's macro block (the display math that defines `\RR`, `\norm` and `\abs`) as the prelude.

Each display math gives one line, in document order:

```
<index> ok <cols> <rows> <items>
<index> err <class>
```

`<index>` is the math's 1-based place among all 135 maths (the numbering of the math grammar's placeholders), `<cols>` and `<rows>` the image's size in cells, `<items>` the length of RaTeX's display list, and `<class>` the error class (`parse`, `glyph`, `size`, `empty`, ...). The list holds no pixel hashes: anti-aliased bytes differ between CPU architectures.

What it shows today: 39 display maths, 37 `ok`; `78 err empty` is the macro block itself (definitions only, nothing to draw); `133 err parse` is the deliberately broken `\begin{align} .. \end{aligned}` pair. The test also checks those two outcomes, that at least 36 typeset, and that the inline maths using the block's macros typeset with the prelude and fail without it.

A RaTeX upgrade shows here first. After checking that a difference is wanted, rewrite the list and look at a few images:

```sh
cd core
JNV_MATH_GOLDEN=write cargo test --release -p libjupynvim --test math_image_fixture
dir=$(mktemp -d)
JNV_MATH_PNG_DIR="$dir" cargo test --release -p libjupynvim --test math_image_fixture -- --nocapture
```

`JNV_MATH_PNG_DIR` writes every image as `<index>.png`, plus five samples (`sample-quadratic.png`, `sample-sum.png`, `sample-matrix.png`, `sample-aligned.png`, `sample-user.png`), and prints the time per formula. The images have a transparent background and light ink: view them on a dark background. Do not commit them.
