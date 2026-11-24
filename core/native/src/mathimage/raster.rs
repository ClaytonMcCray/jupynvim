//! A display list to pixels: the canvas in whole terminal cells
//! ([`plan`]), the glyph check ([`check_glyphs`]) and the drawing
//! ([`draw`]), with the embedded KaTeX fonts, `ttf-parser` outlines and
//! `tiny-skia`.
//!
//! Every number of the display list is treated as hostile. `plan` checks
//! the box before it sizes anything; `draw` skips an item that is not
//! finite or that lies absurdly far away, clips everything to the canvas
//! in `f64` before `tiny-skia` sees an `f32`, and charges each item's
//! clipped area to an ink budget of 32 canvases, so a formula of thousands
//! of glyphs stacked on one spot fails instead of running for seconds.

use std::sync::atomic::{AtomicBool, Ordering};

use ratex_font::FontId;
use ratex_types::color::Color;
use ratex_types::display_item::{DisplayItem, DisplayList};
use ratex_types::path_command::PathCommand;
use tiny_skia::{FillRule, Paint, PathBuilder, PixmapMut, Rect, Stroke, Transform};
use ttf_parser::{Face, GlyphId};

use super::{fonts, MathErr, MAX_BOX_EM, MAX_GRID, MAX_PIXELS, MIN_SHRINK};

/// The farthest a glyph's or a path's pixel position may lie from the
/// canvas origin, and the largest glyph em in pixels, to be drawn at all.
const FAR: f64 = 1.0e6;

/// Canvases of ink one drawing may cover (each item counted by its clipped
/// bounding box), plus a floor for tiny canvases.
const INK_CANVASES: f64 = 32.0;
const INK_FLOOR: f64 = (1 << 20) as f64;

/// How the display list sits on the image.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Canvas {
    pub cols: u32,
    pub rows: u32,
    /// `cols * cell_w` and `rows * cell_h`.
    pub width: u32,
    pub height: u32,
    /// Pixels per em.
    pub ppem: f64,
    /// Pixel position of the display list's origin.
    pub ox: f64,
    pub oy: f64,
    /// Pixels from the top to the baseline.
    pub baseline: u32,
    pub shrunk: bool,
}

impl Canvas {
    /// The pixel of the display-list point `(x, y)` em, if it is finite and
    /// not absurdly far away.
    fn point(&self, x: f64, y: f64) -> Option<(f64, f64)> {
        let (px, py) = (self.ox + x * self.ppem, self.oy + y * self.ppem);
        (px.is_finite() && py.is_finite() && px.abs() <= FAR && py.abs() <= FAR).then_some((px, py))
    }
}

/// Size the image: one em is `scale` cell heights; the width a whole number
/// of cells with a margin of 6% of an em on each side (scaled down, to no
/// less than half, when it would pass `max_cols`); the height a whole
/// number of rows with the formula centred in them. `width == cols *
/// cell_w` and `height == rows * cell_h` always.
pub fn plan(dl: &DisplayList, cell_w: u32, cell_h: u32, scale: f64, max_cols: u32, max_rows: u32) -> Result<Canvas, MathErr> {
    if !(4..=256).contains(&cell_w)
        || !(4..=512).contains(&cell_h)
        || !(scale.is_finite() && (0.25..=4.0).contains(&scale))
        || !(1..=MAX_GRID).contains(&max_cols)
        || !(1..=MAX_GRID).contains(&max_rows)
    {
        return Err(MathErr::Request("the cell size, scale or grid is out of range".into()));
    }
    let (w, a, d) = (dl.width, dl.height, dl.depth);
    let ok = w.is_finite()
        && a.is_finite()
        && d.is_finite()
        && w >= 0.0
        && a + d >= 0.0
        && w <= MAX_BOX_EM
        && a.abs() <= MAX_BOX_EM
        && d.abs() <= MAX_BOX_EM;
    if !ok {
        return Err(MathErr::Size("the layout box is out of range".into()));
    }
    let (cw, ch) = (cell_w as f64, cell_h as f64);
    // Pixels per em: one em is `scale` rows.
    let natural = scale * ch;
    let mut ppem = natural;
    let mut shrunk = false;
    let mut cols;
    let mut pad;
    let mut tries = 0;
    loop {
        // Left and right margin, whole pixels.
        pad = (0.06 * ppem).round().max(1.0);
        let wpx = w * ppem;
        cols = (((wpx + 2.0 * pad) / cw).ceil() as u32).max(1);
        if cols <= max_cols {
            break;
        }
        // Too wide: scale down to fit, never below MIN_SHRINK of the natural
        // size. cols > max_cols implies wpx > 0.
        let avail = max_cols as f64 * cw - 2.0 * pad;
        let next = (ppem * avail / wpx).min(ppem * 0.99);
        tries += 1;
        if !(next >= MIN_SHRINK * natural) || tries > 8 {
            return Err(MathErr::Size(format!("too wide: {cols} columns, {max_cols} allowed")));
        }
        ppem = next;
        shrunk = true;
    }
    let hpx = (a + d) * ppem;
    // One pixel of slack: a formula exactly one em tall takes one row at scale 1.
    let rows = ((hpx - 1.0) / ch).ceil().max(1.0) as u32;
    if rows > max_rows {
        return Err(MathErr::Size(format!("too tall: {rows} rows, {max_rows} allowed")));
    }
    let (width, height) = (cols * cell_w, rows * cell_h);
    if width as u64 * height as u64 > MAX_PIXELS {
        return Err(MathErr::Size(format!("too many pixels: {width}x{height}")));
    }
    // Centred vertically in its rows, the baseline on a whole pixel.
    let top = (height as f64 - hpx) / 2.0;
    let baseline = (top + a * ppem).round();
    Ok(Canvas {
        cols,
        rows,
        width,
        height,
        ppem,
        ox: pad,
        oy: baseline - a * ppem,
        baseline: baseline.clamp(0.0, height as f64) as u32,
        shrunk,
    })
}

