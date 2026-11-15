//! Straight-alpha RGBA8 pixels to an 8-bit RGBA PNG.

use super::MathErr;

/// Encode `rgba` (`width * height * 4` bytes) as a PNG, fast compression.
pub fn encode_rgba(rgba: &[u8], width: u32, height: u32) -> Result<Vec<u8>, MathErr> {
    let want = width as u64 * height as u64 * 4;
    if width == 0 || height == 0 || rgba.len() as u64 != want {
        return Err(MathErr::Internal(format!("png: {} bytes for {width}x{height} pixels", rgba.len())));
    }
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, width, height);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_compression(png::Compression::Fast);
        let mut w = enc.write_header().map_err(|e| MathErr::Internal(format!("png: {e}")))?;
        w.write_image_data(rgba).map_err(|e| MathErr::Internal(format!("png: {e}")))?;
        w.finish().map_err(|e| MathErr::Internal(format!("png: {e}")))?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_the_decoder() {
        let (w, h) = (7u32, 3u32);
        let rgba: Vec<u8> = (0..w * h * 4).map(|i| (i * 37 % 256) as u8).collect();
        let png = encode_rgba(&rgba, w, h).unwrap();
        assert!(png.starts_with(b"\x89PNG\r\n\x1a\n"));
        let dec = png::Decoder::new(std::io::Cursor::new(&png));
        let mut reader = dec.read_info().unwrap();
        let mut buf = vec![0; reader.output_buffer_size().unwrap()];
        let info = reader.next_frame(&mut buf).unwrap();
        assert_eq!((info.width, info.height), (w, h));
        assert_eq!((info.color_type, info.bit_depth), (png::ColorType::Rgba, png::BitDepth::Eight));
        assert_eq!(&buf[..info.buffer_size()], rgba.as_slice());
    }

    #[test]
    fn a_wrong_length_is_internal() {
        assert!(matches!(encode_rgba(&[0; 15], 2, 2), Err(MathErr::Internal(m)) if m.starts_with("png: 15 bytes")));
        assert!(matches!(encode_rgba(&[], 0, 0), Err(MathErr::Internal(_))));
    }
}
