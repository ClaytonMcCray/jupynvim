//! Before RaTeX: notebook TeX written for MathJax rewritten to forms RaTeX
//! has ([`rewrite`]), and the macro definitions taken out of the notebook's
//! markdown source ([`definitions`]), put in front of the formula
//! ([`prepare`]), after [`NO_CHEMISTRY`], which turns mhchem off.
//!
//! The scanner reads the bytes the way RaTeX's lexer splits them into
//! tokens: a control word is a backslash and the longest run of ASCII
//! letters and `@`; any other control sequence is the backslash and one
//! whole character; `\verb` takes its delimited text; `%` comments to the
//! end of its line; and `{`, `}`, `[`, `]`, `&`, `#`, `*` and `=` are only
//! themselves when no combining mark (U+0300 to U+036F) follows, since the
//! lexer joins such a mark to the character before it. Every delimiter is
//! ASCII, so the scanner only cuts the text on character boundaries.
//!
//! Hostile text cannot make it slow: the main passes visit each byte a
//! bounded number of times, and every look-ahead scan (for the end of a
//! group, a bracket, a `\verb`, an environment) is charged to a budget of
//! 32 steps per input byte. Once the budget is spent, look-aheads find
//! nothing and the rest is copied as it is.
//!
//! What [`definitions`] writes is always well formed for RaTeX's `\def` and
//! `\let`: a control sequence name, ordered parameters `#1`..`#9`, and a body
//! that is balanced under the lexer's own rules. So the macro source of one
//! cell can never make another cell's formula fail where it is defined.

use super::{MathErr, MAX_PRELUDE, MAX_TEX};

/// The start of every prepared source: mhchem's `\ce` and `\pu` made
/// aliases of a name nothing defines, so a chemistry formula fails at its
/// first `\ce` or `\pu` with a parse error and shows as text.
///
/// RaTeX's mhchem parser takes time that grows with the square of its
/// argument (seconds for a few kilobytes) and no flag stops it, so it must
/// never see notebook text. Why nothing in the notebook can reach it:
///
/// - `\ce` and `\pu` are its only entry points, and RaTeX looks a name up
///   in the definitions made during the parse before its built-in ones.
/// - These two `\let`s are the parse's first tokens, read before anything
///   from the notebook, in the parse's outermost group. Every group RaTeX
///   opens is closed in the same order, so that outermost one, which alone
///   could put the built-in `\ce` back, ends only with the parse; a group,
///   an environment or a table cell restores these aliases when it closes.
/// - Any later route ends at a lookup of the name: a macro whose body uses
///   `\ce` (from the prelude or the formula), an alias made later with
///   `\let` or `\futurelet` (it copies these aliases), `\global`, or the
///   name inside `\text`. A redefinition (`\def`, `\renewcommand`) makes an
///   ordinary macro of the notebook's own.
/// - RaTeX has no `\csname` or `\expandafter` to build a name from pieces,
///   a control word is only ASCII letters (a combining mark after `\ce` is
///   a token of its own), and `\jnvnomhchem` reaches the parser marked as
///   not expandable, so defining it does not help either.
///
/// The trailing blank ends the last control word, so the definitions or
/// the formula that follow can start with letters.
pub const NO_CHEMISTRY: &str = "\\let\\ce\\jnvnomhchem\\let\\pu\\jnvnomhchem ";

/// [`NO_CHEMISTRY`], the macro definitions of `prelude`, then the
/// rewritten `tex`. Too long is `Input`; nothing but blanks after the
/// rewrite is `Empty`.
pub fn prepare(prelude: &str, tex: &str) -> Result<String, MathErr> {
    if tex.len() > MAX_TEX {
        return Err(MathErr::Input(format!("the formula is {} bytes, at most {MAX_TEX}", tex.len())));
    }
    if prelude.len() > MAX_PRELUDE {
        return Err(MathErr::Input(format!("the prelude is {} bytes, at most {MAX_PRELUDE}", prelude.len())));
    }
    let body = rewrite(tex);
    if body.trim().is_empty() {
        return Err(MathErr::Empty);
    }
    let defs = definitions(prelude);
    let mut src = String::with_capacity(NO_CHEMISTRY.len() + defs.len() + body.len());
    src.push_str(NO_CHEMISTRY);
    src.push_str(&defs);
    src.push_str(&body);
    Ok(src)
}

/// Only the macro definitions of `src` (raw markdown), each written as a
/// `\def` or `\let` and followed by a LF; everything else is skipped.
pub fn definitions(src: &str) -> String {
    let s = src.as_bytes();
    let lim = s.len();
    let mut sc = Sc { s, left: budget(lim) };
    let mut out = Vec::new();
    let mut i = 0;
    while i < lim {
        match s[i] {
            b'%' => i = sc.line_end(i, lim),
            b'\\' => {
                let e = sc.cs_end(i, lim);
                let next = match &s[i + 1..e] {
                    b"newcommand" | b"renewcommand" | b"providecommand" => sc.take_newcommand(e, lim, &mut out),
                    b"DeclareMathOperator" => sc.take_operator(e, lim, &mut out),
                    b"def" | b"gdef" => sc.take_def(e, lim, &mut out),
                    b"let" => sc.take_let(e, lim, &mut out),
                    _ => None,
                };
                i = next.unwrap_or(e);
            }
            _ => i += 1,
        }
    }
    into_string(out)
}

/// `tex` with the constructs RaTeX lacks rewritten (see the module tests
/// for each one): `\label` and `\require` dropped, `\mbox` as `\text`,
/// `\mspace` as `\mkern`, `\bbox`, `\class`, `\cssId` and `\style` reduced
/// to their content, `\unicode` as the character, `\DeclareMathOperator`
/// and `\newcommand` and its kin as `\def`, numbered environments as their
/// starred forms, `flalign` as `align*`, `multline` as `gather*`,
/// `eqnarray` as `aligned`, `displaymath` and `subequations` dropped.
pub fn rewrite(tex: &str) -> String {
    let s = tex.as_bytes();
    let lim = s.len();
    let mut sc = Sc { s, left: budget(lim) };
    let mut out = Out::new();
    sc.rewrite_range(0, lim, true, 0, &mut out);
    into_string(out.buf)
}

/// Look-ahead steps one call may take: 32 per input byte.
fn budget(n: usize) -> usize {
    n.saturating_mul(32).saturating_add(4096)
}

/// How deep rewrites nest: a definition body, the rows of an `eqnarray`
/// and an `eqnarray*` inside it need four; more is never well formed.
const MAX_NEST: u32 = 6;

/// Names a definition taken from the prelude never gets: they would break
/// the definitions after it, or the lexer would read past its line.
const SKIPPED_NAMES: [&[u8]; 13] = [
    b"\\begin",
    b"\\end",
    b"\\def",
    b"\\gdef",
    b"\\edef",
    b"\\xdef",
    b"\\let",
    b"\\global",
    b"\\long",
    b"\\newcommand",
    b"\\renewcommand",
    b"\\providecommand",
    b"\\verb",
];