/// The embedded faces one call has parsed, by their place in
/// [`fonts::FONTS`].
struct Faces {
    faces: [Option<Face<'static>>; 19],
}

impl Faces {
    fn new() -> Self {
        Faces { faces: std::array::from_fn(|_| None) }
    }

    /// The face and glyph that draw `char_code` of `font`. No fallback to
    /// another font and no `.notdef` box: a glyph we cannot draw fails the
    /// formula, which then shows as text.
    fn glyph(&mut self, font: &str, char_code: u32) -> Result<(&Face<'static>, GlyphId), MathErr> {
        let id = FontId::parse(font).ok_or_else(|| MathErr::Glyph(format!("unknown font {font}")))?;
        let ch = ratex_font::katex_ttf_glyph_char(id, char_code);
        let k = fonts::index(id).ok_or_else(|| MathErr::Glyph(format!("U+{:04X} has no font ({font})", ch as u32)))?;
        let slot = &mut self.faces[k];
        if slot.is_none() {
            let face = Face::parse(fonts::FONTS[k].2, 0).map_err(|e| MathErr::Internal(format!("font {font}: {e}")))?;
            *slot = Some(face);
        }
        let Some(face) = slot.as_ref() else {
            return Err(MathErr::Internal(format!("font {font} did not load")));
        };
        let gid = face
            .glyph_index(ch)
            .filter(|g| g.0 != 0)
            .ok_or_else(|| MathErr::Glyph(format!("U+{:04X} is not in {font}", ch as u32)))?;
        Ok((face, gid))
    }
}

/// Every glyph of `dl` has a font and is in it. Draws nothing and
/// allocates no pixels.
pub fn check_glyphs(dl: &DisplayList) -> Result<(), MathErr> {
    let mut faces = Faces::new();
    for item in &dl.items {
        if let DisplayItem::GlyphPath { font, char_code, .. } = item {
            faces.glyph(font, *char_code)?;
        }
    }
    Ok(())
}

/// A glyph outline into a path; font y grows up, the canvas's down.
struct Pb(PathBuilder);

impl ttf_parser::OutlineBuilder for Pb {
    fn move_to(&mut self, x: f32, y: f32) {
        self.0.move_to(x, -y)
    }
    fn line_to(&mut self, x: f32, y: f32) {
        self.0.line_to(x, -y)
    }
    fn quad_to(&mut self, a: f32, b: f32, x: f32, y: f32) {
        self.0.quad_to(a, -b, x, -y)
    }
    fn curve_to(&mut self, a: f32, b: f32, c: f32, d: f32, x: f32, y: f32) {
        self.0.cubic_to(a, -b, c, -d, x, -y)
    }
    fn close(&mut self) {
        self.0.close()
    }
}

/// A colour component: clamped to 0..1, non-finite is 0 (alpha 1).
fn rgba8(c: &Color) -> [u8; 4] {
    let ch = |v: f32| if v.is_finite() { (v.clamp(0.0, 1.0) * 255.0).round() as u8 } else { 0 };
    let a = if c.a.is_finite() { (c.a.clamp(0.0, 1.0) * 255.0).round() as u8 } else { 255 };
    [ch(c.r), ch(c.g), ch(c.b), a]
}

fn paint(c: &Color, anti_alias: bool) -> Paint<'static> {
    let [r, g, b, a] = rgba8(c);
    let mut p = Paint::default();
    p.set_color_rgba8(r, g, b, a);
    p.anti_alias = anti_alias;
    p
}

/// What is left of the ink budget, in pixels.
struct Ink {
    left: f64,
}

impl Ink {
    fn spend(&mut self, area: f64) -> Result<(), MathErr> {
        self.left -= area;
        if self.left < 0.0 {
            return Err(MathErr::Size("too much ink: the formula's items cover the image too many times".into()));
        }
        Ok(())
    }
}

