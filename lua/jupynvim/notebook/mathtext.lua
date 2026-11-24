-- TeX math to readable terminal text.
--
-- Markdown cells show `$..$` and `$$..$$` bodies through this module: the
-- source is tokenized and rendered by a small recursive-descent renderer, so
-- nested braces, scripts on groups and arguments of commands come out right
-- (a gsub chain cannot balance braces). The output is one line of Unicode:
-- fractions stay `a/b`, scripts use the modifier glyphs where every char has
-- one, fonts use the Mathematical Alphanumeric Symbols block.
--
-- This module requires nothing else from jupynvim so it can be unit tested on
-- its own (tests/mathtext_spec.lua).
local M = {}

-- Lua 5.1/LuaJIT has no utf8 library (same helper as html_table.lua).
local function utf8char(cp)
  if not cp or cp ~= cp or cp <= 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
    return "\239\191\189"
  end
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

-- The UTF-8 character starting at byte p. Invalid bytes come back one at a
-- time, so a walk over notebook text never loses or merges a byte.
local function char_at(s, p)
  local b = s:byte(p)
  local n = 1
  if b >= 0xC2 and b <= 0xF4 then
    n = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or 2
    for k = 1, n - 1 do
      local c = s:byte(p + k)
      if not c or c < 0x80 or c > 0xBF then
        n = k
        break
      end
    end
  end
  return s:sub(p, p + n - 1)
end

