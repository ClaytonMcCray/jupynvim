-- VSCode-style rendering for markdown cells.
--
-- We don't actually rewrite the buffer; instead we use extmarks with
-- `conceal` and `virt_text` to make markdown source LOOK like rendered
-- markdown — headings get larger/bolder fg, list bullets get glyphs,
-- inline code/bold/italic get their markers concealed and styled.
--
-- Reference: https://neovim.io/doc/user/api.html#nvim_buf_set_extmark()

local M = {}
-- TeX -> terminal text for math spans and display-math lines.
local mathtext = require("jupynvim.notebook.mathtext")


-- Highlight groups (defined in setup_hl)
local HL = {
  H1   = "JupynvimMdH1",
  H2   = "JupynvimMdH2",
  H3   = "JupynvimMdH3",
  H4   = "JupynvimMdH4",
  H5   = "JupynvimMdH5",
  H6   = "JupynvimMdH6",
  Bold = "JupynvimMdBold",
  Em   = "JupynvimMdEm",
  Code = "JupynvimMdCode",
  Link = "JupynvimMdLink",
  Quote = "JupynvimMdQuote",
  Bullet = "JupynvimMdBullet",
  HR    = "JupynvimMdHR",
  Math  = "JupynvimMdMath",
  MathBlock = "JupynvimMdMathBlock",
  Strike = "JupynvimMdStrike",
  Check = "JupynvimMdCheck",
  TableBorder = "JupynvimMdTableBorder",
  TableHead = "JupynvimMdTableHead",
}

function M.setup_hl()
  local hl = vim.api.nvim_set_hl
  hl(0, HL.H1,          { default = true, link = "@markup.heading.1" })
  hl(0, HL.H2,          { default = true, link = "@markup.heading.2" })
  hl(0, HL.H3,          { default = true, link = "@markup.heading.3" })
  hl(0, HL.H4,          { default = true, link = "@markup.heading.4" })
  hl(0, HL.H5,          { default = true, link = "@markup.heading.5" })
  hl(0, HL.H6,          { default = true, link = "@markup.heading.6" })
  hl(0, HL.Bold,        { default = true, link = "@markup.strong" })
  hl(0, HL.Em,          { default = true, link = "@markup.italic" })
  hl(0, HL.Code,        { default = true, link = "@markup.raw.inline" })
  hl(0, HL.Link,        { default = true, link = "@markup.link.label" })
  hl(0, HL.Quote,       { default = true, link = "@markup.quote" })
  hl(0, HL.Bullet,      { default = true, link = "@markup.list" })
  hl(0, HL.HR,          { default = true, link = "@markup.delimiter" })
  hl(0, HL.Math,        { default = true, link = "@markup.math" })
  hl(0, HL.MathBlock,   { default = true, link = "@markup.math" })
  hl(0, HL.Strike,      { default = true, link = "@markup.strikethrough" })
  hl(0, HL.Check,       { default = true, link = "@markup.list.checked" })
  hl(0, HL.TableBorder, { default = true, link = "Normal" })
  hl(0, HL.TableHead,   { default = true, link = "Normal" })
end

-- ---------- helpers (must be declared before any caller) ----------

local function set_mark(buf, ns, lnum, col, opts)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum, col, opts)
end

local function conceal_range(buf, ns, lnum, start_col, end_col, char)
  set_mark(buf, ns, lnum, start_col, {
    end_col = end_col,
    conceal = char or "",
    hl_mode = "combine",
    priority = 200,
  })
end