/// The part of `[x0, x1) x [y0, y1)` on a `w` by `h` canvas, or `None`.
fn clip(x0: f64, y0: f64, x1: f64, y1: f64, w: u32, h: u32) -> Option<(f64, f64, f64, f64)> {
    let (w, h) = (w as f64, h as f64);
    let (x0, x1) = (x0.max(0.0), x1.min(w));
    let (y0, y1) = (y0.max(0.0), y1.min(h));
    (x0 < x1 && y0 < y1).then_some((x0, y0, x1, y1))
}

fn clipped_area(x0: f64, y0: f64, x1: f64, y1: f64, w: u32, h: u32) -> f64 {
    clip(x0, y0, x1, y1, w, h).map_or(0.0, |(x0, y0, x1, y1)| (x1 - x0) * (y1 - y0))
}

/// Fill the whole pixels `[x0, x1) x [y0, y1)` (already rounded), clipped,
/// without anti-aliasing.
fn fill_px(pm: &mut PixmapMut<'_>, x0: f64, y0: f64, x1: f64, y1: f64, p: &Paint<'_>, ink: &mut Ink) -> Result<(), MathErr> {
    let (w, h) = (pm.width(), pm.height());
    let Some((x0, y0, x1, y1)) = clip(x0, y0, x1, y1, w, h) else { return Ok(()) };
    ink.spend((x1 - x0) * (y1 - y0))?;
    if let Some(r) = Rect::from_ltrb(x0 as f32, y0 as f32, x1 as f32, y1 as f32) {
        pm.fill_rect(r, p, Transform::identity(), None);
    }
    Ok(())
}

/// Draw `dl` on `cv`: straight-alpha RGBA8, `width * height * 4` bytes.
/// Checks `cancel` every 256 items.
pub fn draw(dl: &DisplayList, cv: &Canvas, cancel: &AtomicBool) -> Result<Vec<u8>, MathErr> {
    let (w, h) = (cv.width, cv.height);
    let pixels = w as u64 * h as u64;
    if pixels == 0 || pixels > MAX_PIXELS || !(cv.ppem.is_finite() && cv.ppem > 0.0) {
        return Err(MathErr::Size(format!("too many pixels: {w}x{h}")));
    }
    let n = pixels as usize * 4;
    let mut buf = Vec::new();
    buf.try_reserve_exact(n).map_err(|_| MathErr::Internal(format!("out of memory for {w}x{h} pixels")))?;
    buf.resize(n, 0);
    {
        let mut pm = PixmapMut::from_bytes(&mut buf, w, h)
            .ok_or_else(|| MathErr::Internal(format!("no pixmap of {w}x{h} pixels")))?;
        let mut faces = Faces::new();
        let mut ink = Ink { left: INK_CANVASES * pixels as f64 + INK_FLOOR };
        for (k, item) in dl.items.iter().enumerate() {
            if k % 256 == 0 && cancel.load(Ordering::Relaxed) {
                return Err(MathErr::Cancelled);
            }
            match item {
                DisplayItem::GlyphPath { x, y, scale, font, char_code, color } => {
                    draw_glyph(&mut pm, cv, &mut faces, &mut ink, (*x, *y, *scale), font, *char_code, color)?;
                }
                DisplayItem::Line { x, y, width, thickness, color, dashed } => {
                    draw_line(&mut pm, cv, &mut ink, (*x, *y, *width, *thickness), *dashed, color)?;
                }
                DisplayItem::Rect { x, y, width, height, color } => {
                    let pp = cv.ppem;
                    let x0 = (cv.ox + x * pp).round();
                    let x1 = (cv.ox + (x + width) * pp).round().max(x0 + 1.0);
                    let y0 = (cv.oy + y * pp).round();
                    let y1 = (cv.oy + (y + height) * pp).round().max(y0 + 1.0);
                    if [x0, x1, y0, y1].iter().all(|v| v.is_finite()) {
                        fill_px(&mut pm, x0, y0, x1, y1, &paint(color, false), &mut ink)?;
                    }
                }
                DisplayItem::Path { x, y, commands, fill, color } => {
                    draw_path(&mut pm, cv, &mut ink, (*x, *y), commands, *fill, color)?;
                }
            }
        }
    }
    unpremultiply(&mut buf);
    Ok(buf)
}

