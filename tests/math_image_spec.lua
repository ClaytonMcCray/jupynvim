-- Display math in markdown cells, typeset by libjupynvim and shown as Kitty
-- placeholder images, end to end: the real library, notebooks opened the way
-- a user opens them, and a simulated terminal UI that records every byte
-- meant for the terminal.
--
--   nvim --headless -u NONE -c "luafile tests/math_image_spec.lua" -c "cquit 3"
--
-- A  the two job kinds through the library: the response and the PNG it
--    carries, each class of error, the terminal's size
-- B  a notebook: a first render is text, then every display block is an
--    image placed with its own grid; inline math stays text
-- C  renders that change nothing write nothing and ask for nothing
-- D  an edited block: one job, one transmit, one delete
-- E  macros defined in an earlier cell
-- F  what stays text: errors, missing glyphs, too wide, the text renderer,
--    another image renderer, no library at all and a library from before
--    the math kinds (child Neovims)
-- G  images freed: a colour change, a deleted cell, a wiped buffer, and
--    another notebook's wipe
-- H  the markdown fixture notebook, and what its renders cost
-- I  :checkhealth jupynvim, also before any notebook has rendered (a child
--    Neovim on a pseudo-terminal that reports its size)
-- J  a render never waits for a job
-- K  the rows on the screen
-- L  markdown cells that share one id
-- M  chemistry (\ce, \pu) stays text
-- N  a notebook of hundreds of formulas fills in by itself, with the
--    renders the module asks for spaced by what a render costs
--
-- It needs libjupynvim and jupynvim-core, which section 1 of
-- tests/run_all.sh builds (cd core && cargo build --release). A missing one
-- is a failure, never a skip; so is a missing python3, which section I uses
-- to make a pseudo-terminal. No kernel is started: none plays a part here.
-- Every wait is on a condition; the timings checked are budgets.

local REPO = vim.fn.getcwd()
vim.opt.runtimepath:prepend(REPO)
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. REPO .. "/tests/?.lua;" .. package.path

local fails = 0
local function chk(name, cond, detail)
  if cond then
    io.write("  ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or "") .. "\n")
    fails = fails + 1
  end
end
local function section(title) io.write("\n-- " .. title .. "\n") end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local function finish()
  vim.fn.delete(tmp, "rf")
  if fails == 0 then
    io.write("\nALL MATH IMAGE CHECKS PASSED\n")
    vim.cmd("qa!")
  else
    io.write(("\nMATH IMAGE: %d CHECK(S) FAILED\n"):format(fails))
    vim.cmd("cquit 1")
  end
end
-- A section that stops on a Lua error is one failure; the next one still runs.
local function run(title, fn)
  section(title)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then chk(title .. ": the section runs to its end", false, err) end
end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end

-- ── the terminal ─────────────────────────────────────────────────────────
-- kitty, not inside tmux, whatever shell runs the spec. The backend's own
-- tty (its local mode) is a plain file, so nothing reaches a real terminal.
vim.env.TERM = "xterm-kitty"
vim.env.TMUX, vim.env.JUPYNVIM_DISABLE_TMUX_PASSTHROUGH = nil, nil
vim.env.JUPYNVIM_NATIVE = nil
vim.env.JUPYNVIM_TTY = tmp .. "/tty"
io.open(vim.env.JUPYNVIM_TTY, "w"):close()

-- The simulated UI (as in tests/stream_writer_spec.lua): one terminal UI
-- that takes nvim_ui_send, which records every write. Installed before any
-- module of the plugin loads, since the image module notes the UI at load.
local ui_out = {}
local MARK, MARK_ANSWER = "\27[>q", "\27P>|spec"
vim.api.nvim_ui_send = function(s)
  if vim.in_fast_event() then error("E5560: nvim_ui_send must not be called in a fast event context") end
  ui_out[#ui_out + 1] = s
  -- the terminal answers the version question at once
  if s == MARK then vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = MARK_ANSWER } }) end
