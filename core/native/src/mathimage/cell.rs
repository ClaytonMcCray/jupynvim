//! The terminal's size in cells and pixels (`JNV_KIND_MATH_CELL`), from
//! `TIOCGWINSZ`. Since Neovim 0.10 the editor process has no controlling
//! terminal, so `/dev/tty` fails there (ENXIO) while descriptors 2, 1 and 0
//! still reach the terminal; they are asked first. Nothing is ever read
//! from or written to any descriptor.
//!
//! Answer (status OK):
//!
//! ```text
//! JNC 1
//! cols 180
//! rows 50
//! xpixel 2520         0 when the terminal reports no pixels
//! ypixel 1500
//! source fd2          fd2, fd1, fd0 or tty
//! ```

/// One `TIOCGWINSZ` answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TermSize {
    pub cols: u16,
    pub rows: u16,
    pub xpixel: u16,
    pub ypixel: u16,
}

impl TermSize {
    fn full(&self) -> bool {
        self.cols != 0 && self.rows != 0 && self.xpixel != 0 && self.ypixel != 0
    }
}

/// The window size of the terminal on descriptor `fd`; `None` when `fd` is
/// not a terminal (or not open).
pub fn probe_fd(fd: i32) -> Option<TermSize> {
    let mut ws = libc::winsize { ws_row: 0, ws_col: 0, ws_xpixel: 0, ws_ypixel: 0 };
    // SAFETY: TIOCGWINSZ only writes one winsize into `ws`, which lives for
    // the call; any other descriptor makes the call fail and changes nothing.
    let r = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut ws) };
    (r == 0).then_some(TermSize { cols: ws.ws_col, rows: ws.ws_row, xpixel: ws.ws_xpixel, ypixel: ws.ws_ypixel })
}

/// Descriptors 2, 1 and 0, then `/dev/tty` (opened read-only, without
/// becoming the controlling terminal, and closed at once): the first answer
/// with all four numbers, else the first answer at all (a terminal that
/// reports no pixels), with where it came from.
pub fn probe() -> Option<(TermSize, &'static str)> {
    let mut first = None;
    for (fd, label) in [(2, "fd2"), (1, "fd1"), (0, "fd0")] {
        if let Some(t) = probe_fd(fd) {
            if t.full() {
                return Some((t, label));
            }
            first.get_or_insert((t, label));
        }
    }
    let flags = libc::O_RDONLY | libc::O_NOCTTY | libc::O_CLOEXEC | libc::O_NONBLOCK;
    // SAFETY: the path is a NUL-terminated literal; open only reads it.
    let fd = unsafe { libc::open(c"/dev/tty".as_ptr(), flags) };
    if fd >= 0 {
        let t = probe_fd(fd);
        // SAFETY: `fd` was opened just above, is not shared, and is closed once.
        unsafe { libc::close(fd) };
        if let Some(t) = t {
            if t.full() {
                return Some((t, "tty"));
            }
            first.get_or_insert((t, "tty"));
        }
    }
    first
}

/// JNV_KIND_MATH_CELL: no input; the answer text, or `math cell: no
/// terminal`.
pub fn run(input: &[u8]) -> Result<Vec<u8>, String> {
    if !input.is_empty() {
        return Err("math cell: no input is expected".to_string());
    }
    let (t, source) = probe().ok_or_else(|| "math cell: no terminal".to_string())?;
    Ok(format!(
        "JNC 1\ncols {}\nrows {}\nxpixel {}\nypixel {}\nsource {source}\n",
        t.cols, t.rows, t.xpixel, t.ypixel
    )
    .into_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::sync::Mutex;

    /// `ptsname` answers in a static buffer: one caller at a time.
    static PTSNAME: Mutex<()> = Mutex::new(());

    /// A pseudo-terminal: its master and its opened slave. Not `openpty`,
    /// which old glibc keeps in libutil.
    fn pty() -> (OwnedFd, OwnedFd) {
        // SAFETY: plain calls on a descriptor this test owns; ptsname's
        // static buffer is copied out under the lock before anyone else can
        // call it, and each returned descriptor is owned exactly once.
        unsafe {
            let m = libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY);
            assert!(m >= 0, "posix_openpt");
            let master = OwnedFd::from_raw_fd(m);
            assert_eq!(libc::grantpt(m), 0, "grantpt");
            assert_eq!(libc::unlockpt(m), 0, "unlockpt");
            let path = {
                let _g = PTSNAME.lock().unwrap_or_else(|e| e.into_inner());
                let p = libc::ptsname(m);
                assert!(!p.is_null(), "ptsname");
                CStr::from_ptr(p).to_owned()
            };
            let s = libc::open(path.as_ptr(), libc::O_RDWR | libc::O_NOCTTY);
            assert!(s >= 0, "open {path:?}");
            (master, OwnedFd::from_raw_fd(s))
        }
    }

    fn set_size(fd: &OwnedFd, cols: u16, rows: u16, xpixel: u16, ypixel: u16) {
        let ws = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: xpixel, ws_ypixel: ypixel };
        // SAFETY: TIOCSWINSZ only reads the winsize passed, on a descriptor the test owns.
        let r = unsafe { libc::ioctl(fd.as_raw_fd(), libc::TIOCSWINSZ, &ws) };
        assert_eq!(r, 0, "TIOCSWINSZ");
    }

    #[test]
    fn a_pseudo_terminal_reports_its_size() {
        let (_master, slave) = pty();
        set_size(&slave, 80, 24, 800, 480);
        assert_eq!(probe_fd(slave.as_raw_fd()), Some(TermSize { cols: 80, rows: 24, xpixel: 800, ypixel: 480 }));
        set_size(&slave, 132, 43, 0, 0);
        let t = probe_fd(slave.as_raw_fd()).unwrap();
        assert_eq!(t, TermSize { cols: 132, rows: 43, xpixel: 0, ypixel: 0 });
        assert!(!t.full());
    }

    #[test]
    fn a_pipe_or_a_closed_descriptor_is_none() {
        let (r, w) = std::io::pipe().unwrap();
        let rfd = OwnedFd::from(r);
        let wfd = OwnedFd::from(w);
        assert_eq!(probe_fd(rfd.as_raw_fd()), None);
        assert_eq!(probe_fd(wfd.as_raw_fd()), None);
        assert_eq!(probe_fd(-1), None);
        assert_eq!(probe_fd(i32::MAX), None);
    }

    #[test]
    fn run_answers_or_says_no_terminal() {
        assert_eq!(run(b"x"), Err("math cell: no input is expected".to_string()));
        match run(b"") {
            Ok(out) => {
                let text = String::from_utf8(out).unwrap();
                let lines: Vec<&str> = text.lines().collect();
                assert_eq!(lines.len(), 6, "{text}");
                assert_eq!(lines[0], "JNC 1");
                for (line, key) in lines[1..5].iter().zip(["cols ", "rows ", "xpixel ", "ypixel "]) {
                    let n = line.strip_prefix(key).unwrap_or_else(|| panic!("{text}"));
                    assert!(n.parse::<u16>().is_ok(), "{text}");
                }
                assert!(["source fd2", "source fd1", "source fd0", "source tty"].contains(&lines[5]), "{text}");
                assert!(text.ends_with('\n'));
            }
            Err(m) => assert_eq!(m, "math cell: no terminal"),
        }
    }
}