#[allow(clippy::too_many_arguments)]
fn draw_glyph(
    pm: &mut PixmapMut<'_>,
    cv: &Canvas,
    faces: &mut Faces,
    ink: &mut Ink,
    (x, y, scale): (f64, f64, f64),
    font: &str,
    char_code: u32,
    color: &Color,
) -> Result<(), MathErr> {
    let Some((px, py)) = cv.point(x, y) else { return Ok(()) };
    let (face, gid) = faces.glyph(font, char_code)?;
    let upem = face.units_per_em() as f64;
    let s = cv.ppem * scale / upem;
    if !(s.is_finite() && s > 0.0 && s * upem <= FAR) {
        return Ok(());
    }
    // No bounding box: a blank glyph such as a space.
    let Some(bb) = face.glyph_bounding_box(gid) else { return Ok(()) };
    let area = clipped_area(
        px + bb.x_min as f64 * s - 1.0,
        py - bb.y_max as f64 * s - 1.0,
        px + bb.x_max as f64 * s + 1.0,
        py - bb.y_min as f64 * s + 1.0,
        pm.width(),
        pm.height(),
    );
    if area <= 0.0 {
        return Ok(());
    }
    ink.spend(area)?;
    let mut pb = Pb(PathBuilder::new());
    if face.outline_glyph(gid, &mut pb).is_none() {
        return Ok(());
    }
    let Some(path) = pb.0.finish() else { return Ok(()) };
    let ts = Transform::from_row(s as f32, 0.0, 0.0, s as f32, px as f32, py as f32);
    pm.fill_path(&path, &paint(color, true), FillRule::Winding, ts, None);
    Ok(())
}

/// A rule snapped to whole pixels: at least one pixel thick and one wide.
fn draw_line(
    pm: &mut PixmapMut<'_>,
    cv: &Canvas,
    ink: &mut Ink,
    (x, y, width, thickness): (f64, f64, f64, f64),
    dashed: bool,
    color: &Color,
) -> Result<(), MathErr> {
    let pp = cv.ppem;
    let t = (thickness * pp).round().max(1.0);
    let top = (cv.oy + y * pp - t / 2.0).round();
    let x0 = (cv.ox + x * pp).round();
    let x1 = (cv.ox + (x + width) * pp).round().max(x0 + 1.0);
    if ![t, top, x0, x1].iter().all(|v| v.is_finite()) {
        return Ok(());
    }
    let p = paint(color, false);
    if !dashed {
        return fill_px(pm, x0, top, x1, top + t, &p, ink);
    }
    let dash = (4.0 * t).max(2.0);
    let period = 2.0 * dash;
    let right = x1.min(pm.width() as f64);
    // The last period that starts at or left of the canvas: `%` is exact,
    // so `start` is in (-period, 0] however far left the rule begins (an
    // accumulated `x0 + k * period` stops moving once x0 is huge). The
    // count of dashes is bounded by the canvas width.
    let start = if x0 < 0.0 { -((-x0) % period) } else { x0 };
    let n = ((right - start) / period).ceil().max(0.0) as usize;
    for k in 0..n {
        let sx = start + k as f64 * period;
        fill_px(pm, sx, top, (sx + dash).min(x1), top + t, &p, ink)?;
    }
    Ok(())
}

/// A path of em offsets from `(x, y)`. Filled: each sub-path on its own,
/// even-odd (KaTeX's stretchy arrows are sub-paths of opposite winding).
/// Not filled: stroked, `max(1, 0.04 em)` wide.
fn draw_path(
    pm: &mut PixmapMut<'_>,
    cv: &Canvas,
    ink: &mut Ink,
    (x, y): (f64, f64),
    commands: &[PathCommand],
    fill: bool,
    color: &Color,
) -> Result<(), MathErr> {
    let pt = |cx: f64, cy: f64| cv.point(x + cx, y + cy);
    // Every point in pixels, or nothing is drawn.
    let mut pts: Vec<(f32, f32)> = Vec::new();
    pts.try_reserve_exact(commands.len() * 3).map_err(|_| MathErr::Internal("out of memory for a path".into()))?;
    let (mut lo_x, mut lo_y, mut hi_x, mut hi_y) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
    for c in commands {
        let coords: &[(f64, f64)] = &match *c {
            PathCommand::MoveTo { x, y } | PathCommand::LineTo { x, y } => [(x, y), (x, y), (x, y)],
            PathCommand::QuadTo { x1, y1, x, y } => [(x1, y1), (x, y), (x, y)],
            PathCommand::CubicTo { x1, y1, x2, y2, x, y } => [(x1, y1), (x2, y2), (x, y)],
            PathCommand::Close => continue,
        };
        for &(cx, cy) in coords {
            let Some((px, py)) = pt(cx, cy) else { return Ok(()) };
            (lo_x, lo_y, hi_x, hi_y) = (lo_x.min(px), lo_y.min(py), hi_x.max(px), hi_y.max(py));
            pts.push((px as f32, py as f32));
        }
    }
    if pts.is_empty() {
        return Ok(());
    }
    let stroke_w = (0.04 * cv.ppem).max(1.0);
    let m = if fill { 1.0 } else { stroke_w + 1.0 };
    let area = clipped_area(lo_x - m, lo_y - m, hi_x + m, hi_y + m, pm.width(), pm.height());
    if area <= 0.0 {
        return Ok(());
    }
    ink.spend(area)?;
    let p = paint(color, true);
    // Build from the pixel points, in command order (three per command).
    let build = |cmds: &[PathCommand], first: usize| -> Option<tiny_skia::Path> {
        let mut b = PathBuilder::new();
        let mut k = first;
        for c in cmds {
            let at = |i: usize| pts[k + i];
            match c {
                PathCommand::MoveTo { .. } => b.move_to(at(0).0, at(0).1),
                PathCommand::LineTo { .. } => b.line_to(at(0).0, at(0).1),
                PathCommand::QuadTo { .. } => b.quad_to(at(0).0, at(0).1, at(1).0, at(1).1),
                PathCommand::CubicTo { .. } => b.cubic_to(at(0).0, at(0).1, at(1).0, at(1).1, at(2).0, at(2).1),
                PathCommand::Close => {
                    b.close();
                    continue;
                }
            }
            k += 3;
        }
        b.finish()
    };
    if fill {
        let mut start = 0;
        let mut first = 0;
        let mut k = 0;
        for (i, c) in commands.iter().enumerate() {
            if i > 0 && matches!(c, PathCommand::MoveTo { .. }) {
                if let Some(path) = build(&commands[start..i], first) {
                    pm.fill_path(&path, &p, FillRule::EvenOdd, Transform::identity(), None);
                }
                start = i;
                first = k;
            }
            if !matches!(c, PathCommand::Close) {
                k += 3;
            }
        }
        if let Some(path) = build(&commands[start..], first) {
            pm.fill_path(&path, &p, FillRule::EvenOdd, Transform::identity(), None);
        }
    } else if let Some(path) = build(commands, 0) {
        let stroke = Stroke { width: stroke_w as f32, ..Stroke::default() };
        pm.stroke_path(&path, &p, &stroke, Transform::identity(), None);
    }
    Ok(())
}

