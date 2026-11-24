//! TeX to a display list, through RaTeX's parser and layout (KaTeX's
//! grammar, metrics and fonts).
//!
//! The display list is in em: x grows right, y grows down from the top of
//! the box, the baseline is at `y = dl.height` and `dl.depth` lies below it.
//! A `GlyphPath`'s y is its baseline, a `Line`'s y its centre line, a
//! `Rect`'s y its top, and a `Path`'s commands are offsets from its x, y.
//!
//! RaTeX's own limits (input nesting 32, 1,000 macro expansions, 65,536
//! layout work units and output items) arrive as `Parse` or `Layout` errors.

use ratex_layout::{layout as lay_out, to_display_list, validate_layout, LayoutOptions};
use ratex_types::color::Color;
use ratex_types::display_item::DisplayList;
use ratex_types::math_style::MathStyle;

use super::MathErr;

/// Lay out `src` in display style, inked in `fg`.
pub fn layout(src: &str, fg: [u8; 3]) -> Result<DisplayList, MathErr> {
    // Parser::new, not the free parse(): that one strips outer `$` signs.
    let ast = ratex_parser::parser::Parser::new(src).parse().map_err(|e| MathErr::Parse(e.message))?;
    let color = Color::rgb(fg[0] as f32 / 255.0, fg[1] as f32 / 255.0, fg[2] as f32 / 255.0);
    let opts = LayoutOptions::default().with_style(MathStyle::Display).with_color(color);
    let lbox = lay_out(&ast, &opts);
    validate_layout(&lbox).map_err(MathErr::Layout)?;
    let dl = to_display_list(&lbox);
    if dl.items.is_empty() {
        return Err(MathErr::Empty);
    }
    Ok(dl)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratex_types::display_item::DisplayItem;

    const FG: [u8; 3] = [0xc0, 0xca, 0xf5];

    fn glyphs(dl: &DisplayList) -> Vec<char> {
        dl.items
            .iter()
            .filter_map(|it| match it {
                DisplayItem::GlyphPath { char_code, .. } => char::from_u32(*char_code),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn formulas_typeset() {
        for tex in [
            r"I(t) \approx I'(t) = I_0 e^{t/\text{timeConstant}}",
            r"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}",
            r"\sum_{k=1}^{n} k = \frac{n(n+1)}{2}",
            r"\begin{pmatrix} a & b \\ c & d \end{pmatrix}",
            r"\begin{aligned} f(x) &= (x+1)^2 \\ &= x^2 + 2x + 1 \end{aligned}",
        ] {
            let dl = layout(tex, FG).unwrap_or_else(|e| panic!("{tex}: {e:?}"));
            assert!(!dl.items.is_empty(), "{tex}");
            assert!(dl.width > 0.0 && dl.height + dl.depth > 0.0, "{tex}");
        }
    }

    #[test]
    fn the_ink_has_the_requested_colour() {
        let dl = layout("x", FG).unwrap();
        for it in &dl.items {
            if let DisplayItem::GlyphPath { color, .. } = it {
                assert_eq!((color.r * 255.0).round() as u8, 0xc0);
                assert_eq!((color.g * 255.0).round() as u8, 0xca);
                assert_eq!((color.b * 255.0).round() as u8, 0xf5);
            }
        }
    }

    #[test]
    fn errors_have_their_class() {
        match layout(r"\undefinedcommand", FG) {
            Err(MathErr::Parse(m)) => assert!(m.contains("undefinedcommand"), "{m}"),
            other => panic!("{other:?}"),
        }
        assert!(matches!(layout(r"\frac{1}", FG), Err(MathErr::Parse(_))));
        assert_eq!(layout("\\def\\a{b}\n\\let\\c\\d\n", FG).unwrap_err(), MathErr::Empty);
        assert_eq!(layout(" ", FG).unwrap_err(), MathErr::Empty);
    }

    #[test]
    fn a_tag_shows_in_a_starred_environment() {
        let dl = layout(r"\begin{equation*} x \tag{7} \end{equation*}", FG).unwrap();
        let g = glyphs(&dl);
        for c in ['(', '7', ')'] {
            assert!(g.contains(&c), "{g:?}");
        }
    }

    #[test]
    fn starred_environments_are_not_numbered() {
        let g = glyphs(&layout(r"\begin{align*} a &= b \end{align*}", FG).unwrap());
        assert!(!g.contains(&'1') && !g.contains(&'('), "{g:?}");
        // RaTeX numbers the unstarred one by itself, which the preprocessor avoids.
        let g = glyphs(&layout(r"\begin{align} a &= b \end{align}", FG).unwrap());
        assert!(g.contains(&'1'), "{g:?}");
    }
}