fn into_string(b: Vec<u8>) -> String {
    // The scanner only cuts at character boundaries; the fallback never runs.
    String::from_utf8(b).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())
}

fn is_word(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'@'
}

fn is_blank(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\r' | b'\n')
}

/// Bytes of the UTF-8 character whose first byte is `b`.
fn char_len(b: u8) -> usize {
    match b {
        0x00..=0x7f => 1,
        0xc0..=0xdf => 2,
        0xe0..=0xef => 3,
        0xf0..=0xff => 4,
        _ => 1,
    }
}

/// A combining mark U+0300 to U+036F starts at `i`.
fn combining(s: &[u8], i: usize) -> bool {
    match (s.get(i), s.get(i + 1)) {
        (Some(0xcc), Some(&b)) => (0x80..=0xbf).contains(&b),
        (Some(0xcd), Some(&b)) => (0x80..=0xaf).contains(&b),
        _ => false,
    }
}

/// `s[i]` is the token `b` (no combining mark joined to it).
fn plain_in(s: &[u8], i: usize, b: u8) -> bool {
    s.get(i) == Some(&b) && !combining(s, i + 1)
}

/// The rewrite's output, and where the last control word written ends.
struct Out {
    buf: Vec<u8>,
    cw_end: usize,
}

impl Out {
    fn new() -> Self {
        Out { buf: Vec::new(), cw_end: usize::MAX }
    }

    fn copy(&mut self, b: &[u8]) {
        self.buf.extend_from_slice(b);
    }

    /// Write a control word.
    fn word(&mut self, b: &[u8]) {
        self.buf.extend_from_slice(b);
        self.cw_end = self.buf.len();
    }

    fn ends_with_word(&self) -> bool {
        self.cw_end == self.buf.len()
    }

    /// After text was dropped and scanning resumes at `s[next]`: a control
    /// word written last must not run into the letters that follow
    /// (`\alpha\label{x}b` is `\alpha b`, never `\alphab`).
    fn gap(&mut self, s: &[u8], next: usize, lim: usize) {
        if self.ends_with_word() && next < lim && is_word(s[next]) {
            self.buf.push(b' ');
        }
    }
}

/// A row of an `eqnarray` body: `[start, end)`, the separator after it
/// ends at `sep_end`, and `amp` is its own second `&` (outside braces and
/// inner environments).
struct Row {
    start: usize,
    end: usize,
    sep_end: usize,
    amp: Option<usize>,
}

/// A `\newcommand` form: the name, the argument count, the body (inside
/// its braces) and where the form ends.
struct NewCommand {
    name: (usize, usize),
    args: u8,
    body: (usize, usize),
    end: usize,
}

/// The bytes being scanned and what is left of the look-ahead budget.
struct Sc<'a> {
    s: &'a [u8],
    left: usize,
}