end
vim.api.nvim_list_uis = function() return { { chan = 1, stdout_tty = true, width = 80, height = 24 } } end
local real_chan_send = vim.api.nvim_chan_send
local stderr_out = {}
vim.api.nvim_chan_send = function(ch, s)
  if ch == vim.v.stderr then stderr_out[#stderr_out + 1] = s; return end
  return real_chan_send(ch, s)
end
local real_guess_handle = vim.uv.guess_handle
vim.uv.guess_handle = function(fd)
  if fd == 2 then return "tty" end
  return real_guess_handle(fd)
end

local function reset_ui() ui_out, stderr_out = {}, {} end
-- what went to the terminal, the version question left out
local function writes()
  local t = {}
  for _, s in ipairs(ui_out) do if s ~= MARK then t[#t + 1] = s end end
  for _, s in ipairs(stderr_out) do t[#t + 1] = s end
  return t
end
local function count(list, pred)
  local n = 0
  for _, s in ipairs(list) do if pred(s) then n = n + 1 end end
  return n
end
local function is_tx(s) return s:find("\27_Ga=t,f=100,i=", 1, true) == 1 end
local function txs() local t = {} for _, s in ipairs(writes()) do if is_tx(s) then t[#t + 1] = s end end return t end
-- a transmit's image id, and the grid of the placement that ends it
local function tx_id(s) return tonumber(s:match("^\27_Ga=t,f=100,i=(%d+),")) end
local function tx_grid(s)
  local id, c, r = s:match("\27_Ga=p,U=1,i=(%d+),p=1,c=(%d+),r=(%d+),q=2\27\\$")
  return tonumber(id), tonumber(c), tonumber(r)
end
local function deletes_of(id)
  return count(writes(), function(s) return has(s, ("\27_Ga=d,d=I,i=%d,"):format(id)) end)
end
local function mentions(id) return count(writes(), function(s) return has(s, (",i=%d,"):format(id)) end) end
local function delete_all_sent() return count(writes(), function(s) return has(s, "\27_Ga=d,d=A,") end) > 0 end

-- ── files the spec needs ─────────────────────────────────────────────────
section("files the spec needs")
local EXT = (jit and jit.os == "OSX") and "dylib" or "so"
local LIB = REPO .. "/core/target/release/libjupynvim." .. EXT
local CORE = REPO .. "/core/target/release/jupynvim-core"
local BUILD = "cd core && cargo build --release"
chk("the library is built (" .. LIB .. ")", vim.uv.fs_stat(LIB) ~= nil, "build it: " .. BUILD)
chk("jupynvim-core is built (" .. CORE .. ")", vim.fn.executable(CORE) == 1, "build it: " .. BUILD)
local N = require("jupynvim.native")
local avail = N.available()
chk("the library loads", avail, vim.inspect(N.status()) .. "; build it: " .. BUILD)
if not avail or vim.fn.executable(CORE) ~= 1 then
  finish()
  return
end

-- ── the wire format ──────────────────────────────────────────────────────
local function request(tex, o)
  o = o or {}
  local pre = o.pre or ""
  return ("JNM 1\nfg %s\ncell %d %d\nscale %s\nmax %d %d\npre %d\ntex %d\n\n"):format(
    o.fg or "#c0caf5", o.cw or 14, o.ch or 30, o.scale or "1", o.cols or 100, o.rows or 60, #pre, #tex)
    .. pre .. tex
end
local EXAMPLE = "JNM 1\nfg #c0caf5\ncell 14 30\nscale 1\nmax 100 60\npre 0\ntex 3\n\nx^2"

-- The response: seven lines in this order, an empty line, the base64.
local function parse_response(out)
  if type(out) ~= "string" then return nil, "no text" end
  local lines, pos = {}, 1
  for i = 1, 8 do
    local nl = out:find("\n", pos, true)
    if not nl then return nil, ("line %d has no LF: %q"):format(i, out:sub(1, 200)) end
    lines[i] = out:sub(pos, nl - 1)
    pos = nl + 1
  end
  local r = { b64 = out:sub(pos) }
  if lines[1] ~= "JNM 1" then return nil, "line 1 is " .. ("%q"):format(lines[1]) end
  r.w, r.h = lines[2]:match("^size (%d+) (%d+)$")
  r.cols, r.rows = lines[3]:match("^grid (%d+) (%d+)$")
  r.base = lines[4]:match("^base (%d+)$")
  r.em = lines[5]:match("^em (%d+%.%d%d%d)$")
  r.shrunk = lines[6]:match("^shrunk ([01])$")
  r.n = lines[7]:match("^png (%d+)$")
  if not (r.w and r.cols and r.base and r.em and r.shrunk and r.n) or lines[8] ~= "" then
    return nil, "not size, grid, base, em, shrunk, png and an empty line, in order: "
      .. vim.inspect({ unpack(lines, 2, 8) })
  end
  for _, k in ipairs({ "w", "h", "cols", "rows", "base", "n" }) do r[k] = tonumber(r[k]) end
  r.em, r.shrunk = tonumber(r.em), r.shrunk == "1"
  return r
end
local function be32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end
-- the IHDR of a base64 PNG: width, height, bit depth, colour type
local function png_head(b64)
  local ok, raw = pcall(vim.base64.decode, b64 or "")
  if not ok or type(raw) ~= "string" or #raw < 33 then return nil end
  if raw:sub(1, 8) ~= "\137PNG\r\n\26\n" or raw:sub(13, 16) ~= "IHDR" then return nil end
  return { w = be32(raw, 17), h = be32(raw, 21), depth = raw:byte(25), color = raw:byte(26) }
end
-- what a request asked for: its head, its prelude and its TeX
local function parse_request(req)
  local stop = req:find("\n\n", 1, true)
  if not stop then return nil end
  local head = req:sub(1, stop)
  local pre, tex = tonumber(head:match("\npre (%d+)\n")), tonumber(head:match("\ntex (%d+)\n"))
  if not pre or not tex then return nil end
  local body = req:sub(stop + 2)
  return { head = head, prelude = body:sub(1, pre), tex = body:sub(pre + 1, pre + tex) }
end

-- A formula that parses but passes RaTeX's layout budget: dashed column
-- rules on a tall array, repeated by nested \pmb layers.
local LAYOUT_BOMB = ("\\pmb{"):rep(13) .. "\\begin{array}{:c:}\\rule{1em}{10em}\\end{array}" .. ("}"):rep(13)
-- At 10x20 cells: about 18 em wide, 36 columns at its natural size; at 30
-- columns it shrinks. The sum is about 90 em: too wide for 30 columns even
-- at half size.
local MEDIUM = "a+b+c+d+e+f+g+h+i+j+k"
local wide = {}
for i = 1, 40 do wide[i] = ("x_{%d}"):format(i) end
local WIDE = table.concat(wide, "+")

-- ── A. the job kinds ─────────────────────────────────────────────────────
run("A. the job kinds", function()
  chk("A1 KIND.MATH is 2304 and KIND.MATH_CELL is 2305", N.KIND.MATH == 2304 and N.KIND.MATH_CELL == 2305,
    vim.inspect(N.KIND))
  local lib = N.lib()
  chk("A1 the library supports both kinds", lib ~= nil and lib.jnv_kind_supported(2304) == 1
    and lib.jnv_kind_supported(2305) == 1)
  chk("A2 the spec's request builder gives the example of the wire format", request("x^2") == EXAMPLE)

  local ok, out = N.call(N.KIND.MATH, EXAMPLE)
  local r, why
  if ok then r, why = parse_response(out) else why = out end
  chk("A2 the example typesets: JNM 1, size, grid, base, em, shrunk, png, then the base64", r ~= nil, why)
  if r then
    chk("A2 size is the grid times the cell (14x30), exactly", r.w == r.cols * 14 and r.h == r.rows * 30,
      ("size %dx%d, grid %dx%d"):format(r.w, r.h, r.cols, r.rows))
    chk("A2 the base64 is png bytes long, on one line", r.n > 0 and #r.b64 == r.n and not has(r.b64, "\n"),
      ("png %d, base64 %d"):format(r.n, #r.b64))
    chk("A2 the baseline is inside the image", r.base >= 0 and r.base <= r.h, r.base)
    chk("A2 not shrunk, at the natural 30 px per em", not r.shrunk and r.em == 30, ("em %s"):format(r.em))
    chk("A2 x^2 at 14x30 takes a few columns and one or two rows", r.cols >= 1 and r.cols <= 6
      and r.rows >= 1 and r.rows <= 2, ("%dx%d"):format(r.cols, r.rows))
    local ph = png_head(r.b64)
    chk("A3 the base64 decodes to a PNG whose IHDR is the size: grid times cell",
      ph ~= nil and ph.w == r.w and ph.h == r.h, vim.inspect(ph))
    chk("A3 8-bit RGBA", ph ~= nil and ph.depth == 8 and ph.color == 6, vim.inspect(ph))
  end
  local ok2, out2 = N.call(N.KIND.MATH, EXAMPLE)
  chk("A4 the same request twice gives the same bytes", ok and ok2 and out == out2)

  -- one request for each class of error, by its message
  local cases = {
    { "request", "a first line that is not JNM 1", "JNM 2\n" .. EXAMPLE:sub(7) },
    { "request", "a cell line with one number", (EXAMPLE:gsub("cell 14 30", "cell 14")) },
    { "request", "a cell width below 4", request("x^2", { cw = 3 }) },
    { "request", "a body one byte longer than pre + tex", EXAMPLE .. "y" },
    { "input", "a TeX of 16385 bytes", request(("x"):rep(16385)) },
    { "input", "a prelude of 65537 bytes", request("x", { pre = ("%"):rep(65537) }) },
    { "input", "a TeX that is not UTF-8", request("x\255") },
    { "parse", "an undefined control sequence", request("\\undefinedcommand") },
    { "layout", "a formula past the layout budget", request(LAYOUT_BOMB) },
    { "glyph", "a character no bundled font has", request("\\text{日本語}") },
    { "size", "too wide for one column even at half size", request("x+y+z", { cols = 1 }) },
    { "empty", "a blank TeX", request("   ") },
    { "empty", "definitions only", request("\\newcommand{\\myset}{\\mathbb{R}}") },
  }
  for _, c in ipairs(cases) do
    local okc, msg = N.call(N.KIND.MATH, c[3])
    chk(("A5 %s: math: %s: ..."):format(c[2], c[1]), not okc and has(msg, "math: " .. c[1] .. ": ")
      and msg:find("math: " .. c[1] .. ": ", 1, true) == 1, tostring(msg):sub(1, 200))
  end
  local _, empty_msg = N.call(N.KIND.MATH, request("   "))
  chk("A5 the empty class says there is nothing to draw", empty_msg == "math: empty: nothing to draw",
    tostring(empty_msg))
  -- the internal class (the PNG encoder, an allocation) cannot be produced
  -- from outside the library; its unit tests cover it

  local okw, outw = N.call(N.KIND.MATH, request(MEDIUM, { cw = 10, ch = 20, cols = 30 }))
  local rw = okw and parse_response(outw)
  chk("A5 a formula too wide for its columns shrinks to fit them (shrunk 1, at most 30 columns)",
    rw and rw.shrunk and rw.cols <= 30 and rw.em < 20, okw and vim.inspect(rw and { rw.cols, rw.rows, rw.em,
    rw.shrunk }) or outw)

  local okc, cell = N.call(N.KIND.MATH_CELL, "")
  local jnc = okc and cell:match("^JNC 1\ncols %d+\nrows %d+\nxpixel %d+\nypixel %d+\nsource (%w+)\n$")
  chk("A6 MATH_CELL answers the six lines, or that there is no terminal",
    (okc and (jnc == "fd2" or jnc == "fd1" or jnc == "fd0" or jnc == "tty"))
      or (not okc and cell == "math cell: no terminal"), tostring(cell))
  local okx, msgx = N.call(N.KIND.MATH_CELL, "x")
  chk("A6 MATH_CELL with an input is an error", not okx and msgx == "math cell: no input is expected",
    tostring(msgx))
end)

-- ── the plugin ───────────────────────────────────────────────────────────
local J = require("jupynvim")
local NB = require("jupynvim.notebook")
local Image = require("jupynvim.notebook.image")
local Render = require("jupynvim.notebook.render")
local CellMode = require("jupynvim.notebook.cellmode")
local MD = require("jupynvim.notebook.markdown")
local notes = {}
vim.notify = function(m, l) notes[#notes + 1] = { msg = tostring(m), level = l } end
-- no kernel: the notebooks here only render
J.start_kernel = function() end
J.setup({ log_level = "warn", image_renderer = "placeholder", math = { cell_px = { w = 10, h = 20 } } })

section("the math module")
local okmi, MI = pcall(require, "jupynvim.notebook.mathimage")
chk("require(\"jupynvim.notebook.mathimage\") works", okmi and type(MI) == "table", tostring(MI))
if not okmi or type(MI) ~= "table" then MI = nil end

-- every MATH request the module submits, in order
local submitted = {}
local real_submit = N.submit
N.submit = function(kind, data, opts, cb)
  if kind == N.KIND.MATH then submitted[#submitted + 1] = data end
  return real_submit(kind, data, opts, cb)
end
local function submitted_for(tex)
  local t = {}
  for _, req in ipairs(submitted) do
    local q = parse_request(req)
    if q and q.tex == tex then t[#t + 1] = q end
  end
  return t
end

local function st() return MI and MI.status() or {} end
local function pending() return MI and (MI.status().pending or 0) or 0 end
local function stats()
  local s = MI and MI.stats or {}
  return { submits = s.submits or 0, transmits = s.transmits or 0, deferred = s.deferred or 0,
           fails = s.fails or 0, done = s.done or 0, hits = s.hits or 0, cancels = s.cancels or 0 }
end

-- ── notebooks ────────────────────────────────────────────────────────────
local function md(id, src) return { cell_type = "markdown", id = id, metadata = vim.empty_dict(), source = src } end
local function write_nb(name, cells)
  local p = tmp .. "/" .. name .. ".ipynb"
  local f = assert(io.open(p, "w"))
  f:write(vim.json.encode({
    cells = cells, nbformat = 4, nbformat_minor = 5,
    metadata = { kernelspec = { name = "python3", display_name = "P", language = "python" } },
  }))
  f:close()
  return p
end
local function open(path)
  local buf = J.open(path)
  vim.wait(10000, function() return buf ~= nil and NB.get(buf) ~= nil end, 10)
  if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_set_current_buf(buf) end
  local nb = buf and NB.get(buf)
  return buf, nb, buf and vim.fn.bufwinid(buf) or -1
end
local function close(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.cmd, "bwipeout! " .. buf) end
end
-- the library loaded and the cell size known, as the module sees them
local function lib_ready() vim.wait(10000, function() return st().lib == "ok" end, 10) return st().lib == "ok" end

-- Render until the notebook's math has settled: no job pending, and a render
-- that submits, transmits and defers nothing. False once `ms` have passed.
-- The deadline is on the monotonic clock, which moves also while the loop
-- below never runs the event loop (vim.wait returns at once when nothing is
-- pending, and libuv's cached time then stands still).
local function settle(nb, win, ms)
  local deadline = vim.uv.hrtime() + (ms or 20000) * 1e6
  while vim.uv.hrtime() < deadline do
    vim.wait(math.max(1, math.floor((deadline - vim.uv.hrtime()) / 1e6)), function() return pending() == 0 end, 5)
    local s0 = stats()
    Render.refresh_sync(nb, win)
    local s1 = stats()
    if pending() == 0 and s1.submits == s0.submits and s1.transmits == s0.transmits
        and s1.deferred == s0.deferred then
      return true
    end
  end
  return false
end

-- the slot of the n-th display block of a cell, and what image.lua holds for it
local function slot(buf, cell_id, n) return ("%d\31%s\31math%d"):format(buf, cell_id, n or 1) end
local function placement(buf, cell_id, n) return Image._placements[slot(buf, cell_id, n)] end
local function math_slots(buf)
  local pre, n = tostring(buf) .. "\31", 0
  for k, p in pairs(Image._placements) do
    if k:sub(1, #pre) == pre and has(k, "\31math") and p.renderer == "placeholder" then n = n + 1 end
  end
  return n
end

local function cell_idx(nb, id) for i, c in ipairs(nb.cells) do if c.id == id then return i end end end
-- a cell's source lines, 0-based, first and last
local function span(buf, nb, id)
  local r = CellMode.ranges(buf)[cell_idx(nb, id)]
  return r.start, r.stop - 1
end
local function is_ph(hl) return type(hl) == "string" and hl:sub(1, 11) == "JupynvimPH_" end
-- What the marks of lines first..last show: the overlay rows that carry
-- placeholders, the virtual lines that carry them, the marks of the text
-- rendering of math (inline virt_text in a math group), and per line the
-- number of marks that conceal it or draw over it.
local function look(buf, ns, first, last)
  local r = { ov = {}, vl = {}, text = 0, ph = {}, line = {} }
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { first, 0 }, { last, -1 }, { details = true })) do
    local row, d = m[2], m[4]
    if d.conceal ~= nil or d.virt_text_pos == "overlay" then r.line[row] = (r.line[row] or 0) + 1 end
    for _, ch in ipairs(d.virt_text or {}) do
      if is_ph(ch[2]) then
        r.ph[ch[2]] = true
        if d.virt_text_pos == "overlay" then
          r.ov[#r.ov + 1] = { row = row, text = ch[1], hl = ch[2], mode = d.hl_mode, prio = d.priority }
        end
      elseif d.virt_text_pos == "inline" and (ch[2] == "JupynvimMdMathBlock" or ch[2] == "JupynvimMdMath") then
        r.text = r.text + 1
      end
    end
    for _, vl in ipairs(d.virt_lines or {}) do
      for _, ch in ipairs(vl) do
        if is_ph(ch[2]) then
          r.ph[ch[2]] = true
          r.vl[#r.vl + 1] = { row = row, text = ch[1], hl = ch[2], above = d.virt_lines_above == true }
        end
      end
    end
  end
  table.sort(r.ov, function(a, b) return a.row < b.row end)
  return r
end
local function view(buf, nb, id)
  local a, b = span(buf, nb, id)
  return look(buf, nb.border_ns, a, b), a, b
end
local function ph_count(v) local n = 0 for _ in pairs(v.ph) do n = n + 1 end return n end
local function text_only(v) return #v.ov == 0 and #v.vl == 0 and ph_count(v) == 0 and v.text >= 1 end

-- Is the block on lines first..last drawn as image p: every row of it, with
-- its highlight group, its width in cells, overlays where the block has
-- lines and virtual lines under it for the rest (centred when it has more
-- lines than the image has rows), and each line's conceal and image row in
-- one mark?
local function placed(v, first, last, p)
  if not p then return false, "no placement" end
  for row, n in pairs(v.line) do
    if n > 1 then return false, ("line %d has %d marks that conceal it or draw over it"):format(row, n) end
  end
  local hl = "JupynvimPH_" .. p.image_id
  local S, R = last - first + 1, p.rows
  for _, o in ipairs(v.ov) do
    if o.hl ~= hl then return false, "overlay hl " .. o.hl .. ", want " .. hl end
    if o.mode ~= "replace" then return false, "overlay hl_mode " .. tostring(o.mode) end
    if vim.fn.strdisplaywidth(o.text) ~= p.cols then return false, "overlay width " .. vim.fn.strdisplaywidth(o.text) end
  end
  for _, l in ipairs(v.vl) do
    if l.hl ~= hl then return false, "virtual line hl " .. l.hl end
    if l.above then return false, "a virtual line above the block" end
    if vim.fn.strdisplaywidth(l.text) ~= p.cols then return false, "virtual line width" end
  end
  if #v.ov + #v.vl ~= R then return false, ("%d overlays + %d virtual lines for %d rows"):format(#v.ov, #v.vl, R) end
  if R <= S then
    local top = first + math.floor((S - R) / 2)
    for k, o in ipairs(v.ov) do
      if o.row ~= top + k - 1 then return false, ("overlay %d on line %d, want %d"):format(k, o.row, top + k - 1) end
    end
  else
    if #v.ov ~= S then return false, ("%d overlays for %d lines"):format(#v.ov, S) end
    for _, l in ipairs(v.vl) do
      if l.row ~= last then return false, "virtual lines not under the block's last line" end
    end
  end
  return true
end

-- one cell per block, so each block is its cell's first slot
local B_CELLS = {
  md("b1", "$$\nE = mc^2\n$$"),
  md("b2", "$$\\frac{a}{b}$$"),
  md("b3", "\\begin{align}\na &= b + c \\\\\nd &= e\n\\end{align}"),
  md("b4", "```math\n\\sum_{i=1}^{n} i\n```"),
  md("b5", "Inline $x^2 + y$ here."),
}
local B_BLOCKS = { "b1", "b2", "b3", "b4" }
local bbuf, bnb, bwin

-- ── B. a notebook ────────────────────────────────────────────────────────
run("B. a notebook", function()
  bbuf, bnb, bwin = open(write_nb("blocks", B_CELLS))
  chk("B0 the notebook opens", bnb ~= nil)
  local c = lib_ready() and st().cell
  chk("B0 the module has the library and the cell size from math.cell_px", type(c) == "table"
    and (c.w or c[1]) == 10 and (c.h or c[2]) == 20 and c.source == "config", vim.inspect(st()))
  chk("B0 math images are active: renderer auto, every precondition met", st().renderer == "auto"
    and st().active == true, vim.inspect({ st().renderer, st().active, st().why }))
  -- a first render: the cache emptied, so every block is new to it
  if MI then MI.reset() end
  reset_ui()
  local s0 = stats()
  Render.refresh_sync(bnb, bwin)
  local all_text = true
  for _, id in ipairs(B_BLOCKS) do
    local v = view(bbuf, bnb, id)
    if not text_only(v) then all_text = false end
  end
  chk("B1 a first render draws every block as text, with no placeholder", all_text)
  chk("B1 it submits one job per block, none collected yet, and writes nothing",
    MI ~= nil and stats().submits - s0.submits == #B_BLOCKS and pending() == #B_BLOCKS and #writes() == 0,
    ("submits %d, pending %d, writes %d"):format(stats().submits - s0.submits, pending(), #writes()))

  chk("B2 the jobs finish and the notebook settles", settle(bnb, bwin), vim.inspect(st()))
  for _, id in ipairs(B_BLOCKS) do
    local v, a, b = view(bbuf, bnb, id)
    local p = placement(bbuf, id)
    local okp, why = placed(v, a, b, p)
    chk("B2 block " .. id .. " is an image: its rows over the block, in its own highlight group", okp, why)
  end
  local t = txs()
  chk("B2 one transmit per block", #t == #B_BLOCKS, #t .. " transmits")
  for _, id in ipairs(B_BLOCKS) do
    local p = placement(bbuf, id)
    local found
    for _, s in ipairs(t) do if p and tx_id(s) == p.image_id then found = s end end
    local pid, c, r = tx_grid(found or "")
    chk("B2 block " .. id .. "'s transmit ends in a placement with its columns and rows",
      p and found and pid == p.image_id and c == p.cols and r == p.rows,
      p and ("placement %dx%d, sent %s"):format(p.cols, p.rows, tostring(found and (c .. "x" .. r))) or "no placement")
  end
  do
    -- the inline math is drawn exactly as without images
    local a, b = span(bbuf, bnb, "b5")
    local lines = vim.api.nvim_buf_get_lines(bbuf, a, b + 1, false)
    local function marks_of(buf, ns, first, last)
      local got = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { first, 0 }, { last, -1 }, { details = true })) do
        local d = m[4]
        if d.virt_text or d.conceal then
          got[#got + 1] = vim.inspect({ m[2] - first, m[3], d.end_col, d.conceal, d.virt_text, d.virt_text_pos })
        end
      end
      table.sort(got)
      return got
    end
    local sb = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(sb, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("math_image_spec_plain")
    MD.render(sb, ns, 0, #lines - 1, 73)
    local want = marks_of(sb, ns, 0, #lines - 1)
    vim.api.nvim_buf_delete(sb, { force = true })
    local v = look(bbuf, bnb.border_ns, a, b)
    chk("B3 inline math is unchanged: the marks of a render without images, and no placeholder",
      vim.deep_equal(marks_of(bbuf, bnb.border_ns, a, b), want) and ph_count(v) == 0 and v.text >= 1,
      vim.inspect(marks_of(bbuf, bnb.border_ns, a, b)) .. " vs " .. vim.inspect(want))
  end
end)

-- ── C. nothing on nothing ────────────────────────────────────────────────
run("C. a render that changes nothing", function()
  reset_ui()
  local s0 = stats()
  for _ = 1, 10 do Render.refresh_sync(bnb, bwin) end
  local s1 = stats()
  chk("C1 ten renders write nothing to the terminal", MI ~= nil and #writes() == 0, #writes() .. " writes")
  chk("C1 and submit nothing, transmit nothing", MI ~= nil and s1.submits == s0.submits
    and s1.transmits == s0.transmits and s1.hits - s0.hits == 10 * #B_BLOCKS,
    vim.inspect({ s0, s1 }))
end)

-- ── D. an edited block ───────────────────────────────────────────────────
run("D. an edited block", function()
  local before = {}
  for _, id in ipairs(B_BLOCKS) do local p = placement(bbuf, id); before[id] = p and p.image_id end
  reset_ui()
  local s0, n0 = stats(), #submitted
  local a = span(bbuf, bnb, "b1")
  vim.api.nvim_set_current_win(bwin)
  vim.api.nvim_win_set_cursor(bwin, { a + 2, 0 })
  CellMode.enter_edit(bbuf)
  vim.api.nvim_buf_set_lines(bbuf, a + 1, a + 2, false, { "E = mc^3" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bbuf })
  CellMode.enter_command(bbuf)
  chk("D0 the edit reaches the cell", bnb.cells[cell_idx(bnb, "b1")].source == "$$\nE = mc^3\n$$",
    bnb.cells[cell_idx(bnb, "b1")].source)
  chk("D0 the notebook settles", settle(bnb, bwin))
  local q = submitted[n0 + 1] and parse_request(submitted[n0 + 1])
  chk("D1 exactly one new job, for the new TeX", stats().submits - s0.submits == 1 and #submitted == n0 + 1
    and q ~= nil and q.tex == "E = mc^3", ("%d jobs: %s"):format(#submitted - n0, q and q.tex or "?"))
  local p = placement(bbuf, "b1")
  local t = txs()
  chk("D2 one transmit, of the new image", #t == 1 and p ~= nil and tx_id(t[1]) == p.image_id
    and p.image_id ~= before.b1, #t .. " transmits")
  chk("D3 one delete, of the old image", before.b1 ~= nil and deletes_of(before.b1) == 1,
    before.b1 and deletes_of(before.b1) or "no old image")
  local quiet = true
  for _, id in ipairs({ "b2", "b3", "b4" }) do
    if not before[id] or mentions(before[id]) > 0 then quiet = false end
  end
  chk("D4 the other blocks write nothing", quiet, vim.inspect(writes()):sub(1, 300))
  local v, fa, fb = view(bbuf, bnb, "b1")
  chk("D5 the edited block shows its new image", placed(v, fa, fb, p))
end)
close(bbuf)

-- ── E. macros ────────────────────────────────────────────────────────────
run("E. macros from an earlier cell", function()
  local DEF = "$$\\newcommand{\\myset}{\\mathbb{R}}$$"
  local s0 = stats()
  local buf, nb, win = open(write_nb("macros", { md("e1", DEF), md("e2", "$$x \\in \\myset$$") }))
  settle(nb, win)
  local v2, a2, b2 = view(buf, nb, "e2")
  chk("E1 a formula that uses a macro defined in the cell above is an image",
    placed(v2, a2, b2, placement(buf, "e2")))
  local q = submitted_for("x \\in \\myset")[1]
  chk("E1 its request carries the defining cell's source as the prelude", q ~= nil and q.prelude == DEF,
    q and q.prelude or "no request")
  local v1 = view(buf, nb, "e1")
  chk("E1 the defining block itself stays text (nothing to draw)", text_only(v1) and placement(buf, "e1") == nil
    and stats().fails > s0.fails)
  close(buf)

  local f0 = stats().fails
  buf, nb, win = open(write_nb("nomacros", { md("e3", "$$x \\in \\myset$$") }))
  settle(nb, win)
  chk("E2 without the defining cell the formula stays text, and the failure is counted",
    MI ~= nil and text_only(view(buf, nb, "e3")) and placement(buf, "e3") == nil and stats().fails > f0,
    ("fails %d -> %d"):format(f0, stats().fails))
  close(buf)

  buf, nb, win = open(write_nb("redefine", { md("e4", "$$\\newcommand{\\R}{\\mathbf{R}}$$"), md("e5", "$$\\R^n$$") }))
  settle(nb, win)
  local v5, a5, b5 = view(buf, nb, "e5")
  chk("E3 \\newcommand of a name KaTeX already has (\\R) works in the next cell: an image",
    placed(v5, a5, b5, placement(buf, "e5")))
  close(buf)
end)

-- ── F. fallbacks ─────────────────────────────────────────────────────────
local F_CELLS = {
  md("f1", "$$\\undefinedcommand$$"),
  md("f2", "$$\\text{日本語}$$"),
  md("f3", "$$\n" .. WIDE .. "\n$$"),
  md("f4", "$$\n" .. MEDIUM .. "\n$$"),
  md("f5", "$$x^2$$"),
}
local fpath = write_nb("fallbacks", F_CELLS)
run("F. what stays text", function()
  vim.cmd("silent! only")
  local f0 = stats().fails
  local buf, nb, win = open(fpath)
  settle(nb, win)
  chk("F1 an undefined command stays text", MI ~= nil and text_only(view(buf, nb, "f1"))
    and placement(buf, "f1") == nil)
  chk("F2 a character no bundled font has stays text", MI ~= nil and text_only(view(buf, nb, "f2"))
    and placement(buf, "f2") == nil)
  chk("F1 F2 both count as failures", stats().fails - f0 >= 2, stats().fails - f0)
  local v5, a5, b5 = view(buf, nb, "f5")
  chk("F0 a plain formula next to them is an image", placed(v5, a5, b5, placement(buf, "f5")))

  -- a window whose text area is 30 columns
  vim.api.nvim_set_current_win(win)
  vim.cmd("leftabove vnew")
  local scratch = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_width(win, 30 + CellMode.GUTTER)
  chk("F3 the notebook window's text area is 30 columns", vim.api.nvim_win_get_width(win) - CellMode.GUTTER == 30,
    vim.api.nvim_win_get_width(win))
  settle(nb, win)
  chk("F3 a formula too wide for 30 columns even at half size stays text",
    MI ~= nil and text_only(view(buf, nb, "f3")) and placement(buf, "f3") == nil)
  local p4 = placement(buf, "f4")
  local v4, a4, b4 = view(buf, nb, "f4")
  chk("F3 a formula a little too wide is shrunk to fit: an image of at most 30 columns",
    placed(v4, a4, b4, p4) and p4.cols <= 30, p4 and p4.cols)
  local asked = false
  for _, q in ipairs(submitted_for(MEDIUM)) do if has(q.head, "\nmax 30 ") then asked = true end end
  chk("F3 the job for it asked for at most 30 columns", asked)
  local p5 = placement(buf, "f5")
  chk("F3 a formula that fits keeps its image", p5 ~= nil and placed(view(buf, nb, "f5"), a5, b5, p5))
  pcall(vim.api.nvim_win_close, scratch, true)
  vim.api.nvim_set_current_win(win)
  settle(nb, win)

  -- math.renderer = "text", and back
  chk("F4 :JupynvimMathMode exists", vim.fn.exists(":JupynvimMathMode") == 2)
  local id5 = placement(buf, "f5") and placement(buf, "f5").image_id
  reset_ui()
  local s0 = stats()
  pcall(vim.cmd, "JupynvimMathMode text")
  Render.refresh_sync(nb, win)
  chk("F4 math.renderer = \"text\": every block is text and its image is deleted",
    st().renderer == "text" and text_only(view(buf, nb, "f5")) and placement(buf, "f5") == nil
      and id5 ~= nil and deletes_of(id5) >= 1 and math_slots(buf) == 0,
    vim.inspect({ st().renderer, math_slots(buf) }))
  for _ = 1, 3 do Render.refresh_sync(nb, win) end
  chk("F4 and nothing is asked of the library", stats().submits == s0.submits)
  pcall(vim.cmd, "JupynvimMathMode auto")
  settle(nb, win)
  chk("F4 :JupynvimMathMode auto brings the image back", st().renderer == "auto"
    and placed(view(buf, nb, "f5"), a5, b5, placement(buf, "f5")))

  -- another image renderer, and back
  reset_ui()
  s0 = stats()
  pcall(vim.cmd, "JupynvimImageMode chafa")
  Render.refresh_sync(nb, win)
  chk("F5 :JupynvimImageMode chafa: math is text", text_only(view(buf, nb, "f5")) and placement(buf, "f5") == nil
    and stats().submits == s0.submits)
  pcall(vim.cmd, "JupynvimImageMode placeholder")
  settle(nb, win)
  chk("F5 and back to placeholder: an image again", MI ~= nil
    and placed(view(buf, nb, "f5"), a5, b5, placement(buf, "f5")))
  close(buf)

  -- no library at all: a child Neovim with JUPYNVIM_NATIVE=off
  local child = tmp .. "/child.lua"
  local f = assert(io.open(child, "w"))
  f:write([==[
-- opens one notebook with the library turned off and prints, as one JSON
-- line, what its math shows and every notice it made
local repo, path = arg[1], arg[2]
vim.opt.runtimepath:prepend(repo)
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
local notes = {}
vim.notify = function(m, l) notes[#notes + 1] = { msg = tostring(m), level = l or 0 } end
local out = { notes = notes }
local ok, err = pcall(function()
  local J = require("jupynvim")
  J.start_kernel = function() end
  J.setup({ log_level = "warn", image_renderer = "placeholder", math = { cell_px = { w = 10, h = 20 } } })
  local NB = require("jupynvim.notebook")
  local buf = J.open(path)
  vim.wait(10000, function() return buf ~= nil and NB.get(buf) ~= nil end, 10)
  local nb = NB.get(buf)
  local okm, MI = pcall(require, "jupynvim.notebook.mathimage")
  out.module = okm
  vim.wait(10000, function() return okm and MI.status().lib == "off" end, 10)
  require("jupynvim.notebook.render").refresh_sync(nb, vim.fn.bufwinid(buf))
  -- whatever was scheduled before this runs first: a notice lands
  local flushed = false
  vim.schedule(function() flushed = true end)
  vim.wait(5000, function() return flushed end, 5)
  local ph, text = 0, 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, nb.border_ns, 0, -1, { details = true })) do
    local d = m[4]
    for _, ch in ipairs(d.virt_text or {}) do
      if type(ch[2]) == "string" and ch[2]:sub(1, 11) == "JupynvimPH_" then ph = ph + 1 end
      if d.virt_text_pos == "inline" and ch[2] == "JupynvimMdMathBlock" then text = text + 1 end
    end
    for _, vl in ipairs(d.virt_lines or {}) do
      for _, ch in ipairs(vl) do
        if type(ch[2]) == "string" and ch[2]:sub(1, 11) == "JupynvimPH_" then ph = ph + 1 end
      end
    end
  end
  out.ph, out.text = ph, text
  out.lib = okm and MI.status().lib or nil
  out.native = require("jupynvim.native").status().state
end)
out.ok, out.err = ok, (not ok) and tostring(err) or nil
io.stdout:write("\n", vim.json.encode(out), "\n")
vim.cmd("qa!")
]==])
  f:close()
  local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", child, REPO, fpath },
    { env = { JUPYNVIM_NATIVE = "off" }, text = true }):wait(60000)
  local line
  for l in (r.stdout or ""):gmatch("[^\n]+") do if l:sub(1, 1) == "{" then line = l end end
  local okj, j = pcall(vim.json.decode, line or "")
  if not okj or type(j) ~= "table" then j = nil end
  local loud = {}
  for _, n in ipairs(j and j.notes or {}) do
    if (tonumber(n.level) or 0) >= vim.log.levels.WARN then loud[#loud + 1] = n.msg end
  end
  chk("F6 JUPYNVIM_NATIVE=off: the notebook opens and renders", j ~= nil and j.ok == true and j.module == true,
    j and (j.err or "module missing") or ("exit %s, stderr %s"):format(r.code, r.stderr))
  chk("F6 every block is text, no placeholder, the library off", j ~= nil and j.ph == 0 and j.text >= 3
    and j.lib == "off" and j.native == "disabled", j and vim.inspect({ j.ph, j.text, j.lib, j.native }))
  chk("F6 and no warning or error says so", j ~= nil and #loud == 0 and not has(r.stderr, "Error")
    and not has(r.stderr, "E5108"), vim.inspect(loud) .. " " .. tostring(r.stderr))

  -- a library from before the math kinds: a child Neovim in which the real
  -- library answers as a 1.1 build would (ABI 1.1, no math kind)
  local child11 = tmp .. "/child11.lua"
  f = assert(io.open(child11, "w"))
  f:write([==[
-- opens one notebook with the library answering as ABI 1.1 without the math
-- kinds, and prints, as one JSON line, what its math shows, what the
-- palette and math sections of :checkhealth say, and every notice it made
local repo, path = arg[1], arg[2]
vim.opt.runtimepath:prepend(repo)
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
local ffi = require("ffi")
local real_load = ffi.load
ffi.load = function(p, ...)
  local lib = real_load(p, ...)
  if not tostring(p):find("libjupynvim", 1, true) then return lib end
  return setmetatable({
    jnv_abi_version = function() return 1 * 65536 + 1 end,
    jnv_kind_supported = function(k)
      if k == 2304 or k == 2305 then return 0 end
      return lib.jnv_kind_supported(k)
    end,
  }, { __index = function(_, name) return lib[name] end })
end
local notes = {}
vim.notify = function(m, l) notes[#notes + 1] = { msg = tostring(m), level = l or 0 } end
local out = { notes = notes }
local ok, err = pcall(function()
  local J = require("jupynvim")
  J.start_kernel = function() end
  J.setup({ log_level = "warn", image_renderer = "placeholder", math = { cell_px = { w = 10, h = 20 } } })
  local N = require("jupynvim.native")
  local NB = require("jupynvim.notebook")
  local buf = J.open(path)
  vim.wait(10000, function() return buf ~= nil and NB.get(buf) ~= nil end, 10)
  local nb = NB.get(buf)
  local MI = require("jupynvim.notebook.mathimage")
  vim.wait(10000, function() local l = MI.status().lib return l == "off" or l == "ok" end, 10)
  require("jupynvim.notebook.render").refresh_sync(nb, vim.fn.bufwinid(buf))
  local flushed = false
  vim.schedule(function() flushed = true end)
  vim.wait(5000, function() return flushed end, 5)
  local ph, text = 0, 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, nb.border_ns, 0, -1, { details = true })) do
    local d = m[4]
    for _, ch in ipairs(d.virt_text or {}) do
      if type(ch[2]) == "string" and ch[2]:sub(1, 11) == "JupynvimPH_" then ph = ph + 1 end
      if d.virt_text_pos == "inline" and ch[2] == "JupynvimMdMathBlock" then text = text + 1 end
    end
    for _, vl in ipairs(d.virt_lines or {}) do
      for _, ch in ipairs(vl) do
        if type(ch[2]) == "string" and ch[2]:sub(1, 11) == "JupynvimPH_" then ph = ph + 1 end
      end
    end
  end
  out.ph, out.text = ph, text
  out.lib = MI.status().lib
  local ns = N.status()
  out.native, out.abi, out.abi2 = ns.state, ns.abi, N.has_abi(2)
  local lines = {}
  local function rec(kind) return function(m) lines[#lines + 1] = kind .. " " .. tostring(m) end end
  local H = require("jupynvim.health")
  local h = { start = rec("START"), ok = rec("OK"), info = rec("INFO"), warn = rec("WARN"), error = rec("ERROR") }
  H._palette(h)
  H._math(h)
  out.health = lines
end)
out.ok, out.err = ok, (not ok) and tostring(err) or nil
io.stdout:write("\n", vim.json.encode(out), "\n")
vim.cmd("qa!")
]==])
  f:close()
  r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", child11, REPO, fpath }, { text = true }):wait(60000)
  line = nil
  for l in (r.stdout or ""):gmatch("[^\n]+") do if l:sub(1, 1) == "{" then line = l end end
  okj, j = pcall(vim.json.decode, line or "")
  if not okj or type(j) ~= "table" then j = nil end
  loud = {}
  for _, n in ipairs(j and j.notes or {}) do
    if (tonumber(n.level) or 0) >= vim.log.levels.WARN then loud[#loud + 1] = n.msg end
  end
  local hl = j and type(j.health) == "table" and j.health or {}
  local function hline(prefix, sub)
    for _, l in ipairs(hl) do if l:sub(1, #prefix) == prefix and has(l, sub) then return l end end
  end
  chk("F7 a library at ABI 1.1 without the math kinds loads: ok, ABI 1.1, has_abi(2) false",
    j ~= nil and j.ok == true and j.native == "ok" and j.abi == "1.1" and j.abi2 == false,
    j and vim.inspect({ j.err, j.native, j.abi, j.abi2 }) or ("exit %s, stderr %s"):format(r.code, r.stderr))
  chk("F7 every block is text, no placeholder, the module's library off", j ~= nil and j.ph == 0 and j.text >= 3
    and j.lib == "off", j and vim.inspect({ j.ph, j.text, j.lib }))
  chk("F7 the palette still derives (OK palette: ...)", hline("OK ", "palette: ") ~= nil, vim.inspect(hl))
  chk("F7 the math section says why, as information: this libjupynvim (ABI 1.1)",
    hline("INFO ", "this libjupynvim (ABI 1.1)") ~= nil and hline("WARN ", "") == nil and hline("ERROR ", "") == nil,
    vim.inspect(hl))
  chk("F7 and no notice warns", j ~= nil and #loud == 0 and not has(r.stderr, "Error") and not has(r.stderr, "E5108"),
    vim.inspect(loud) .. " " .. tostring(r.stderr))
end)

-- ── G. lifetime ──────────────────────────────────────────────────────────
run("G. image lifetime", function()
  vim.cmd("silent! only")
  local G_BLOCKS = { "g1", "g2", "g3" }
  local buf, nb, win = open(write_nb("lifetime", { md("g1", "$$a^2$$"), md("g2", "$$b^2$$"), md("g3", "$$c^2$$") }))
  settle(nb, win)
  local ids = {}
  for _, id in ipairs(G_BLOCKS) do ids[id] = placement(buf, id) and placement(buf, id).image_id end
  chk("G0 three images", ids.g1 and ids.g2 and ids.g3)

  -- a new ink colour: every block typeset again, new images, the old ones deleted
  reset_ui()
  local n0, s0 = #submitted, stats()
  vim.cmd("hi JupynvimMathImage guifg=#ff0000")
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  -- the event alone: the module has the notebook rendered again, reads the
  -- colour there and asks for every block again
  chk("G1 a ColorScheme event alone makes the module take the new colour and typeset again",
    vim.wait(5000, function() return st().fg == "#ff0000" and stats().submits > s0.submits end, 5),
    tostring(st().fg))
  settle(nb, win)
  local red = 0
  for k = n0 + 1, #submitted do if has(submitted[k], "\nfg #ff0000\n") then red = red + 1 end end
  chk("G1 every block is typeset again in the new colour", stats().submits - s0.submits == #G_BLOCKS
    and red == #G_BLOCKS, ("%d jobs, %d in #ff0000"):format(stats().submits - s0.submits, red))
  local fresh, gone = true, true
  for _, id in ipairs(G_BLOCKS) do
    local p = placement(buf, id)
    if not p or p.image_id == ids[id] then fresh = false end
    if not ids[id] or deletes_of(ids[id]) ~= 1 then gone = false end
  end
  chk("G1 new images", fresh)
  chk("G1 the old images are deleted, each once", gone)
  vim.api.nvim_set_hl(0, "JupynvimMathImage", { link = "JupynvimMdMathBlock" })
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  vim.wait(5000, function() return st().fg ~= "#ff0000" end, 5)
  settle(nb, win)

  -- a deleted cell takes its image with it
  for _, id in ipairs(G_BLOCKS) do ids[id] = placement(buf, id) and placement(buf, id).image_id end
  reset_ui()
  local a2 = span(buf, nb, "g2")
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { a2 + 1, 0 })
  J.delete_cell(buf)
  vim.wait(5000, function() return cell_idx(nb, "g2") == nil end, 5)
  chk("G2 the cell is deleted", cell_idx(nb, "g2") == nil and #nb.cells == 2, #nb.cells)
  settle(nb, win)
  chk("G2 deleting a cell deletes its image", ids.g2 ~= nil and deletes_of(ids.g2) == 1
    and placement(buf, "g2") == nil)
  chk("G2 and leaves the others alone", ids.g1 and ids.g3 and deletes_of(ids.g1) == 0 and deletes_of(ids.g3) == 0
    and placement(buf, "g1") ~= nil and placement(buf, "g3") ~= nil)

  -- a second notebook, wiped: its images go; the first one's come back
  -- on its next render with no new job
  vim.cmd("split")
  local buf2, nb2, win2 = open(write_nb("second", { md("h1", "$$d^2$$"), md("h2", "$$e^2$$") }))
  settle(nb2, win2)
  settle(nb, win)
  local h1 = placement(buf2, "h1")
  chk("G3 the second notebook has its images", h1 ~= nil and placement(buf2, "h2") ~= nil)
  reset_ui()
  local sub0 = stats().submits
  close(buf2)
  chk("G3 wiping it deletes its images", h1 ~= nil and (deletes_of(h1.image_id) >= 1 or delete_all_sent())
    and placement(buf2, "h1") == nil and placement(buf2, "h2") == nil)
  reset_ui()
  win = vim.fn.bufwinid(buf)
  Render.refresh_sync(nb, win)
  chk("G4 the first notebook's images are sent again on its next render", #txs() == 2
    and placement(buf, "g1") ~= nil and placement(buf, "g3") ~= nil, #txs() .. " transmits")
  chk("G4 with no new job", MI ~= nil and stats().submits == sub0, stats().submits - sub0)

  -- the buffer wiped: its images go
  ids.g1, ids.g3 = placement(buf, "g1") and placement(buf, "g1").image_id, placement(buf, "g3")
    and placement(buf, "g3").image_id
  reset_ui()
  close(buf)
  chk("G5 wiping a notebook deletes its images", ids.g1 ~= nil and ids.g3 ~= nil
    and (delete_all_sent() or (deletes_of(ids.g1) >= 1 and deletes_of(ids.g3) >= 1))
    and placement(buf, "g1") == nil and placement(buf, "g3") == nil and (not MI or st().slots == 0),
    vim.inspect({ st().slots }))
end)

-- ── H. the fixture notebook ──────────────────────────────────────────────
run("H. the markdown fixture notebook", function()
  vim.cmd("silent! only")
  local Log = require("jupynvim.log")
  local logp = Log.path and Log.path()
  local log0 = logp and vim.uv.fs_stat(logp) and vim.uv.fs_stat(logp).size or 0
  local errs0 = 0
  for _, n in ipairs(notes) do if n.level == vim.log.levels.ERROR then errs0 = errs0 + 1 end end
  local buf, nb, win = open(REPO .. "/tests/fixtures/markdown/md-fixture.ipynb")
  chk("H1 the fixture notebook opens in place", nb ~= nil and #nb.cells == 31, nb and #nb.cells)
  chk("H1 it settles: nothing pending", settle(nb, win, 60000) and pending() == 0, vim.inspect(st()))
  local n = math_slots(buf)
  chk(("H1 at least 30 of its display maths are images (%d)"):format(n), n >= 30, n)
  local errs = 0
  for _, x in ipairs(notes) do if x.level == vim.log.levels.ERROR then errs = errs + 1 end end
  local logged = ""
  if logp then
    local f = io.open(logp, "r")
    if f then f:seek("set", log0); logged = f:read("*a") or ""; f:close() end
  end
  local bad = {}
  for l in logged:gmatch("[^\n]+") do
    if has(l, "[error]") or has(l, "render_cell failed") or has(l, "math images:") then bad[#bad + 1] = l end
  end
  chk("H1 and logs no error", errs == errs0 and #bad == 0, vim.inspect(bad))

  -- what 200 renders cost with images, against the same notebook as text
  local function cost(times)
    local best = math.huge
    for _ = 1, 3 do
      local t0 = vim.uv.hrtime()
      for _ = 1, times do Render.refresh_sync(nb, win) end
      best = math.min(best, (vim.uv.hrtime() - t0) / 1e6)
    end
    return best
  end
  reset_ui()
  local with_images = cost(200)
  local quiet = MI ~= nil and #writes() == 0
  pcall(vim.cmd, "JupynvimMathMode text")
  Render.refresh_sync(nb, win)
  local as_text = cost(200)
  pcall(vim.cmd, "JupynvimMathMode auto")
  chk(("C2 200 renders of the fixture notebook: %.1f ms with images, %.1f ms as text, at most 1.5 times")
    :format(with_images, as_text), MI ~= nil and with_images <= 1.5 * as_text)
  chk("C2 and the renders with images wrote nothing", quiet)
  close(buf)
end)

-- ── I. health ────────────────────────────────────────────────────────────
run("I. :checkhealth jupynvim", function()
  local tab = vim.api.nvim_get_current_tabpage()
  local ok, err = pcall(vim.cmd, "checkhealth jupynvim")
  -- :checkhealth writes its progress to stdout with no newline
  io.write("\n")
  local hbuf = vim.api.nvim_get_current_buf()
  local text = table.concat(vim.api.nvim_buf_get_lines(hbuf, 0, -1, false), "\n")
  pcall(vim.cmd, "bwipe! " .. hbuf)
  if vim.api.nvim_tabpage_is_valid(tab) then pcall(vim.api.nvim_set_current_tabpage, tab) end
  chk("I0 :checkhealth jupynvim runs", ok and not has(text, "Failed to run healthcheck"), err)
  local head = "jupynvim: math images"
  local a = text:find(head, 1, true)
  local part = a and text:sub(a, (text:find("\n%S[^\n]* ~\n", a + #head)) or #text) or ""
  chk("I1 the report has a math images section", a ~= nil)
  local function line_with(sub) for l in part:gmatch("[^\n]+") do if has(l, sub) then return l end end end
  local function is_ok(l) return l ~= nil and l:find("^%- .*OK ") ~= nil end
  local l1 = line_with("cell 10x20 px, from math.cell_px")
  chk("I2 OK cell 10x20 px, from math.cell_px", is_ok(l1), l1 or part)
  local l2 = line_with("typeset probe:")
  chk("I3 OK typeset probe: <cols>x<rows> cells in <ms>", is_ok(l2) and l2:find("typeset probe: %d+x%d+ cells in ") ~= nil,
    l2 or part)
  chk("I4 nothing in the section warns", part ~= "" and not has(part, "WARNING") and not has(part, "ERROR"), part)

  -- Before any notebook has rendered, the module has not asked for the
  -- library nor measured the cell: the section asks the terminal itself. A
  -- child Neovim whose stderr is a pseudo-terminal of 180x50 cells and
  -- 2520x1500 pixels (14x30 a cell), with no math.cell_px.
  local hchild = tmp .. "/health_child.lua"
  local f = assert(io.open(hchild, "w"))
  f:write([==[
-- the math section of :checkhealth before any notebook has rendered, then
-- with the module's library answer "off", as one JSON line
local repo = arg[1]
vim.opt.runtimepath:prepend(repo)
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
vim.env.TERM = "xterm-kitty"
vim.notify = function() end
local out = {}
local ok, err = pcall(function()
  local J = require("jupynvim")
  J.setup({ log_level = "warn", image_renderer = "placeholder" })
  local N = require("jupynvim.native")
  out.up = N.available()
  local MI = require("jupynvim.notebook.mathimage")
  local H = require("jupynvim.health")
  local function section()
    local lines = {}
    local function rec(kind) return function(m) lines[#lines + 1] = kind .. " " .. tostring(m) end end
    H._math({ start = rec("START"), ok = rec("OK"), info = rec("INFO"), warn = rec("WARN"), error = rec("ERROR") })
    return lines
  end
  out.lib_before = MI.status().lib
  out.first = section()
  out.lib_after = MI.status().lib
  MI._S.lib = "off"
  local st = MI.status()
  out.active, out.why, out.lib_off = st.active, st.why, st.lib
  out.second = section()
end)
out.ok, out.err = ok, (not ok) and tostring(err) or nil
io.stdout:write("\n", vim.json.encode(out), "\n")
vim.cmd("qa!")
]==])
  f:close()
  -- stdin from /dev/null, stdout a pipe, stderr the pseudo-terminal, whose
  -- other end is drained so nothing written there can block the child
  local PTY = [[
import fcntl, os, pty, struct, subprocess, sys, termios, threading
m, s = pty.openpty()
fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 180, 2520, 1500))
def drain():
    try:
        while os.read(m, 4096):
            pass
    except OSError:
        pass
threading.Thread(target=drain, daemon=True).start()
p = subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=s, timeout=60)
sys.stdout.buffer.write(p.stdout)
sys.exit(p.returncode)
]]
  local py = vim.fn.exepath("python3")
  chk("I5 python3 is there to make a pseudo-terminal", py ~= "", "python3 not found in PATH")
  if py == "" then return end
  local r = vim.system({ py, "-I", "-c", PTY, vim.v.progpath, "--headless", "-u", "NONE", "-l", hchild, REPO },
    { text = true }):wait(90000)
  local jl
  for l in (r.stdout or ""):gmatch("[^\n]+") do if l:sub(1, 1) == "{" then jl = l end end
  local okj, j = pcall(vim.json.decode, jl or "")
  if not okj or type(j) ~= "table" then j = nil end
  local function hline(list, prefix, sub)
    for _, l in ipairs(type(list) == "table" and list or {}) do
      if l:sub(1, #prefix) == prefix and has(l, sub) then return l end
    end
  end
  chk("I5 the child runs the section", j ~= nil and j.ok == true and j.up == true,
    j and vim.inspect(j) or ("exit %s, stderr %s"):format(r.code, r.stderr))
  local first = j and j.first or {}
  chk("I5 before any notebook has rendered: OK cell 14x30 px, from the terminal (asked by the section)",
    hline(first, "OK ", "cell 14x30 px, from the terminal") ~= nil and hline(first, "WARN ", "") == nil,
    vim.inspect(first))
  chk("I5 and it says the module has not asked for the library yet, and leaves it so",
    hline(first, "INFO ", "none has rendered yet") ~= nil and j.lib_before == "unasked" and j.lib_after == "unasked",
    j and vim.inspect({ j.lib_before, j.lib_after, first }))
  local second = j and j.second or {}
  local said = j and j.active == false and type(j.why) == "string" and j.why ~= ""
    and (hline(second, "INFO ", j.why) ~= nil
      or (j.lib_off == "unasked" and hline(second, "INFO ", "none has rendered yet") ~= nil))
  chk("I6 images off for the module's own reason: the section prints that reason", said == true,
    j and vim.inspect({ j.active, j.why, second }))
end)

-- ── J. the UI thread ─────────────────────────────────────────────────────
run("J. a render never waits for a job", function()
  vim.cmd("silent! only")
  -- a job that keeps a worker busy for tens of milliseconds: 16 KB of x+
  -- (too wide in the end, so it fails, after all the work). A render that
  -- waited for it would take longer than the budget.
  local heavy = "$$" .. ("x+"):rep(8000) .. "x$$"
  local buf, nb, win = open(write_nb("thread", { md("j1", "$$x + 1$$"), md("j2", heavy) }))
  -- rendered once before, so the timings below hold no first-time cost of
  -- the text rendering
  settle(nb, win)
  if MI then MI.reset() end
  local t0 = vim.uv.hrtime()
  Render.refresh_sync(nb, win)
  local first = (vim.uv.hrtime() - t0) / 1e6
  local inflight = pending()
  t0 = vim.uv.hrtime()
  Render.refresh_sync(nb, win)
  local second = (vim.uv.hrtime() - t0) / 1e6
  chk("J1 the render that submits leaves its jobs running", MI ~= nil and inflight == 2 and pending() == 2,
    inflight)
  chk(("J1 that render returns in under 20 ms (%.2f ms)"):format(first), MI ~= nil and first < 20)
  chk(("J1 and so does the next one, with the jobs not yet collected (%.2f ms)"):format(second),
    MI ~= nil and second < 20)
  settle(nb, win)
  close(buf)
end)

-- ── K. rows on the screen ────────────────────────────────────────────────
run("K. the rows on the screen", function()
  vim.cmd("silent! only")
  local buf, nb, win = open(write_nb("screen", {
    md("k1", "Before\n$$\\frac{a}{b}$$"),
    md("k2", "| a | b |\n|---|---|\n| 1 | 2 |"),
    md("k3", "After"),
  }))
  vim.api.nvim_win_call(win, function() vim.fn.winrestview({ topline = 1, lnum = 1, col = 0, topfill = 0 }) end)
  settle(nb, win)
  vim.cmd("redraw!")
  local info = vim.fn.getwininfo(win)[1]
  local tcol = info.wincol + info.textoff
  local PH = 0x10EEEE
  local kind, first_ph, text_of = {}, nil, {}
  for row = info.winrow, info.winrow + info.height - 1 do
    local s = vim.fn.screenstring(row, tcol)
    local cp = s ~= "" and vim.fn.char2nr(s) or 0
    local t = {}
    for c = tcol, math.min(tcol + 20, info.wincol + info.width - 1) do t[#t + 1] = vim.fn.screenstring(row, c) end
    text_of[row] = table.concat(t)
    if cp == PH then
      kind[row] = "ph"
      first_ph = first_ph or row
    elseif vim.trim(text_of[row]) == "" then
      kind[row] = "blank"
    else
      kind[row] = "text"
    end
  end
  local p = placement(buf, "k1")
  local R = p and p.rows or 0
  chk("K0 the one-line \\frac{a}{b} is an image of more rows than its one line", p ~= nil and R >= 2, R)
  local run_len = 0
  if first_ph then
    local row = first_ph
    while kind[row] == "ph" do run_len, row = run_len + 1, row + 1 end
  end
  chk("K1 its rows are on the screen one under the other, with no blank row between", first_ph ~= nil
    and run_len == R, ("%s rows from row %s"):format(run_len, tostring(first_ph)))
  local after = first_ph and first_ph + run_len
  chk("K1 the row after the last image row is the cell's spacer, blank", after ~= nil and kind[after] == "blank",
    after and ("%q"):format(text_of[after] or "") or "")
  local next_row = after and after + 1
  while next_row and kind[next_row] == "blank" do next_row = next_row + 1 end
  chk("K1 and the next thing drawn after it is the next cell's table", next_row ~= nil
    and (text_of[next_row] or ""):find("┌", 1, true) == 1, next_row and ("%q"):format(text_of[next_row] or "") or "")
  local bottom
  for row = info.winrow, info.winrow + info.height - 1 do
    if (text_of[row] or ""):find("└", 1, true) == 1 then bottom = row; break end
  end
  chk("K2 a cell that ends in a table: the bottom border is the row right under the last table row",
    bottom ~= nil and has(text_of[bottom - 1] or "", "│ 1 ") and kind[bottom + 1] == "blank",
    bottom and ("%q / %q / %q"):format(text_of[bottom - 1] or "", text_of[bottom] or "", text_of[bottom + 1] or "")
      or vim.inspect(text_of))
  close(buf)
end)

-- ── L. cells that share an id ────────────────────────────────────────────
-- A notebook in which markdown cells repeat one id (invalid since nbformat
-- 4.5, but copies and hand merges make them): each cell still gets images of
-- its own, the notebook settles, and an idle editor then renders nothing.
-- The same notebook with distinct ids is the control for the idle check.
run("L. markdown cells that share one id", function()
  vim.cmd("silent! only")
  local function twenty(id_of)
    local cells = {}
    for i = 1, 20 do cells[i] = md(id_of(i), ("$$x^{%d}$$"):format(i)) end
    return cells
  end
  -- every cell's block an image, each in a group of its own; the number of
  -- images, and whether every cell has one
  local function own_images(buf, nb)
    local ranges = CellMode.ranges(buf)
    local groups, n, all = {}, 0, true
    for i = 1, #nb.cells do
      local r = ranges[i]
      local v = r and look(buf, nb.border_ns, r.start, r.stop - 1)
      local hl = v and next(v.ph)
      if not v or ph_count(v) ~= 1 or #v.ov == 0 then
        all = false
      elseif not groups[hl] then
        groups[hl], n = true, n + 1
      end
    end
    return n, all
  end
  -- a second left idle: renders, jobs, transmits and terminal writes in it,
  -- once what the last render scheduled has run
  local function idle()
    vim.wait(300, function() return false end, 10)
    reset_ui()
    local s0, r0 = stats(), Render._render_n or 0
    vim.wait(1000, function() return false end, 10)
    local s1 = stats()
    return { renders = (Render._render_n or 0) - r0, submits = s1.submits - s0.submits,
             transmits = s1.transmits - s0.transmits, writes = #writes() }
  end
  local function quiet(t) return t.renders == 0 and t.submits == 0 and t.transmits == 0 and t.writes == 0 end

  local buf, nb, win = open(write_nb("ids_distinct", twenty(function(i) return "d" .. i end)))
  chk("L0 control: 20 cells with distinct ids settle", nb ~= nil and settle(nb, win, 20000), vim.inspect(st()))
  local n, all = own_images(buf, nb)
  chk(("L0 control: 20 images of their own (%d)"):format(n), n == 20 and all)
  local t = idle()
  chk("L0 control: idle for a second, nothing renders", quiet(t), vim.inspect(t))
  close(buf)

  buf, nb, win = open(write_nb("ids_same", twenty(function() return "same-id" end)))
  chk("L1 20 cells with one id open", nb ~= nil and #nb.cells == 20, nb and #nb.cells)
  if not nb then return end
  chk("L1 they settle within 10 s", settle(nb, win, 10000), vim.inspect(st()))
  n, all = own_images(buf, nb)
  chk(("L2 every block is an image of its own: 20 images, 20 groups (%d, %d slots)"):format(n, math_slots(buf)),
    n == 20 and all and math_slots(buf) == 20)
  t = idle()
  chk("L3 left idle for a second: no render, no job, no transmit, nothing written", quiet(t), vim.inspect(t))
  close(buf)
end)

-- ── M. chemistry ─────────────────────────────────────────────────────────
-- \ce and \pu (mhchem) are turned off: a formula that uses them fails to
-- parse and stays text, whether it uses them directly, through a macro
-- from an earlier cell or through an alias made with \let.
run("M. chemistry stays text", function()
  vim.cmd("silent! only")
  for _, tex in ipairs({ "\\ce{H2O}", "\\pu{123 kJ}" }) do
    local okc, msg = N.call(N.KIND.MATH, request(tex))
    chk(("M1 %s through the library: math: parse: ..."):format(tex),
      not okc and type(msg) == "string" and msg:find("math: parse: ", 1, true) == 1, tostring(msg):sub(1, 200))
  end
  local f0 = stats().fails
  local buf, nb, win = open(write_nb("chemistry", {
    md("m1", "$$\\ce{H2O}$$"),
    md("m2", "$$\\pu{123 kJ/mol}$$"),
    md("m3", "Water: $\\def\\water{\\ce{H_2O}}$ and $\\let\\chem\\ce$"),
    md("m4", "$$\\water + x$$"),
    md("m5", "$$\\chem{CO2}$$"),
    md("m6", "$$x^2 + 1$$"),
  }))
  chk("M2 the notebook settles", nb ~= nil and settle(nb, win, 20000), vim.inspect(st()))
  if not nb then return end
  for _, c in ipairs({ { "m1", "\\ce" }, { "m2", "\\pu" }, { "m4", "a macro holding \\ce" },
                       { "m5", "an alias of \\ce made with \\let" } }) do
    chk(("M2 %s stays text"):format(c[2]), text_only(view(buf, nb, c[1])) and placement(buf, c[1]) == nil)
  end
  chk("M2 and each counts as a failure", stats().fails - f0 >= 4, stats().fails - f0)
  local v6, a6, b6 = view(buf, nb, "m6")
  chk("M3 a formula next to them without chemistry is an image", placed(v6, a6, b6, placement(buf, "m6")))
  close(buf)
end)

-- ── N. a notebook of hundreds of formulas ────────────────────────────────
-- It fills in by itself, and the renders the module asks for while its
-- jobs come in are spaced: each starts at least three times the length of
-- the render before it after that one began (30 ms at least, a second at
-- most), so the main loop is free between them however long a render of
-- the notebook takes. The notebook opens with math as text and settles
-- first, so that every render after the switch to images is one the
-- module asked for.
run("N. a notebook of hundreds of formulas", function()
  vim.cmd("silent! only")
  local NBL = 700
  local cells = {}
  for i = 1, NBL do cells[i] = md("n" .. i, ("$$y_{%d} + \\frac{%d}{k}$$"):format(i, i)) end
  vim.cmd("JupynvimMathMode text")
  local buf, nb, win = open(write_nb("many", cells))
  chk("N0 the notebook opens", nb ~= nil and #nb.cells == NBL)
  if not nb then return end
  vim.wait(1500, function() return false end, 10)
  local log = {}
  local rb, rf, t_b = MI.begin, MI.finish, nil
  MI.begin = function(...) t_b = vim.uv.hrtime() / 1e6; return rb(...) end
  MI.finish = function(rctx, ...)
    local r = rf(rctx, ...)
    if t_b and rctx and rctx.buf == buf then log[#log + 1] = { t = t_b, d = vim.uv.hrtime() / 1e6 - t_b } end
    t_b = nil
    return r
  end
  local ok, err = pcall(function()
    local function images()
      local n = 0
      for i = 1, NBL do if placement(buf, "n" .. i) then n = n + 1 end end
      return n
    end
    vim.cmd("JupynvimMathMode auto")                   -- one render of the notebook, then it is on its own
    local t0 = vim.uv.hrtime()
    local done_ = vim.wait(30000, function() return images() == NBL and pending() == 0 end, 10)
    local secs = (vim.uv.hrtime() - t0) / 1e9
    chk(("N1 every formula is an image, with no render asked from outside (%d renders, %.2f s)"):format(#log, secs),
      done_ and images() == NBL, ("%d of %d"):format(images(), NBL))
    chk(("N2 the jobs, at most 256 at once, take a few renders, not one per formula (%d)"):format(#log),
      #log >= 3 and #log <= 12)
    local worst, close_ = math.huge, nil
    for i = 2, #log do
      local want = math.min(1000, math.max(30, 3 * log[i - 1].d))
      local got = log[i].t - log[i - 1].t
      if got - want < worst then worst, close_ = got - want, ("render %d: %.1f ms after one of %.1f ms"):format(i, got, log[i - 1].d) end
    end
    chk("N3 each render the module asked for began at least 3 x the one before after it (30 ms to 1 s)",
      #log >= 2 and worst >= -3, close_)
    vim.wait(300, function() return false end, 10)
    local n0 = #log
    reset_ui()
    vim.wait(1000, function() return false end, 10)
    chk("N4 then, left idle for a second: no render, nothing written", #log == n0 and #writes() == 0,
      ("%d renders, %d writes"):format(#log - n0, #writes()))
  end)
  MI.begin, MI.finish = rb, rf
  chk("N ran to its end", ok, err)
  close(buf)
end)

section("the whole run")
local loud = {}
for _, x in ipairs(notes) do if x.level == vim.log.levels.ERROR then loud[#loud + 1] = x.msg end end
chk("no error notice in the whole run", #loud == 0, vim.inspect(loud))

finish()
