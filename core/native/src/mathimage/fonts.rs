//! The KaTeX fonts, embedded. They are the files of `fonts/katex/` (SIL Open
//! Font License 1.1, unmodified; see `OFL.txt` and `FONT_NOTICE.txt` there),
//! and the library reads no font from the system.

use ratex_font::FontId;

macro_rules! font {
    ($id:ident, $file:literal) => {
        (FontId::$id, $file, include_bytes!(concat!("../../fonts/katex/", $file)) as &[u8])
    };
}

/// The 19 fonts a `FontId` can name: id, file name, bytes.
/// `KaTeX_Caligraphic-Bold.ttf` is vendored with the set but no id names it.
pub const FONTS: [(FontId, &str, &[u8]); 19] = [
    font!(AmsRegular, "KaTeX_AMS-Regular.ttf"),
    font!(CaligraphicRegular, "KaTeX_Caligraphic-Regular.ttf"),
    font!(FrakturRegular, "KaTeX_Fraktur-Regular.ttf"),
    font!(FrakturBold, "KaTeX_Fraktur-Bold.ttf"),
    font!(MainBold, "KaTeX_Main-Bold.ttf"),
    font!(MainBoldItalic, "KaTeX_Main-BoldItalic.ttf"),
    font!(MainItalic, "KaTeX_Main-Italic.ttf"),
    font!(MainRegular, "KaTeX_Main-Regular.ttf"),
    font!(MathBoldItalic, "KaTeX_Math-BoldItalic.ttf"),
    font!(MathItalic, "KaTeX_Math-Italic.ttf"),
    font!(SansSerifBold, "KaTeX_SansSerif-Bold.ttf"),
    font!(SansSerifItalic, "KaTeX_SansSerif-Italic.ttf"),
    font!(SansSerifRegular, "KaTeX_SansSerif-Regular.ttf"),
    font!(ScriptRegular, "KaTeX_Script-Regular.ttf"),
    font!(Size1Regular, "KaTeX_Size1-Regular.ttf"),
    font!(Size2Regular, "KaTeX_Size2-Regular.ttf"),
    font!(Size3Regular, "KaTeX_Size3-Regular.ttf"),
    font!(Size4Regular, "KaTeX_Size4-Regular.ttf"),
    font!(TypewriterRegular, "KaTeX_Typewriter-Regular.ttf"),
];

/// Where `id` is in [`FONTS`]; `None` for the CJK and emoji fallbacks.
pub fn index(id: FontId) -> Option<usize> {
    FONTS.iter().position(|f| f.0 == id)
}

/// The font file of `id`; `None` for `CjkRegular`, `CjkFallback` and
/// `EmojiFallback`, which are system fonts we never load.
pub fn bytes(id: FontId) -> Option<&'static [u8]> {
    index(id).map(|i| FONTS[i].2)
}