impl Sc<'_> {
    /// Charge `n` look-ahead steps; false once the budget is spent.
    fn spend(&mut self, n: usize) -> bool {
        if self.left < n {
            self.left = 0;
            false
        } else {
            self.left -= n;
            true
        }
    }

    fn plain(&self, i: usize, lim: usize, b: u8) -> bool {
        i < lim && plain_in(self.s, i, b)
    }

    fn skip_blanks(&self, mut i: usize, lim: usize) -> usize {
        while i < lim && is_blank(self.s[i]) {
            i += 1;
        }
        i
    }

    /// The end of the control sequence at `i` (`s[i]` is a backslash).
    fn cs_end(&self, i: usize, lim: usize) -> usize {
        let s = self.s;
        let j = i + 1;
        if j >= lim {
            return lim;
        }
        if is_word(s[j]) {
            let mut k = j;
            while k < lim && is_word(s[k]) {
                k += 1;
            }
            k
        } else {
            (j + char_len(s[j])).min(lim)
        }
    }

    /// The end of the text of `\verb` whose name ends at `e`: an optional
    /// `*`, a delimiter character, everything through the same character
    /// again, or everything to `lim` (RaTeX's lexer does the same).
    fn verb_end(&self, e: usize, lim: usize) -> usize {
        let s = self.s;
        let mut j = e;
        if j < lim && s[j] == b'*' {
            j += 1;
        }
        if j >= lim {
            return lim;
        }
        let d = (j + char_len(s[j])).min(lim);
        let delim = &s[j..d];
        j = d;
        while j < lim {
            if s[j..lim].starts_with(delim) {
                return j + delim.len();
            }
            j += 1;
        }
        lim
    }

    /// After the LF that ends the comment at `i`, or `lim`.
    fn line_end(&self, i: usize, lim: usize) -> usize {
        match self.s[i..lim].iter().position(|&b| b == b'\n') {
            Some(p) => i + p + 1,
            None => lim,
        }
    }

    /// The end of the token at `i`: a control sequence (`\verb` with its
    /// text), a comment through its LF, or one byte.
    fn tok_end(&self, i: usize, lim: usize) -> usize {
        match self.s[i] {
            b'\\' => {
                let e = self.cs_end(i, lim);
                if &self.s[i..e] == b"\\verb" {
                    self.verb_end(e, lim)
                } else {
                    e
                }
            }
            b'%' => self.line_end(i, lim),
            _ => i + 1,
        }
    }

    /// `s[i]` is a plain `{`: the index after its matching `}`.
    fn group_end(&mut self, i: usize, lim: usize) -> Option<usize> {
        let s = self.s;
        let mut depth = 0usize;
        let mut j = i;
        while j < lim {
            let next = match s[j] {
                b'{' if plain_in(s, j, b'{') => {
                    depth += 1;
                    j + 1
                }
                b'}' if plain_in(s, j, b'}') => {
                    depth = depth.checked_sub(1)?;
                    if depth == 0 {
                        return self.spend(1).then_some(j + 1);
                    }
                    j + 1
                }
                b'\\' | b'%' => self.tok_end(j, lim),
                _ => j + 1,
            };
            if !self.spend(next - j) {
                return None;
            }
            j = next;
        }
        None
    }

    /// A group at `i`, if there is one: the index after it.
    fn group_at(&mut self, i: usize, lim: usize) -> Option<usize> {
        if self.plain(i, lim, b'{') {
            self.group_end(i, lim)
        } else {
            None
        }
    }

    /// `s[i]` is a plain `[`: the index after the first plain `]` at brace
    /// depth 0. A `}` that closes nothing ends the search.
    fn bracket_end(&mut self, i: usize, lim: usize) -> Option<usize> {
        let s = self.s;
        let mut depth = 0usize;
        let mut j = i + 1;
        while j < lim {
            let next = match s[j] {
                b'{' if plain_in(s, j, b'{') => {
                    depth += 1;
                    j + 1
                }
                b'}' if plain_in(s, j, b'}') => {
                    depth = depth.checked_sub(1)?;
                    j + 1
                }
                b']' if depth == 0 && plain_in(s, j, b']') => return self.spend(1).then_some(j + 1),
                b'\\' | b'%' => self.tok_end(j, lim),
                _ => j + 1,
            };
            if !self.spend(next - j) {
                return None;
            }
            j = next;
        }
        None
    }

    /// A control sequence of at least one character after the backslash at
    /// `i`, never `\verb`: its range.
    fn cs_name(&self, i: usize, lim: usize) -> Option<(usize, usize)> {
        if i >= lim || self.s[i] != b'\\' {
            return None;
        }
        let e = self.cs_end(i, lim);
        (e - i >= 2 && &self.s[i..e] != b"\\verb").then_some((i, e))
    }

    /// NAME at `i`: `{` blanks control-sequence blanks `}`, or a bare
    /// control sequence. Its range and where it ends.
    fn name_at(&self, i: usize, lim: usize) -> Option<((usize, usize), usize)> {
        if self.plain(i, lim, b'{') {
            let k = self.skip_blanks(i + 1, lim);
            let name = self.cs_name(k, lim)?;
            let m = self.skip_blanks(name.1, lim);
            self.plain(m, lim, b'}').then_some((name, m + 1))
        } else {
            let name = self.cs_name(i, lim)?;
            Some((name, name.1))
        }
    }

    /// After `\newcommand` (ending at `e`): optional `*`, blanks, NAME,
    /// blanks, optional `[n]` with one digit, blanks, `{B}`. A second `[`
    /// (a default argument, which KaTeX does not have) does not match.
    fn newcommand_form(&mut self, e: usize, lim: usize) -> Option<NewCommand> {
        let s = self.s;
        let mut j = e;
        if self.plain(j, lim, b'*') {
            j += 1;
        }
        j = self.skip_blanks(j, lim);
        let (name, after) = self.name_at(j, lim)?;
        j = self.skip_blanks(after, lim);
        let mut args = 0u8;
        if self.plain(j, lim, b'[') {
            let k = self.skip_blanks(j + 1, lim);
            if k >= lim || !s[k].is_ascii_digit() || combining(s, k + 1) {
                return None;
            }
            args = s[k] - b'0';
            let m = self.skip_blanks(k + 1, lim);
            if !self.plain(m, lim, b']') {
                return None;
            }
            j = self.skip_blanks(m + 1, lim);
        }
        if self.plain(j, lim, b'[') {
            return None;
        }
        let g = self.group_at(j, lim)?;
        Some(NewCommand { name, args, body: (j + 1, g - 1), end: g })
    }

    /// After `\DeclareMathOperator` (ending at `e`): optional `*`, blanks,
    /// NAME, blanks, `{B}`. The form (no arguments), and whether it has the
    /// star.
    fn operator_form(&mut self, e: usize, lim: usize) -> Option<(NewCommand, bool)> {
        let mut j = e;
        let star = self.plain(j, lim, b'*');
        if star {
            j += 1;
        }
        j = self.skip_blanks(j, lim);
        let (name, after) = self.name_at(j, lim)?;
        j = self.skip_blanks(after, lim);
        let g = self.group_at(j, lim)?;
        Some((NewCommand { name, args: 0, body: (j + 1, g - 1), end: g }, star))
    }

    /// From `j`, the first plain `{` of a `\def` parameter text: tokens up
    /// to it, never a plain `}`.
    fn param_brace(&mut self, mut j: usize, lim: usize) -> Option<usize> {
        while j < lim {
            if self.plain(j, lim, b'{') {
                return Some(j);
            }
            if self.plain(j, lim, b'}') {
                return None;
            }
            let next = self.tok_end(j, lim);
            if !self.spend(next - j) {
                return None;
            }
            j = next;
        }
        None
    }

    /// From `j`, the first `\end` blanks `{name}`: where `\end` starts and
    /// where its group ends.
    fn find_end(&mut self, mut j: usize, lim: usize, name: &[u8]) -> Option<(usize, usize)> {
        let s = self.s;
        while j < lim {
            if s[j] == b'\\' && &s[j..self.cs_end(j, lim)] == b"\\end" {
                let e = self.cs_end(j, lim);
                let k = self.skip_blanks(e, lim);
                if let Some(g) = self.group_at(k, lim) {
                    if &s[k + 1..g - 1] == name {
                        return Some((j, g));
                    }
                }
            }
            let next = self.tok_end(j, lim);
            if !self.spend(next - j) {
                return None;
            }
            j = next;
        }
        None
    }

    /// The rows of `[a, b)`: split at each `\\` that is the eqnarray's own,
    /// outside braces and outside any inner environment (`\begin` opens
    /// one, `\end` closes it), so a nested matrix, array or cases keeps its
    /// rows and columns; the separator keeps a `[..]` right after it.
    fn rows(&mut self, a: usize, b: usize) -> Option<Vec<Row>> {
        let s = self.s;
        let mut rows = Vec::new();
        let (mut depth, mut envs) = (0usize, 0usize);
        let (mut start, mut amps, mut amp) = (a, 0u32, None);
        let mut j = a;
        while j < b {
            let next = match s[j] {
                b'{' if plain_in(s, j, b'{') => {
                    depth += 1;
                    j + 1
                }
                b'}' if plain_in(s, j, b'}') => {
                    depth = depth.saturating_sub(1);
                    j + 1
                }
                b'&' if depth == 0 && envs == 0 && plain_in(s, j, b'&') => {
                    amps += 1;
                    if amps == 2 {
                        amp = Some(j);
                    }
                    j + 1
                }
                b'\\' => {
                    let e = self.tok_end(j, b);
                    match &s[j..e] {
                        b"\\\\" if depth == 0 && envs == 0 => {
                            let mut sep = e;
                            if self.plain(e, b, b'[') {
                                if let Some(k) = self.bracket_end(e, b) {
                                    sep = k;
                                }
                            }
                            rows.push(Row { start, end: j, sep_end: sep, amp });
                            (start, amps, amp) = (sep, 0, None);
                            sep
                        }
                        b"\\begin" => {
                            envs += 1;
                            e
                        }
                        b"\\end" => {
                            envs = envs.saturating_sub(1);
                            e
                        }
                        _ => e,
                    }
                }
                b'%' => self.line_end(j, b),
                _ => j + 1,
            };
            if !self.spend(next - j) {
                return None;
            }
            j = next;
        }
        rows.push(Row { start, end: b, sep_end: b, amp });
        Some(rows)
    }

    /// Rewrite `s[i..lim]` into `out`. `defs`: the definition rows of the
    /// table apply (not inside a definition's body).
    fn rewrite_range(&mut self, mut i: usize, lim: usize, defs: bool, nest: u32, out: &mut Out) {
        let s = self.s;
        while i < lim {
            match s[i] {
                b'%' => {
                    let e = self.line_end(i, lim);
                    out.copy(&s[i..e]);
                    i = e;
                }
                b'\\' => {
                    let e = self.cs_end(i, lim);
                    if e - i < 2 || !is_word(s[i + 1]) {
                        out.copy(&s[i..e]);
                        i = e;
                        continue;
                    }
                    match self.construct(i, e, lim, defs, nest, out) {
                        Some(next) => i = next,
                        None => {
                            out.word(&s[i..e]);
                            i = e;
                        }
                    }
                }
                _ => {
                    let run = s[i..lim].iter().position(|&b| b == b'\\' || b == b'%').map_or(lim, |p| i + p);
                    out.copy(&s[i..run]);
                    i = run;
                }
            }
        }
    }

    /// The control word `s[i..e]` and what follows it, rewritten into
    /// `out` when it is one of the table's forms: the index after the form.
    /// `None` when it is not (nothing was written).
    fn construct(&mut self, i: usize, e: usize, lim: usize, defs: bool, nest: u32, out: &mut Out) -> Option<usize> {
        let s = self.s;
        match &s[i + 1..e] {
            b"verb" => {
                let v = self.verb_end(e, lim);
                out.copy(&s[i..v]);
                Some(v)
            }
            b"label" | b"require" | b"class" | b"cssId" | b"style" => {
                let g = self.group_at(self.skip_blanks(e, lim), lim)?;
                out.gap(s, g, lim);
                Some(g)
            }
            b"mbox" => {
                out.word(b"\\text");
                Some(e)
            }
            b"mspace" => {
                let j = self.skip_blanks(e, lim);
                let g = self.group_at(j, lim)?;
                let x = &s[j + 1..g - 1];
                out.word(b"\\mkern");
                if x.first().is_some_and(|&b| is_word(b)) {
                    out.copy(b" ");
                }
                out.copy(x);
                out.copy(b" ");
                Some(g)
            }
            b"bbox" => {
                let j = self.skip_blanks(e, lim);
                let k = if self.plain(j, lim, b'[') { self.bracket_end(j, lim)? } else { j };
                out.gap(s, k, lim);
                Some(k)
            }
            b"unicode" => {
                let mut j = self.skip_blanks(e, lim);
                if self.plain(j, lim, b'[') {
                    let k = self.bracket_end(j, lim)?;
                    j = self.skip_blanks(k, lim);
                }
                let g = self.group_at(j, lim)?;
                let c = unicode_char(&s[j + 1..g - 1])?;
                let mut tmp = [0u8; 4];
                out.copy(b"{");
                out.copy(c.encode_utf8(&mut tmp).as_bytes());
                out.copy(b"}");
                Some(g)
            }
            b"DeclareMathOperator" if defs && nest < MAX_NEST => {
                let (f, star) = self.operator_form(e, lim)?;
                out.word(b"\\def");
                out.copy(&s[f.name.0..f.name.1]);
                out.copy(if star { b"{\\operatorname*{" } else { b"{\\operatorname{" });
                out.copy(&s[f.body.0..f.body.1]);
                out.copy(b"}}");
                Some(f.end)
            }
            b"newcommand" | b"renewcommand" | b"providecommand" if defs && nest < MAX_NEST => {
                let f = self.newcommand_form(e, lim)?;
                out.word(b"\\def");
                out.copy(&s[f.name.0..f.name.1]);
                write_params(&mut out.buf, f.args);
                out.copy(b"{");
                let mut body = Out::new();
                self.rewrite_range(f.body.0, f.body.1, false, nest + 1, &mut body);
                out.copy(&body.buf);
                out.copy(b"}");
                Some(f.end)
            }
            b"def" | b"gdef" if defs => {
                let name = self.cs_name(self.skip_blanks(e, lim), lim)?;
                let brace = self.param_brace(name.1, lim)?;
                let g = self.group_end(brace, lim)?;
                out.copy(&s[i..g]);
                Some(g)
            }
            b"begin" | b"end" => self.environment(i, e, lim, defs, nest, out),
            _ => None,
        }
    }

    /// `\begin` or `\end` (the control word `s[i..e]`), blanks, `{name}`.
    fn environment(&mut self, i: usize, e: usize, lim: usize, defs: bool, nest: u32, out: &mut Out) -> Option<usize> {
        let s = self.s;
        let begin = &s[i + 1..e] == b"begin";
        let j = self.skip_blanks(e, lim);
        let g = self.group_at(j, lim)?;
        let name = &s[j + 1..g - 1];
        let starred: &[u8] = match name {
            b"equation" => b"equation*",
            b"align" => b"align*",
            b"gather" => b"gather*",
            b"alignat" => b"alignat*",
            b"flalign" | b"flalign*" => b"align*",
            b"multline" | b"multline*" => b"gather*",
            b"displaymath" | b"subequations" => {
                out.gap(s, g, lim);
                return Some(g);
            }
            b"eqnarray" | b"eqnarray*" if begin && nest < MAX_NEST => {
                return self.eqnarray(g, lim, name, defs, nest, out);
            }
            _ => return None,
        };
        out.copy(if begin { b"\\begin{" } else { b"\\end{" });
        out.copy(starred);
        out.copy(b"}");
        Some(g)
    }

    /// `\begin{eqnarray}` ended at `body`: the body up to the first
    /// `\end{eqnarray}` as `aligned`, the second `&` of each of its own
    /// rows deleted ([`Sc::rows`]; an inner environment is left whole).
    /// No end: `None` (copied as written).
    fn eqnarray(&mut self, body: usize, lim: usize, name: &[u8], defs: bool, nest: u32, out: &mut Out) -> Option<usize> {
        let s = self.s;
        let (end_at, after) = self.find_end(body, lim, name)?;
        let rows = self.rows(body, end_at)?;
        out.copy(b"\\begin{aligned}");
        for r in rows {
            match r.amp {
                Some(a) => {
                    self.rewrite_range(r.start, a, defs, nest + 1, out);
                    if out.ends_with_word() && a + 1 < r.end && is_word(s[a + 1]) {
                        out.copy(b" ");
                    }
                    self.rewrite_range(a + 1, r.end, defs, nest + 1, out);
                }
                None => self.rewrite_range(r.start, r.end, defs, nest + 1, out),
            }
            out.copy(&s[r.end..r.sep_end]);
        }
        out.copy(b"\\end{aligned}");
        Some(after)
    }

    /// `\newcommand` and its kin in the prelude: `\def NAME #1.. {B'}` with
    /// B' the body rewritten without the definition rows.
    fn take_newcommand(&mut self, e: usize, lim: usize, out: &mut Vec<u8>) -> Option<usize> {
        let f = self.newcommand_form(e, lim)?;
        let name = &self.s[f.name.0..f.name.1];
        if SKIPPED_NAMES.contains(&name) {
            return Some(f.end);
        }
        let mut body = Out::new();
        self.rewrite_range(f.body.0, f.body.1, false, 1, &mut body);
        if balanced(&body.buf) {
            out.extend_from_slice(b"\\def");
            out.extend_from_slice(name);
            write_params(out, f.args);
            out.push(b'{');
            out.extend_from_slice(&body.buf);
            out.extend_from_slice(b"}\n");
        }
        Some(f.end)
    }

    /// `\DeclareMathOperator` in the prelude: `\def NAME{\operatorname{B}}`.
    fn take_operator(&mut self, e: usize, lim: usize, out: &mut Vec<u8>) -> Option<usize> {
        let s = self.s;
        let (f, star) = self.operator_form(e, lim)?;
        let (name, body) = (&s[f.name.0..f.name.1], &s[f.body.0..f.body.1]);
        if !SKIPPED_NAMES.contains(&name) && balanced(body) {
            out.extend_from_slice(b"\\def");
            out.extend_from_slice(name);
            out.extend_from_slice(if star { b"{\\operatorname*{" } else { b"{\\operatorname{" });
            out.extend_from_slice(body);
            out.extend_from_slice(b"}}\n");
        }
        Some(f.end)
    }

    /// `\def` or `\gdef` in the prelude: taken as `\def NAME P{B}` when the
    /// parameter text P is, without blanks, empty or `#1`, `#1#2`, ... in
    /// order; a delimited one is skipped whole.
    fn take_def(&mut self, e: usize, lim: usize, out: &mut Vec<u8>) -> Option<usize> {
        let s = self.s;
        let name = self.cs_name(self.skip_blanks(e, lim), lim)?;
        let mut k = name.1;
        let mut args = 0u8;
        let ordered = loop {
            k = self.skip_blanks(k, lim);
            if k >= lim {
                return None;
            }
            if self.plain(k, lim, b'{') {
                break true;
            }
            if !self.plain(k, lim, b'#') || args == 9 {
                break false;
            }
            let d = self.skip_blanks(k + 1, lim);
            if d < lim && s[d] == b'1' + args && !combining(s, d + 1) {
                args += 1;
                k = d + 1;
            } else {
                break false;
            }
        };
        let brace = if ordered { k } else { self.param_brace(name.1, lim)? };
        let g = self.group_end(brace, lim)?;
        let (name, body) = (&s[name.0..name.1], &s[brace + 1..g - 1]);
        if ordered && !SKIPPED_NAMES.contains(&name) && balanced(body) {
            out.extend_from_slice(b"\\def");
            out.extend_from_slice(name);
            write_params(out, args);
            out.push(b'{');
            out.extend_from_slice(body);
            out.extend_from_slice(b"}\n");
        }
        Some(g)
    }

    /// `\let` blanks control-sequence blanks optional `=` blanks
    /// control-sequence in the prelude: `\let a b`.
    fn take_let(&mut self, e: usize, lim: usize, out: &mut Vec<u8>) -> Option<usize> {
        let s = self.s;
        let a = self.cs_name(self.skip_blanks(e, lim), lim)?;
        let mut k = self.skip_blanks(a.1, lim);
        if self.plain(k, lim, b'=') {
            k = self.skip_blanks(k + 1, lim);
        }
        let b = self.cs_name(k, lim)?;
        let (an, bn) = (&s[a.0..a.1], &s[b.0..b.1]);
        if !SKIPPED_NAMES.contains(&an) {
            out.extend_from_slice(b"\\let");
            out.extend_from_slice(an);
            out.extend_from_slice(bn);
            out.push(b'\n');
        }
        Some(b.1)
    }
}