/// Premultiplied (as `tiny-skia` stores it) to straight alpha (as PNG
/// wants it): alpha 0 is `0,0,0,0`, alpha 255 is left as it is.
fn unpremultiply(buf: &mut [u8]) {
    for px in buf.chunks_exact_mut(4) {
        let a = px[3] as u32;
        if a == 0 {
            px[..3].fill(0);
        } else if a < 255 {
            for c in &mut px[..3] {
                *c = ((*c as u32 * 255 + a / 2) / a).min(255) as u8;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mathimage::engine;

    const FG: [u8; 3] = [0xc0, 0xca, 0xf5];

    fn bx(width: f64, height: f64, depth: f64) -> DisplayList {
        DisplayList { items: Vec::new(), width, height, depth }
    }

    #[test]
    fn plan_fills_whole_cells() {
        let boxes = [bx(0.0, 0.0, 0.0), bx(0.5, 0.7, 0.2), bx(3.3, 1.6, 0.9), bx(12.0, 2.5, 1.5), bx(1.0, 0.75, 0.25)];
        for (cw, chh) in [(4, 4), (9, 18), (14, 30), (18, 40), (256, 512)] {
            for scale in [0.25, 0.5, 0.9, 1.0, 1.3, 2.0, 4.0] {
                for b in &boxes {
                    let Ok(cv) = plan(b, cw, chh, scale, MAX_GRID, MAX_GRID) else { continue };
                    assert_eq!(cv.width, cv.cols * cw);
                    assert_eq!(cv.height, cv.rows * chh);
                    assert!(cv.cols >= 1 && cv.rows >= 1);
                    assert!(cv.baseline <= cv.height);
                    assert!(cv.ox >= 1.0 && cv.ox == cv.ox.round());
                    // The ink box fits the canvas.
                    let right = cv.ox + b.width * cv.ppem + cv.ox;
                    assert!(right <= cv.width as f64 + 1e-9, "{cw}x{chh} {scale} {b:?}: {cv:?}");
                    let (top, bottom) = (cv.oy, cv.oy + (b.height + b.depth) * cv.ppem);
                    assert!(top >= -1.0 && bottom <= cv.height as f64 + 1.0, "{cv:?}");
                }
            }
        }
    }

    #[test]
    fn one_em_at_scale_one_is_one_row() {
        for chh in [18, 30, 40] {
            let cv = plan(&bx(2.0, 0.75, 0.25), 9, chh, 1.0, 100, 10).unwrap();
            assert_eq!(cv.rows, 1);
            assert_eq!(cv.ppem, chh as f64);
            assert_eq!(cv.baseline as f64, (0.75 * chh as f64).round());
            let cv = plan(&bx(2.0, 0.75, 0.35), 9, chh, 1.0, 100, 10).unwrap();
            assert_eq!(cv.rows, 2);
        }
        // The pad is 6% of an em, at least one pixel; ink starts there.
        let cv = plan(&bx(1.0, 0.5, 0.0), 14, 30, 1.0, 100, 10).unwrap();
        assert_eq!(cv.ox, 2.0);
        let cv = plan(&bx(1.0, 0.5, 0.0), 4, 4, 1.0, 100, 10).unwrap();
        assert_eq!(cv.ox, 1.0);
    }

    #[test]
    fn too_wide_shrinks_then_fails() {
        // 20 em at 30 px is 600 px plus pads: 44 columns of 14.
        let natural = plan(&bx(20.0, 0.75, 0.25), 14, 30, 1.0, 100, 10).unwrap();
        assert!(!natural.shrunk && natural.cols == 44, "{natural:?}");
        let cv = plan(&bx(20.0, 0.75, 0.25), 14, 30, 1.0, 30, 10).unwrap();
        assert!(cv.shrunk && cv.cols <= 30, "{cv:?}");
        assert!(cv.ppem >= 0.5 * 30.0 && cv.ppem < 30.0, "{cv:?}");
        assert_eq!(cv.width, cv.cols * 14);
        match plan(&bx(20.0, 0.75, 0.25), 14, 30, 1.0, 20, 10) {
            Err(MathErr::Size(m)) => assert!(m.starts_with("too wide: ") && m.ends_with(" columns, 20 allowed"), "{m}"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn size_errors() {
        let size = |r: Result<Canvas, MathErr>| match r {
            Err(MathErr::Size(m)) => m,
            other => panic!("expected a size error, got {other:?}"),
        };
        assert!(size(plan(&bx(1.0, 30.0, 0.0), 14, 30, 1.0, 100, 10)).starts_with("too tall: 30 rows, 10 allowed"));
        assert!(size(plan(&bx(9.0, 8.0, 2.0), 256, 512, 1.0, 297, 297)).starts_with("too many pixels: "));
        for b in [
            bx(f64::NAN, 1.0, 0.0),
            bx(1.0, f64::INFINITY, 0.0),
            bx(1.0, 0.0, f64::NEG_INFINITY),
            bx(-1.0, 1.0, 0.0),
            bx(1.0, -2.0, 1.0),
            bx(MAX_BOX_EM * 2.0, 1.0, 0.0),
            bx(1.0, MAX_BOX_EM * 2.0, -MAX_BOX_EM * 2.0),
            bx(f64::MAX, f64::MAX, f64::MAX),
        ] {
            assert_eq!(size(plan(&b, 14, 30, 1.0, 297, 297)), "the layout box is out of range", "{b:?}");
        }
        for (cw, chh, sc, mc, mr) in [(0, 30, 1.0, 1, 1), (14, 0, 1.0, 1, 1), (14, 30, f64::NAN, 1, 1), (14, 30, 0.0, 1, 1), (14, 30, 1.0, 0, 1), (14, 30, 1.0, 1, 298), (u32::MAX, u32::MAX, 1.0, 297, 297)] {
            assert!(matches!(plan(&bx(1.0, 1.0, 0.0), cw, chh, sc, mc, mr), Err(MathErr::Request(_))));
        }
    }

    fn typeset_rgba(tex: &str, cw: u32, chh: u32) -> (Canvas, Vec<u8>) {
        let dl = engine::layout(tex, FG).unwrap();
        check_glyphs(&dl).unwrap();
        let cv = plan(&dl, cw, chh, 1.0, 100, 20).unwrap();
        let rgba = draw(&dl, &cv, &AtomicBool::new(false)).unwrap();
        assert_eq!(rgba.len(), (cv.width * cv.height * 4) as usize);
        (cv, rgba)
    }

    fn alpha(cv: &Canvas, rgba: &[u8], x: u32, y: u32) -> u8 {
        rgba[((y * cv.width + x) * 4 + 3) as usize]
    }

    #[test]
    fn pixels_are_straight_alpha_in_the_ink_colour() {
        for tex in ["x", r"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}", r"\sum_{k=1}^n k", r"\left( \int_0^1 f \right)"] {
            let (_, rgba) = typeset_rgba(tex, 14, 30);
            assert!(rgba.chunks_exact(4).any(|p| p[3] > 0), "{tex}");
            for p in rgba.chunks_exact(4) {
                match p[3] {
                    0 => assert_eq!(p, [0, 0, 0, 0], "{tex}"),
                    255 => assert_eq!(p[..3], FG, "{tex}"),
                    _ => {}
                }
            }
        }
    }

    #[test]
    fn x_sits_on_its_baseline_inside_the_canvas() {
        let (cv, rgba) = typeset_rgba("x", 14, 30);
        let ink: Vec<(u32, u32)> = (0..cv.height)
            .flat_map(|y| (0..cv.width).map(move |x| (x, y)))
            .filter(|&(x, y)| alpha(&cv, &rgba, x, y) > 0)
            .collect();
        assert!(!ink.is_empty());
        let left = ink.iter().map(|p| p.0).min().unwrap();
        let lowest = ink.iter().map(|p| p.1).max().unwrap();
        assert!(left >= 1, "no empty column on the left: {left}");
        assert!((lowest as i64 - (cv.baseline as i64 - 1)).abs() <= 1, "lowest {lowest}, baseline {}", cv.baseline);
    }

    #[test]
    fn a_fraction_bar_is_whole_rows() {
        let (cv, rgba) = typeset_rgba(r"\frac{1}{2}", 14, 30);
        let dl = engine::layout(r"\frac{1}{2}", FG).unwrap();
        let (x, y, width, thickness) = dl
            .items
            .iter()
            .find_map(|it| match it {
                DisplayItem::Line { x, y, width, thickness, .. } => Some((*x, *y, *width, *thickness)),
                _ => None,
            })
            .expect("a bar");
        let t = (thickness * cv.ppem).round().max(1.0) as u32;
        let top = (cv.oy + y * cv.ppem - t as f64 / 2.0).round() as u32;
        let x0 = (cv.ox + x * cv.ppem).round() as u32;
        let x1 = (cv.ox + (x + width) * cv.ppem).round() as u32;
        let mid = (x0 + x1) / 2;
        for row in top..top + t {
            for col in x0..x1 {
                assert_eq!(alpha(&cv, &rgba, col, row), 255, "bar pixel {col},{row}");
            }
        }
        assert_eq!(alpha(&cv, &rgba, mid, top - 1), 0, "above the bar");
        assert_eq!(alpha(&cv, &rgba, mid, top + t), 0, "below the bar");
    }

    #[test]
    fn a_rule_is_an_exact_rectangle() {
        let (cv, rgba) = typeset_rgba(r"\rule{2em}{1em}", 14, 30);
        let opaque: Vec<(u32, u32)> = (0..cv.height)
            .flat_map(|y| (0..cv.width).map(move |x| (x, y)))
            .filter(|&(x, y)| alpha(&cv, &rgba, x, y) == 255)
            .collect();
        let any = rgba.chunks_exact(4).filter(|p| p[3] > 0).count();
        assert_eq!(any, opaque.len(), "every inked pixel is opaque");
        let (x0, x1) = (opaque.iter().map(|p| p.0).min().unwrap(), opaque.iter().map(|p| p.0).max().unwrap() + 1);
        let (y0, y1) = (opaque.iter().map(|p| p.1).min().unwrap(), opaque.iter().map(|p| p.1).max().unwrap() + 1);
        assert_eq!((x1 - x0) as f64, (2.0 * cv.ppem).round());
        assert_eq!((y1 - y0) as f64, cv.ppem.round());
        assert_eq!(opaque.len() as u32, (x1 - x0) * (y1 - y0));
    }

    #[test]
    fn colour_commands_win() {
        let (_, rgba) = typeset_rgba(r"\color{red} x", 14, 30);
        let mut opaque = 0;
        for p in rgba.chunks_exact(4) {
            if p[3] == 255 {
                assert_eq!(p[..3], [255, 0, 0]);
                opaque += 1;
            }
        }
        assert!(opaque > 0);
    }

    #[test]
    fn a_missing_glyph_fails_before_drawing() {
        let dl = engine::layout(r"\text{日本語}", FG).unwrap();
        match check_glyphs(&dl) {
            Err(MathErr::Glyph(m)) => assert_eq!(m, "U+65E5 has no font (CJK-Regular)"),
            other => panic!("{other:?}"),
        }
        let dl = engine::layout("½", FG).unwrap();
        assert!(matches!(check_glyphs(&dl), Err(MathErr::Glyph(m)) if m.contains("U+00BD")));
        let odd = DisplayList {
            items: vec![DisplayItem::GlyphPath {
                x: 0.0,
                y: 0.0,
                scale: 1.0,
                font: "Nope".into(),
                char_code: 120,
                color: Color::BLACK,
            }],
            width: 1.0,
            height: 1.0,
            depth: 0.0,
        };
        assert_eq!(check_glyphs(&odd), Err(MathErr::Glyph("unknown font Nope".into())));
        // Accented text is built from glyphs the fonts have.
        assert!(check_glyphs(&engine::layout(r"\text{é}", FG).unwrap()).is_ok());
    }

    fn canvas(w: u32, h: u32) -> Canvas {
        Canvas { cols: w / 10, rows: h / 20, width: w, height: h, ppem: 20.0, ox: 1.0, oy: 1.0, baseline: 15, shrunk: false }
    }

    fn glyph(x: f64, y: f64, scale: f64) -> DisplayItem {
        DisplayItem::GlyphPath { x, y, scale, font: "Main-Regular".into(), char_code: 'M' as u32, color: Color::WHITE }
    }

    #[test]
    fn hostile_items_are_skipped_or_clipped() {
        let nan = f64::NAN;
        let inf = f64::INFINITY;
        let red = Color::new(f32::NAN, 2.0, -1.0, f32::NAN);
        let items = vec![
            glyph(nan, 0.5, 1.0),
            glyph(0.5, inf, 1.0),
            glyph(0.5, 0.5, nan),
            glyph(0.5, 0.5, -1.0),
            glyph(0.5, 0.5, 1e300),
            glyph(1e300, 0.5, 1.0),
            glyph(-1e7, 0.5, 1.0),
            DisplayItem::Line { x: nan, y: 0.5, width: 1.0, thickness: 0.1, color: red, dashed: false },
            DisplayItem::Line { x: -1e300, y: 0.5, width: 2e300, thickness: 1e300, color: red, dashed: true },
            DisplayItem::Line { x: -1e12, y: 0.5, width: 2e12, thickness: 0.05, color: red, dashed: true },
            DisplayItem::Line { x: -1e300, y: 0.5, width: 2e300, thickness: 0.05, color: red, dashed: true },
            DisplayItem::Line { x: -1e300, y: 0.5, width: 2e300, thickness: 1e306, color: red, dashed: true },
            DisplayItem::Line { x: 0.0, y: 0.5, width: -5.0, thickness: -1.0, color: red, dashed: false },
            DisplayItem::Rect { x: -1e300, y: -1e300, width: inf, height: 1e300, color: red },
            DisplayItem::Rect { x: 0.1, y: 0.1, width: 1e18, height: 1e18, color: red },
            DisplayItem::Path { x: 0.0, y: 0.0, commands: vec![PathCommand::MoveTo { x: nan, y: 0.0 }, PathCommand::LineTo { x: 1.0, y: 1.0 }], fill: true, color: red },
            DisplayItem::Path { x: 1e300, y: 0.0, commands: vec![PathCommand::MoveTo { x: 0.0, y: 0.0 }, PathCommand::LineTo { x: 1.0, y: 1.0 }], fill: false, color: red },
            DisplayItem::Path { x: 0.0, y: 0.0, commands: vec![PathCommand::Close, PathCommand::LineTo { x: 1.0, y: 1.0 }, PathCommand::Close], fill: true, color: red },
            DisplayItem::Path { x: 0.0, y: 0.0, commands: vec![], fill: false, color: red },
        ];
        let dl = DisplayList { items, width: 1.0, height: 1.0, depth: 0.0 };
        let cv = canvas(40, 40);
        let rgba = draw(&dl, &cv, &AtomicBool::new(false)).unwrap();
        assert_eq!(rgba.len(), 40 * 40 * 4);
        // No glyph was drawn (they are white); the colour (NaN, 2, -1, NaN)
        // is opaque green; rules and rects are never anti-aliased.
        assert!(rgba.chunks_exact(4).all(|p| p == [0, 0, 0, 0] || p == [0, 255, 0, 255]));
        // The rect of 1e18 em is clipped to the canvas.
        assert_eq!(rgba[(39 * 40 + 39) * 4..][..4], [0, 255, 0, 255]);
    }

    #[test]
    fn dashes_keep_their_period_from_far_left() {
        // x0 = round(1 - 10.3 * 20) = -205; one pixel thick: dashes of 4
        // every 8 pixels, the one through x = 0 starting at -205 + 200 = -5.
        let line = DisplayItem::Line { x: -10.3, y: 1.0, width: 20.0, thickness: 0.05, color: Color::WHITE, dashed: true };
        let dl = DisplayList { items: vec![line], width: 1.0, height: 1.0, depth: 0.0 };
        let cv = canvas(40, 40);
        let rgba = draw(&dl, &cv, &AtomicBool::new(false)).unwrap();
        let row = (1.0f64 + 20.0 - 0.5).round() as usize;
        let on: Vec<bool> = (0..40).map(|x| rgba[(row * 40 + x) * 4 + 3] == 255).collect();
        let want: Vec<bool> = (0..40).map(|x: i32| (x + 5).rem_euclid(8) < 4).collect();
        assert_eq!(on, want);
        let inked = rgba.chunks_exact(4).filter(|p| p[3] > 0).count();
        assert_eq!(inked, want.iter().filter(|&&b| b).count(), "one row only");
    }

    #[test]
    fn ink_stacked_on_one_spot_is_capped() {
        let cv = canvas(100, 100);
        let many = DisplayList { items: (0..2000).map(|_| glyph(0.0, 3.0, 4.0)).collect(), width: 1.0, height: 1.0, depth: 0.0 };
        match draw(&many, &cv, &AtomicBool::new(false)) {
            Err(MathErr::Size(m)) => assert!(m.starts_with("too much ink"), "{m}"),
            other => panic!("{:?}", other.map(|v| v.len())),
        }
        let few = DisplayList { items: (0..20).map(|_| glyph(0.0, 3.0, 4.0)).collect(), width: 1.0, height: 1.0, depth: 0.0 };
        assert!(draw(&few, &cv, &AtomicBool::new(false)).is_ok());
    }

    #[test]
    fn draw_stops_when_cancelled() {
        let dl = engine::layout("x", FG).unwrap();
        let cv = plan(&dl, 14, 30, 1.0, 100, 20).unwrap();
        assert_eq!(draw(&dl, &cv, &AtomicBool::new(true)), Err(MathErr::Cancelled));
    }

    #[test]
    fn unpremultiply_rounds() {
        let mut b = [0, 0, 0, 0, 10, 20, 30, 0, 64, 32, 0, 128, 1, 2, 3, 255, 255, 255, 255, 1];
        unpremultiply(&mut b);
        assert_eq!(b, [0, 0, 0, 0, 0, 0, 0, 0, 128, 64, 0, 128, 1, 2, 3, 255, 255, 255, 255, 1]);
    }
}