local function chars(s)
  local list, p = {}, 1
  while p <= #s do
    local c = char_at(s, p)
    list[#list + 1] = c
    p = p + #c
  end
  return list
end

local function set(list)
  local t = {}
  for _, k in ipairs(list) do t[k] = true end
  return t
end

-- ---------- tables ----------

-- Modifier letters. No `q` (Unicode has none), no capitals (patchy in fonts),
-- no Greek. The identity entries let `x^\prime`, `A^\dagger` and `x^*` attach
-- without a `^`.
local SUPER = {
  ["0"]="⁰", ["1"]="¹", ["2"]="²", ["3"]="³", ["4"]="⁴",
  ["5"]="⁵", ["6"]="⁶", ["7"]="⁷", ["8"]="⁸", ["9"]="⁹",
  ["+"]="⁺", ["-"]="⁻", ["="]="⁼", ["("]="⁽", [")"]="⁾",
  ["a"]="ᵃ", ["b"]="ᵇ", ["c"]="ᶜ", ["d"]="ᵈ", ["e"]="ᵉ",
  ["f"]="ᶠ", ["g"]="ᵍ", ["h"]="ʰ", ["i"]="ⁱ", ["j"]="ʲ",
  ["k"]="ᵏ", ["l"]="ˡ", ["m"]="ᵐ", ["n"]="ⁿ", ["o"]="ᵒ",
  ["p"]="ᵖ", ["r"]="ʳ", ["s"]="ˢ", ["t"]="ᵗ", ["u"]="ᵘ",
  ["v"]="ᵛ", ["w"]="ʷ", ["x"]="ˣ", ["y"]="ʸ", ["z"]="ᶻ",
  ["′"]="′", ["″"]="″", ["†"]="†", ["‡"]="‡", ["*"]="*",
  -- `90^\circ` reads as the degree sign
  ["∘"]="°",
}
local SUB = {
  ["0"]="₀", ["1"]="₁", ["2"]="₂", ["3"]="₃", ["4"]="₄",
  ["5"]="₅", ["6"]="₆", ["7"]="₇", ["8"]="₈", ["9"]="₉",
  ["+"]="₊", ["-"]="₋", ["="]="₌", ["("]="₍", [")"]="₎",
  ["a"]="ₐ", ["e"]="ₑ", ["h"]="ₕ", ["i"]="ᵢ", ["j"]="ⱼ",
  ["k"]="ₖ", ["l"]="ₗ", ["m"]="ₘ", ["n"]="ₙ", ["o"]="ₒ",
  ["p"]="ₚ", ["r"]="ᵣ", ["s"]="ₛ", ["t"]="ₜ", ["u"]="ᵤ",
  ["v"]="ᵥ", ["x"]="ₓ",
}

-- Command name -> text. Written as "name glyph" pairs per group to keep the
-- table readable; split on whitespace once at load.
local SYMBOLS = {}
-- Binary operators, relations and arrows: spacing around them is mirrored.
local RELBIN = {}
local BIGOP = {}
local function add_pairs(spec, group)
  local name
  for word in spec:gmatch("%S+") do
    if name then
      SYMBOLS[name] = word
      if group then group[name] = true end
      name = nil
    else
      name = word
    end
  end
end

-- Greek
add_pairs([[
  alpha α beta β gamma γ delta δ epsilon ϵ varepsilon ε zeta ζ eta η theta θ
  vartheta ϑ iota ι kappa κ varkappa ϰ lambda λ mu μ nu ν xi ξ omicron ο pi π
  varpi ϖ rho ρ varrho ϱ sigma σ varsigma ς tau τ upsilon υ phi ϕ varphi φ
  chi χ psi ψ omega ω
  Gamma Γ Delta Δ Theta Θ Lambda Λ Xi Ξ Pi Π Sigma Σ Upsilon Υ Phi Φ Psi Ψ
  Omega Ω Alpha Α Beta Β Epsilon Ε Zeta Ζ Eta Η Iota Ι Kappa Κ Mu Μ Nu Ν
  Omicron Ο Rho Ρ Tau Τ Chi Χ
]])
-- Binary operators
add_pairs([[
  pm ± mp ∓ times × div ÷ cdot · ast ∗ star ⋆ circ ∘ bullet ∙ oplus ⊕
  ominus ⊖ otimes ⊗ oslash ⊘ odot ⊙ cup ∪ cap ∩ setminus ∖ smallsetminus ∖
  wedge ∧ land ∧ vee ∨ lor ∨ lnot ¬ neg ¬ sqcup ⊔ sqcap ⊓ uplus ⊎ wr ≀
  dagger † ddagger ‡ diamond ⋄ bigcirc ◯ triangleleft ◃ triangleright ▹
  amalg ⨿
]], RELBIN)
-- Relations
add_pairs([[
  le ≤ leq ≤ ge ≥ geq ≥ ne ≠ neq ≠ equiv ≡ approx ≈ sim ∼ simeq ≃ cong ≅
  propto ∝ ll ≪ gg ≫ prec ≺ succ ≻ preceq ⪯ succeq ⪰ subset ⊂ supset ⊃
  subseteq ⊆ supseteq ⊇ subsetneq ⊊ supsetneq ⊋ sqsubseteq ⊑ sqsupseteq ⊒
  in ∈ notin ∉ ni ∋ owns ∋ mid | nmid ∤ parallel ∥ nparallel ∦ perp ⊥
  vdash ⊢ dashv ⊣ models ⊨ doteq ≐ asymp ≍ bowtie ⋈ lt < gt > leqslant ⩽
  geqslant ⩾ lesssim ≲ gtrsim ≳ triangleq ≜ coloneqq ≔
]], RELBIN)
-- `f\colon X \to Y` reads `f: X → Y`, so no mirrored space before it
SYMBOLS.colon = ":"
-- Arrows
add_pairs([[
  to → rightarrow → leftarrow ← gets ← leftrightarrow ↔ Rightarrow ⇒
  Leftarrow ⇐ Leftrightarrow ⇔ implies ⇒ impliedby ⇐ iff ⇔ mapsto ↦
  longrightarrow ⟶ longleftarrow ⟵ longmapsto ⟼ Longrightarrow ⟹
  Longleftarrow ⟸ Longleftrightarrow ⟺ uparrow ↑ downarrow ↓ updownarrow ↕
  Uparrow ⇑ Downarrow ⇓ nearrow ↗ searrow ↘ swarrow ↙ nwarrow ↖
  hookrightarrow ↪ hookleftarrow ↩ rightharpoonup ⇀ leftharpoonup ↼
  rightleftharpoons ⇌ leftrightarrows ⇆ twoheadrightarrow ↠
]], RELBIN)
-- Big operators
add_pairs([[
  sum ∑ prod ∏ coprod ∐ int ∫ iint ∬ iiint ∭ oint ∮ oiint ∯ bigcup ⋃
  bigcap ⋂ bigvee ⋁ bigwedge ⋀ bigoplus ⨁ bigotimes ⨂ bigodot ⨀ biguplus ⨄
  bigsqcup ⨆
]], BIGOP)
-- Misc
add_pairs([[
  infty ∞ partial ∂ nabla ∇ forall ∀ exists ∃ nexists ∄ emptyset ∅
  varnothing ∅ hbar ℏ ell ℓ Re ℜ Im ℑ aleph ℵ beth ℶ wp ℘ angle ∠
  measuredangle ∡ triangle △ top ⊤ bot ⊥ prime ′ backprime ‵ degree °
  checkmark ✓ square □ Box □ blacksquare ■ flat ♭ sharp ♯ natural ♮
  clubsuit ♣ diamondsuit ♢ heartsuit ♡ spadesuit ♠ S § P ¶ copyright ©
  pounds £ therefore ∴ because ∵ surd √ complement ∁ imath ı jmath ȷ eth ð
]])
-- Dots
add_pairs([[
  cdots ⋯ ldots … dots … dotsc … dotso … dotsb ⋯ dotsm ⋯ dotsi ⋯ hdots ⋯
  vdots ⋮ ddots ⋱
]])
-- Delimiters
add_pairs([[
  langle ⟨ rangle ⟩ lvert | rvert | vert | Vert ‖ lVert ‖ rVert ‖ lfloor ⌊
  rfloor ⌋ lceil ⌈ rceil ⌉ lbrace { rbrace } lbrack [ rbrack ] ulcorner ⌜
  urcorner ⌝ llcorner ⌞ lrcorner ⌟ lgroup ⟮ rgroup ⟯ backslash \
]])
-- Control symbols (`\{`, `\|`, ...)
add_pairs([[ { { } } | ‖ $ $ % % & & # # _ _ ]])
-- KaTeX-only shorthands, common in notebooks
add_pairs([[
  R ℝ N ℕ Z ℤ Reals ℝ Complex ℂ natnums ℕ cnums ℂ infin ∞ isin ∈ notni ∌
  sdot ⋅ plusmn ± larr ← rarr → harr ↔ lArr ⇐ rArr ⇒ hArr ⇔ uarr ↑ darr ↓
  alef ℵ weierp ℘ real ℜ image ℑ bull ∙ exist ∃ empty ∅ sub ⊂ sube ⊆
  supe ⊇ thetasym ϑ
]])
-- Function names print upright as their own name, set off by spaces.
local FUNC = { limsup = true, liminf = true }
for _, name in ipairs({
  "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
  "sinh", "cosh", "tanh", "coth", "log", "ln", "lg", "exp", "lim", "max",
  "min", "sup", "inf", "det", "dim", "ker", "deg", "gcd", "lcm", "arg", "hom",
  "Pr", "argmax", "argmin", "sgn", "injlim", "projlim",
}) do
  SYMBOLS[name] = name
  FUNC[name] = true
end
SYMBOLS.limsup = "lim sup"
SYMBOLS.liminf = "lim inf"

-- Font alphabets. Letters and digits are consecutive from a base code point;
-- the holes in the block are letters that already existed in Letterlike
-- Symbols (ℝ, ℂ, ℒ, ...), listed as exceptions.
local function alphabet(upper, lower, digit, exceptions)
  local t = {}
  for k = 0, 25 do
    t[string.char(65 + k)] = utf8char(upper + k)
    if lower then t[string.char(97 + k)] = utf8char(lower + k) end
  end
  if digit then
    for k = 0, 9 do t[string.char(48 + k)] = utf8char(digit + k) end
  end
  for c, cp in pairs(exceptions or {}) do t[c] = utf8char(cp) end
  return t
end

local BOLD = alphabet(0x1D400, 0x1D41A, 0x1D7CE)
local DOUBLE = alphabet(0x1D538, 0x1D552, 0x1D7D8, {
  C = 0x2102, H = 0x210D, N = 0x2115, P = 0x2119, Q = 0x211A, R = 0x211D, Z = 0x2124,
})
local SCRIPT = alphabet(0x1D49C, 0x1D4B6, nil, {
  B = 0x212C, E = 0x2130, F = 0x2131, H = 0x210B, I = 0x2110, L = 0x2112, M = 0x2133,
  R = 0x211B, e = 0x212F, g = 0x210A, o = 0x2134,
})
local FRAKTUR = alphabet(0x1D504, 0x1D51E, nil, {
  C = 0x212D, H = 0x210C, I = 0x2111, R = 0x211C, Z = 0x2128,
})
local SANS = alphabet(0x1D5A0, 0x1D5BA, 0x1D7E2)
local MONO = alphabet(0x1D670, 0x1D68A, 0x1D7F6)

local FONTS = {
  mathbb = DOUBLE, mathcal = SCRIPT, mathscr = SCRIPT, mathfrak = FRAKTUR,
  mathbf = BOLD, boldsymbol = BOLD, bm = BOLD, pmb = BOLD,
  mathsf = SANS, mathtt = MONO,
}

local FRAC = set({ "frac", "dfrac", "tfrac", "cfrac" })
local BINOM = set({ "binom", "tbinom", "dbinom" })
local PLAIN = set({ "mathrm", "mathit", "mathnormal", "operatorname", "mathop" })
local TEXT = set({
  "text", "textrm", "textit", "textbf", "textsf", "texttt", "textnormal",
  "textup", "mbox", "hbox",
})
local ACCENTS = {
  vec = 0x20D7, overrightarrow = 0x20D7, overleftarrow = 0x20D6,
  hat = 0x0302, widehat = 0x0302, tilde = 0x0303, widetilde = 0x0303,
  bar = 0x0304, overline = 0x0305, underline = 0x0332, dot = 0x0307,
  ddot = 0x0308, dddot = 0x20DB, check = 0x030C, breve = 0x0306,
  acute = 0x0301, grave = 0x0300, mathring = 0x030A,
}
local SIZERS = set({
  "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl",
  "Bigr", "biggl", "biggr", "Biggl", "Biggr", "bigm", "middle",
})
local ROW_BREAK = set({ "\\", "cr", "newline" })
local ENV_OPEN = {
  pmatrix = "(", bmatrix = "[", Bmatrix = "{", vmatrix = "|", Vmatrix = "‖", cases = "{",
}
local ENV_CLOSE = {
  pmatrix = ")", bmatrix = "]", Bmatrix = "}", vmatrix = "|", Vmatrix = "‖", rcases = "}",
}
-- These environments take a second group (column spec or column count).
local ENV_WITH_ARG = set({ "array", "tabular", "alignat", "alignat*" })
local DROP_ARG = set({ "label", "phantom", "hphantom", "vphantom", "vspace" })
local DROP = set({
  "nonumber", "notag", "displaystyle", "textstyle", "scriptstyle",
  "scriptscriptstyle", "limits", "nolimits", "mathstrut", "allowbreak", "strut",
  "hfill", "noindent", "relax", "hline",
})
local PASS = set({
  "boxed", "mathclap", "mathrlap", "mathllap", "overbrace", "underbrace", "substack",
})
local SPACE = {
  [","] = 1, [";"] = 1, [":"] = 1, [">"] = 1, [" "] = 1, ["\t"] = 1, ["\n"] = 1,
  ["\r"] = 1, enspace = 1, thinspace = 1, medspace = 1, thickspace = 1,
  quad = 2, qquad = 4, ["!"] = 0,
}
local NOT_CHAR = { ["="] = "≠", ["<"] = "≮", [">"] = "≯" }
local NOT_CMD = {
  ["in"] = "∉", ni = "∌", equiv = "≢", subset = "⊄", supset = "⊅",
  subseteq = "⊈", supseteq = "⊉", le = "≰", leq = "≰", ge = "≱", geq = "≱",
  sim = "≁", exists = "∄", mid = "∤",
}
-- Escapes that print their own character inside \text.
local TEXT_ESC = set({ "$", "%", "&", "#", "_", "{", "}", "|" })
-- A fraction side holding one of these at bracket depth 0 is parenthesised:
-- `(a+b)/c`, but `n(n+1)/2`.
local LOOSE = set({
  " ", "+", "-", "=", "±", "∓", "·", "×", "∗", "*", "/", ",", ";", "<", ">",
  "≤", "≥", "≠", "≈", "≡", "∼", "≃", "≅", "∝", "→", "←", "↔", "⇒", "⇐", "⇔",
  "∈", "∉", "∧", "∨", "∪", "∩", "⊂", "⊃", "⊆", "⊇", "|", "‖",
})
local OPEN = set({ "(", "[", "{" })
local CLOSE = set({ ")", "]", "}" })
-- Output that ends in one of these is not a factor: a function name after it
-- gets no space of its own, and a fraction after it is not parenthesised.
local OPERATOR = {}
for c in pairs(LOOSE) do OPERATOR[c] = true end
for name in pairs(RELBIN) do OPERATOR[SYMBOLS[name]] = true end
for _, c in ipairs({ "⟨", "⌊", "⌈", "⌜", "⌞", "⟮", "√", "∛", "∜", "¬", ":" }) do OPERATOR[c] = true end
local NOT_FACTOR = {}
for c in pairs(OPERATOR) do NOT_FACTOR[c] = true end
for name in pairs(BIGOP) do NOT_FACTOR[SYMBOLS[name]] = true end
for _, c in ipairs({ "⋯", "…", "⋮", "⋱", "^", "_", "'", "!", "." }) do NOT_FACTOR[c] = true end
-- A command right after a fraction that multiplies it: `\frac{g}{l}\sin`.
local CLOSE_DELIM = set({
  "rangle", "rvert", "rVert", "rfloor", "rceil", "rbrace", "rbrack",
  "urcorner", "lrcorner", "rgroup", "}", "$", "%", "&", "#", "_",
  "cdots", "ldots", "dots", "dotsc", "dotso", "dotsb", "dotsm", "dotsi", "hdots",
  "vdots", "ddots",
})
local OPEN_SIZER = set({ "left", "bigl", "Bigl", "biggl", "Biggl" })
-- Math commands that keep their meaning inside \text{..}: `\text{\mathbb{R}}`.
local TEXT_MATH = set({ "frac", "dfrac", "tfrac", "cfrac", "binom", "sqrt" })

-- ---------- tokenizer ----------

local WS = { [32] = true, [9] = true, [10] = true, [11] = true, [12] = true, [13] = true }
local SINGLE = { [123] = "{", [125] = "}", [94] = "^", [95] = "_", [38] = "&" }

local function is_letter(b)
  return b and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

function M.tokenize(tex)
  local toks = {}
  local p, n = 1, #tex
  while p <= n do
    local b = tex:byte(p)
    if b == 92 then -- backslash
      local q = p + 1
      while q <= n and is_letter(tex:byte(q)) do q = q + 1 end
      if q > p + 1 then
        toks[#toks + 1] = { t = "cmd", v = tex:sub(p + 1, q - 1) }
        p = q
      elseif p < n then
        local c = char_at(tex, p + 1)
        toks[#toks + 1] = { t = "cmd", v = c }
        p = p + 1 + #c
      else
        toks[#toks + 1] = { t = "char", v = "\\" }
        p = p + 1
      end
    elseif SINGLE[b] then
      toks[#toks + 1] = { t = SINGLE[b] }
      p = p + 1
    elseif WS[b] then
      local q = p
      while q <= n and WS[tex:byte(q)] do q = q + 1 end
      toks[#toks + 1] = { t = "sp", v = tex:sub(p, q - 1) }
      p = q
    elseif b == 37 then -- `%` starts a TeX comment that runs to the end
      break
    else
      local c = char_at(tex, p)
      toks[#toks + 1] = { t = "char", v = c }
      p = p + #c
    end
  end
  return toks
end

-- ---------- renderer ----------

-- Groups and command arguments recurse; past this depth braces are dropped
-- and arguments read as empty so `{{{{...` cannot overflow the Lua stack.
local MAX_DEPTH = 64
local depth = 0
-- Output cap per sequence, set by M.render from the input size: no state may
-- hold more than this many bytes, so hostile nesting fails fast to the source.
local budget = math.huge

local render_seq, step

-- Output is a list of parts joined once by `result`; `last` is the final
-- byte written so far (nil while nothing has been written), which is all the
-- gap rules need to know about what came before.
local function new_state()
  return { parts = {}, n = 0, bytes = 0, last = nil, gap = 0 }
end

local function append(st, s)
  if s == "" then return end
  st.bytes = st.bytes + #s
  if st.bytes > budget then error("mathtext: output budget exceeded") end
  st.n = st.n + 1
  st.parts[st.n] = s
  st.last = s:sub(-1)
end

local function result(st)
  return table.concat(st.parts, "", 1, st.n)
end

-- The last UTF-8 char written to st, or nil.
local function tail(st)
  local piece = st.parts[st.n]
  if not piece then return nil end
  local k = #piece
  while k > 1 do
    local b = piece:byte(k)
    if b < 0x80 or b > 0xBF then break end
    k = k - 1
  end
  return piece:sub(k)
end

-- True when st ends in something a following factor multiplies: `2`, `x`,
-- `)`, `θ`, `²`, but not an operator, an opening bracket or a space.
local function factor_before(st)
  if st.gap > 0 then return false end
  local c = tail(st)
  if not c then return false end
  if #c == 1 then return c:find("^[%w%)%]]") ~= nil end
  return not NOT_FACTOR[c]
end

-- True when toks[j], with no space before it, multiplies what precedes it.
local function factor_after(toks, j)
  local tk = toks[j]
  if not tk then return false end
  local t = tk.t
  if t == "{" or t == "^" or t == "_" then return true end
  if t == "char" then return #tk.v == 1 and tk.v:find("^[%w(|]") ~= nil end
  if t ~= "cmd" then return false end
  local n = tk.v
  if FUNC[n] or FRAC[n] or BINOM[n] or n == "sqrt" or FONTS[n] or ACCENTS[n]
    or PLAIN[n] or OPEN_SIZER[n] then
    return true
  end
  return SYMBOLS[n] ~= nil and not RELBIN[n] and not CLOSE_DELIM[n]
end

-- Set by read_arg while it renders one command as an argument (`^\frac12`),
-- where the caller already brackets the result.
local arg_ctx = false

local function space(st, n)
  if n > st.gap then st.gap = n end
end

-- Spaces collapse into one pending gap that is written only between two
-- pieces of output, never after an opening bracket or before a closing one.
-- Non-ASCII opening brackets: no gap after them, like `(`. `‖` and `|` open
-- and close alike, so they are left out.
local OPEN_GLYPH = set({ "⟨", "⌊", "⌈", "⌜", "⟮" })

local function emit(st, s)
  if s == "" then return end
  local first = s:sub(1, 1)
  if first ~= ")" and first ~= "]" and first ~= "}" and st.gap > 0 and st.last then
    local last = st.last
    local opened = last == "(" or last == "[" or last == "{"
      or (last:byte() >= 0x80 and OPEN_GLYPH[tail(st)])
    if not opened then
      local n = st.gap
      -- `\text{if } x` already carries its space
      if last == " " or first == " " then n = n - 1 end
      if n > 0 then append(st, string.rep(" ", n)) end
    end
  end
  st.gap = 0
  append(st, s)
end

local function skip_sp(toks, i)
  while toks[i] and toks[i].t == "sp" do i = i + 1 end
  return i
end

local function skip_star(toks, i)
  if toks[i] and toks[i].t == "char" and toks[i].v == "*" then return i + 1 end
  return i
end

local function read_arg(toks, i, mode)
  local j = skip_sp(toks, i)
  local tk = toks[j]
  if not tk or depth >= MAX_DEPTH then return "", i end
  if tk.t == "{" then return render_seq(toks, j + 1, "}", mode) end
  if tk.t == "char" then return tk.v, j + 1 end
  if tk.t == "cmd" then
    -- one whole command with its own arguments: `^\infty`, `^\frac{1}{2}`
    local sub = new_state()
    depth = depth + 1
    arg_ctx = true
    local k = step(toks, j, sub, mode)
    depth = depth - 1
    return result(sub), k
  end
  return "", i
end

local function read_opt(toks, i)
  local j = skip_sp(toks, i)
  local tk = toks[j]
  if depth < MAX_DEPTH and tk and tk.t == "char" and tk.v == "[" then
    return render_seq(toks, j + 1, "]", "math")
  end
  return nil, i
end

local function one_char(s)
  return s ~= "" and #char_at(s, 1) == #s
end

local function all_in(s, map)
  local out = {}
  for _, c in ipairs(chars(s)) do
    local g = map[c]
    if not g then return nil end
    out[#out + 1] = g
  end
  return table.concat(out)
end

-- A script as glyphs when every char has one, else spelled out with its mark;
-- nested scripts never stack glyphs, so `e^{-x^2}` reads `e^(-x²)`.
local function script(arg, map, mark)
  if arg == "" then return mark end
  local glyphs = all_in(arg, map)
  if glyphs then return glyphs end
  if one_char(arg) then return mark .. arg end
  return mark .. "(" .. arg .. ")"
end

-- Bytes, not a chars() list: fractions nest up to MAX_DEPTH levels and each
-- level scans its whole argument.
local LOOSE_BYTE = {}
for c in pairs(LOOSE) do
  if #c == 1 then LOOSE_BYTE[c:byte()] = true end
end

local function wrap(s)
  local d, p, n = 0, 1, #s
  while p <= n do
    local b = s:byte(p)
    if b < 0x80 then
      if b == 40 or b == 91 or b == 123 then
        d = d + 1
      elseif b == 41 or b == 93 or b == 125 then
        if d > 0 then d = d - 1 end
      elseif d == 0 and LOOSE_BYTE[b] then
        return "(" .. s .. ")"
      end
      p = p + 1
    else
      local c = char_at(s, p)
      if d == 0 and LOOSE[c] then return "(" .. s .. ")" end
      p = p + #c
    end
  end
  return s
end

-- A combining mark (U+0300-U+036F, U+20D0-U+20FF): two-byte CC 80..CD AF,
-- three-byte E2 83 90..E2 83 BF.
local function is_mark(c)
  local b1, b2, b3 = c:byte(1, 3)
  if #c == 2 then return (b1 == 0xCC) or (b1 == 0xCD and b2 <= 0xAF) end
  return #c == 3 and b1 == 0xE2 and b2 == 0x83 and b3 >= 0x90
end

-- The mark goes after each base char and the marks already on it, once per
-- char: `\hat{\hat{x}}` is x + one U+0302, so nesting never multiplies output.
local function accent(s, mark)
  local out, n, open, has = {}, 0, false, false
  local function close()
    if open and not has then
      n = n + 1
      out[n] = mark
    end
  end
  for _, c in ipairs(chars(s)) do
    if is_mark(c) then
      if c == mark then has = true end
    else
      close()
      open, has = true, false
    end
    n = n + 1
    out[n] = c
  end
  close()
  return table.concat(out, "", 1, n)
end

local function map_chars(s, map)
  local out = {}
  for _, c in ipairs(chars(s)) do out[#out + 1] = map[c] or c end
  return table.concat(out)
end

-- True when a row break is the last thing on its line or in its group, so a
-- block line `a &= b \\` does not end in `;`.
local function rest_blank(toks, i)
  local tk = toks[skip_sp(toks, i)]
  return not tk or tk.t == "}" or (tk.t == "cmd" and tk.v == "end")
end

local function text_cmd(name)
  if SYMBOLS[name] then return SYMBOLS[name] end
  if TEXT_ESC[name] then return name end
  if SPACE[name] == 1 and #name == 1 then return " " end
  if name == "textbackslash" then return "\\" end
  -- a nested \textbf{..} inside \text{..}: its group renders as content
  if TEXT[name] or PLAIN[name] then return "" end
  return "\\" .. name
end

-- A function name, its scripts, then a space: `n\log n` reads `n log n`,
-- `\sin^2\theta` reads `sin² θ`; none before an operator or after `(`.
-- No space between a function name and an opening delimiter: `exp(x)`,
-- `E[X]`, `max{a,b}`, `exp(-x²/2)` from `\exp\left(`.
local FUNC_OPEN_CHAR = set({ "(", "[", "|" })
local FUNC_OPEN_CMD = set({ "{", "|", "langle", "lvert", "lVert", "lfloor", "lceil" })

local function emit_func(toks, j, st, text)
  local c = tail(st)
  if c and (#c == 1 and c:find("^[%w%)%]]") or #c > 1 and not OPERATOR[c]) then
    space(st, 1)
  end
  emit(st, text)
  while toks[j] and (toks[j].t == "^" or toks[j].t == "_") do
    j = step(toks, j, st, "math")
  end
  local tk = toks[j]
  local opens = tk and ((tk.t == "char" and FUNC_OPEN_CHAR[tk.v])
    or (tk.t == "cmd" and (FUNC_OPEN_CMD[tk.v] or OPEN_SIZER[tk.v])))
  if not opens then space(st, 1) end
  return j
end

local function math_cmd(toks, i, st, in_arg)
  local name = toks[i].v
  local j = i + 1
  local a, b, _

  if FRAC[name] then
    -- `2\frac{1}{3}` is 2(1/3), not 21/3: a fraction multiplied by a
    -- neighbour with no space between is parenthesised whole.
    local before = not in_arg and factor_before(st)
    a, j = read_arg(toks, j, "math")
    b, j = read_arg(toks, j, "math")
    local s = wrap(a) .. "/" .. wrap(b)
    if before or (not in_arg and factor_after(toks, j)) then s = "(" .. s .. ")" end
    emit(st, s)
    return j
  end
  if BINOM[name] then
    a, j = read_arg(toks, j, "math")
    b, j = read_arg(toks, j, "math")
    emit(st, "C(" .. a .. "," .. b .. ")")
    return j
  end
  if name == "sqrt" then
    local idx
    idx, j = read_opt(toks, j)
    a, j = read_arg(toks, j, "math")
    local prefix = "√"
    if idx == "3" then
      prefix = "∛"
    elseif idx == "4" then
      prefix = "∜"
    elseif idx then
      local glyphs = all_in(idx, SUPER)
      prefix = glyphs and (glyphs .. "√") or ("√[" .. idx .. "]")
    end
    if one_char(a) then
      -- `\sqrt{x}^2` is (√x)², not √x²
      if not in_arg and factor_after(toks, j) then
        emit(st, "(" .. prefix .. a .. ")")
      else
        emit(st, prefix .. a)
      end
    else
      emit(st, prefix .. "(" .. a .. ")")
    end
    return j
  end
  if FONTS[name] then
    a, j = read_arg(toks, j, "math")
    emit(st, map_chars(a, FONTS[name]))
    return j
  end
  if PLAIN[name] then
    a, j = read_arg(toks, skip_star(toks, j), "math")
    if name == "operatorname" and a ~= "" then return emit_func(toks, j, st, a) end
    emit(st, a)
    return j
  end
  if TEXT[name] then
    a, j = read_arg(toks, j, "text")
    emit(st, a)
    return j
  end
  if ACCENTS[name] then
    a, j = read_arg(toks, j, "math")
    emit(st, accent(a, utf8char(ACCENTS[name])))
    return j
  end
  if SIZERS[name] then
    j = skip_sp(toks, j)
    local tk = toks[j]
    if tk and tk.t == "char" then
      if tk.v ~= "." then emit(st, tk.v) end
      return j + 1
    elseif tk and tk.t == "cmd" then
      emit(st, SYMBOLS[tk.v] or ("\\" .. tk.v))
      return j + 1
    end
    return j
  end
  if ROW_BREAK[name] then
    _, j = read_opt(toks, j)
    if rest_blank(toks, j) or not st.last then return j end
    -- the space before `\\` belongs to the row, not before the `;`
    st.gap = 0
    emit(st, ";")
    space(st, 1)
    return j
  end
  if name == "begin" or name == "end" then
    local env
    env, j = read_arg(toks, j, "math")
    if name == "begin" then
      if ENV_WITH_ARG[env] then _, j = read_arg(toks, j, "math") end
      emit(st, ENV_OPEN[env] or "")
    else
      emit(st, ENV_CLOSE[env] or "")
    end
    return j
  end
  if DROP_ARG[name] then
    _, j = read_arg(toks, skip_star(toks, j), "math")
    return j
  end
  if DROP[name] then return j end
  if name == "hspace" then
    _, j = read_arg(toks, skip_star(toks, j), "math")
    space(st, 1)
    return j
  end
  if name == "color" then
    _, j = read_arg(toks, j, "math")
    return j
  end
  if name == "textcolor" or name == "colorbox" or name == "fcolorbox" then
    _, j = read_arg(toks, j, "math")
    if name == "fcolorbox" then _, j = read_arg(toks, j, "math") end
    a, j = read_arg(toks, j, "math")
    emit(st, a)
    return j
  end
  if PASS[name] then
    a, j = read_arg(toks, j, "math")
    emit(st, a)
    return j
  end
  if name == "tag" or name == "eqref" then
    a, j = read_arg(toks, skip_star(toks, j), "math")
    emit(st, "(" .. a .. ")")
    return j
  end
  if name == "ref" then
    a, j = read_arg(toks, j, "math")
    emit(st, a)
    return j
  end
  if name == "overset" or name == "stackrel" or name == "underset" then
    a, j = read_arg(toks, j, "math")
    b, j = read_arg(toks, j, "math")
    if a ~= "" then
      if name == "underset" then
        b = b .. script(a, SUB, "_")
      else
        b = b .. script(a, SUPER, "^")
      end
    end
    emit(st, b)
    return j
  end
  if name == "xrightarrow" or name == "xleftarrow" then
    _, j = read_opt(toks, j)
    a, j = read_arg(toks, j, "math")
    local arrow = name == "xrightarrow" and "→" or "←"
    emit(st, a ~= "" and (arrow .. script(a, SUPER, "^")) or arrow)
    return j
  end
  if name == "not" then
    local k = skip_sp(toks, j)
    local tk = toks[k]
    local neg = tk and ((tk.t == "char" and NOT_CHAR[tk.v]) or (tk.t == "cmd" and NOT_CMD[tk.v]))
    if neg then
      emit(st, neg)
      return k + 1
    end
    -- no negated glyph: a slash, then the token renders as usual
    emit(st, "/")
    return k
  end
  if name == "pmod" then
    a, j = read_arg(toks, j, "math")
    emit(st, "(mod " .. a .. ")")
    return j
  end
  if name == "bmod" or name == "mod" then
    emit(st, "mod")
    return j
  end
  if SPACE[name] then
    if SPACE[name] > 0 then space(st, SPACE[name]) end
    return j
  end
  if FUNC[name] then return emit_func(toks, j, st, SYMBOLS[name]) end
  if RELBIN[name] then
    -- mirror the source's one-sided spacing: `a\le b` reads `a ≤ b`
    local had = st.gap > 0
    local after = toks[j] and toks[j].t == "sp"
    if after then space(st, 1) end
    emit(st, SYMBOLS[name])
    if had and not after then space(st, 1) end
    return j
  end
  if SYMBOLS[name] then
    emit(st, SYMBOLS[name])
    return j
  end
  -- Unknown: shown as written so nothing silently disappears (a user macro
  -- reads `\RR`), with its groups rendered.
  emit(st, "\\" .. name)
  while toks[j] and toks[j].t == "{" and depth < MAX_DEPTH do
    a, j = render_seq(toks, j + 1, "}", "math")
    emit(st, "{" .. a .. "}")
  end
  return j
end

-- One token (a command with all of its arguments) into st; returns the next
-- index.
step = function(toks, i, st, mode)
  local tk = toks[i]
  local t = tk.t
  local in_arg = arg_ctx
  arg_ctx = false
  if mode == "text" then
    local nx = toks[i + 1]
    if t == "cmd" and (TEXT_MATH[tk.v] or FONTS[tk.v] or ACCENTS[tk.v]) and nx and depth < MAX_DEPTH
      and (nx.t == "{" or (tk.v == "sqrt" and nx.t == "char" and nx.v == "[")) then
      -- `\text{\mathbb{R}}`: a math command with its group keeps its meaning
      local sub = new_state()
      depth = depth + 1
      local k = math_cmd(toks, i, sub, true)
      depth = depth - 1
      append(st, result(sub))
      return k
    end
    if t == "{" then
      local s
      s, i = render_seq(toks, i + 1, "}", "text")
      append(st, s)
      return i
    elseif t == "cmd" then
      append(st, text_cmd(tk.v))
    elseif t ~= "}" then
      -- spaces verbatim, `^ _ &` as themselves
      append(st, tk.v or t)
    end
    return i + 1
  end

  if t == "sp" or t == "&" then
    space(st, 1)
    return i + 1
  end
  if t == "{" then
    local s
    s, i = render_seq(toks, i + 1, "}", mode)
    emit(st, s)
    return i
  end
  if t == "}" then return i + 1 end
  if t == "^" or t == "_" then
    local arg
    arg, i = read_arg(toks, i + 1, "math")
    st.gap = 0
    emit(st, script(arg, t == "^" and SUPER or SUB, t))
    return i
  end
  if t == "char" then
    if tk.v == "~" then
      space(st, 1)
    else
      emit(st, tk.v)
    end
    return i + 1
  end
  return math_cmd(toks, i, st, in_arg)
end

-- Renders from toks[i] to the end, to the `}` closing the current group
-- (stop "}"), or to a `]` at this level (stop "]", optional arguments).
render_seq = function(toks, i, stop, mode)
  local st = new_state()
  depth = depth + 1
  while i <= #toks do
    local tk = toks[i]
    if tk.t == "}" then
      i = i + 1
      -- a stray `}` with nothing open is ignored
      if stop == "}" then break end
    elseif stop == "]" and tk.t == "char" and tk.v == "]" then
      i = i + 1
      break
    elseif tk.t == "{" and depth >= MAX_DEPTH then
      i = i + 1
    else
      i = step(toks, i, st, mode)
    end
  end
  depth = depth - 1
  return result(st), i
end

-- render runs per cell on every edit; most math repeats between edits.
local cache, cache_n = {}, 0
local CACHE_MAX = 512

function M.render(tex)
  if type(tex) ~= "string" then tex = tostring(tex or "") end
  local hit = cache[tex]
  if hit then return hit end
  local ok, out = pcall(function()
    depth = 0
    budget = 8 * #tex + 256
    local s = render_seq(M.tokenize(tex), 1, nil, "math")
    return vim.trim(s)
  end)
  budget = math.huge
  -- A renderer bug, or output past the budget, must never break the markdown
  -- view: show the source. Failures are not cached.
  -- Neovim cuts virt_text at a NUL byte; show it as a visible placeholder.
  if not ok or type(out) ~= "string" then return (vim.trim(tex):gsub("%z", "\u{2400}")) end
  out = out:gsub("%z", "\u{2400}")
  if cache_n >= CACHE_MAX then
    cache, cache_n = {}, 0
  end
  cache[tex] = out
  cache_n = cache_n + 1
  return out
end

M.SYMBOLS = SYMBOLS
M.SUPER = SUPER
M.SUB = SUB

return M