-- Scan a line for [text](url) links with BALANCED brackets, so link text
-- like "[[link]]" (brackets inside the label) parses. Returns a list of
-- { start, text_close, stop, text, url } with 1-based byte positions of
-- the opening '[', the closing ']' and the closing ')'.
-- Byte position of the bracket matching each opener, via one stack pass.
-- Equal to scanning forward from the opener until the depth returns to 0,
-- without that scan's O(n^2) on `[[[[...`.
local function match_pairs(line, open, close)
  local match, stack = {}, {}
  local i = 1
  while true do
    i = line:find(open == "[" and "[%[%]]" or "[()]", i)
    if not i then break end
    if line:byte(i) == open:byte() then
      stack[#stack + 1] = i
    elseif #stack > 0 then
      match[stack[#stack]] = i
      stack[#stack] = nil
    end
    i = i + 1
  end
  return match
end

local function find_links(line)
  local links = {}
  if not line:find("[", 1, true) then return links end
  local bmatch = match_pairs(line, "[", "]")
  local pmatch
  local i = 1
  while true do
    i = line:find("[", i, true)
    if not i then break end
    local close = bmatch[i]
    local j = close and close + 1
    if j and line:byte(j) == 40 then
      pmatch = pmatch or match_pairs(line, "(", ")")
      local k = pmatch[j]
      if k then
        table.insert(links, {
          start = i, text_close = close, stop = k,
          text = line:sub(i + 1, close - 1),
          url = line:sub(j + 1, k - 1),
        })
        i = k + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return links
end
M.find_links = find_links

-- Index of the last span (sorted, disjoint, 1-based inclusive ranges) whose
-- start is <= p, or 0. Binary search, so per-match guards stay O(log n).
local function last_start_le(spans, p)
  local lo, hi = 1, #spans
  local found = 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if spans[mid].start <= p then
      found = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return found
end

-- Is byte p inside one of `spans`?
local function in_spans(spans, p)
  local i = last_start_le(spans, p)
  return i > 0 and spans[i].stop >= p
end

-- Does [a, b] overlap one of `spans`?
local function overlaps_spans(spans, a, b)
  local i = last_start_le(spans, b)
  return i > 0 and spans[i].stop >= a
end

-- The link under byte column `col` (1-based) in `line`, or the first link
-- on the line as a fallback. Used by the gx mapping. Autolinks and bare
-- URLs that overlap a math span are ignored: the screen shows the math
-- rendering there, not that URL. Explicit [text](url) links win over math
-- (as in inline_styling) and are checked first.
function M.link_at(line, col)
  local links = find_links(line)
  for _, l in ipairs(links) do
    if col >= l.start and col <= l.stop then return l end
  end
  local spans = M.find_math_spans(line)
  -- autolink <http://...>
  for a, url, b in line:gmatch("()<(%a[%w+.-]*://[^>%s]+)>()") do
    if col >= a and col < b and not overlaps_spans(spans, a, b - 1) then
      return { url = url }
    end
  end
  -- bare URL under cursor
  for a, url in line:gmatch("()(%a[%w+.-]*://[%w%-._~:/?#%[%]@!$&'()*+,;=%%]+)") do
    if col >= a and col < a + #url and not overlaps_spans(spans, a, a + #url - 1) then
      return { url = url }
    end
  end
  return links[1]
end

-- ---------- math ----------

-- Delimiter rules follow the Rust grammar (core/native/src/mathgrammar,
-- scan.rs `scan_text`/`dollar`/`inline_dollar`) so it can replace this walk
-- later. Byte compares and plain finds only: notebook text is never used as
-- a Lua pattern.
local BT, BS, DOLLAR, LPAREN, LBRACK = 96, 92, 36, 40, 91

local function is_ws(b)
  return b == 32 or b == 9 or b == 10 or b == 11 or b == 12 or b == 13
end

local function run_len(line, i, b)
  local j = i
  while line:byte(j) == b do j = j + 1 end
  return j - i
end

-- A local trim, byte-exact with vim.trim, so linear time on attacker-
-- controlled notebook text does not depend on vim.trim's implementation.
local function trim(s)
  local a = s:find("%S")
  if not a then return "" end
  local b = #s
  while is_ws(s:byte(b)) do b = b - 1 end
  return s:sub(a, b)
end

local function blank(s) return s:find("%S") == nil end

-- Bare display environments that open a block without `$$` (multi-line, via
-- the M.render state machine) or form one display span on a single line.
local DISPLAY_ENVS = {}
for _, e in ipairs({
  "equation", "equation*", "align", "align*", "gather", "gather*",
  "multline", "multline*", "eqnarray", "eqnarray*", "flalign", "flalign*",
  "alignat", "alignat*", "displaymath",
}) do DISPLAY_ENVS[e] = true end

-- Start of the first run of exactly `len` backticks at or after `i`, which
-- callers pass at a run boundary. `memo.bt` indexes every backtick run of
-- the line once (len -> sorted starts), so a line full of unclosed runs of
-- distinct lengths stays linear.
local function backtick_close(line, i, len, memo)
  local idx = memo.bt
  if not idx then
    idx = {}
    local n, j = #line, 1
    while j <= n do
      j = line:find("`", j, true)
      if not j then break end
      local r = run_len(line, j, BT)
      local list = idx[r]
      if not list then list = {}; idx[r] = list end
      list[#list + 1] = j
      j = j + r
    end
    memo.bt = idx
  end
  local list = idx[len]
  if not list then return nil end
  local lo, hi, found = 1, #list, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if list[mid] >= i then
      found = list[mid]
      hi = mid - 1
    else
      lo = mid + 1
    end
  end
  return found
end

-- Escape-aligned closer search from `i`: a backslash always takes the byte
-- after it. `close` == DOLLAR finds the first `$$`; otherwise it finds the
-- `\` of the first `\)`/`\]` (byte `close`).
--
-- memo[close] holds the start of an earlier failed search. Every walk that
-- starts before a position p with line[p-1] ~= `\` visits p (p-1 is either
-- visited and not a backslash, or skipped as the second byte of a pair), so
-- once this walk reaches such a p past the failed start, the rest is that
-- failed walk and cannot match. That keeps `\(\(\(...` linear.
local function aligned_close(line, i, close, memo)
  local n, start, floor = #line, i, memo[close]
  while i <= n do
    if floor and i >= floor and (i == floor or line:byte(i - 1) ~= BS) then break end
    local c = line:byte(i)
    if c == BS then
      if close ~= DOLLAR and line:byte(i + 1) == close then return i end
      i = i + 2
    elseif close == DOLLAR and c == DOLLAR and line:byte(i + 1) == DOLLAR then
      return i
    else
      i = i + 1
    end
  end
  if not floor or start < floor then memo[close] = start end
  return nil
end

-- Plain find of a fixed needle from `i`, remembering per needle the first
-- start that failed: a plain find that fails from i fails from every j > i.
local function memo_find(line, needle, i, memo)
  local key = "f:" .. needle
  local floor = memo[key]
  if floor and i >= floor then return nil end
  local e = line:find(needle, i, true)
  if not e then memo[key] = i end
  return e
end

-- Pandoc `$...$` (scan.rs inline_dollar): position of the closing `$` of
-- the `$` at `k`, or nil. Keeps `costs $5 and $10` out of math.
local function inline_dollar(line, k)
  local n = #line
  local j = k + 1
  if j > n or is_ws(line:byte(j)) then return nil end
  j = j + (line:byte(j) == BS and 2 or 1)
  while j <= n do
    local c = line:byte(j)
    if c == DOLLAR then
      local d = line:byte(j + 1)
      if d and d >= 48 and d <= 57 then return nil end
      return j
    elseif c == BS then
      j = j + 2
    elseif is_ws(c) then
      local e = j
      while e <= n and is_ws(line:byte(e)) do e = e + 1 end
      if line:byte(e) == DOLLAR then return nil end
      j = e
    else
      j = j + 1
    end
  end
  return nil
end

-- Math spans of one line, left to right: { start, stop, inner, display }
-- with 1-based inclusive byte positions of the whole delimited span (the
-- find_links convention). `escaped` lists the `\` of every `\$` outside math
-- and code spans, so the renderer can hide the backslash.
function M.find_math_spans(line)
  local spans, escaped = {}, {}
  local n = #line
  local k = 1
  -- per-call memo of failed closer searches (see aligned_close/memo_find)
  local memo = {}
  local function add(start, stop, inner, display)
    spans[#spans + 1] = { start = start, stop = stop, inner = inner, display = display }
  end
  while k <= n do
    local c = line:byte(k)
    if c == BT then
      -- a code span is skipped whole; an unclosed run is literal
      local len = run_len(line, k, BT)
      local close = backtick_close(line, k + len, len, memo)
      k = close and (close + len) or (k + len)
    elseif c == BS then
      local d = line:byte(k + 1)
      local nk = k + 2
      if d == DOLLAR then
        escaped[#escaped + 1] = k
      elseif d == BS and (line:byte(k + 2) == LPAREN or line:byte(k + 2) == LBRACK) then
        -- classic notebook doubling \\( .. \\) and \\[ .. \\]
        local open = line:byte(k + 2)
        local e = memo_find(line, open == LPAREN and "\\\\)" or "\\\\]", k + 3, memo)
        if e then
          add(k, e + 2, line:sub(k + 3, e - 1), open == LBRACK)
          nk = e + 3
        end
      elseif d == LPAREN or d == LBRACK then
        local e = aligned_close(line, k + 2, d == LPAREN and 41 or 93, memo)
        if e then
          add(k, e + 1, line:sub(k + 2, e - 1), d == LBRACK)
          nk = e + 2
        end
      elseif d == 98 then
        -- one-line bare environment \begin{equation} .. \end{equation}:
        -- a display span whose inner is the whole text (mathtext renders
        -- \begin/\end itself)
        local env = line:match("^\\begin{([%a*]+)}", k)
        if env and DISPLAY_ENVS[env] then
          local needle = "\\end{" .. env .. "}"
          local e = memo_find(line, needle, k + 8 + #env, memo)
          if e then
            local stop = e + #needle - 1
            add(k, stop, line:sub(k, stop), true)
            nk = stop + 1
          end
        end
      end
      k = nk
    elseif c == DOLLAR then
      local nk
      -- backtick form $`...`$
      if line:byte(k + 1) == BT then
        local len = run_len(line, k + 1, BT)
        local r = k + 1 + len
        local close = backtick_close(line, r, len, memo)
        if close and line:byte(close + len) == DOLLAR then
          local inner = line:sub(r, close - 1)
          if #inner > 1 and inner:sub(1, 1) == " " and inner:sub(-1) == " "
             and not blank(inner) then
            inner = inner:sub(2, -2)
          end
          add(k, close + len, inner, false)
          nk = close + len + 1
        end
      end
      -- display $$...$$
      if not nk and line:byte(k + 1) == DOLLAR then
        local e = aligned_close(line, k + 2, DOLLAR, memo)
        if e and not blank(line:sub(k + 2, e - 1)) then
          add(k, e + 1, line:sub(k + 2, e - 1), true)
          nk = e + 2
        end
      end
      -- inline $...$ (pandoc)
      if not nk then
        local e = inline_dollar(line, k)
        if e then
          add(k, e, line:sub(k + 1, e - 1), false)
          nk = e + 1
        end
      end
      k = nk or (k + 1)
    else
      k = k + 1
    end
  end
  return spans, escaped
end

-- One source line of display math. Row count never changes (one source line
-- becomes one rendered line), so no virt_lines bookkeeping. `tex` is the
-- part of `raw` that holds math (defaults to all of it); the whole line is
-- concealed either way. Inline virt_text, not overlay: the source never
-- shows through, and insert mode shows source followed by the rendering.
-- Rendering of block TeX; a render of "" (`% comment`, `\label{x}`, an
-- unknown `\begin{..}`) falls back to the trimmed source so nothing that is
-- in the buffer ever vanishes from the screen.
local function block_text(tex)
  local t = trim(tex)
  local txt = mathtext.render(t)
  if txt == "" then txt = t end
  return txt
end

local function math_block_line(buf, ns, lnum, raw, tex)
  if blank(raw) then
    set_mark(buf, ns, lnum, 0, { line_hl_group = HL.MathBlock, priority = 100 })
    return
  end
  local indent = raw:match("^%s*")
  local txt = block_text(tex or raw)
  set_mark(buf, ns, lnum, 0, {
    end_col = #raw,
    conceal = "",
    virt_text = txt ~= "" and { { indent .. txt, HL.MathBlock } } or nil,
    virt_text_pos = "inline",
    line_hl_group = HL.MathBlock,
    hl_mode = "combine",
    priority = 110,
  })
end

-- The line closing a display block (`$$`, `\]`, `\end{env}`). `tex` is the
-- math before/through the delimiter and `de` the 1-based byte where the
-- closing delimiter ends. Only [0, de) is concealed (with the rendering of
-- `tex` inline); prose after the closer stays as ordinary visible text.
local function math_closer_line(buf, ns, lnum, raw, tex, de)
  if blank(raw:sub(de + 1)) then
    if blank(tex) then
      -- bare delimiter line: keep it visible, like the opener
      set_mark(buf, ns, lnum, 0, { line_hl_group = HL.MathBlock, priority = 110 })
    else
      math_block_line(buf, ns, lnum, raw, tex)
    end
    return
  end
  local opts = { end_col = de, conceal = "", hl_mode = "combine", priority = 110 }
  if not blank(tex) then
    opts.virt_text = { { raw:match("^%s*") .. block_text(tex), HL.MathBlock } }
    opts.virt_text_pos = "inline"
  end
  set_mark(buf, ns, lnum, 0, opts)
end

-- `all_spans`/`escaped` are find_math_spans(line) when the caller already
-- has them (apply_line); otherwise they are computed here.
local function inline_styling(buf, ns, lnum, line, all_spans, escaped)
  -- Links FIRST (balanced-bracket scan), marking their spans so emphasis
  -- regexes don't fire inside URLs.
  local links = find_links(line)
  for _, l in ipairs(links) do
    local img = l.start > 1 and line:sub(l.start - 1, l.start - 1) == "!"
    -- conceal "[", show text as link, conceal "](url)"
    conceal_range(buf, ns, lnum, l.start - 1, l.start, "")
    set_mark(buf, ns, lnum, l.start, { end_col = l.text_close - 1, hl_group = HL.Link, hl_mode = "combine" })
    set_mark(buf, ns, lnum, l.text_close - 1, {
      end_col = l.stop,
      conceal = "",
      virt_text = { { img and " 🖼" or " ↗", HL.Link } },
      virt_text_pos = "inline",
      hl_mode = "combine",
      priority = 105,
    })
  end
  -- Math spans next; a link wins over a math span it overlaps, so
  -- `[t](http://x/$a$)` keeps its link rendering.
  if not all_spans then all_spans, escaped = M.find_math_spans(line) end
  -- Both lists are sorted and disjoint: one merge walk.
  local spans = {}
  local li = 1
  for _, sp in ipairs(all_spans) do
    while links[li] and links[li].stop < sp.start do li = li + 1 end
    local l = links[li]
    if not (l and l.start <= sp.stop) then spans[#spans + 1] = sp end
  end
  -- A markup match whose opening or closing delimiter sits inside math is
  -- not markup (`$a_1 * b_2 * c_3$`). A match that merely contains a whole
  -- math span (`*see $x$ here*`) still styles. Binary search per check.
  local function in_math(a, b) return in_spans(spans, a) or in_spans(spans, b) end

  -- Autolinks <http://...>
  for a, url in line:gmatch("()<(%a[%w+.-]*://[^>%s]+)>") do
    if not in_math(a, a + #url + 1) then
      conceal_range(buf, ns, lnum, a - 1, a, "")
      set_mark(buf, ns, lnum, a, { end_col = a + #url, hl_group = HL.Link, hl_mode = "combine" })
      conceal_range(buf, ns, lnum, a + #url, a + #url + 1, "")
    end
  end
  -- Bold **text** and __text__. A match rejected for math resumes one byte
  -- later, so markup after the math span is still found.
  for _, pat in ipairs({ "%*%*[^%*]+%*%*", "__[^_]+__" }) do
    local s = 1
    while true do
      local a, b = line:find(pat, s)
      if not a then break end
      if in_math(a, b) then
        s = a + 1
      else
        conceal_range(buf, ns, lnum, a - 1, a + 1, "")
        set_mark(buf, ns, lnum, a + 1, { end_col = b - 2, hl_group = HL.Bold, hl_mode = "combine" })
        conceal_range(buf, ns, lnum, b - 2, b, "")
        s = b + 1
      end
    end
  end
  -- Strikethrough ~~text~~
  local s = 1
  while true do
    local a, b = line:find("~~[^~]+~~", s)
    if not a then break end
    if in_math(a, b) then
      s = a + 1
    else
      conceal_range(buf, ns, lnum, a - 1, a + 1, "")
      set_mark(buf, ns, lnum, a + 1, { end_col = b - 2, hl_group = HL.Strike, hl_mode = "combine" })
      conceal_range(buf, ns, lnum, b - 2, b, "")
      s = b + 1
    end
  end
  -- Italic *text* (single asterisks; require non-* neighbours to avoid bold/list overlap)
  s = 1
  while true do
    local a, b = line:find("([^%*])%*([^%*\n][^%*\n]-)%*", s)
    if not a then break end
    local star1 = a + 1
    local inner_end = b
    if in_math(star1, inner_end) then
      s = star1 + 1
    else
      conceal_range(buf, ns, lnum, star1 - 1, star1, "")
      set_mark(buf, ns, lnum, star1, { end_col = inner_end - 1, hl_group = HL.Em, hl_mode = "combine" })
      conceal_range(buf, ns, lnum, inner_end - 1, inner_end, "")
      s = b + 1
    end
  end
  -- Italic _text_ (word-boundary guarded so snake_case identifiers survive)
  s = 1
  while true do
    local a, b = line:find("_[^_%s][^_]-_", s)
    if not a then break end
    if in_math(a, b) then
      s = a + 1
    else
      local prev = a > 1 and line:sub(a - 1, a - 1) or " "
      local nxt = line:sub(b + 1, b + 1)
      if not prev:match("[%w_]") and not nxt:match("[%w_]") then
        conceal_range(buf, ns, lnum, a - 1, a, "")
        set_mark(buf, ns, lnum, a, { end_col = b - 1, hl_group = HL.Em, hl_mode = "combine" })
        conceal_range(buf, ns, lnum, b - 1, b, "")
      end
      s = b + 1
    end
  end
  -- Inline code `text`
  s = 1
  while true do
    local a, b = line:find("`([^`]+)`", s)
    if not a then break end
    if in_math(a, b) then
      s = a + 1
    else
      conceal_range(buf, ns, lnum, a - 1, a, "")
      set_mark(buf, ns, lnum, a, { end_col = b - 1, hl_group = HL.Code, hl_mode = "combine" })
      conceal_range(buf, ns, lnum, b - 1, b, "")
      s = b + 1
    end
  end
  -- Math: the whole delimited span is concealed and the rendering drawn
  -- inline in its place. A render of "" falls back to the trimmed source so
  -- nothing vanishes.
  for _, sp in ipairs(spans) do
    local txt = mathtext.render(sp.inner)
    if txt == "" then txt = trim(sp.inner) end
    set_mark(buf, ns, lnum, sp.start - 1, {
      end_col = sp.stop,
      conceal = "",
      virt_text = txt ~= "" and { { txt, sp.display and HL.MathBlock or HL.Math } } or nil,
      virt_text_pos = "inline",
      hl_mode = "combine",
      priority = 105,
    })
  end
  -- `\$` is a literal dollar: hide the backslash, keep the `$`
  for _, pos in ipairs(escaped) do
    conceal_range(buf, ns, lnum, pos - 1, pos, "")
  end
end

local function apply_line(buf, ns, lnum, raw)
  if raw == "" then return end
  -- A line that is exactly one display span ($$..$$ or \[..\]) renders as
  -- a block line; mid-paragraph display spans go through inline_styling.
  local spans, escaped = M.find_math_spans(raw)
  if #spans == 1 and spans[1].display
     and trim(raw) == raw:sub(spans[1].start, spans[1].stop) then
    math_block_line(buf, ns, lnum, raw, spans[1].inner)
    return
  end
  -- ATX headings — accept `#`, `##` etc with OR without trailing space
  -- (CommonMark requires space; Jupyter/VSCode are lenient).
  local hashes = raw:match("^(#+)")
  if hashes and #hashes <= 6 and (raw:sub(#hashes + 1, #hashes + 1) ~= "#") then
    local level = #hashes
    local hl = HL["H" .. level]
    local prefix = ({ "█ ", "▌ ", "▎ ", "▏ ", "· ", "· " })[level] or "  "
    -- Conceal hashes; if a space follows, conceal it too.
    local conceal_end = #hashes
    if raw:sub(#hashes + 1, #hashes + 1) == " " then conceal_end = conceal_end + 1 end
    set_mark(buf, ns, lnum, 0, {
      end_col = conceal_end,
      conceal = "",
      virt_text = { { prefix, hl } },
      virt_text_pos = "inline",
      hl_mode = "combine",
      priority = 105,
    })
    set_mark(buf, ns, lnum, 0, { line_hl_group = hl, priority = 100 })
    -- breathing room above headings, like VSCode's vertical rhythm
    set_mark(buf, ns, lnum, 0, {
      virt_lines = { { { " ", "Normal" } } },
      virt_lines_above = true,
    })
    inline_styling(buf, ns, lnum, raw, spans, escaped)
    return
  end
  -- HR — fully conceal the line (no decoration). Render-markdown convention.
  if raw:match("^%s*[-_*]%s*[-_*]%s*[-_*][-_*%s]*$") then
    set_mark(buf, ns, lnum, 0, {
      end_col = #raw,
      conceal = "",
      hl_mode = "combine",
      priority = 200,
    })
    return
  end
  -- Quote: ^> text
  if raw:match("^>%s*") then
    set_mark(buf, ns, lnum, 0, { line_hl_group = HL.Quote, priority = 90 })
    inline_styling(buf, ns, lnum, raw, spans, escaped)
    return
  end
  -- Bullet list (with GitHub task-list checkboxes). Overlay WITHOUT
  -- conceal: concealing the marker shifted the text left one cell and
  -- glued the bullet to the word.
  local indent, marker = raw:match("^(%s*)([%-%*%+])%s+")
  if marker then
    set_mark(buf, ns, lnum, #indent, {
      end_col = #indent + 1,
      virt_text = { { "•", HL.Bullet } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
    local box_s, box_e, state = raw:find("^%s*[%-%*%+]%s+%[([ xX])%]")
    if box_s then
      local glyph = (state == " ") and "☐" or "☑"
      set_mark(buf, ns, lnum, box_e - 3, {
        end_col = box_e,
        conceal = "",
        virt_text = { { glyph, HL.Check } },
        virt_text_pos = "inline",
        hl_mode = "combine",
        priority = 105,
      })
      if state ~= " " then
        set_mark(buf, ns, lnum, box_e, { end_col = #raw, hl_group = HL.Strike, hl_mode = "combine", priority = 90 })
      end
    end
    inline_styling(buf, ns, lnum, raw, spans, escaped)
    return
  end
  -- Numbered list
  local num_pre = raw:match("^(%s*%d+%.)%s+")
  if num_pre then
    set_mark(buf, ns, lnum, 0, { hl_group = HL.Bullet, end_col = #num_pre, hl_mode = "combine", priority = 100 })
    inline_styling(buf, ns, lnum, raw, spans, escaped)
    return
  end
  -- Embedded image placeholder: ![alt](jupynvim-img:N) — fully conceal so
  -- the cell shows just the rendered image below, like VSCode does.
  if raw:match("!%[[^%]]*%]%(jupynvim%-img:%d+%)") then
    set_mark(buf, ns, lnum, 0, {
      end_col = #raw,
      conceal = "",
      priority = 200,
    })
    return
  end

  -- Plain
  inline_styling(buf, ns, lnum, raw, spans, escaped)
end

-- ---------- tables ----------

local function dw(s) return vim.fn.strdisplaywidth(s) end

-- A pipe-table separator row: only |, -, :, spaces, with at least one dash.
local function is_table_sep(line)
  if not (line:find("|") and line:find("%-")) then return false end
  return line:match("^[|: %-%s]+$") ~= nil
end

local function split_row(raw)
  local inner = raw:gsub("^%s*|", ""):gsub("|%s*$", "")
  local cells = {}
  for cell in (inner .. "|"):gmatch("([^|]*)|") do
    table.insert(cells, trim(cell))
  end
  return cells
end

-- Word-wrap one cell's text to `width` display columns (hard-breaking
-- words longer than the column, multi-byte safe).
local function wrap_cell(text, width)
  if dw(text) <= width then return { text } end
  local out, cur = {}, ""
  for word in text:gmatch("%S+") do
    while dw(word) > width do
      if cur ~= "" then table.insert(out, cur); cur = "" end
      local taken, rest, w = "", "", 0
      for ch in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local cw = dw(ch)
        if rest ~= "" or w + cw > width then
          rest = rest .. ch
        else
          taken = taken .. ch
          w = w + cw
        end
      end
      if taken == "" then break end
      table.insert(out, taken)
      word = rest
    end
    if word ~= "" then
      local cand = cur == "" and word or (cur .. " " .. word)
      if dw(cand) > width and cur ~= "" then
        table.insert(out, cur)
        cur = word
      else
        cur = cand
      end
    end
  end
  if cur ~= "" then table.insert(out, cur) end
  if #out == 0 then out = { "" } end
  return out
end

-- Pure layout (testable): logical rows -> boxed physical lines that fit
-- max_w display columns. Wide columns shrink and their text wraps INSIDE
-- the cell (VSCode behavior for dataframe-style tables), so the box never
-- overflows the window. rows[1] is the header.
function M._layout_table(rows, max_w)
  local ncols = 0
  for _, cells in ipairs(rows) do ncols = math.max(ncols, #cells) end
  if ncols == 0 then return nil end
  local wid = {}
  for c = 1, ncols do
    local w = 3
    for _, cells in ipairs(rows) do w = math.max(w, dw(cells[c] or "")) end
    wid[c] = w
  end
  local MIN = 8
  local function total()
    local t = ncols + 1
    for c = 1, ncols do t = t + wid[c] + 2 end
    return t
  end
  for _ = 1, 256 do
    if total() <= max_w then break end
    local bi, bw = nil, MIN
    for c = 1, ncols do
      if wid[c] > bw then bi, bw = c, wid[c] end
    end
    if not bi then break end  -- every column already at MIN: give up
    wid[bi] = math.max(MIN, wid[bi] - math.max(1, total() - max_w))
  end
  local function border(l, m, r)
    local parts = {}
    for c = 1, ncols do parts[c] = string.rep("─", wid[c] + 2) end
    return l .. table.concat(parts, m) .. r
  end
  local function fmt_row(cells)
    local wrapped, height = {}, 1
    for c = 1, ncols do
      wrapped[c] = wrap_cell(cells[c] or "", wid[c])
      height = math.max(height, #wrapped[c])
    end
    local phys = {}
    for i = 1, height do
      local parts = {}
      for c = 1, ncols do
        local t = wrapped[c][i] or ""
        parts[c] = " " .. t .. string.rep(" ", math.max(wid[c] - dw(t), 0)) .. " "
      end
      phys[i] = "│" .. table.concat(parts, "│") .. "│"
    end
    return phys
  end
  local body = {}
  for ri = 2, #rows do body[ri - 1] = fmt_row(rows[ri]) end
  return {
    header = fmt_row(rows[1]),
    top = border("┌", "┬", "┐"),
    mid = border("├", "┼", "┤"),
    bot = border("└", "┴", "┘"),
    body = body,
  }
end

-- Render a pipe table as a proper box: raw rows are fully concealed and a
-- laid-out version is drawn in their place. Robust to ragged sources and
-- rows wider than the window (the old renderer assumed monospace-aligned
-- pipes and overflowed past the border).
--
-- Two placements, because conceal hides TEXT but does not collapse a long
-- line's WRAP ROWS (they stay as blank screen rows):
--   • every raw row fits the width  -> overlay each row 1:1 (no gaps)
--   • some raw row would wrap       -> the whole boxed table renders as
--     one contiguous virt-line block above the concealed source rows;
--     the leftover blank rows fall BELOW the box as plain spacing
local function render_table(buf, ns, base, lines, first, last, max_w)
  max_w = math.max(max_w or 80, 24)
  local rows = { split_row(lines[first]) }
  for i = first + 2, last do
    table.insert(rows, split_row(lines[i]))
  end
  local layout = M._layout_table(rows, max_w)
  if not layout then return end

  local function conceal_row(lnum)
    local raw = lines[lnum - base + 1] or ""
    set_mark(buf, ns, lnum, 0, { end_col = #raw, conceal = "", priority = 150 })
  end

  local fits = true
  for i = first, last do
    if dw(lines[i]) > max_w then fits = false; break end
  end

  if not fits then
    local vls = { { { layout.top, HL.TableBorder } } }
    for _, h in ipairs(layout.header) do table.insert(vls, { { h, HL.TableHead } }) end
    table.insert(vls, { { layout.mid, HL.TableBorder } })
    for _, phys in ipairs(layout.body) do
      for _, p in ipairs(phys) do table.insert(vls, { { p, "Normal" } }) end
    end
    table.insert(vls, { { layout.bot, HL.TableBorder } })
    set_mark(buf, ns, base + first - 1, 0, {
      virt_lines = vls,
      virt_lines_above = true,
    })
    for i = first, last do conceal_row(base + i - 1) end
    return
  end

  local function put(lnum, phys, hl, extra_below)
    conceal_row(lnum)
    set_mark(buf, ns, lnum, 0, {
      virt_text = { { phys[1], hl } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = 160,
    })
    local below = {}
    for i = 2, #phys do table.insert(below, { { phys[i], hl } }) end
    for _, b in ipairs(extra_below or {}) do table.insert(below, b) end
    if #below > 0 then
      set_mark(buf, ns, lnum, 0, { virt_lines = below })
    end
  end

  set_mark(buf, ns, base + first - 1, 0, {
    virt_lines = { { { layout.top, HL.TableBorder } } },
    virt_lines_above = true,
  })
  local bot_row = { { { layout.bot, HL.TableBorder } } }
  put(base + first - 1, layout.header, HL.TableHead)
  put(base + first, { layout.mid }, HL.TableBorder,
    #layout.body == 0 and bot_row or nil)
  for bi, phys in ipairs(layout.body) do
    put(base + first + 1 + bi - 1, phys, "Normal",
      bi == #layout.body and bot_row or nil)
  end
end

-- ---------- public API ----------

local MATH_FENCE = "^%s*[`~][`~][`~]+%s*[Mm][Aa][Tt][Hh]%s*$"

-- Is `raw` a fence line given the current fence state? Returns
-- is_fence, fence_char, is_math (the last two only for an opener).
-- Backtick fences toggle on any ``` line as before; a tilde fence is only
-- recognised for ~~~math so plain ~~~ text keeps its old rendering.
local function fence_line(raw, in_fence, fence_ch)
  if in_fence then
    if fence_ch == "~" then return raw:match("^%s*~~~+%s*$") ~= nil end
    return raw:match("^%s*```") ~= nil
  end
  if raw:match("^%s*```") then return true, "`", raw:match(MATH_FENCE) ~= nil end
  if raw:match(MATH_FENCE) then return true, "~", true end
  return false
end

-- Apply markdown extmarks to lines [start_line, end_line] (0-based, inclusive)
-- in `buf`, in namespace `ns`. Multi-line constructs (fenced code blocks,
-- block math) are tracked via a small state machine.
function M.render(buf, ns, start_line, end_line, render_width)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local total = vim.api.nvim_buf_line_count(buf)
  if start_line >= total then return end
  end_line = math.min(end_line, total - 1)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line + 1, false)
  local heading_width = render_width or 60

  -- Pre-pass: pipe tables (outside fences). Rows claimed by a table are
  -- rendered here and skipped by the per-line pass below.
  local claimed = {}
  do
    -- same fence rules as the per-line pass (fence_line knows ~~~math)
    local fence, fch = false, nil
    local i = 1
    while i <= #lines do
      local raw = lines[i]
      local is_fence, ch = fence_line(raw, fence, fch)
      if is_fence then
        if fence then fence, fch = false, nil else fence, fch = true, ch end
      end
      if not fence and raw:find("|") and not is_table_sep(raw)
         and lines[i + 1] and is_table_sep(lines[i + 1]) then
        local first, last = i, i + 1
        local j = i + 2
        while j <= #lines and lines[j]:find("|") and not fence_line(lines[j], false) do
          last = j
          j = j + 1
        end
        render_table(buf, ns, start_line, lines, first, last, render_width)
        for r = first, last do claimed[r] = true end
        i = last + 1
      else
        i = i + 1
      end
    end
  end

  local in_fence, fence_ch, fence_math = false, nil, false
  -- What closes the open display-math block: "$$", "]" (for \[) or the
  -- name of a bare environment. nil outside a block.
  local math_close = nil

  for i, raw in ipairs(lines) do
    local lnum = start_line + i - 1
    if claimed[i] then
      -- table row: already rendered by the pre-pass
      goto continue
    end
    do
      -- Fenced code blocks take priority over everything, as before.
      local is_fence, ch, is_math = fence_line(raw, in_fence, fence_ch)
      if is_fence then
        if in_fence then
          in_fence, fence_ch, fence_math = false, nil, false
        else
          in_fence, fence_ch, fence_math = true, ch, is_math
        end
        set_mark(buf, ns, lnum, 0, {
          line_hl_group = HL.Code,
          virt_text = { { string.rep("─", 60), HL.Code } },
          virt_text_pos = "overlay",
          conceal = "",
          hl_mode = "combine",
          priority = 110,
        })
      elseif in_fence then
        if fence_math then
          math_block_line(buf, ns, lnum, raw)
        else
          set_mark(buf, ns, lnum, 0, { line_hl_group = HL.Code, priority = 100 })
        end
      elseif math_close == "$$" then
        local p = raw:find("$$", 1, true)
        if p then
          math_close = nil
          math_closer_line(buf, ns, lnum, raw, raw:sub(1, p - 1), p + 1)
        else
          math_block_line(buf, ns, lnum, raw)
        end
      elseif math_close == "]" then
        -- `\]` or `\\]` anywhere on the line closes, like `$$` and \end{env}
        local p = raw:find("\\]", 1, true)
        if p then
          math_close = nil
          local ds = (p > 1 and raw:byte(p - 1) == BS) and p - 1 or p
          math_closer_line(buf, ns, lnum, raw, raw:sub(1, ds - 1), p + 1)
        else
          math_block_line(buf, ns, lnum, raw)
        end
      elseif math_close then
        local needle = "\\end{" .. math_close .. "}"
        local p = raw:find(needle, 1, true)
        if p then
          math_close = nil
          local de = p + #needle - 1
          math_closer_line(buf, ns, lnum, raw, raw:sub(1, de), de)
        else
          math_block_line(buf, ns, lnum, raw)
        end
      else
        local dollar_rest = raw:match("^%s*%$%$(.*)$")
        local env = raw:match("^%s*\\begin{([%a*]+)}")
        if dollar_rest and not dollar_rest:find("$$", 1, true) then
          -- $$ opener; content on the same line (`$$ a`) is rendered
          math_close = "$$"
          if blank(dollar_rest) then
            set_mark(buf, ns, lnum, 0, { line_hl_group = HL.MathBlock, priority = 110 })
          else
            math_block_line(buf, ns, lnum, raw, dollar_rest)
          end
        elseif raw:match("^%s*\\\\?%[%s*$") then
          math_close = "]"
          set_mark(buf, ns, lnum, 0, { line_hl_group = HL.MathBlock, priority = 110 })
        elseif env and DISPLAY_ENVS[env]
               and not raw:find("\\end{" .. env .. "}", 1, true) then
          math_close = env
          math_block_line(buf, ns, lnum, raw)
        else
          -- Setext headings: text line followed by `===` (h1) or `---` (h2).
          -- Style the text line as a heading; fully conceal the underline below.
          local next_line = lines[i + 1]
          local is_setext_h1 = next_line and next_line:match("^=+%s*$")
          local is_setext_h2 = next_line and next_line:match("^%-+%s*$")
          if (is_setext_h1 or is_setext_h2) and raw ~= "" and not raw:match("^#+%s") then
            local level = is_setext_h1 and 1 or 2
            local hl = HL["H" .. level]
            set_mark(buf, ns, lnum, 0, { line_hl_group = hl, priority = 100 })
            inline_styling(buf, ns, lnum, raw)
            -- Conceal the entire underline-marker line — no decoration overlay.
            set_mark(buf, ns, lnum + 1, 0, {
              end_col = #(next_line or ""),
              conceal = "",
              hl_mode = "combine",
              priority = 200,
            })
          else
            apply_line(buf, ns, lnum, raw)
            -- ATX heading: NO underline virt_line. The styled heading text speaks for itself.
          end
        end
      end
    end
    ::continue::
  end
end

return M