/// File name and sha256 of the 20 vendored fonts and `OFL.txt`.
pub const FILES: [(&str, &str); 21] = [
    ("KaTeX_AMS-Regular.ttf", "68534840bcfdd2bffb6f0e8deb48684dd01e7f04ea2813267577afb906de1d13"),
    ("KaTeX_Caligraphic-Bold.ttf", "07d8e303ce4fc12b4bb54f1004170dd190a1f3db45d400fe68060df3e0897268"),
    ("KaTeX_Caligraphic-Regular.ttf", "ed0b74372feefcbb9c0666b2e210da37b7e49fa7fbbf3eeb11db5f693dacfbb7"),
    ("KaTeX_Fraktur-Bold.ttf", "9163df9c7122432e6495b4229fa9071cf9ae86a758ae5efc4924ec2e1a6dbce1"),
    ("KaTeX_Fraktur-Regular.ttf", "1e6f9579e90e2cac37f8f60a597c436e075c114385652b7cbeb0dec0421291b3"),
    ("KaTeX_Main-Bold.ttf", "138ac28d1663b3037e9c5f52371fa5c63d8324f4a38d22cd573e6ea3a3fd0cf8"),
    ("KaTeX_Main-BoldItalic.ttf", "70ee1f64a20f2048c21940ef46d0144fd215baa953ca69afd1e31e98544f708f"),
    ("KaTeX_Main-Italic.ttf", "0d85ae7cc30f23790a7f1a58c4a112fdca8aae769b6ba11429af1d98b1b6cb3a"),
    ("KaTeX_Main-Regular.ttf", "d0332f52868370fd83ae7fa46470f90c8f2eab2fcf12bc4f88080b340c95a830"),
    ("KaTeX_Math-BoldItalic.ttf", "f9377ab0271cda59af24bcffbd46a4d0c8a3572ffafdbb38de2ad5ea7b0d5ee5"),
    ("KaTeX_Math-Italic.ttf", "08ce98e51b04d58945a301e639e02b6998af29fdfd61a7b8afdd07bbfc479d4a"),
    ("KaTeX_SansSerif-Bold.ttf", "1ece03f79f95277d57dc7f6b435a74e1379b0d46104a8530286b60ff49369ea0"),
    ("KaTeX_SansSerif-Italic.ttf", "3931dd81faed86ba021bb2bbdc36f5bed9a38d6b4f4077aca59b265aa1b02083"),
    ("KaTeX_SansSerif-Regular.ttf", "f36ea897e19f4a2e571d1e900e4e3710e438deb05a842486045ba0a3e616a4ad"),
    ("KaTeX_Script-Regular.ttf", "1c67f068fea8bb09bf099c088b1cf64bd27516a6e07f4684344873564bb66a67"),
    ("KaTeX_Size1-Regular.ttf", "95b6d2f1a50173bfedb8c63e1d1c99b10427d0a4df4201cb44513b226951a22b"),
    ("KaTeX_Size2-Regular.ttf", "a6b2099fb555c60e3a0db3a08842ebf1d732c6eb4e4bf44913613bed4fc4e39b"),
    ("KaTeX_Size3-Regular.ttf", "500e04d54f0d51666332c9d2089aa803be22aa878eca539e59fa53c6e522b082"),
    ("KaTeX_Size4-Regular.ttf", "c647367d1dd4e162468717d020e1fc0f1dc5c26ebfdffbe55261713bf88c5877"),
    ("KaTeX_Typewriter-Regular.ttf", "f01f3e87d9c6a61c0c081ceb577abd864eb00a612f7ac1620dd6915fad2ef5aa"),
    ("OFL.txt", "f19c674290e5dc79f02e8efe16139ab56a06a7128876f5b1579ffd0db5bc897e"),
];

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    use std::path::PathBuf;

    fn dir() -> PathBuf {
        PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/fonts/katex/"))
    }

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    #[test]
    fn every_vendored_file_has_its_hash() {
        for (name, want) in FILES {
            let data = std::fs::read(dir().join(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
            assert_eq!(hex(&Sha256::digest(&data)), want, "{name}");
        }
        // The folder holds the 20 fonts, OFL.txt and FONT_NOTICE.txt only.
        let mut found: Vec<String> = std::fs::read_dir(dir())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        found.sort();
        let mut want: Vec<String> = FILES.iter().map(|f| f.0.to_string()).collect();
        want.push("FONT_NOTICE.txt".to_string());
        want.sort();
        assert_eq!(found, want);
    }

    #[test]
    fn each_embedded_font_is_its_file() {
        for (id, name, data) in FONTS {
            let file = std::fs::read(dir().join(name)).unwrap();
            assert!(data == file.as_slice(), "{name}");
            assert_eq!(name, format!("KaTeX_{}.ttf", id.as_str()), "{id:?}");
            assert_eq!(bytes(id).map(<[u8]>::len), Some(file.len()));
        }
    }

    #[test]
    fn bytes_names_the_19_and_not_the_fallbacks() {
        for (k, (id, _, _)) in FONTS.iter().enumerate() {
            // Each id once: its first place is its own.
            assert_eq!(index(*id), Some(k), "{id:?}");
            assert!(bytes(*id).is_some(), "{id:?}");
        }
        for id in [FontId::CjkRegular, FontId::CjkFallback, FontId::EmojiFallback] {
            assert_eq!(bytes(id), None, "{id:?}");
        }
    }

    #[test]
    fn every_font_parses_at_1000_units_per_em() {
        for (_, name, data) in FONTS {
            let face = ttf_parser::Face::parse(data, 0).unwrap_or_else(|e| panic!("{name}: {e}"));
            assert_eq!(face.units_per_em(), 1000, "{name}");
        }
    }
}
