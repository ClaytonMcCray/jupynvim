-- Headless verification of the TeX -> terminal text renderer.
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(here, ":p:h:h"))
local MT = require("jupynvim.notebook.mathtext")

local failed = 0
local function fail(msg)
  failed = failed + 1
  print("FAIL: " .. msg)
end

-- 1. input -> expected rendering
local cases = {
  { [[I(t) \approx I'(t) = I_0 e^{t/\text{timeConstant}}]], "I(t) ≈ I'(t) = I₀ e^(t/timeConstant)" },
  { [[e^{-x^2}]], "e^(-x²)" },
  { [[x^{10} + y_{12}]], "x¹⁰ + y₁₂" },
  { [[a_{ij} b^{C}]], "aᵢⱼ b^C" },
  { [[\frac{a+b}{c}]], "(a+b)/c" },
  { [[\frac{1}{1+\frac{1}{x}}]], "1/(1+1/x)" },
  { [[\sum_{i=1}^{n} i = \frac{n(n+1)}{2}]], "∑ᵢ₌₁ⁿ i = n(n+1)/2" },
  { [[\mathbb{R}^n \to \mathbb{R}]], "ℝⁿ → ℝ" },
  { [[\mathrm{d}x]], "dx" },
  { [[\text{if } x > 0]], "if x > 0" },
  { [[\left( \frac{a}{b} \right)]], "(a/b)" },
  { [[\vec{v} \cdot \hat{n}]], "v\u{20D7} · n\u{0302}" },
  { [[\lim_{x \to 0} \frac{\sin x}{x} = 1]], "lim_(x → 0) (sin x)/x = 1" },
  { [[\int_0^\infty e^{-t} dt]], "∫₀^∞ e⁻ᵗ dt" },
  { [[\alpha_1^2 + \beta^{n+1}]], "α₁² + βⁿ⁺¹" },
  { [[\sqrt{x^2 + y^2}]], "√(x² + y²)" },
  { [[\dot{x} = Ax + Bu]], "x\u{0307} = Ax + Bu" },
  { [[P(A \mid B) = \frac{P(B \mid A)P(A)}{P(B)}]], "P(A | B) = P(B | A)P(A)/P(B)" },
  { [[\| x \|_2 \le \epsilon]], "‖ x ‖₂ ≤ ϵ" },
  { [[E = mc^2]], "E = mc²" },
  { [[x^2]], "x²" },
  { [[x^C]], "x^C" },
  { [[x_i^2]], "xᵢ²" },
  { [[x^\prime]], "x′" },
  { [[\sqrt[3]{x}]], "∛x" },
  { [[\sqrt[n]{1 + x^2}]], "ⁿ√(1 + x²)" },
  { [[\begin{pmatrix} a & b \\ c & d \end{pmatrix}]], "(a b; c d)" },
  { [[\left\{ x \in \mathbb{R} \mid x > 0 \right\}]], "{x ∈ ℝ | x > 0}" },
  { [[\badmacro{x}]], [[\badmacro{x}]] },
  { [[\frac{1}{$]], "1/$" },
  { [[x^$]], "x^$" },
  { [[a \\ b]], "a; b" },
  { [[\$4 + x]], "$4 + x" },
  { [[\{a, b\}]], "{a, b}" },
  { [[\#\%\&\_]], "#%&_" },
  { [[x \lt y]], "x < y" },
  { [[a \quad b]], "a  b" },
  { [[\nabla \cdot \mathbf{E} &= \frac{\rho}{\varepsilon_0} \\]], "∇ · 𝐄 = ρ/ε₀" },
  { [[\hat{\beta}]], "β\u{0302}" },
  { [[\overline{AB}]], "A\u{0305}B\u{0305}" },
  { [[\operatorname{argmax}_{x} f(x)]], "argmaxₓ f(x)" },
  { [[\mathcal{L}\{f\}(s) = \int_0^\infty f(t) e^{-st}\,dt]], "ℒ{f}(s) = ∫₀^∞ f(t) e⁻ˢᵗ dt" },
  -- m, a and x all have subscript glyphs, so the script rule (3.3) gives
  -- glyphs, not `x_(max)`
  { [[x_{\text{max}}]], "xₘₐₓ" },
  { [[\lim_{n\to\infty} a_n = L]], "lim_(n→∞) aₙ = L" },
  { [[\mathbf{v} \in \mathbb{N}^2]], "𝐯 ∈ ℕ²" },
  { [[\mathfrak{g}]], "𝔤" },
  { [[\boldsymbol{\alpha}]], "α" },
  { [[\tag{Euler} \label{eq:euler}]], "(Euler)" },
  { [[a % comment]], "a" },
  { [[\eqref{eq:euler}]], "(eq:euler)" },
  { [[\sin^2 \theta + \cos^2 \theta = 1]], "sin² θ + cos² θ = 1" },
  { [[f'(x) = \lim_{h \to 0} \frac{f(x+h) - f(x)}{h}]], "f'(x) = lim_(h → 0) (f(x+h) - f(x))/h" },
  { [[\color{red}{x + y}]], "x + y" },
  { [[\binom{n}{k}]], "C(n,k)" },
  { [[A^\dagger]], "A†" },
  { [[\left( \sum_{k=1}^{n} \frac{x_k}{\sqrt{1 + x_k^2}} \right)^{2}]], "(∑ₖ₌₁ⁿ xₖ/√(1 + xₖ²))²" },
  { [[α + β = γ]], "α + β = γ" },
  { [[]], "" },
  -- a fraction or one-char root multiplied by a neighbour is parenthesised
  { [[2\frac{1}{3}]], "2(1/3)" },
  { [[\frac{1}{2}mv^2]], "(1/2)mv²" },
  { [[\frac{a}{b}\frac{c}{d}]], "(a/b)(c/d)" },
  { [[\frac{dy}{du}\frac{du}{dx}]], "(dy/du)(du/dx)" },
  { [[\frac{a}{b}^2]], "(a/b)²" },
  { [[\frac{1}{\sqrt{d_k}}QK^T]], "(1/√(dₖ))QK^T" },
  { [[\frac{g}{l}\sin\theta]], "(g/l) sin θ" },
  { [[\sqrt{x}^2]], "(√x)²" },
  -- function names are set off from the factors around them
  { [[O(n\log n)]], "O(n log n)" },
  { [[i\sin\theta]], "i sin θ" },
  { [[\log\frac{P(x)}{Q(x)}]], "log P(x)/Q(x)" },
  { [[e^x\sin x]], "eˣ sin x" },
  { [[\sin\theta\cos\phi]], "sin θ cos ϕ" },
  { [[n\ln n]], "n ln n" },
  { [[\sin{x}]], "sin x" },
  -- one-sided spacing around relations and binary operators is mirrored
  { [[a\pm b]], "a ± b" },
  { [[a\le b]], "a ≤ b" },
  { [[a\le{}b]], "a≤b" },
  { [[\sum_{n\geq 1}]], "∑_(n ≥ 1)" },
  { [[\mathbb{R}^{n\times m}]], "ℝ^(n × m)" },
  { [[\frac{a}{b}\cdot c]], "a/b · c" },
  -- coverage
  { [[\sum_{\substack{i<n}} x_i]], "∑_(i<n) xᵢ" },
  { [[90^\circ]], "90°" },
  { [[\text{\mathbb{R}}]], "ℝ" },
  -- a fraction before a norm or absolute-value bar is parenthesised
  { [[\frac{1}{2}\|w\|^2]], "(1/2)‖w‖²" },
  { [[\frac{\lambda}{2}\|w\|^2]], "(λ/2)‖w‖²" },
  { [[\frac{1}{2}|x|]], "(1/2)|x|" },
  -- the space after `\vert` stays: `|` opens and closes alike, so it is not
  -- treated as an opener (same as `\lVert w\rVert` -> `‖ w‖`)
  { [[\frac{1}{2}\vert x\vert]], "(1/2)| x|" },
  { [[\left\|\frac{a}{b}\right\|]], "‖a/b‖" },
  { [[\frac{a}{b} | c]], "a/b | c" },
  -- no space between a function name and an opening delimiter
  { [[\exp\left(-\frac{x^2}{2}\right)]], "exp(-x²/2)" },
  { [[\operatorname{E}[X] ]], "E[X]" },
  { [[\Pr[A] ]], "Pr[A]" },
  { [[\max\{a,b\}]], "max{a,b}" },
  -- \colon is punctuation, not a relation
  { [[f\colon X\to Y]], "f: X → Y" },
  -- no gap after a non-ASCII opening bracket
  { [[\langle x, y\rangle]], "⟨x, y⟩" },
  { [[\lfloor x\rfloor]], "⌊x⌋" },
}
for _, c in ipairs(cases) do
  local ok, got = pcall(MT.render, c[1])
  if not ok or got ~= c[2] then
    fail(c[1] .. " => [" .. tostring(got) .. "] want [" .. c[2] .. "]")
  end
end

-- 2. every command name of the plan's symbol table is present
local names = {
  -- Greek
  "alpha beta gamma delta epsilon varepsilon zeta eta theta vartheta iota kappa varkappa",
  "lambda mu nu xi omicron pi varpi rho varrho sigma varsigma tau upsilon phi varphi chi",
  "psi omega Gamma Delta Theta Lambda Xi Pi Sigma Upsilon Phi Psi Omega Alpha Beta",
  "Epsilon Zeta Eta Iota Kappa Mu Nu Omicron Rho Tau Chi",
  -- binary
  "pm mp times div cdot ast star circ bullet oplus ominus otimes oslash odot cup cap",
  "setminus smallsetminus wedge land vee lor lnot neg sqcup sqcap uplus wr dagger",
  "ddagger diamond bigcirc triangleleft triangleright amalg",
  -- relations
  "le leq ge geq ne neq equiv approx sim simeq cong propto ll gg prec succ preceq succeq",
  "subset supset subseteq supseteq subsetneq supsetneq sqsubseteq sqsupseteq in notin",
  "ni owns mid nmid parallel nparallel perp vdash dashv models doteq asymp bowtie lt gt",
  "leqslant geqslant lesssim gtrsim triangleq coloneqq colon",
  -- arrows
  "to rightarrow leftarrow gets leftrightarrow Rightarrow Leftarrow Leftrightarrow",
  "implies impliedby iff mapsto longrightarrow longleftarrow longmapsto Longrightarrow",
  "Longleftarrow Longleftrightarrow uparrow downarrow updownarrow Uparrow Downarrow",
  "nearrow searrow swarrow nwarrow hookrightarrow hookleftarrow rightharpoonup",
  "leftharpoonup rightleftharpoons leftrightarrows twoheadrightarrow",
  -- big operators
  "sum prod coprod int iint iiint oint oiint bigcup bigcap bigvee bigwedge bigoplus",
  "bigotimes bigodot biguplus bigsqcup",
  -- misc
  "infty partial nabla forall exists nexists emptyset varnothing hbar ell Re Im aleph",
  "beth wp angle measuredangle triangle top bot prime backprime degree checkmark square",
  "Box blacksquare flat sharp natural clubsuit diamondsuit heartsuit spadesuit S P",
  "copyright pounds therefore because surd complement imath jmath eth",
  -- dots
  "cdots ldots dots dotsc dotso dotsb dotsm dotsi hdots vdots ddots",
  -- delimiters
  "langle rangle lvert rvert vert Vert lVert rVert lfloor rfloor lceil rceil lbrace",
  "rbrace lbrack rbrack ulcorner urcorner llcorner lrcorner lgroup rgroup backslash",
  -- control symbols
  "{ } | $ % & # _",
  -- function names
  "sin cos tan cot sec csc arcsin arccos arctan sinh cosh tanh coth log ln lg exp lim",
  "max min sup inf det dim ker deg gcd lcm arg hom Pr argmax argmin sgn injlim projlim",
  "limsup liminf",
  -- KaTeX shorthands
  "R N Z Reals Complex natnums cnums infin isin notni sdot plusmn larr rarr harr lArr",
  "rArr hArr uarr darr alef weierp real image bull exist empty sub sube supe thetasym",
}
for _, row in ipairs(names) do
  for name in row:gmatch("%S+") do
    if MT.SYMBOLS[name] == nil then fail("SYMBOLS." .. name .. " missing") end
  end
end
if MT.SYMBOLS.limsup ~= "lim sup" then fail("SYMBOLS.limsup") end

-- 3. smoke: every $..$ / $$..$$ body of the markdown fixture renders without
-- raising (a throwaway pair scan; span detection proper lives in markdown.lua)
local fixture = vim.fn.fnamemodify(here, ":p:h") .. "/fixtures/markdown/md-fixture.md"
local lines = vim.fn.readfile(fixture)
if #lines == 0 then fail("fixture not read: " .. fixture) end
local bodies = 0
for _, line in ipairs(lines) do
  local p = 1
  while true do
    local a = line:find("$", p, true)
    if not a then break end
    local dd = line:sub(a, a + 1) == "$$"
    local open = dd and 2 or 1
    local b = line:find(dd and "$$" or "$", a + open, true)
    if not b then break end
    local inner = line:sub(a + open, b - 1)
    bodies = bodies + 1
    local ok, got = pcall(MT.render, inner)
    if not ok or type(got) ~= "string" then
      fail("fixture body raised: " .. inner .. " => [" .. tostring(got) .. "] want [string]")
    end
    p = b + open
  end
end
if bodies == 0 then fail("no math bodies found in " .. fixture) end

-- 4. hostile input never raises and nests safely
for _, s in ipairs({ "\\", "{", "}", "^", "_", "\\frac", "\\sqrt[", "\\left", "\\begin{",
  string.rep("{", 5000) .. "x", string.rep("\\frac", 5000), string.rep("x^{", 3000),
  "\255\254", "\\not", "\\\\[" }) do
  local ok, got = pcall(MT.render, s)
  if not ok or type(got) ~= "string" then
    fail(s:sub(1, 20) .. " => [" .. tostring(got) .. "] want [string]")
  end
end

-- 5. hostile input stays bounded: output budget, accent nesting, NUL, speed
do
  -- (a) 30 nested accents would be 2^30 chars if each level re-marked every
  -- char; output must stay within the 8 * #input + 256 byte budget.
  local s = string.rep("\\hat{", 30) .. "x" .. string.rep("}", 30)
  local ok, got = pcall(MT.render, s)
  if not ok or type(got) ~= "string" or #got > 8 * #s + 256 then
    fail("nested \\hat x30 => " .. (ok and type(got) == "string" and (#got .. " bytes") or tostring(got))
      .. " want <= " .. (8 * #s + 256) .. " bytes")
  end
  -- (b) an accent goes on base chars only, once per mark: a repeated accent
  -- is not stacked, so x + exactly one U+0302.
  got = MT.render([[\hat{\hat{x}}]])
  if got ~= "x\u{0302}" then fail("\\hat{\\hat{x}} => [" .. got .. "] want [x\u{0302}]") end
  -- (c) Neovim cuts virt_text at NUL, so NUL shows as U+2400.
  got = MT.render("x\0y")
  if got ~= "x\u{2400}y" then fail("x<NUL>y => [" .. got .. "] want [x\u{2400}y]") end
  -- (d) output is joined once, not rebuilt per piece.
  s = string.rep("a ", 80000)
  local t0 = vim.uv.hrtime()
  got = MT.render(s)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  if got ~= vim.trim(s) then fail("'a ' x80000 output differs from the input trimmed") end
  if ms >= 1000 then fail(("'a ' x80000 took %.0f ms, want < 1000"):format(ms)) end
end

if failed == 0 then
  print("ALL MATHTEXT CHECKS PASSED (" .. #cases .. " renderings, " .. bodies .. " fixture bodies)")
else
  print(failed .. " MATHTEXT CHECK(S) FAILED")
  vim.cmd("cquit 1")
end