/// `#1#2..#n`.
fn write_params(out: &mut Vec<u8>, n: u8) {
    for k in 1..=n.min(9) {
        out.push(b'#');
        out.push(b'0' + k);
    }
}

/// `b` is a balanced body under RaTeX's lexer: every `{` closed, never a
/// `}` too many, no comment or `\verb` that would run past its end, no
/// trailing lone backslash, and no combining mark first (it would join the
/// `{` written before it).
fn balanced(b: &[u8]) -> bool {
    if combining(b, 0) {
        return false;
    }
    let sc = Sc { s: b, left: 0 };
    let lim = b.len();
    let mut depth = 0usize;
    let mut j = 0;
    while j < lim {
        j = match b[j] {
            b'{' if plain_in(b, j, b'{') => {
                depth += 1;
                j + 1
            }
            b'}' if plain_in(b, j, b'}') => {
                let Some(d) = depth.checked_sub(1) else { return false };
                depth = d;
                j + 1
            }
            b'%' => match b[j..].iter().position(|&c| c == b'\n') {
                Some(p) => j + p + 1,
                None => return false,
            },
            b'\\' => {
                let e = sc.cs_end(j, lim);
                if e - j < 2 {
                    return false;
                }
                if &b[j..e] == b"\\verb" {
                    let v = sc.verb_end(e, lim);
                    // Terminated: the text ends with its delimiter and is
                    // longer than `\verb`, the star and the opening one.
                    let open = if b.get(e) == Some(&b'*') { e + 1 } else { e };
                    let dl = b.get(open).map_or(0, |&c| char_len(c));
                    if dl == 0 || v < open + 2 * dl || b[v - dl..v] != b[open..open + dl] {
                        return false;
                    }
                    v
                } else {
                    e
                }
            }
            _ => j + 1,
        };
    }
    depth == 0
}

/// `N` of `\unicode{N}`: `x` or `X` and hex digits, or decimal digits; a
/// character from U+00A0 on, never a combining mark (it would join the `{`
/// written before it).
fn unicode_char(n: &[u8]) -> Option<char> {
    let text = std::str::from_utf8(n).ok()?;
    let v = match text.strip_prefix('x').or_else(|| text.strip_prefix('X')) {
        Some(h) if !h.is_empty() && h.len() <= 8 && h.bytes().all(|b| b.is_ascii_hexdigit()) => {
            u32::from_str_radix(h, 16).ok()?
        }
        Some(_) => return None,
        None if !text.is_empty() && text.len() <= 10 && text.bytes().all(|b| b.is_ascii_digit()) => text.parse().ok()?,
        None => return None,
    };
    if v < 0xa0 || (0x300..=0x36f).contains(&v) {
        return None;
    }
    char::from_u32(v)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn rw(cases: &[(&str, &str)]) {
        for (input, want) in cases {
            assert_eq!(rewrite(input), *want, "rewrite({input:?})");
        }
    }

    #[test]
    fn newcommand_and_kin_become_def() {
        rw(&[
            (r"\newcommand{\RR}{\mathbb{R}} \RR", r"\def\RR{\mathbb{R}} \RR"),
            (r"\newcommand{\abs}[1]{\left| #1 \right|}", r"\def\abs#1{\left| #1 \right|}"),
            (r"\newcommand*\x{y}", r"\def\x{y}"),
            (r"\renewcommand { \x } [ 2 ] {#1+#2}", r"\def\x#1#2{#1+#2}"),
            (r"\providecommand\x[0]{y}x", r"\def\x{y}x"),
            (r"\newcommand{\f}[2][d]{#1#2}", r"\newcommand{\f}[2][d]{#1#2}"),
            (r"\newcommand{\f}[x]{y}", r"\newcommand{\f}[x]{y}"),
            (r"\newcommand{\f}[10]{y}", r"\newcommand{\f}[10]{y}"),
            (r"\newcommand{\f g}{y}", r"\newcommand{\f g}{y}"),
            (r"\newcommand{\f}", r"\newcommand{\f}"),
            (r"\newcommand{\f}{y", r"\newcommand{\f}{y"),
            (r"\newcommand x{y}", r"\newcommand x{y}"),
            // The body is rewritten, without the definition rows.
            (r"\newcommand{\a}{\mbox{b}\label{c}}", r"\def\a{\text{b}}"),
            (r"\newcommand{\a}{\newcommand{\b}{c}}", r"\def\a{\newcommand{\b}{c}}"),
            (r"\newcommand{\a}{\def\b{c}\label{x}}", r"\def\a{\def\b{c}}"),
            (r"\newcommand{\b}{\{ \} {x}}", r"\def\b{\{ \} {x}}"),
            (r"\newcommand{\b}{\}}", r"\def\b{\}}"),
            (r"\DeclareMathOperator*{\argmax}{arg\,max}", r"\def\argmax{\operatorname*{arg\,max}}"),
            (r"\DeclareMathOperator{\Tr}{Tr} \Tr A", r"\def\Tr{\operatorname{Tr}} \Tr A"),
            (r"\DeclareMathOperator\Tr {Tr}", r"\def\Tr{\operatorname{Tr}}"),
            (r"\DeclareMathOperator{\Tr}", r"\DeclareMathOperator{\Tr}"),
        ]);
    }

    #[test]
    fn def_is_copied_whole() {
        rw(&[
            (r"\def\a#1{\label{x}#1}\a b", r"\def\a#1{\label{x}#1}\a b"),
            (r"\gdef\a(#1){#1}", r"\gdef\a(#1){#1}"),
            (r"\def\a{\newcommand{\b}{c}}", r"\def\a{\newcommand{\b}{c}}"),
            // Malformed: the control word alone, then the table goes on.
            (r"\def\a}\label{x}", r"\def\a}"),
            (r"\def x\mbox", r"\def x\text"),
        ]);
    }

    #[test]
    fn dropped_and_renamed_commands() {
        rw(&[
            (r"x \label{eq:1} = 1", "x  = 1"),
            (r"x \label {eq:1}", "x "),
            (r"x \label y", r"x \label y"),
            (r"\label", r"\label"),
            (r"\require{cancel}\cancel{x}", r"\cancel{x}"),
            (r"\mbox{if } x", r"\text{if } x"),
            (r"\mboxed{x}", r"\mboxed{x}"),
            (r"a\mspace{3mu}b", r"a\mkern3mu b"),
            (r"a\mspace {mu}b", r"a\mkern mu b"),
            (r"\bbox[yellow]{x}", "{x}"),
            (r"\bbox[5px,border:2px solid red]{x}", "{x}"),
            (r"\bbox{x}", "{x}"),
            (r"\bbox[yellow{x}", r"\bbox[yellow{x}"),
            (r"\class{c}{x}", "{x}"),
            (r"\cssId{c}{x}", "{x}"),
            (r"\style{color:red}{x}", "{x}"),
            (r"\class x", r"\class x"),
            (r"\unicode{x2260}", "{\u{2260}}"),
            (r"\unicode{X1D400}", "{\u{1D400}}"),
            (r"\unicode{8800}", "{\u{2260}}"),
            (r"\unicode[Arial]{x2260}", "{\u{2260}}"),
            (r"\unicode{x41}", r"\unicode{x41}"),
            (r"\unicode{x301}", r"\unicode{x301}"),
            (r"\unicode{xD800}", r"\unicode{xD800}"),
            (r"\unicode{x110000}", r"\unicode{x110000}"),
            (r"\unicode{0x2260}", r"\unicode{0x2260}"),
            (r"\unicode{x}", r"\unicode{x}"),
            (r"\unicode", r"\unicode"),
            (r"\ref{a} \eqref{b}", r"\ref{a} \eqref{b}"),
        ]);
    }

    #[test]
    fn a_dropped_form_never_joins_a_control_word_to_letters() {
        rw(&[
            (r"\alpha\label{x}b", r"\alpha b"),
            (r"\alpha\label{x}\beta", r"\alpha\beta"),
            (r"\alpha\label{x}1", r"\alpha1"),
            (r"a\label{x}b", "ab"),
            (r"\ver\bbox b", r"\ver b"),
            (r"\ver\class{x}b", r"\ver b"),
            (r"\x\begin{displaymath}y", r"\x y"),
            (r"\\\label{x}b", r"\\b"),
        ]);
    }

    #[test]
    fn environments() {
        rw(&[
            (r"\begin{align}a&=b\end{align}", r"\begin{align*}a&=b\end{align*}"),
            (r"\begin {align} a \end {align}", r"\begin{align*} a \end{align*}"),
            (r"\begin{align*}a\end{align*}", r"\begin{align*}a\end{align*}"),
            (r"\begin{equation}x\tag{7}\end{equation}", r"\begin{equation*}x\tag{7}\end{equation*}"),
            (r"\begin{gather}x\end{gather}", r"\begin{gather*}x\end{gather*}"),
            (r"\begin{alignat}{2}x\end{alignat}", r"\begin{alignat*}{2}x\end{alignat*}"),
            (r"\begin{flalign}x\end{flalign}", r"\begin{align*}x\end{align*}"),
            (r"\begin{flalign*}x\end{flalign*}", r"\begin{align*}x\end{align*}"),
            (r"\begin{multline}x\\y\end{multline}", r"\begin{gather*}x\\y\end{gather*}"),
            (r"\begin{multline*}x\end{multline*}", r"\begin{gather*}x\end{gather*}"),
            (r"\begin{displaymath}x\end{displaymath}", "x"),
            (r"\begin{subequations}\begin{align}x\end{align}\end{subequations}", r"\begin{align*}x\end{align*}"),
            (r"\begin{pmatrix}x\end{pmatrix}", r"\begin{pmatrix}x\end{pmatrix}"),
            (r"\begin{ align }x", r"\begin{ align }x"),
            (r"\begin x", r"\begin x"),
        ]);
    }

    #[test]
    fn eqnarray_becomes_aligned() {
        rw(&[
            (
                r"\begin{eqnarray} a &=& b \\ c &=& d \end{eqnarray}",
                r"\begin{aligned} a &= b \\ c &= d \end{aligned}",
            ),
            (
                r"\begin{eqnarray*}a&=&b\\[2pt]c&<&\frac{1}{2}\label{x}\end{eqnarray*}",
                r"\begin{aligned}a&=b\\[2pt]c&<\frac{1}{2}\end{aligned}",
            ),
            // Braces hide their & and \\; \& is not a column.
            (
                r"\begin{eqnarray}{a&b\\c}&=&x\&y&z\end{eqnarray}",
                r"\begin{aligned}{a&b\\c}&=x\&y&z\end{aligned}",
            ),
            // An inner environment keeps its rows and columns: only the
            // eqnarray's own \\ and & count.
            (
                r"\begin{eqnarray} A &=& \begin{pmatrix} 1 & 2 & 3 \\ 4 & 5 & 6 \end{pmatrix} \\ b &=& c \end{eqnarray}",
                r"\begin{aligned} A &= \begin{pmatrix} 1 & 2 & 3 \\ 4 & 5 & 6 \end{pmatrix} \\ b &= c \end{aligned}",
            ),
            (
                r"\begin{eqnarray} f(x) &=& \begin{cases} 1 & x > 0 \\ 0 & x \le 0 \end{cases} \\ g &=& h \end{eqnarray}",
                r"\begin{aligned} f(x) &= \begin{cases} 1 & x > 0 \\ 0 & x \le 0 \end{cases} \\ g &= h \end{aligned}",
            ),
            // On the left of the relation, and two environments deep.
            (
                r"\begin{eqnarray}\begin{matrix}a&b\\c&d\end{matrix}&=&e\end{eqnarray}",
                r"\begin{aligned}\begin{matrix}a&b\\c&d\end{matrix}&=e\end{aligned}",
            ),
            (
                r"\begin{eqnarray}x&=&\begin{array}{cc}\begin{pmatrix}1&2\\3&4\end{pmatrix}&y\\z&w\end{array}\\a&<&b\end{eqnarray}",
                r"\begin{aligned}x&=\begin{array}{cc}\begin{pmatrix}1&2\\3&4\end{pmatrix}&y\\z&w\end{array}\\a&<b\end{aligned}",
            ),
            // After an inner environment closes, the eqnarray's own count again.
            (
                r"\begin{eqnarray}\begin {smallmatrix}1&2\end {smallmatrix}x&=&y&z\\u&v&w\end{eqnarray}",
                r"\begin{aligned}\begin {smallmatrix}1&2\end {smallmatrix}x&=y&z\\u&vw\end{aligned}",
            ),
            // \begingroup is not an environment.
            (
                r"\begin{eqnarray}\begingroup a&=&b\endgroup\\c&=&d\end{eqnarray}",
                r"\begin{aligned}\begingroup a&=b\endgroup\\c&=d\end{aligned}",
            ),
            // The deleted & never joins a control word to letters.
            (r"\begin{eqnarray}a&\le&b\end{eqnarray}", r"\begin{aligned}a&\le b\end{aligned}"),
            (r"\begin{eqnarray}a\end{eqnarray}", r"\begin{aligned}a\end{aligned}"),
            // No end: as written.
            (r"\begin{eqnarray}a&=&b", r"\begin{eqnarray}a&=&b"),
            (r"\begin{eqnarray}a\end{eqnarray*}", r"\begin{eqnarray}a\end{eqnarray*}"),
            (r"\end{eqnarray}", r"\end{eqnarray}"),
        ]);
    }

    #[test]
    fn comments_verb_and_escapes_are_untouched() {
        rw(&[
            ("x % \\label{y}\n\\label{z}w", "x % \\label{y}\nw"),
            ("x % \\label{y}", "x % \\label{y}"),
            (r"\% \label{a}", r"\% "),
            (r"\verb|\label{x}| \label{y}", r"\verb|\label{x}| "),
            (r"\verb*|\mbox| \mbox", r"\verb*|\mbox| \text"),
            (r"\verb!\label{x}", r"\verb!\label{x}"),
            (r"\{ \label{a} \}", r"\{  \}"),
            (r"\\ \mbox \\", r"\\ \text \\"),
            ("\\", "\\"),
            ("x\\", "x\\"),
        ]);
    }

    #[test]
    fn non_ascii_text_around_every_construct() {
        let constructs = [
            r"\newcommand{\é}{é}",
            r"\newcommand{\a}[1]{é#1é}",
            r"\DeclareMathOperator{\a}{é}",
            r"\def\a#1{é}",
            r"\label{é}",
            r"\require{é}",
            r"\mbox{é}",
            r"\mspace{é}",
            r"\bbox[é]{é}",
            r"\class{é}{é}",
            r"\unicode[é]{x2260}",
            r"\unicode{é}",
            r"\begin{é}é\end{é}",
            r"\begin{align}é\end{align}",
            r"\begin{eqnarray}é&é&é\\é\end{eqnarray}",
            r"\verb|é|",
            r"\verbé",
            "% é\n",
            r"\é\日\😀",
        ];
        for c in constructs {
            for (pre, post) in [("日本", "語"), ("é", ""), ("", "é"), ("\u{301}", "\u{301}"), ("😀", "😀")] {
                let t = format!("{pre}{c}{post}");
                let r = rewrite(&t);
                assert!(r.contains(pre) && r.contains(post), "{t:?} -> {r:?}");
                let d = definitions(&t);
                assert!(d.is_empty() || d.ends_with('\n'), "{t:?} -> {d:?}");
                // Every prefix and suffix at a character boundary.
                for (k, _) in t.char_indices() {
                    let _ = rewrite(&t[..k]);
                    let _ = definitions(&t[k..]);
                }
            }
        }
    }

    #[test]
    fn definitions_take_only_definitions() {
        let src = "# Notation\n\nLet $\\newcommand{\\RR}{\\mathbb{R}} x \\in \\RR$ and\n\
                   $$\\def\\norm#1{\\left\\lVert #1 \\right\\rVert}$$ with \\gdef\\v{v} \
                   and \\let\\phi=\\varphi, \\let \\a \\b; also \\DeclareMathOperator*{\\argmax}{arg\\,max}\n\
                   \\renewcommand\\abs[1]{|#1|\\label{q}} \\providecommand{\\x}{\\mbox{x}} text 50\\% done.";
        assert_eq!(
            definitions(src),
            "\\def\\RR{\\mathbb{R}}\n\
             \\def\\norm#1{\\left\\lVert #1 \\right\\rVert}\n\
             \\def\\v{v}\n\
             \\let\\phi\\varphi\n\
             \\let\\a\\b\n\
             \\def\\argmax{\\operatorname*{arg\\,max}}\n\
             \\def\\abs#1{|#1|}\n\
             \\def\\x{\\text{x}}\n"
        );
    }

    #[test]
    fn definitions_skip_what_is_not_taken() {
        for (src, want) in [
            // Commented out.
            ("% \\newcommand{\\a}{b}\n\\def\\c{d}", "\\def\\c{d}\n"),
            ("50% \\def\\a{b}", ""),
            ("\\% \\def\\a{b}", "\\def\\a{b}\n"),
            // Delimited parameters: skipped whole, its body included.
            ("\\def\\a(#1){\\def\\b{c}} \\def\\d{e}", "\\def\\d{e}\n"),
            ("\\def\\a#2{x}", ""),
            ("\\def\\a#1#3{x}", ""),
            ("\\def\\a #1 #2{#1#2}", "\\def\\a#1#2{#1#2}\n"),
            ("\\def\\a# 1{#1}", "\\def\\a#1{#1}\n"),
            // Names that are never taken.
            ("\\def\\begin{} \\newcommand{\\end}{x} \\let\\def\\relax \\def\\x{y}", "\\def\\x{y}\n"),
            ("\\newcommand{\\verb}{x}\\let\\a\\verb\\let\\verb\\a", ""),
            ("\\DeclareMathOperator{\\newcommand}{x}", ""),
            ("\\gdef\\gdef{x}\\def\\long{x}\\def\\global{x}\\def\\edef{}\\def\\xdef{}\\def\\let{}", ""),
            // Malformed: skipped by one control sequence, the scan goes on.
            ("\\def\\a{b \\def\\c{d}", "\\def\\c{d}\n"),
            ("\\newcommand{\\a}[2][x]{y} \\def\\b{c}", "\\def\\b{c}\n"),
            ("\\let\\a \\def\\b{c}", "\\let\\a\\def\n"),
            ("\\let a\\b \\def\\c{d}", "\\def\\c{d}\n"),
            ("\\def\\", ""),
            ("\\def\\a", ""),
            // Bodies that would not be balanced for RaTeX's lexer.
            ("\\def\\a{\\verb|}|} \\def\\b{c}", "\\def\\a{\\verb|}|}\n\\def\\b{c}\n"),
            ("\\def\\a{\\verb|} \\def\\b{c}", "\\def\\b{c}\n"),
            ("\\def\\a{x\u{301}} \\def\\b{\u{301}x}", "\\def\\a{x\u{301}}\n"),
            // `{` with a mark is one token, not a brace.
            ("\\def\\a{{\u{301}} \\def\\b{c}", "\\def\\a{{\u{301}}\n\\def\\b{c}\n"),
            ("\\newcommand{\\a}{x\\unicode{x301}}", "\\def\\a{x\\unicode{x301}}\n"),
            ("\\newcommand{\\a}{\\ver\\label{x}b|}", "\\def\\a{\\ver b|}\n"),
        ] {
            assert_eq!(definitions(src), want, "definitions({src:?})");
        }
    }

    #[test]
    fn balanced_follows_the_lexer() {
        for (b, want) in [
            ("", true),
            ("{x}", true),
            (r"\{", true),
            ("{", false),
            ("}", false),
            ("}{", false),
            ("x\\", false),
            ("% c", false),
            ("% c\n", true),
            (r"\verb|x|", true),
            (r"\verb*|x|", true),
            (r"\verb|x", false),
            (r"\verb|", false),
            (r"\verb", false),
            (r"\verb*", false),
            ("\u{301}x", false),
            ("x{\u{301}}", false),
            ("{x}\u{301}", false),
            ("{\u{301}", true),
        ] {
            assert_eq!(balanced(b.as_bytes()), want, "{b:?}");
        }
    }

    #[test]
    fn prepare_joins_and_checks() {
        let nc = NO_CHEMISTRY;
        assert_eq!(prepare("", "x").unwrap(), format!("{nc}x"));
        assert_eq!(prepare("\\newcommand{\\R}{r} prose", "\\R").unwrap(), format!("{nc}\\def\\R{{r}}\n\\R"));
        // The notebook's own \let, \def and \ce all come after it.
        assert_eq!(
            prepare("\\let\\ce\\relax \\def\\pu{p}", "\\ce{H2O}").unwrap(),
            format!("{nc}\\let\\ce\\relax\n\\def\\pu{{p}}\n\\ce{{H2O}}")
        );
        assert_eq!(prepare("", "  \n\t"), Err(MathErr::Empty));
        assert_eq!(prepare("", ""), Err(MathErr::Empty));
        assert_eq!(prepare("\\def\\a{b}", "\\label{x}"), Err(MathErr::Empty));
        assert_eq!(prepare("", "\\begin{displaymath} \\end{displaymath}"), Err(MathErr::Empty));
        let long = "x".repeat(MAX_TEX + 1);
        assert!(matches!(prepare("", &long), Err(MathErr::Input(m)) if m == "the formula is 16385 bytes, at most 16384"));
        let long = "x".repeat(MAX_PRELUDE + 1);
        assert!(matches!(prepare(&long, "x"), Err(MathErr::Input(m)) if m.starts_with("the prelude is 65537 bytes")));
        assert!(prepare(&"x".repeat(MAX_PRELUDE), &"x".repeat(MAX_TEX)).is_ok());
    }

    /// Text built to make look-ahead scans run to the end, again and again.
    #[test]
    fn hostile_text_stays_linear() {
        let cases: Vec<String> = vec![
            r"\label{".repeat(MAX_PRELUDE / 7),
            r"\newcommand{\a}{".repeat(MAX_PRELUDE / 16),
            r"\def\a".repeat(MAX_PRELUDE / 6),
            r"\def\a#1".repeat(MAX_PRELUDE / 8),
            r"\bbox[".repeat(MAX_PRELUDE / 6),
            r"\verb|".repeat(MAX_PRELUDE / 6),
            r"\begin{eqnarray}".repeat(MAX_PRELUDE / 16),
            format!("{}{}", r"\begin{eqnarray}".repeat(MAX_PRELUDE / 32), r"\end{eqnarray}".repeat(MAX_PRELUDE / 32)),
            "{".repeat(MAX_PRELUDE),
            "}".repeat(MAX_PRELUDE),
            format!("{}{}", r"\newcommand{\a}{".repeat(1000), "}".repeat(MAX_PRELUDE - 16_000)),
            r"\begin{eqnarray}a\\".repeat(MAX_PRELUDE / 19) + r"\end{eqnarray}",
            format!(r"\begin{{eqnarray}}{}\end{{eqnarray}}", r"\begin{m}a&b\\".repeat(MAX_PRELUDE / 16)),
            format!(r"\begin{{eqnarray}}{}\end{{eqnarray}}", r"\end{m}a&b\\".repeat(MAX_PRELUDE / 14)),
            r"\unicode[".repeat(MAX_PRELUDE / 9),
            r"\let\a=".repeat(MAX_PRELUDE / 7),
        ];
        for c in &cases {
            let t = Instant::now();
            let d = definitions(c);
            let r = rewrite(c);
            let el = t.elapsed();
            assert!(el < Duration::from_millis(500), "{:?}...: {el:?}", &c[..40.min(c.len())]);
            assert!(r.len() <= c.len() * 2 + 64 && d.len() <= c.len() * 2 + 64);
        }
    }
}
