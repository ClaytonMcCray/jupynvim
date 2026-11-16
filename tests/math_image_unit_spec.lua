-- Display-math images, the Lua side, without the library.
--
-- I  image.lua: a per-image grid, an exact content identity, placeholder
--    rows built once per placement (and their highlight group set again
--    after a colorscheme), ids that never reuse a live image's id.
-- M  mathimage.lua driven directly on a scratch notebook, with a stand-in
--    for native.lua (M._native) whose jobs the spec completes by hand with
--    answers in the library's grammar: one job per formula, cache hits that
--    write nothing, widths, failures, the macro prelude, the colour and the
--    cell size in the variant, slots and their images, back-pressure, the
--    paths where images are off, what the source may call, and the cost of
--    a cache hit. Then the bounds a hostile notebook meets: cells that share
--    an id, the bytes of one answer, of the cache and of one render, what a
--    wiped notebook leaves, a full set of job slots with no timer, jobs past
--    10 s (cancelled, their slot given back, their answer still taken),
--    what reaches the log, the prelude's size, a library that arrives
--    later, a bare :hi clear, a cache over its record count, a notebook
--    whose formulas all fail going idle, the renders the module asks for
--    (spaced by what a render costs, and coalesced), a new ink waking the
--    notebooks that waited on dropped jobs, the byte budget counted by the
--    results windows show, a buffer wiped without autocommands, macros
--    past the 64th defining cell, and a width that is not a number.
-- C  setup(): every bad value falls back to its default with one warning.
--
-- The terminal UI is simulated as in stream_writer_spec.lua: nvim_list_uis
-- reports a terminal UI and nvim_ui_send records every write in ui_out.

package.path = "./lua/?.lua;./lua/?/init.lua;./tests/?.lua;" .. package.path

local fails = 0
local function chk(name, cond, detail)
  if cond then io.write("  ok " .. name .. "\n")
  else io.write("FAIL " .. name .. (detail and ("  -- " .. detail) or "") .. "\n"); fails = fails + 1 end
end
-- a section that throws counts as one failure; the rest still run
local function section(title, fn)
  io.write(title .. "\n")
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then chk(title .. " ran to the end", false, tostring(err)) end
end

vim.env.TERM = "xterm-kitty"
vim.env.TMUX, vim.env.JUPYNVIM_DISABLE_TMUX_PASSTHROUGH = nil, nil

-- ── the simulated UI, before image.lua loads (it asks for the UIs then) ──
local ui_out = {}
vim.api.nvim_ui_send = function(s) ui_out[#ui_out + 1] = s end
vim.api.nvim_list_uis = function() return { { chan = 1, stdout_tty = true, width = 80, height = 24 } } end
local function reset_out() ui_out = {} end
local function count_out(needle)
  local n = 0
  for _, s in ipairs(ui_out) do
    local pos = 1
    while true do
      local a = s:find(needle, pos, true)
      if not a then break end
      n = n + 1
      pos = a + 1
    end
  end
  return n
end
local function n_tx() return count_out("\27_Ga=t,") end
local function deleted(id) return count_out(("\27_Ga=d,d=I,i=%d,q=2\27\\"):format(id)) > 0 end

local notes = {}
vim.notify = function(m, lvl) notes[#notes + 1] = { msg = tostring(m), lvl = lvl } end
local function math_notes()
  local t = {}
  for _, n in ipairs(notes) do
    if n.msg:find("jupynvim: math:", 1, true) == 1 then t[#t + 1] = n end
  end
  return t
end

local Image = require("jupynvim.notebook.image")
local J = require("jupynvim")
J.config.image_renderer = "placeholder"
local Render = require("jupynvim.notebook.render")
-- every refresh the module asks for, in all and per buffer
local refreshed, refreshed_buf = 0, {}
Render.refresh = function(nb)
  refreshed = refreshed + 1
  local b = type(nb) == "table" and nb.buf
  if b then refreshed_buf[b] = (refreshed_buf[b] or 0) + 1 end
end
local function refreshes_of(buf) return refreshed_buf[buf] or 0 end
local MI = require("jupynvim.notebook.mathimage")
local Log = require("jupynvim.log")

local PNG = vim.base64.encode(require("png_fixture")(28, 30, 1))
local PNG2 = vim.base64.encode(require("png_fixture")(28, 30, 2))

local function hl_fg(name)
  local h = vim.api.nvim_get_hl(0, { name = name, link = false })
  return h.fg and ("#%06x"):format(h.fg) or nil
end

-- ── I. image.lua ────────────────────────────────────────────────────────
section("I. image.lua", function()
  Image.clear_all()
  reset_out()
  local id1
  Image.ensure_transmitted("i_grid", PNG, function(id) id1 = id end,
    { renderer = "placeholder", rows = 3, cols = 27, content_id = "c1" })
  local want = ("\27_Ga=p,U=1,i=%d,p=1,c=27,r=3,q=2\27\\"):format(id1 or -1)
  chk("I1 a transmit with rows = 3, cols = 27 ends in a=p,U=1,i=<id>,p=1,c=27,r=3",
    id1 and ui_out[1] and ui_out[1]:find("\27_Ga=t,f=100,i=" .. id1 .. ",", 1, true) == 1
      and ui_out[1]:sub(-#want) == want,
    ui_out[1] and vim.inspect(ui_out[1]:sub(-40)))
  chk("I2 its placement asks for the same grid",
    ui_out[2] == ("\27_Ga=d,d=i,i=%d,q=2\27\\"):format(id1 or -1) .. want)
  local p1 = Image._placements.i_grid
  chk("I3 the placement keeps rows 3 and cols 27", p1 and p1.rows == 3 and p1.cols == 27)

  reset_out()
  local id0
  Image.ensure_transmitted("i_default", PNG, function(id) id0 = id end, { renderer = "placeholder" })
  local want0 = ("\27_Ga=p,U=1,i=%d,p=1,c=48,r=16,q=2\27\\"):format(id0 or -1)
  chk("I4 without rows and cols the grid is c=48,r=16, today's bytes",
    id0 and ui_out[1] and ui_out[1]:sub(-#want0) == want0
      and ui_out[2] == ("\27_Ga=d,d=i,i=%d,q=2\27\\"):format(id0) .. want0)

  reset_out()
  local id2
  Image.ensure_transmitted("i_grid", PNG, function(id) id2 = id end,
    { renderer = "placeholder", rows = 3, cols = 27, content_id = "c2" })
  chk("I5 another content_id with the same base64 is a second transmit",
    id2 and id2 ~= id1 and n_tx() == 1, ("%s writes, ids %s %s"):format(#ui_out, tostring(id1), tostring(id2)))
  chk("I6 ...and the first image is deleted (a=d,d=I,i=<old>)", id1 and deleted(id1))

  reset_out()
  local id3
  Image.ensure_transmitted("i_grid", PNG, function(id) id3 = id end,
    { renderer = "placeholder", rows = 3, cols = 27, content_id = "c2" })
  chk("I7 the same content_id again writes nothing and answers the id", #ui_out == 0 and id3 == id2,
    #ui_out .. " writes")

  chk("I8 is_cached with a content id",
    Image.is_cached("i_grid", PNG, "placeholder", "c2") == true
      and Image.is_cached("i_grid", PNG, "placeholder", "c1") == false
      and Image.is_cached("i_grid", PNG, "placeholder") == false
      and Image.is_cached("i_default", PNG, "placeholder") == true
      and Image.is_cached("i_grid", PNG, "chafa", "c2") == false)

  local ph = Image.placeholder_rows("i_grid", "c2")
  local widths_ok = ph and #ph.rows == 3 and ph.n == 3 and ph.cols == 27
  if widths_ok then
    for r = 1, 3 do
      if vim.fn.strdisplaywidth(ph.rows[r]) ~= 27 then widths_ok = false end
    end
  end
  chk("I9 placeholder_rows: n strings, each of strdisplaywidth == cols", widths_ok,
    ph and ("%d rows, width %d"):format(#ph.rows, vim.fn.strdisplaywidth(ph.rows[1] or "")) or "nil")
  local row2_ok = ph and ph.rows[2]:sub(1, 4) == "\244\142\187\174" and ph.rows[2] ~= ph.rows[1]
  chk("I10 each row starts with U+10EEEE and rows differ by their diacritic", row2_ok)
  chk("I11 placeholder_rows is nil for another content id", Image.placeholder_rows("i_grid", "c1") == nil)
  chk("I12 placeholder_rows without a content id gives the key's rows",
    Image.placeholder_rows("i_grid") == ph and Image.placeholder_rows("nope") == nil)
  chk("I13 the same table on a second call", rawequal(Image.placeholder_rows("i_grid", "c2"), ph))
  local colour = ("#%06x"):format(id2 or 0)
  chk("I14 the highlight group carries the id as its foreground",
    ph and ph.hl == "JupynvimPH_" .. id2 and hl_fg(ph.hl) == colour, ph and hl_fg(ph.hl))
  vim.api.nvim_set_hl(0, ph.hl, {})
  Image.placeholder_rows("i_grid", "c2")
  local stayed_clear = hl_fg(ph.hl) == nil
  vim.api.nvim_exec_autocmds("ColorScheme", { group = "jupynvim_image_ui" })
  Image.placeholder_rows("i_grid", "c2")
  chk("I15 the group is set once, and again after a ColorScheme event",
    stayed_clear and hl_fg(ph.hl) == colour, tostring(hl_fg(ph.hl)))

  reset_out()
  local id4
  Image.ensure_transmitted("i_big", PNG, function(id) id4 = id end,
    { renderer = "placeholder", rows = 300, cols = 0, content_id = "big" })
  local p4 = Image._placements.i_big
  chk("I16 300 rows clamp to 297, 0 cols to 1",
    p4 and p4.rows == 297 and p4.cols == 1
      and ui_out[1]:sub(-40):find(("i=%d,p=1,c=1,r=297,q=2"):format(id4 or -1), 1, true) ~= nil)
  local ph4 = Image.placeholder_rows("i_big", "big")
  chk("I17 ...and its placeholder rows number 297", ph4 and #ph4.rows == 297)

  -- ids: a cycle of 2^3 = 8 instead of 24^3
  Image.clear_all()
  Image._id_spread = 2
  local ids, live = {}, {}
  for k = 1, 8 do
    Image.ensure_transmitted("id" .. k, PNG, function(id) ids[k] = id end,
      { renderer = "placeholder", rows = 1, cols = 1, content_id = "x" .. k })
    if ids[k] then live[ids[k]] = k end
  end
  local distinct = 0
  for _ in pairs(live) do distinct = distinct + 1 end
  chk("I18 a full (shrunk) cycle gives 8 distinct ids", distinct == 8, distinct .. " distinct")
  -- free the fourth: the next allocation starts the cycle again at the first
  -- id, which is live, and must go past three live ids to the free one
  local freed = ids[4]
  Image.clear_for_cell("id4")
  local idn
  Image.ensure_transmitted("idn", PNG, function(id) idn = id end,
    { renderer = "placeholder", rows = 1, cols = 1, content_id = "xn" })
  local clash = false
  for k, id in pairs(ids) do if k ~= 4 and id == idn then clash = true end end
  chk("I19 with the rest of the cycle live, a new id equals none of them (it takes the freed one)",
    idn ~= nil and not clash and idn == freed, ("new %s, freed %s"):format(tostring(idn), tostring(freed)))
  local idx
  Image.ensure_transmitted("idx", PNG, function(id) idx = id end,
    { renderer = "placeholder", rows = 1, cols = 1, content_id = "xx" })
  chk("I20 with every id of the cycle live, an allocation still ends (one cycle of tries)", idx ~= nil)
  Image._id_spread = 24
  Image.clear_all()
end)

-- ── the stand-in for native.lua ─────────────────────────────────────────
local CELL_14x30 = "JNC 1\ncols 100\nrows 50\nxpixel 1400\nypixel 1500\nsource fd2\n"
local function new_fake(o)
  o = o or {}
  local F = {
    KIND = o.KIND or { MATH = 2304, MATH_CELL = 2305 },
    STATUS = { CANCELLED = 3 },
    jobs = {}, cancelled = {}, calls = 0, next_id = 0, asked = 0,
    cell_answer = o.cell_answer == nil and CELL_14x30 or o.cell_answer,
    supported = o.supported or 1,
    ready = o.ready == nil and true or o.ready,   -- true, false, or "never" (still loading)
  }
  function F.status() return { state = F.ready == true and "ok" or "unloaded" } end
  function F.when_ready(cb)
    F.asked = F.asked + 1
    if F.ready == "never" then F.waiting = cb; return end
    vim.schedule(function() cb(F.ready == true, F.status()) end)
  end
  function F.lib() return { jnv_kind_supported = function() return F.supported end } end
  function F.submit(kind, data, opts, cb)
    F.next_id = F.next_id + 1
    local j = { id = F.next_id, kind = kind, data = data, opts = opts, cb = cb }
    F.jobs[#F.jobs + 1] = j
    return j.id
  end
  function F.cancel(id) F.cancelled[#F.cancelled + 1] = id; return true end
  function F.call(kind)
    F.calls = F.calls + 1
    if kind == F.KIND.MATH_CELL and F.cell_answer then return true, F.cell_answer, 0 end
    return false, "math cell: no terminal", 1
  end
  return F
end

-- a field of a request (the spec's own data)
local function req_field(data, key) return data:match("\n" .. key .. " ([^\n]*)\n") end
-- the library's answer for job j: a cols x rows grid of the request's cell size
local function answer(j, cols, rows, shrunk, o)
  o = o or {}
  local b64 = o.b64 or PNG
  local cw, ch = req_field(j.data, "cell"):match("^(%d+) (%d+)$")
  cw, ch = tonumber(cw), tonumber(ch)
  local out = ("JNM 1\nsize %d %d\ngrid %d %d\nbase %d\nem 30.000\nshrunk %d\npng %d\n\n"):format(
    o.w or cols * cw, o.h or rows * ch, cols, rows, ch - 4, shrunk and 1 or 0, o.n or #b64) .. b64
  j.cb(true, out)
end
local function fail(j, msg, status) j.cb(false, msg, status or 1) end

local function slot(buf, id, n) return ("%d\31%s\31math%d"):format(buf, id, n) end

local fake
local REAL_NOW = MI._now
local REAL_DEFER = MI._defer
local count_refresh = Render.refresh
-- a clean module with this stand-in and config, the library not asked yet
local function fresh(f, cfg)
  Render.refresh = count_refresh
  MI._now = REAL_NOW
  MI._defer = REAL_DEFER
  for buf in pairs(MI._S.bufs) do MI.forget_buffer(buf) end
  MI.reset()
  MI._native = f
  fake = f
  MI._S.lib = "unasked"
  MI._S.cell = nil
  MI.setup(cfg or { renderer = "auto" })
  Image.clear_all()
  reset_out()
end

local function new_nb(cells)
  return { buf = vim.api.nvim_create_buf(false, true), cells = cells }
end
local function md(id, blocks, source)
  return { id = id, cell_type = "markdown", blocks = blocks or {}, source = source or "" }
end

-- one render as render.lua makes it: begin, then cell / math_block per
-- block / cell_done for each markdown cell not being edited, then finish
local rendered = 0
local function render(nb, o)
  o = o or {}
  rendered = rendered + 1
  local rctx = MI.begin(nb, o.win, o.edit)
  if not rctx then return nil end
  local out = {}
  for i, cell in ipairs(nb.cells) do
    if cell.cell_type == "markdown" and i ~= o.edit then
      local cctx = MI.cell(rctx, cell, i)
      out[i] = {}
      for k, tex in ipairs(cell.blocks) do
        out[i][k] = cctx.math_block(tex, { first = i * 100 + k * 3, last = i * 100 + k * 3 + 2,
                                           indent = o.indent or 0, width = o.width or 80 })
      end
      MI.cell_done(cctx)
    end
  end
  MI.finish(rctx)
  return out, rctx
end

-- the first render asks for the library; its answer comes on the main loop
local function activate(nb)
  local r = MI.begin(nb)
  vim.wait(1000, function() return MI._S.lib ~= "wait" end, 5)
  return r
end

-- Render.refresh as render.lua has it, for one notebook: a render on the
-- main loop, at most one waiting (every call is counted as before)
local function live(nb)
  local waiting = false
  Render.refresh = function(x)
    count_refresh(x)
    if x == nb and not waiting then
      waiting = true
      vim.schedule(function() waiting = false; render(nb) end)
    end
  end
end

local function wait_ms(ms) vim.wait(ms, function() return false end, 5) end
local function was_cancelled(id)
  for _, c in ipairs(fake.cancelled) do if c == id then return true end end
  return false
end
-- base64 of a given length (the stand-in's answers carry it as the image)
local function blob(n) return ("A"):rep(n) end
-- render until a render transmits, submits and holds back nothing; how many
-- renders that took, or nil
local function settle(nb, max)
  for k = 1, max or 10 do
    local t0, s0, d0 = MI.stats.transmits, MI.stats.submits, MI.stats.deferred
    render(nb)
    if MI.stats.transmits == t0 and MI.stats.submits == s0 and MI.stats.deferred == d0 then return k end
  end
  return nil
end

vim.api.nvim_set_hl(0, "JupynvimMathImage", { fg = "#c0caf5" })

-- ── M. mathimage.lua ────────────────────────────────────────────────────
section("M1. one formula: one job, then cache hits", function()
  fresh(new_fake())
  local nb = new_nb({ md("m1", { "x^2" }, "$$x^2$$") })
  local r0 = activate(nb)
  chk("M1.1 the first render asks for the library and shows text", r0 == nil and MI._S.lib == "ok")
  chk("M1.2 the library's answer measured the cell size (14x30 from the terminal)",
    MI._S.cell and MI._S.cell.w == 14 and MI._S.cell.h == 30 and MI._S.cell.source == "terminal")
  local out = render(nb)
  chk("M1.3 the first math_block returns nil", out and out[1][1] == nil)
  local want = "JNM 1\nfg #c0caf5\ncell 14 30\nscale 1\nmax 80 60\npre 0\ntex 3\n\nx^2"
  chk("M1.4 one request, its bytes the request grammar for this colour, cell, scale and width",
    #fake.jobs == 1 and fake.jobs[1].data == want and fake.jobs[1].kind == 2304,
    fake.jobs[1] and vim.inspect(fake.jobs[1].data))
  render(nb)
  chk("M1.5 a second render submits nothing", #fake.jobs == 1)
  local r1 = refreshed
  answer(fake.jobs[1], 3, 1, false)
  vim.wait(1000, function() return refreshed > r1 end, 5)
  chk("M1.6 the completion refreshes the notebook that waited", refreshed == r1 + 1)
  reset_out()
  out = render(nb)
  local img = out and out[1][1]
  local key = slot(nb.buf, "m1", 1)
  local p = Image._placements[key]
  chk("M1.7 after the completion math_block returns { rows, cols, hl, text }",
    img and img.rows == 1 and img.cols == 3 and type(img.hl) == "string" and #img.text == 1
      and vim.fn.strdisplaywidth(img.text[1]) == 3)
  chk("M1.8 one transmit went out with that grid",
    n_tx() == 1 and p and count_out(("a=p,U=1,i=%d,p=1,c=3,r=1,q=2"):format(p.image_id)) >= 1)
  reset_out()
  local s0 = MI.stats.submits
  for _ = 1, 5 do render(nb) end
  chk("M1.9 five more renders write nothing and submit nothing",
    #ui_out == 0 and #fake.jobs == 1 and MI.stats.submits == s0, #ui_out .. " writes")
  local st = MI.status()
  chk("M1.10 status: active, the library ok, one record, one slot, nothing pending",
    st.active == true and st.lib == "ok" and st.records == 1 and st.slots == 1 and st.pending == 0
      and st.renderer == "auto" and st.cell.w == 14 and st.fg == "#c0caf5")
  local cctx = MI.cell(select(2, render(nb)) or MI.begin(nb), nb.cells[1], 1)
  chk("M1.11 the cell ctx carries align and overlay (true by default)",
    cctx.align == "left" and cctx.overlay == true)
  MI._overlay = false
  cctx = MI.cell(MI.begin(nb), nb.cells[1], 1)
  chk("M1.12 M._overlay = false reaches the ctx", cctx.overlay == false)
  MI._overlay = true
end)

section("M2. widths", function()
  fresh(new_fake())
  local nb = new_nb({ md("w1", { "\\sum_k a_k" }) })
  activate(nb)
  render(nb, { width = 80 })
  answer(fake.jobs[1], 27, 2, false)
  local o40 = render(nb, { width = 40 })
  local o100 = render(nb, { width = 100 })
  chk("M2.1 an unshrunk result serves a narrower width that fits and a wider one, no new job",
    o40[1][1] and o40[1][1].cols == 27 and o100[1][1] and o100[1][1].cols == 27 and #fake.jobs == 1)
  local o20 = render(nb, { width = 20 })
  chk("M2.2 a too narrow width submits one job with max <avail>",
    o20[1][1] == nil and #fake.jobs == 2 and req_field(fake.jobs[2].data, "max") == "20 60")
  render(nb, { width = 20 })
  chk("M2.3 ...once", #fake.jobs == 2)
  answer(fake.jobs[2], 20, 2, true)
  o20 = render(nb, { width = 20 })
  chk("M2.4 a shrunk answer is used at its width", o20[1][1] and o20[1][1].cols == 20)
  local o21 = render(nb, { width = 21 })
  chk("M2.5 ...and only there: another narrow width is a new job",
    o21[1][1] == nil and #fake.jobs == 3 and req_field(fake.jobs[3].data, "max") == "21 60")
  local oi = render(nb, { width = 50, indent = 4 })
  chk("M2.6 the indent is taken off the width", oi[1][1] and oi[1][1].cols == 27 and #fake.jobs == 3)
  local o400 = render(nb, { width = 400 })
  chk("M2.7 the natural result at a very wide window", o400[1][1] and #fake.jobs == 3)
  nb.cells[1].blocks = { "\\sum_k a_k", "\\int f" }
  render(nb, { width = 400 })
  chk("M2.8 a new formula in a window wider than 297 columns asks for at most 297",
    #fake.jobs == 4 and req_field(fake.jobs[4].data, "max") == "297 60")
end)

section("M3. failures", function()
  fresh(new_fake())
  local nb = new_nb({ md("f1", { "a" }) })
  activate(nb)
  render(nb)
  answer(fake.jobs[1], 1, 1, false)
  render(nb)
  local key = slot(nb.buf, "f1", 1)
  local old = Image._placements[key] and Image._placements[key].image_id
  nb.cells[1].blocks = { "\\foo" }
  reset_out()
  local o = render(nb)
  chk("M3.1 a changed block shows text while it is typeset, and its old image stays",
    o[1][1] == nil and #fake.jobs == 2 and Image._placements[key] ~= nil and #ui_out == 0)
  fail(fake.jobs[2], "math: parse: Undefined control sequence: \\foo")
  reset_out()
  o = render(nb)
  chk("M3.2 a parse failure: nil, and the slot's old image is deleted",
    o[1][1] == nil and old and deleted(old) and Image._placements[key] == nil)
  for _ = 1, 3 do o = render(nb) end
  chk("M3.3 ...nil for ever, with no second job", o[1][1] == nil and #fake.jobs == 2)

  nb.cells[1].blocks = { "\\rule{100em}{1em}" }
  render(nb)
  fail(fake.jobs[3], "math: size: too wide: 241 columns, 80 allowed")
  o = render(nb)
  render(nb)
  chk("M3.4 a size failure: nil at that width, no new job there", o[1][1] == nil and #fake.jobs == 3)
  o = render(nb, { width = 70 })
  chk("M3.5 ...a job again at another width",
    o[1][1] == nil and #fake.jobs == 4 and req_field(fake.jobs[4].data, "max") == "70 60")

  nb.cells[1].blocks = { "y" }
  render(nb)
  local c0 = MI.stats.cancels
  fail(fake.jobs[5], "CANCELLED", 3)
  render(nb)
  chk("M3.6 a cancelled job: a job again next render", #fake.jobs == 6 and MI.stats.cancels == c0 + 1)

  -- answers that do not agree with what was asked are never drawn
  local bad = {
    { "grid wider than the max asked", function(j) answer(j, 81, 1, false) end },
    { "more rows than 60", function(j) answer(j, 2, 61, false) end },
    { "size is not grid times cell", function(j) answer(j, 2, 1, false, { w = 999 }) end },
    { "png length differs", function(j) answer(j, 2, 1, false, { n = 5 }) end },
    { "body not base64", function(j) answer(j, 2, 1, false, { b64 = "\27[2J" }) end },
    { "no head end", function(j) j.cb(true, "JNM 1\nsize 1 1") end },
    { "another magic", function(j) j.cb(true, "JNX 1\n\nAAAA") end },
  }
  for i, b in ipairs(bad) do
    nb.cells[1].blocks = { "bad" .. i }
    render(nb)
    local j = fake.jobs[#fake.jobs]
    local f0 = MI.stats.fails
    b[2](j)
    local n0 = #fake.jobs
    o = render(nb)
    render(nb)
    chk("M3.7 an answer whose " .. b[1] .. " is an error: text, no new job",
      o[1][1] == nil and #fake.jobs == n0 and MI.stats.fails == f0 + 1)
  end
end)

section("M4. the macro prelude", function()
  fresh(new_fake())
  local defs = "Let\n$$\\newcommand{\\R}{\\mathbb{R}}$$"
  local below = "\\def\\Q{\\mathbb{Q}}"
  local nb = new_nb({
    md("p1", { "a+b" }, "$$a+b$$"),
    md("p2", {}, defs),
    md("p3", { "\\R^2" }, "$$\\R^2$$"),
    md("p4", {}, below),
  })
  activate(nb)
  render(nb)
  local j1, j3
  for _, j in ipairs(fake.jobs) do
    if j.data:sub(-3) == "a+b" then j1 = j else j3 = j end
  end
  chk("M4.1 a formula above every definition has pre 0", j1 and req_field(j1.data, "pre") == "0")
  chk("M4.2 a cell with \\newcommand above makes pre its length and the bytes that cell's source",
    j3 and req_field(j3.data, "pre") == tostring(#defs)
      and j3.data:sub(-(#defs + 4)) == defs .. "\\R^2",
    j3 and vim.inspect(j3.data))
  chk("M4.3 a defining cell below is not in the prelude", j3 and not j3.data:find(below, 1, true))
  answer(j1, 3, 1, false)
  answer(j3, 3, 1, false)
  render(nb)
  local n0 = #fake.jobs
  nb.cells[2].source = defs:gsub("mathbb", "mathbf")
  render(nb)
  chk("M4.4 changing the defining cell re-submits the formulas below it only",
    #fake.jobs == n0 + 1 and fake.jobs[#fake.jobs].data:sub(-4) == "\\R^2")
  answer(fake.jobs[#fake.jobs], 3, 1, false)
  render(nb, { edit = 2 })
  local n1 = #fake.jobs
  nb.cells[2].source = defs .. "\n\\def\\C{\\mathbb{C}}"
  render(nb, { edit = 2 })
  render(nb, { edit = 2 })
  chk("M4.5 while that cell is edited nothing is re-submitted", #fake.jobs == n1)
  render(nb)
  chk("M4.6 leaving the editor picks the new source up, once", #fake.jobs == n1 + 1)
  render(nb)
  chk("M4.7 ...and only once", #fake.jobs == n1 + 1)
  nb.cells[2].source = "plain text now"
  render(nb)
  local last = fake.jobs[#fake.jobs]
  chk("M4.8 a cell that stops defining leaves the prelude", #fake.jobs == n1 + 2
    and req_field(last.data, "pre") == "0")
end)

section("M5. colour and cell size", function()
  fresh(new_fake())
  local nb = new_nb({ md("c1", { "z" }) })
  activate(nb)
  render(nb)
  local pending = fake.jobs[1].id
  vim.cmd("hi JupynvimMathImage guifg=#ff0000")
  render(nb)
  local cancelled = false
  for _, id in ipairs(fake.cancelled) do if id == pending then cancelled = true end end
  chk("M5.1 a new foreground cancels the pending jobs", cancelled)
  chk("M5.2 ...and the next math_block submits with fg #ff0000",
    #fake.jobs == 2 and req_field(fake.jobs[2].data, "fg") == "#ff0000")
  fake.jobs[1].cb(false, "CANCELLED", 3)
  chk("M5.3 the dropped job's answer is ignored", MI.status().pending == 1)
  vim.cmd("hi JupynvimMathImage guifg=#c0caf5")

  fresh(new_fake({ cell_answer = false }))
  activate(nb)
  render(nb)
  chk("M5.4 M._nominal when MATH_CELL fails",
    fake.jobs[1] and req_field(fake.jobs[1].data, "cell") == "18 40" and MI.status().cell.source == "nominal")

  fresh(new_fake(), { renderer = "auto", cell_px = { w = 10, h = 20 } })
  activate(nb)
  render(nb)
  chk("M5.5 cfg.cell_px wins over the terminal",
    fake.jobs[1] and req_field(fake.jobs[1].data, "cell") == "10 20" and fake.calls == 0
      and MI.status().cell.source == "config")
  MI.setup({ renderer = "auto" })
  render(nb)
  chk("M5.6 without it the terminal is asked again",
    req_field(fake.jobs[#fake.jobs].data, "cell") == "14 30")
  local r0 = refreshed
  fake.cell_answer = "JNC 1\ncols 100\nrows 50\nxpixel 1600\nypixel 1500\nsource fd2\n"
  MI.refresh_cell_px()
  chk("M5.7 a new cell size refreshes the notebooks", refreshed > r0 and MI._S.cell.w == 16)
  r0 = refreshed
  MI.refresh_cell_px()
  chk("M5.8 the same size again refreshes nothing", refreshed == r0)
  local before = #fake.jobs
  render(nb)
  chk("M5.9 a new cell size changes the request's cell line",
    #fake.jobs == before + 1 and req_field(fake.jobs[#fake.jobs].data, "cell") == "16 30")
  fake.cell_answer = "JNC 1\ncols 1\nrows 1\nxpixel 9000\nypixel 1\nsource tty\n"
  MI.refresh_cell_px()
  chk("M5.10 a measured size is clamped to 4..256 and 4..512", MI._S.cell.w == 256 and MI._S.cell.h == 4)
  fake.cell_answer = "JNC 1\ncols 100\nrows 50\nxpixel 0\nypixel 0\nsource fd2\n"
  MI.refresh_cell_px()
  chk("M5.11 a terminal that reports no pixels gives the nominal size",
    MI._S.cell.w == 18 and MI._S.cell.h == 40 and MI._S.cell.source == "nominal")
  MI.setup({ renderer = "auto", scale = 1.5 })
  render(nb)
  chk("M5.12 the scale is in the request", req_field(fake.jobs[#fake.jobs].data, "scale") == "1.5")
end)

section("M6. slots", function()
  fresh(new_fake())
  local nb = new_nb({ md("s1", { "a", "b" }), md("s2", { "c" }) })
  activate(nb)
  render(nb)
  for _, j in ipairs(fake.jobs) do answer(j, 2, 1, false) end
  local o = render(nb)
  local k1, k2, k3 = slot(nb.buf, "s1", 1), slot(nb.buf, "s1", 2), slot(nb.buf, "s2", 1)
  local id2 = Image._placements[k2] and Image._placements[k2].image_id
  local id3 = Image._placements[k3] and Image._placements[k3].image_id
  chk("M6.1 three blocks, three images", o[1][1] and o[1][2] and o[2][1] and id2 and id3
    and MI.status().slots == 3)
  nb.cells[1].blocks = { "a" }
  reset_out()
  render(nb)
  chk("M6.2 fewer blocks free the upper slots",
    deleted(id2) and Image._placements[k2] == nil and Image._placements[k1] ~= nil
      and MI.status().slots == 2)
  reset_out()
  table.remove(nb.cells, 2)
  render(nb)
  chk("M6.3 a cell missing from nb.cells frees its slots at finish",
    deleted(id3) and Image._placements[k3] == nil and MI.status().slots == 1)
  nb.cells[2] = { id = "s9", cell_type = "code", source = "$$a$$", blocks = {} }
  nb.cells[1].cell_type = "code"
  render(nb)
  chk("M6.4 a cell that is no longer markdown frees its slots",
    Image._placements[k1] == nil and MI.status().slots == 0)
  nb.cells[1].cell_type = "markdown"
  render(nb)
  local id1 = Image._placements[k1] and Image._placements[k1].image_id
  chk("M6.5 back to markdown: a cache hit, no job", id1 and MI.status().pending == 0)
  reset_out()
  render(nb, { edit = 1 })
  chk("M6.6 a cell in the editor keeps its slot and image", Image._placements[k1] ~= nil and #ui_out == 0)
  Image.clear_all()
  reset_out()
  local n0 = #fake.jobs
  o = render(nb)
  chk("M6.7 after Image.clear_all() the next render transmits again and submits nothing",
    o[1][1] ~= nil and n_tx() == 1 and #fake.jobs == n0)
  reset_out()
  MI.forget_buffer(nb.buf)
  chk("M6.8 forget_buffer frees the buffer's slots and forgets it",
    Image._placements[k1] == nil and MI._S.bufs[nb.buf] == nil and n_tx() == 0
      and count_out("\27_Ga=d,d=I,") == 1)
  chk("M6.8b ...and with no notebook left the cache is empty",
    MI.status().records == 0 and MI.status().bytes == 0 and MI.status().pending == 0)
  render(nb)
  answer(fake.jobs[#fake.jobs], 2, 1, false)     -- "a" again: the cache went with the last notebook
  render(nb)
  nb.cells[1].blocks = { "a", "new" }
  render(nb)
  chk("M6.9 a pending job before reset", MI.status().pending == 1)
  local pend = fake.jobs[#fake.jobs].id
  reset_out()
  MI.reset()
  local was_cancelled = false
  for _, id in ipairs(fake.cancelled) do if id == pend then was_cancelled = true end end
  chk("M6.10 reset frees every slot, cancels every job, empties the cache",
    Image._placements[k1] == nil and was_cancelled and MI.status().records == 0
      and MI.status().pending == 0 and MI.status().slots == 0)
  local before = #fake.jobs
  fake.jobs[#fake.jobs].cb(false, "CANCELLED", 3)
  render(nb)
  chk("M6.11 after reset the next render asks again", #fake.jobs == before + 2)
end)

section("M7. back-pressure", function()
  fresh(new_fake())
  local blocks = {}
  for k = 1, 257 do blocks[k] = "x_{" .. k .. "}" end
  local nb = new_nb({ md("b1", blocks) })
  activate(nb)
  local s0 = MI.stats.submits
  render(nb)
  chk("M7.1 257 new blocks in one render: 256 submits", #fake.jobs == 256 and MI.stats.submits == s0 + 256,
    #fake.jobs)
  local has257 = false
  for _, j in ipairs(fake.jobs) do if j.data:sub(-7) == "x_{257}" then has257 = true end end
  chk("M7.2 ...and the 257th waits", not has257 and MI.status().pending == 256 and MI.status().inflight == 256)
  answer(fake.jobs[1], 2, 1, false)
  render(nb)
  chk("M7.3 a completion frees room: the 257th is asked for in the next render",
    #fake.jobs == 257 and fake.jobs[257].data:sub(-7) == "x_{257}")

  -- no count of transmits per render: only its bytes
  fresh(new_fake())
  blocks = {}
  for k = 1, 200 do blocks[k] = "y_{" .. k .. "}" end
  nb = new_nb({ md("t1", blocks) })
  activate(nb)
  render(nb)
  for _, j in ipairs(fake.jobs) do answer(j, 2, 1, false) end
  reset_out()
  local t0, d0 = MI.stats.transmits, MI.stats.deferred
  local o = render(nb)
  local shown = 0
  for k = 1, 200 do if o[1][k] then shown = shown + 1 end end
  chk("M7.4 200 small results ready: one render sends them all (no count per render, only the bytes)",
    n_tx() == 200 and MI.stats.transmits == t0 + 200 and shown == 200 and MI.stats.deferred == d0,
    ("%d transmits, %d shown, %d held back"):format(n_tx(), shown, MI.stats.deferred - d0))
  reset_out()
  render(nb)
  chk("M7.5 ...and the next render sends nothing", #ui_out == 0, #ui_out)
end)

section("M8. images off", function()
  local nb = new_nb({ md("o1", { "q" }) })
  -- slots first, so turning images off has something to free
  fresh(new_fake())
  activate(nb)
  render(nb)
  answer(fake.jobs[1], 2, 1, false)
  render(nb)
  local key = slot(nb.buf, "o1", 1)
  chk("M8.0 an image to start with", Image._placements[key] ~= nil)
  MI.setup({ renderer = "text" })
  local n0 = #fake.jobs
  chk("M8.1 renderer = \"text\": begin is nil, nothing submitted, the slots freed",
    MI.begin(nb) == nil and #fake.jobs == n0 and Image._placements[key] == nil
      and MI.status().why ~= nil and MI.status().active == false)
  MI.setup(false)
  chk("M8.2 math = false is renderer \"text\"", MI.status().renderer == "text" and MI.begin(nb) == nil)

  MI.setup({ renderer = "image" })
  J.config.image_renderer = "chafa"
  chk("M8.3 image_renderer = \"chafa\": begin is nil", MI.begin(nb) == nil and #fake.jobs == n0)
  J.config.image_renderer = "placeholder"

  local saved = { TERM = vim.env.TERM, TERM_PROGRAM = vim.env.TERM_PROGRAM,
                  GHOSTTY_RESOURCES_DIR = vim.env.GHOSTTY_RESOURCES_DIR,
                  KITTY_WINDOW_ID = vim.env.KITTY_WINDOW_ID }
  vim.env.TERM = "xterm"
  vim.env.TERM_PROGRAM, vim.env.GHOSTTY_RESOURCES_DIR, vim.env.KITTY_WINDOW_ID = nil, nil, nil
  MI.setup({ renderer = "auto" })
  chk("M8.4 TERM=xterm with auto: begin is nil", MI.begin(nb) == nil and #fake.jobs == n0)
  MI.setup({ renderer = "image" })
  chk("M8.5 ...\"image\" does not ask about the terminal", MI.begin(nb) ~= nil)
  for k, v in pairs(saved) do vim.env[k] = v end

  local real_send = vim.api.nvim_ui_send
  vim.api.nvim_ui_send = nil
  MI.setup({ renderer = "auto" })
  chk("M8.6 Neovim 0.11 (no nvim_ui_send) with auto: begin is nil", MI.begin(nb) == nil)
  vim.api.nvim_ui_send = real_send

  local function lib_case(name, f, want)
    fresh(f)
    local nb2 = new_nb({ md("k1", { "q" }) })
    activate(nb2)
    local r = render(nb2)
    chk(name, r == nil and #f.jobs == 0 and MI._S.lib == want, MI._S.lib)
  end
  lib_case("M8.7 the library reports the kind unsupported: nil, nothing submitted",
    new_fake({ supported = 0 }), "off")
  lib_case("M8.8 a native layer without KIND.MATH (ABI 1.1): nil, the library state off",
    new_fake({ KIND = { NOP = 1, ECHO = 2 } }), "off")
  lib_case("M8.9 no library at all: nil", new_fake({ ready = false }), "off")
  lib_case("M8.10 the library still loading: nil, nothing submitted", new_fake({ ready = "never" }), "wait")
  chk("M8.11 ...and MATH_CELL is never asked before it is loaded", fake.calls == 0)
  local f = fake
  f.ready = true
  f.waiting(true, f.status())
  local nb3 = new_nb({ md("k2", { "q" }) })
  render(nb3)
  chk("M8.12 once it is loaded images are on", MI._S.lib == "ok" and #f.jobs == 1)
end)

section("M9. the source", function()
  local fh = io.open("lua/jupynvim/notebook/mathimage.lua", "r")
  local src = fh and fh:read("*a") or ""
  if fh then fh:close() end
  local calls, pos = {}, 1
  while true do
    local a = src:find("N.call(", pos, true)
    if not a then break end
    calls[#calls + 1] = src:sub(a, a + 25)
    pos = a + 1
  end
  chk("M9.1 the only N.call( is the MATH_CELL one",
    #calls == 1 and calls[1]:find("N.call(N.KIND.MATH_CELL,", 1, true) == 1, vim.inspect(calls))
  local bare = 0
  pos = 1
  while true do
    local a = src:find("call(", pos, true)
    if not a then break end
    local before = src:sub(a - 1, a - 1)
    if before ~= "p" and src:sub(a - 2, a - 1) ~= "N." then bare = bare + 1 end
    pos = a + 1
  end
  chk("M9.2 no other call( in any form", bare == 0)
  chk("M9.3 no available(, .load( or has_abi(",
    not src:find("available(", 1, true) and not src:find(".load(", 1, true)
      and not src:find("has_abi(", 1, true))
  chk("M9.4 it never draws an extmark", not src:find("set_extmark", 1, true))
end)

section("M10. the cost of a cache hit", function()
  fresh(new_fake())
  local blocks = {}
  for k = 1, 20 do blocks[k] = "\\frac{" .. k .. "}{2}" end
  local nb = new_nb({ md("h1", blocks, "text") })
  activate(nb)
  render(nb)
  for _, j in ipairs(fake.jobs) do answer(j, 3, 2, false) end
  render(nb)
  render(nb)
  reset_out()
  local h0 = MI.stats.hits
  local best = math.huge
  for _ = 1, 3 do
    local t0 = vim.uv.hrtime()
    for _ = 1, 100 do render(nb) end
    best = math.min(best, (vim.uv.hrtime() - t0) / 1e6)
  end
  chk("M10.1 2,000 cache hits (20 blocks, 100 renders) take under 30 ms",
    best < 30 and MI.stats.hits - h0 == 6000 and #ui_out == 0 and #fake.jobs == 20,
    ("%.2f ms, %d hits, %d writes"):format(best, MI.stats.hits - h0, #ui_out))
end)

section("M11. the window: visibility and job priority", function()
  fresh(new_fake())
  -- blocks on lines 103..105 (cell 1) and 303..305 (cell 3) of a 400-line buffer
  local nb = new_nb({ md("v1", { "a" }), { id = "v2", cell_type = "code", source = "", blocks = {} },
                      md("v3", { "b" }) })
  local filler = {}
  for i = 1, 400 do filler[i] = "line " .. i end
  vim.api.nvim_buf_set_lines(nb.buf, 0, -1, false, filler)
  activate(nb)
  render(nb)
  for _, j in ipairs(fake.jobs) do answer(j, 2, 1, false) end
  render(nb)
  local k1, k3 = slot(nb.buf, "v1", 1), slot(nb.buf, "v3", 1)
  chk("M11.1 an image of a buffer no window shows is off screen",
    Image._placements[k1] ~= nil and Image._on_screen(k1) == false)
  local win = vim.api.nvim_get_current_win()
  local prev = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, nb.buf)
  vim.api.nvim_win_set_cursor(win, { 105, 0 })
  vim.cmd("normal! zz")
  chk("M11.2 ...on screen when a window shows its lines, off when they are far away",
    Image._on_screen(k1) == true and Image._on_screen(k3) == false)
  nb.cells[1].blocks = { "a", "c" }
  nb.cells[3].blocks = { "b", "d" }
  render(nb, { win = win })
  local prio = {}
  for _, j in ipairs(fake.jobs) do prio[j.data:sub(-1)] = j.opts and j.opts.priority end
  chk("M11.3 a job for a block near the window is \"visible\", one far below it \"normal\"",
    prio.c == "visible" and prio.d == "normal", vim.inspect(prio))
  vim.api.nvim_win_set_buf(win, prev)
end)

section("M12. cells that share an id", function()
  fresh(new_fake())
  local cells = {}
  for k = 1, 20 do cells[k] = md("same", { "x^{" .. k .. "}" }) end
  local nb = new_nb(cells)
  activate(nb)
  render(nb)
  chk("M12.1 twenty cells with one id: one job per block", #fake.jobs == 20, #fake.jobs)
  -- from here the module drives the renders itself, as in the editor
  live(nb)
  reset_out()
  local r0 = rendered
  for _, j in ipairs(fake.jobs) do answer(j, 3, 1, false) end
  vim.wait(1000, function() return n_tx() >= 20 end, 5)
  wait_ms(100)
  local ids, keys_ok = {}, true
  for k = 1, 20 do
    local p = Image._placements[slot(nb.buf, k == 1 and "same" or ("#" .. k), 1)]
    if p then ids[p.image_id] = true else keys_ok = false end
  end
  local distinct = 0
  for _ in pairs(ids) do distinct = distinct + 1 end
  chk("M12.2 the first cell keeps the id as its key, the others take #<index>: twenty slots, twenty images",
    keys_ok and distinct == 20, ("%d distinct"):format(distinct))
  chk("M12.3 they settle by themselves: twenty transmits in two renders",
    n_tx() == 20 and rendered - r0 <= 3, ("%d transmits, %d renders"):format(n_tx(), rendered - r0))
  local r1, f1 = rendered, refreshed
  reset_out()
  wait_ms(200)
  chk("M12.4 then an idle editor renders nothing and writes nothing",
    rendered == r1 and refreshed == f1 and #ui_out == 0,
    ("%d renders, %d writes"):format(rendered - r1, #ui_out))
  Render.refresh = count_refresh

  -- ids that are not strings, and an id that looks like a fallback key
  fresh(new_fake())
  local nb2 = new_nb({
    md("#3", { "a" }),
    { id = 7, cell_type = "markdown", blocks = { "b" }, source = "" },
    md("#3", { "c" }),
    { id = vim.NIL, cell_type = "markdown", blocks = { "d" }, source = "" },
    { id = true, cell_type = "markdown", blocks = { "e" }, source = "" },
  })
  activate(nb2)
  render(nb2)
  for _, j in ipairs(fake.jobs) do answer(j, 2, 1, false) end
  local n = settle(nb2, 4)
  local want, ok2, ids2, d2 = { "#3", "#2", "#3#", "#4", "#5" }, true, {}, 0
  for _, k in ipairs(want) do
    local p = Image._placements[slot(nb2.buf, k, 1)]
    if p then ids2[p.image_id] = true else ok2 = false end
  end
  for _ in pairs(ids2) do d2 = d2 + 1 end
  chk("M12.5 an id that is not a string counts as absent, and a taken #<index> gets one more #",
    ok2 and d2 == 5 and n ~= nil, vim.inspect(vim.tbl_keys(Image._placements)))

  -- two blocks that come to one slot in one render
  fresh(new_fake())
  local nb3 = new_nb({ md("g1", { "a" }) })
  activate(nb3)
  render(nb3)
  answer(fake.jobs[1], 2, 1, false)
  render(nb3)
  local key = slot(nb3.buf, "g1", 1)
  local id0 = Image._placements[key] and Image._placements[key].image_id
  reset_out()
  local n0 = #fake.jobs
  local rctx = MI.begin(nb3)
  local c1 = MI.cell(rctx, nb3.cells[1], 1)
  local c2 = MI.cell(rctx, nb3.cells[1], 1)
  local spec = { first = 103, last = 105, indent = 0, width = 80 }
  local img1 = c1.math_block("a", spec)
  local img2 = c2.math_block("zz", spec)
  MI.cell_done(c1)
  MI.cell_done(c2)
  MI.finish(rctx)
  local p = Image._placements[key]
  chk("M12.6 a second block in a slot used in this render is text: no job, no write, the first image stays",
    img1 ~= nil and img2 == nil and #fake.jobs == n0 and #ui_out == 0 and p and p.image_id == id0,
    ("%d jobs, %d writes"):format(#fake.jobs - n0, #ui_out))

  -- held-back transmits after a render that got none onto the terminal
  local L = MI._limits
  local saved_rb = L.render_bytes
  fresh(new_fake())
  L.render_bytes = 1500
  local blocks = {}
  for k = 1, 3 do blocks[k] = "p_{" .. k .. "}" end
  local nb4 = new_nb({ md("q1", blocks) })
  activate(nb4)
  render(nb4)
  for _, j in ipairs(fake.jobs) do answer(j, 2, 1, false, { b64 = blob(1000) }) end
  wait_ms(80)
  local real = Image.ensure_transmitted
  Image.ensure_transmitted = function(_, _, cb) cb(nil) end      -- a transmit that never lands
  local f0, d0, t0 = refreshed, MI.stats.deferred, MI.stats.transmits
  local okr, err = pcall(render, nb4)
  Image.ensure_transmitted = real
  L.render_bytes = saved_rb
  wait_ms(120)
  chk("M12.7 a render that held transmits back but put no image on the terminal asks for no other render",
    okr and MI.stats.transmits == t0 + 1 and MI.stats.deferred == d0 + 2 and refreshed == f0,
    okr and ("%d transmits, %d held back, %d refreshes"):format(MI.stats.transmits - t0,
      MI.stats.deferred - d0, refreshed - f0) or tostring(err))
end)

section("M13. byte bounds", function()
  local L = MI._limits or {}
  chk("M13.0 the bounds: one image at most the base64 of 1 MiB of PNG, 64 MiB cached, 2 MiB sent per render",
    L.image_b64 == 1398104 and L.cache_bytes == 64 * 1048576 and L.render_bytes == 2 * 1048576, vim.inspect(L))
  local saved = { cache_bytes = L.cache_bytes, render_bytes = L.render_bytes }
  local ok, err = pcall(function()
    -- one answer over the bound, one exactly at it
    fresh(new_fake())
    local nb = new_nb({ md("z1", { "big" }), md("z2", { "edge" }) })
    activate(nb)
    render(nb)
    local jb, je
    for _, j in ipairs(fake.jobs) do if j.data:sub(-3) == "big" then jb = j else je = j end end
    local f0 = MI.stats.fails
    answer(jb, 2, 1, false, { b64 = blob(1398108) })
    answer(je, 2, 1, false, { b64 = blob(1398104) })
    reset_out()
    local o = render(nb)
    render(nb)
    chk("M13.1 an answer longer than the base64 of 1 MiB of PNG is refused: text, never sent, not kept",
      o[1][1] == nil and Image._placements[slot(nb.buf, "z1", 1)] == nil and MI.stats.fails == f0 + 1
        and MI.status().bytes == 1398104 and #fake.jobs == 2)
    chk("M13.2 ...one exactly that long is shown", o[2][1] ~= nil and n_tx() == 1, n_tx())
    render(nb, { width = 60 })
    chk("M13.3 ...and the refused one is asked for again only at another width",
      #fake.jobs == 3 and req_field(fake.jobs[3].data, "max") == "60 60")

    -- the cache's byte budget
    local U = 4000
    L.cache_bytes = 3.5 * U
    fresh(new_fake())
    local nb2 = new_nb({ md("y1", { "y1", "y2", "y3", "y4", "y5" }) })
    activate(nb2)
    render(nb2)
    local by = {}
    for _, j in ipairs(fake.jobs) do by[j.data:sub(-2)] = j end
    local b0 = MI.stats.budget or 0
    answer(by.y1, 2, 1, false, { b64 = blob(U) })
    answer(by.y2, 2, 1, false, { b64 = blob(U) })
    answer(by.y3, 2, 1, false, { b64 = blob(U) })
    answer(by.y4, 2, 1, false, { b64 = blob(U) })
    answer(by.y5, 2, 1, false, { b64 = blob(U / 2) })
    o = render(nb2)
    render(nb2)
    chk("M13.4 over the cache's byte budget, with every record in use, a result is refused: its block is text",
      o[1][4] == nil and (MI.stats.budget or 0) == b0 + 1 and (MI.status().bytes or 0) <= L.cache_bytes,
      vim.inspect({ MI.stats.budget, MI.status().bytes }))
    chk("M13.5 ...a smaller one after it that fits is kept, and the rest are images",
      o[1][1] ~= nil and o[1][2] ~= nil and o[1][3] ~= nil and o[1][5] ~= nil)
    chk("M13.6 ...and the refused one is not asked for again", #fake.jobs == 5, #fake.jobs)
    nb2.cells[1].blocks = { "n1" }
    render(nb2)
    answer(fake.jobs[#fake.jobs], 2, 1, false, { b64 = blob(U) })
    o = render(nb2)
    chk("M13.7 records the latest render does not use are dropped, oldest first, to make room",
      o[1][1] ~= nil and MI.status().bytes <= L.cache_bytes and MI.status().records < 6,
      vim.inspect({ MI.status().records, MI.status().bytes }))

    -- another notebook's latest render keeps its records
    L.cache_bytes = 2 * U
    fresh(new_fake())
    local A = new_nb({ md("a1", { "a1", "a2" }) })
    local Bn = new_nb({ md("b1", { "b1" }) })
    activate(A)
    render(A)
    for _, j in ipairs(fake.jobs) do answer(j, 2, 1, false, { b64 = blob(U) }) end
    render(A)
    render(Bn)
    answer(fake.jobs[#fake.jobs], 2, 1, false, { b64 = blob(U) })
    local oB = render(Bn)
    local nA = #fake.jobs
    local oA = render(A)
    chk("M13.8 another notebook's images are not dropped for this one's: this one's is refused",
      oB[1][1] == nil and oA[1][1] ~= nil and oA[1][2] ~= nil and #fake.jobs == nA)
    MI.forget_buffer(A.buf)
    oB = render(Bn)
    chk("M13.9 once that notebook is wiped, the refused formula is asked for once more", #fake.jobs == nA + 1)
    answer(fake.jobs[#fake.jobs], 2, 1, false, { b64 = blob(U) })
    oB = render(Bn)
    chk("M13.10 ...and now kept and shown", oB[1][1] ~= nil and MI.status().bytes == U)
    L.cache_bytes = saved.cache_bytes

    -- the bytes one render sends
    L.render_bytes = 2.5 * U
    fresh(new_fake())
    local nt = new_nb({ md("t1", { "s1", "bg", "s2" }) })
    activate(nt)
    render(nt)
    local bt = {}
    for _, j in ipairs(fake.jobs) do bt[j.data:sub(-2)] = j end
    answer(bt.s1, 2, 1, false, { b64 = blob(U) })
    answer(bt.bg, 2, 1, false, { b64 = blob(3 * U) })
    answer(bt.s2, 2, 1, false, { b64 = blob(U) })
    reset_out()
    local d0 = MI.stats.deferred
    local ot = render(nt)
    chk("M13.11 a block that would take a render past its bytes waits, and a smaller one after it still goes",
      n_tx() == 2 and ot[1][1] ~= nil and ot[1][2] == nil and ot[1][3] ~= nil and MI.stats.deferred == d0 + 1,
      ("%d transmits"):format(n_tx()))
    reset_out()
    ot = render(nt)
    chk("M13.12 the next render sends it, larger than the bound on its own: one transmit always goes",
      n_tx() == 1 and ot[1][2] ~= nil)
    reset_out()
    render(nt)
    chk("M13.13 ...and the render after that sends nothing", #ui_out == 0)
  end)
  L.cache_bytes, L.render_bytes = saved.cache_bytes, saved.render_bytes
  chk("M13 ran to the end", ok, tostring(err))
end)

section("M14. a wiped notebook", function()
  fresh(new_fake())
  local A = new_nb({ md("fa", { "shared", "onlyA" }) })
  local Bn = new_nb({ md("fb", { "shared", "onlyB" }) })
  activate(A)
  render(A)
  render(Bn)
  local by = {}
  for _, j in ipairs(fake.jobs) do by[j.data:match("%a+$")] = j end
  chk("M14.0 three jobs: the shared formula's and one for each notebook's own",
    #fake.jobs == 3 and by.shared and by.onlyA and by.onlyB)
  answer(by.shared, 2, 1, false)
  render(A)
  render(Bn)
  MI.forget_buffer(A.buf)
  local st = MI.status()
  chk("M14.1 wiping one notebook cancels the jobs only it waited for",
    was_cancelled(by.onlyA.id) and not was_cancelled(by.onlyB.id) and st.pending == 1, vim.inspect(fake.cancelled))
  chk("M14.2 ...and drops the records only it used: the shared one stays", st.records == 2, st.records)
  answer(by.onlyA, 2, 1, false)
  chk("M14.3 a late answer for the cancelled job is ignored",
    MI.status().records == 2 and MI.status().pending == 1)
  local n0 = #fake.jobs
  local o = render(Bn)
  chk("M14.4 the other notebook keeps its image, with no new job", o[1][1] ~= nil and #fake.jobs == n0)
  MI.forget_buffer(Bn.buf)
  st = MI.status()
  chk("M14.5 wiping the last notebook cancels every job and empties the cache",
    was_cancelled(by.onlyB.id) and st.pending == 0 and st.records == 0 and (st.bytes or 0) == 0)
end)

section("M15. every job slot taken", function()
  fresh(new_fake())
  local blocks = {}
  for k = 1, 256 do blocks[k] = "w_{" .. k .. "}" end
  local A = new_nb({ md("wa", blocks) })
  local Bn = new_nb({ md("wb", { "late" }) })
  activate(A)
  render(A)
  local f0 = refreshed
  local ob = render(Bn)
  chk("M15.1 a block that finds every slot taken is text, with no job", ob[1][1] == nil and #fake.jobs == 256)
  wait_ms(120)
  chk("M15.2 nothing renders again by itself while the slots stay taken (no timer)", refreshed == f0,
    refreshed - f0)
  local rb = refreshes_of(Bn.buf)
  answer(fake.jobs[1], 2, 1, false)
  vim.wait(1000, function() return refreshes_of(Bn.buf) > rb end, 5)
  chk("M15.3 a completion renders the notebook that waited for a slot, though not for that job",
    refreshes_of(Bn.buf) == rb + 1)
  render(Bn)
  chk("M15.4 ...and its block takes the free slot", #fake.jobs == 257 and fake.jobs[257].data:sub(-4) == "late")
end)

-- the slot count against the jobs: in flight = the jobs not overdue, never below 0
local function slots_agree()
  local n = 0
  for _, j in pairs(MI._S.jobs) do if not j.overdue then n = n + 1 end end
  return MI._S.inflight == n and n >= 0, ("inflight %d, jobs not overdue %d"):format(MI._S.inflight, n)
end
-- the jobs asked for a formula (no prelude: the request ends in "\n\n" .. tex)
local function jobs_for(tex)
  local n = 0
  for _, j in ipairs(fake.jobs) do if j.data:sub(-(#tex + 2)) == "\n\n" .. tex then n = n + 1 end end
  return n
end

section("M16. a job in flight past 10 s: cancelled, its slot given back, no verdict", function()
  fresh(new_fake())
  local clock = 0
  MI._now = function() return clock end
  MI._S.watch_at = nil
  local l0 = MI.stats.late or 0
  local names = { "late", "never", "cancelled", "broken" }
  local nb = new_nb({ md("wd", names) })
  activate(nb)
  render(nb)
  local by = {}
  for _, j in ipairs(fake.jobs) do by[j.data:match("%a+$")] = j end
  clock = 600
  nb.cells[1].blocks = { "late", "never", "cancelled", "broken", "young" }
  render(nb)
  for _, j in ipairs(fake.jobs) do by[j.data:match("%a+$")] = j end
  clock = 5000
  render(nb)
  local st = MI.status()
  chk("M16.1 a job in flight for 5 s is left alone", by.late and by.young and not was_cancelled(by.late.id)
    and st.pending == 5 and st.inflight == 5 and st.overdue == 0)
  clock = 10500
  local t0, f0 = MI.stats.timeouts, MI.stats.fails
  local o = render(nb)
  st = MI.status()
  local four = true
  for _, k in ipairs(names) do if not (by[k] and was_cancelled(by[k].id)) then four = false end end
  chk("M16.2 past 10 s the next render cancels the jobs that old and gives their slots back",
    four and not was_cancelled(by.young.id) and st.inflight == 1 and st.overdue == 4
      and MI.stats.timeouts == t0 + 4, vim.inspect({ st.inflight, st.overdue, MI.stats.timeouts - t0 }))
  chk("M16.3 ...and decides nothing: still pending, no failure, text, not asked for again",
    st.pending == 5 and MI.stats.fails == f0 and o[1][1] == nil and o[1][2] == nil and #fake.jobs == 5)
  chk("M16.3b ...and the slot count agrees with the jobs", slots_agree())
  clock = 10800
  render(nb)
  chk("M16.4 the jobs are looked at no more than once a second", not was_cancelled(by.young.id))
  clock = 11700
  render(nb)
  st = MI.status()
  chk("M16.5 ...a second later the younger one goes overdue too",
    was_cancelled(by.young.id) and st.inflight == 0 and st.overdue == 5 and slots_agree())

  -- the answers decide
  answer(by.late, 2, 1, false)
  answer(by.young, 3, 1, false)
  fail(by.cancelled, "CANCELLED", 3)
  fail(by.broken, "math: parse: Undefined control sequence: \\broken")
  st = MI.status()
  chk("M16.6 answers to overdue jobs free no slot a second time: in flight 0, not below",
    st.inflight == 0 and st.pending == 1 and st.overdue == 1 and slots_agree(),
    vim.inspect({ st.inflight, st.pending, st.overdue }))
  local n0 = #fake.jobs
  o = render(nb)
  chk("M16.7 a result that comes late is kept and shown", o[1][1] ~= nil and o[1][5] ~= nil
    and (MI.stats.late or 0) == l0 + 2, vim.inspect({ o[1][1] ~= nil, o[1][5] ~= nil, MI.stats.late }))
  chk("M16.8 a job that answers CANCELLED never ran: the next render asks for it again",
    #fake.jobs == n0 + 1 and jobs_for("cancelled") == 2 and o[1][3] == nil)
  chk("M16.9 an error is an error: text, and not asked for again", o[1][4] == nil and jobs_for("broken") == 1)
  for _ = 1, 3 do
    clock = clock + 20000
    o = render(nb)
  end
  st = MI.status()
  chk("M16.10 one that never answers stays pending: text, never asked for again, holding no slot",
    o[1][2] == nil and jobs_for("never") == 1 and st.overdue >= 1 and slots_agree(),
    vim.inspect({ jobs_for("never"), st.overdue, st.inflight }))

  -- the overdue job's notebook wiped, then a variant switch with an overdue job out
  local nb_w = new_nb({ md("ww", { "gone" }) })
  render(nb_w)
  local jg = fake.jobs[#fake.jobs]
  clock = clock + 20000
  render(nb)
  local in0 = MI.status().inflight
  MI.forget_buffer(nb_w.buf)
  chk("M16.11 a notebook wiped while its job is overdue: the job goes, the slot count stays right",
    jg.data:sub(-4) == "gone" and MI._S.jobs[jg.id] == nil and MI.status().inflight == in0 and slots_agree())
  vim.cmd("hi JupynvimMathImage guifg=#00ff00")
  local n1 = #fake.jobs
  render(nb)
  st = MI.status()
  chk("M16.12 a new colour drops every job, overdue ones too, and asks for the block again",
    st.overdue == 0 and jobs_for("never") == 2 and #fake.jobs > n1 and slots_agree())
  answer(by.never, 2, 1, false)
  chk("M16.13 ...and the old job's answer is ignored", MI.status().records == 5 and slots_agree())
  vim.cmd("hi JupynvimMathImage guifg=#c0caf5")

  -- every slot held by a job that goes overdue, and a 257th block waiting
  fresh(new_fake())
  MI._now = function() return clock end
  MI._S.watch_at = nil
  clock = 20000
  local blocks = {}
  for k = 1, 257 do blocks[k] = "h_{" .. k .. "}" end
  local nb2 = new_nb({ md("wh", blocks) })
  activate(nb2)
  render(nb2)
  chk("M16.14 256 jobs, and the 257th block waits", #fake.jobs == 256)
  clock = 31000
  render(nb2)
  st = MI.status()
  chk("M16.15 once they go overdue, the same render gives the waiting block a slot",
    #fake.jobs == 257 and fake.jobs[257].data:sub(-7) == "h_{257}" and st.inflight == 1
      and st.overdue == 256 and st.pending == 257 and slots_agree())
  MI._now = REAL_NOW
end)

section("M17. what goes to the log", function()
  local got = {}
  local saved_debug, saved_warn = Log.debug, Log.warn
  Log.debug = function(...) got[#got + 1] = table.concat({ ... }, " ") end
  Log.warn = Log.debug
  local ok, err = pcall(function()
    fresh(new_fake())
    local tex = "\27]0;title\7\27[2J\n" .. ("y"):rep(200)
    local nb = new_nb({ md("lg", { tex }) })
    activate(nb)
    render(nb)
    fail(fake.jobs[1], "math: parse: bad \27[31m\n input")
    Image.ensure_transmitted("key\27[2J\n", "not base64 at all!", function() end, { renderer = "placeholder" })
  end)
  Log.debug, Log.warn = saved_debug, saved_warn
  local clean, short = #got >= 2, true
  for _, l in ipairs(got) do
    for i = 1, #l do
      local b = l:byte(i)
      if b < 32 or b == 127 then clean = false end
    end
    if l:find(("y"):rep(81), 1, true) then short = false end
  end
  chk("M17.1 a formula's failure and a refused key are logged without a control byte", ok and clean,
    ok and vim.inspect(got) or tostring(err))
  chk("M17.2 ...and with at most 80 bytes of the formula", ok and short)
  chk("M17.3 log_text: control and C1 control bytes become ?, at most 80 bytes",
    Image.log_text ~= nil and Image.log_text("a\27b\n\194\155c") == "a?b???c"
      and #Image.log_text(("x"):rep(500)) == 80)
end)

section("M18. the macro prelude's bounds", function()
  fresh(new_fake())
  local cells = {}
  for k = 1, 100 do cells[k] = md("d" .. k, {}, "\\def\\m" .. k .. "{" .. k .. "}") end
  cells[64].blocks = { "\\m1" }                          -- the 64th defining cell: its prelude is whole
  cells[101] = md("f", { "\\m2" }, "$$\\m2$$")
  local nb = new_nb(cells)
  activate(nb)
  render(nb)
  local srcs = {}
  for k = 1, 64 do srcs[k] = cells[k].source end
  local want = table.concat(srcs, "\n")
  local j = fake.jobs[1]
  chk("M18.1 the prelude is the first 64 macro-defining cells",
    #fake.jobs == 1 and req_field(j.data, "pre") == tostring(#want) and j.data:sub(-(#want + 3)) == want .. "\\m1"
      and not j.data:find("\\def\\m65{", 1, true), j and req_field(j.data, "pre"))
  local big = {}
  for k = 1, 3 do big[k] = "\\def\\b" .. k .. "{" .. ("x"):rep(30000) .. "}" end
  fresh(new_fake())
  local nb2 = new_nb({ md("e1", {}, big[1]), md("e2", { "\\b1" }, "$$\\b1$$"), md("e3", {}, big[2]),
                       md("e4", { "\\b2" }, "$$\\b2$$"), md("e5", {}, big[3]), md("e6", { "\\b1" }, "$$\\b1$$") })
  activate(nb2)
  local c0 = MI.stats.prelude_cut or 0
  local o = render(nb2)
  local pre = {}
  for _, jj in ipairs(fake.jobs) do pre[jj.data:sub(-3)] = req_field(jj.data, "pre") end
  chk("M18.2 within 64 KiB every definition above a formula is in its prelude",
    #fake.jobs == 2 and pre["\\b1"] == tostring(#big[1]) and pre["\\b2"] == tostring(#big[1] + 1 + #big[2]),
    vim.inspect(pre))
  chk("M18.3 a formula below the cell that would pass 64 KiB is text, with no job",
    o[6][1] == nil and (MI.stats.prelude_cut or 0) == c0 + 1, vim.inspect({ #fake.jobs, MI.stats.prelude_cut }))
end)

section("M19. the library arrives later", function()
  local f = new_fake({ ready = false })
  fresh(f)
  local nb = new_nb({ md("la", { "q" }) })
  activate(nb)
  for _ = 1, 3 do render(nb) end
  chk("M19.1 no library: off, asked once, and not again while the loader says the same",
    MI._S.lib == "off" and f.asked == 1, ("%s, asked %d"):format(MI._S.lib, f.asked))
  f.ready = true                       -- installed: the loader's state is no longer that of the answer
  activate(nb)
  chk("M19.2 once the loader's state changes the next render asks again, and images come on",
    MI._S.lib == "ok" and f.asked == 2, ("%s, asked %d"):format(MI._S.lib, f.asked))
  render(nb)
  chk("M19.3 ...and its block gets a job", #f.jobs == 1)
  local g = new_fake({ ready = false })
  fresh(g)
  activate(nb)
  local was = MI._S.lib
  MI.reset()
  chk("M19.4 reset() forgets an \"off\"", was == "off" and MI._S.lib == "unasked", MI._S.lib)
  activate(nb)
  was = MI._S.lib
  MI.setup({ renderer = "auto" })
  chk("M19.5 so does setup()", was == "off" and MI._S.lib == "unasked", MI._S.lib)
end)

section("M20. :hi clear without a ColorScheme event", function()
  fresh(new_fake())
  local nb = new_nb({ md("hc", { "a" }) })
  activate(nb)
  render(nb)
  answer(fake.jobs[1], 2, 1, false)
  render(nb)
  local p = Image._placements[slot(nb.buf, "hc", 1)]
  local hl = p and ("JupynvimPH_" .. p.image_id)
  local colour = p and ("#%06x"):format(p.image_id)
  chk("M20.0 an image, and its group carries the id", hl ~= nil and hl_fg(hl) == colour)
  vim.cmd("hi clear")
  vim.api.nvim_set_hl(0, "JupynvimMathImage", { fg = "#c0caf5" })   -- the same ink: no new variant
  local cleared = hl and hl_fg(hl) == nil
  reset_out()
  local o = render(nb)
  chk("M20.1 the next render sets the group again, and writes nothing",
    cleared and o[1][1] ~= nil and hl_fg(hl) == colour and #ui_out == 0, hl and tostring(hl_fg(hl)))
end)

section("M21. more records than the cache keeps, all in use", function()
  fresh(new_fake())
  local blocks = {}
  for k = 1, 1030 do blocks[k] = "r_{" .. k .. "}" end
  local nb = new_nb({ md("ev", blocks) })
  activate(nb)
  local s0 = MI.stats.evict_scans or 0
  for _ = 1, 4 do render(nb) end
  chk("M21.1 one scan finds nothing to drop, and the renders after it do not look again",
    MI.status().records == 1030 and (MI.stats.evict_scans or 0) - s0 == 1,
    ("%d records, %d scans"):format(MI.status().records, (MI.stats.evict_scans or 0) - s0))
  local keep = {}
  for k = 1, 930 do keep[k] = blocks[k] end
  nb.cells[1].blocks = keep
  render(nb)
  chk("M21.2 records that went out of use stay while the cache keeps its size", MI.status().records == 1030)
  keep[931] = "r_new"
  render(nb)
  chk("M21.3 ...and are dropped once it changes",
    MI.status().records == 931 and (MI.stats.evict_scans or 0) - s0 == 2,
    ("%d records, %d scans"):format(MI.status().records, (MI.stats.evict_scans or 0) - s0))
end)

section("M22. a notebook whose formulas all fail", function()
  fresh(new_fake())
  local blocks = {}
  for k = 1, 80 do blocks[k] = "\\nosuch_{" .. k .. "}" end
  local nb = new_nb({ md("af", blocks) })
  activate(nb)
  live(nb)
  reset_out()
  local f0 = MI.stats.fails
  render(nb)
  -- every job fails as it comes; the module's own renders ask for the rest
  local answered = 0
  vim.wait(3000, function()
    while answered < #fake.jobs do
      answered = answered + 1
      local j = fake.jobs[answered]
      if answered % 10 == 0 then
        fail(j, "math: size: too wide: 400 columns, 80 allowed")
      elseif answered % 10 == 1 then
        j.cb(true, "JNM 1\n\n")                       -- an answer with no head
      else
        fail(j, "math: parse: Undefined control sequence: \\nosuch")
      end
    end
    return answered == 80 and MI.status().pending == 0
  end, 5)
  wait_ms(100)
  chk("M22.1 all 80 jobs fail, asked for by the module's own renders",
    answered == 80 and MI.stats.fails - f0 == 80 and MI.status().pending == 0,
    ("%d answered, %d failures"):format(answered, MI.stats.fails - f0))
  local r0, rf0 = rendered, refreshed
  reset_out()
  wait_ms(300)
  chk("M22.2 then the editor is idle: no render, no refresh asked for, nothing written",
    rendered == r0 and refreshed == rf0 and #ui_out == 0,
    ("%d renders, %d refreshes, %d writes"):format(rendered - r0, refreshed - rf0, #ui_out))
  Render.refresh = count_refresh
end)

section("M23. the renders the module asks for: spaced, and coalesced", function()
  fresh(new_fake())
  local clock = 1000
  MI._now = function() return clock end
  local defers = {}
  MI._defer = function(fn, ms) defers[#defers + 1] = { fn = fn, ms = ms } end
  local nb = new_nb({ md("sp", { "s_{1}", "s_{2}", "s_{3}", "s_{4}", "s_{5}", "s_{6}" }) })
  activate(nb)
  -- a render as render.lua makes one, that takes `ms` on the clock
  local function render_for(ms)
    local rctx = MI.begin(nb)
    local cctx = MI.cell(rctx, nb.cells[1], 1)
    for k, tex in ipairs(nb.cells[1].blocks) do
      cctx.math_block(tex, { first = k * 3, last = k * 3 + 2, indent = 0, width = 80 })
    end
    MI.cell_done(cctx)
    clock = clock + ms
    MI.finish(rctx)
  end
  local function new_formula(tex)
    local b = nb.cells[1].blocks
    b[#b + 1] = tex
  end
  render_for(200)                                     -- begins at 1000, takes 200 ms
  local r0 = refreshes_of(nb.buf)
  clock = 1250
  for k = 1, 5 do answer(fake.jobs[k], 2, 1, false) end
  chk("M23.1 five completions after a render of 200 ms: no render at once, one asked for 3 x 200 ms after it began",
    refreshes_of(nb.buf) == r0 and #defers == 1 and defers[1].ms == 350,
    vim.inspect({ refreshes_of(nb.buf) - r0, #defers, defers[1] and defers[1].ms }))
  defers[1].fn()
  chk("M23.2 when it is due, that one render is asked for", refreshes_of(nb.buf) == r0 + 1)
  answer(fake.jobs[6], 2, 1, false)
  chk("M23.3 a request made before that render begins rides on it", #defers == 1 and refreshes_of(nb.buf) == r0 + 1)

  clock = 1600
  new_formula("s_{7}")
  render_for(500)                                     -- 3 x 500 is more than a second
  clock = 2110
  answer(fake.jobs[#fake.jobs], 2, 1, false)
  chk("M23.4 after a render of 500 ms the wait is capped at a second from its start",
    #defers == 2 and defers[2].ms == 1600 + 1000 - 2110, defers[2] and defers[2].ms)

  -- a render someone else causes in the meantime does what was asked
  clock = 3000
  render_for(1)                                       -- the user's: never held back
  local r1 = refreshes_of(nb.buf)
  defers[2].fn()
  chk("M23.5 a render that began after the request answers it: the request then renders nothing",
    refreshes_of(nb.buf) == r1)
  new_formula("s_{8}")
  render_for(1)
  clock = clock + 5
  answer(fake.jobs[#fake.jobs], 2, 1, false)
  chk("M23.6 after a render of 1 ms the wait is the 30 ms floor", #defers == 3 and defers[3].ms == 30 - 6,
    defers[3] and defers[3].ms)
  defers[3].fn()
  new_formula("s_{9}")
  clock = clock + 100
  render_for(10)
  clock = clock + 500
  local r2 = refreshes_of(nb.buf)
  answer(fake.jobs[#fake.jobs], 2, 1, false)
  chk("M23.7 a request past the wait renders at once", #defers == 3 and refreshes_of(nb.buf) == r2 + 1)
  MI._now, MI._defer = REAL_NOW, REAL_DEFER
end)

section("M24. a new ink wakes the notebooks that waited on its dropped jobs", function()
  fresh(new_fake())
  local blocks = {}
  for k = 1, 257 do blocks[k] = "n_{" .. k .. "}" end
  local A = new_nb({ md("na", blocks) })              -- 256 jobs and one block waiting for a slot
  local Bn = new_nb({ md("nb", {}, "text only") })
  activate(A)
  render(A)
  render(Bn)
  chk("M24.0 A has every slot and waits for one more", #fake.jobs == 256 and MI._S.starved[A.buf] == true)
  live(A)
  vim.cmd("hi JupynvimMathImage guifg=#123456")
  local ra, n0 = refreshes_of(A.buf), #fake.jobs
  render(Bn)                                          -- B's render switches the variant
  chk("M24.1 B's render drops A's jobs", MI.status().pending == 0 and was_cancelled(fake.jobs[1].id))
  vim.wait(1000, function() return #fake.jobs > n0 end, 5)
  chk("M24.2 A renders again by itself and asks for its formulas in the new ink",
    refreshes_of(A.buf) >= ra + 1 and #fake.jobs == n0 + 256
      and req_field(fake.jobs[#fake.jobs].data, "fg") == "#123456",
    vim.inspect({ refreshes_of(A.buf) - ra, #fake.jobs - n0 }))
  local answered = n0
  local function all_shown()
    local P = MI._S.cache[""]
    for k = 1, 257 do
      local F = P and P[blocks[k]]
      if not (F and F.nat and Image.is_cached(slot(A.buf, "na", k), nil, "placeholder", F.nat.id)) then
        return false
      end
    end
    return true
  end
  vim.wait(3000, function()
    while answered < #fake.jobs do
      answered = answered + 1
      answer(fake.jobs[answered], 2, 1, false)
    end
    return all_shown()
  end, 5)
  chk("M24.3 ...and gets every image without any other event", all_shown(), ("%d jobs"):format(#fake.jobs - n0))
  Render.refresh = count_refresh
  vim.cmd("hi JupynvimMathImage guifg=#c0caf5")
end)

section("M25. the byte budget counts the results that windows show", function()
  local L = MI._limits
  local saved = L.cache_bytes
  local ok, err = pcall(function()
    local U = 4000
    L.cache_bytes = 3.5 * U
    fresh(new_fake())
    local nb = new_nb({ md("rb", { "q1", "q2", "q3" }) })
    activate(nb)
    render(nb, { width = 80 })
    for _, j in ipairs(fake.jobs) do answer(j, 30, 1, false, { b64 = blob(U) }) end
    local o = render(nb, { width = 80 })
    chk("M25.1 three formulas at their natural 30 columns fill most of the budget",
      o[1][1] and o[1][2] and o[1][3] and MI.status().bytes == 3 * U)
    local b0 = MI.stats.budget
    o = render(nb, { width = 20 })
    chk("M25.2 a window of 20 columns asks for each formula at that width", #fake.jobs == 6
      and o[1][1] == nil and req_field(fake.jobs[6].data, "max") == "20 60")
    for k = 4, 6 do answer(fake.jobs[k], 20, 1, true, { b64 = blob(U) }) end
    o = render(nb, { width = 20 })
    chk("M25.3 the results at 30 columns, which no window shows now, make room: every block is an image again",
      o[1][1] ~= nil and o[1][2] ~= nil and o[1][3] ~= nil and MI.stats.budget == b0
        and MI.status().bytes <= L.cache_bytes,
      vim.inspect({ MI.stats.budget - b0, MI.status().bytes }))
    chk("M25.4 ...and the formulas' records stay, only those results went", MI.status().records == 3)
    -- two notebooks share a formula: the result the other one shows keeps its bytes
    fresh(new_fake())
    L.cache_bytes = 3.5 * U
    local A = new_nb({ md("ra", { "p1", "p2" }) })
    local Bn = new_nb({ md("rc", { "p1" }) })
    activate(A)
    render(A, { width = 80 })
    for _, j in ipairs(fake.jobs) do answer(j, 30, 1, false, { b64 = blob(U) }) end
    render(A, { width = 80 })
    render(Bn, { width = 80 })
    render(A, { width = 20 })
    for k = 3, #fake.jobs do answer(fake.jobs[k], 20, 1, true, { b64 = blob(U) }) end
    local oA = render(A, { width = 20 })
    local oB = render(Bn, { width = 80 })
    local P = MI._S.cache[""] or {}
    chk("M25.5 two notebooks share a formula: the narrow one's images come in, the wide one keeps its own",
      oA[1][1] ~= nil and oA[1][2] ~= nil and oB[1][1] ~= nil and MI.status().bytes <= L.cache_bytes,
      vim.inspect({ oA[1][1] ~= nil, oA[1][2] ~= nil, oB[1][1] ~= nil, MI.status().bytes }))
    chk("M25.6 ...the result only the narrowed notebook used went, the shared one's stayed",
      P.p1 and P.p1.nat ~= nil and P.p2 and P.p2.nat == nil)
  end)
  L.cache_bytes = saved
  chk("M25 ran to the end", ok, tostring(err))
end)

section("M26. a notebook wiped without its autocommands", function()
  fresh(new_fake())
  local A = new_nb({ md("ga", { "a1", "a2" }) })
  local Bn = new_nb({ md("gb", { "b1" }) })
  activate(A)
  render(A)
  render(Bn)
  for _, j in ipairs(fake.jobs) do answer(j, 2, 1, false) end
  render(A)
  render(Bn)
  local ka = slot(A.buf, "ga", 1)
  chk("M26.0 both notebooks show their images", Image._placements[ka] ~= nil and MI.status().records == 3
    and MI.status().slots == 3)
  local abuf = A.buf
  vim.cmd("noautocmd bwipeout! " .. abuf)
  render(Bn)
  local st = MI.status()
  chk("M26.1 the next render of another notebook forgets it: its slots, records and bytes go",
    MI._S.bufs[abuf] == nil and Image._placements[ka] == nil and st.records == 1 and st.slots == 1
      and st.bytes == #PNG, vim.inspect({ st.records, st.slots, st.bytes }))
end)

section("M27. macros past the 64th defining cell", function()
  fresh(new_fake())
  local cells = {}
  for k = 1, 70 do cells[k] = md("d" .. k, {}, "\\def\\m" .. k .. "{" .. k .. "}") end
  cells[1].source = "\\newcommand{\\R}{\\mathbb{R}}"
  cells[10].blocks = { "\\R^{10}" }
  cells[64].blocks = { "\\R^{64}" }
  cells[66].source = "\\renewcommand{\\R}{\\mathbb{Q}}"
  cells[68].blocks = { "\\R^{68}" }
  cells[71] = md("tail", { "x^{71}" }, "$$x^{71}$$")
  local nb = new_nb(cells)
  activate(nb)
  local c0 = MI.stats.prelude_cut or 0
  local o = render(nb)
  local tex_of = {}
  for _, j in ipairs(fake.jobs) do tex_of[#tex_of + 1] = j.data:match("\\R%^{%d+}$") or j.data:match("x%^{%d+}$") end
  chk("M27.1 the formulas within the first 64 defining cells are asked for",
    #fake.jobs == 2 and vim.tbl_contains(tex_of, "\\R^{10}") and vim.tbl_contains(tex_of, "\\R^{64}"),
    vim.inspect(tex_of))
  chk("M27.2 below the 65th, a formula that a left-out \\renewcommand changes is text, with no job",
    o[68][1] == nil and not vim.tbl_contains(tex_of, "\\R^{68}") and (MI.stats.prelude_cut or 0) >= c0 + 1)
  chk("M27.3 ...and so is every display formula under it", o[71][1] == nil and not vim.tbl_contains(tex_of, "x^{71}")
    and (MI.stats.prelude_cut or 0) == c0 + 2)
  for _, j in ipairs(fake.jobs) do answer(j, 2, 1, false) end
  o = render(nb)
  chk("M27.4 the formulas above it are images", o[10][1] ~= nil and o[64][1] ~= nil and o[68][1] == nil)
  for k = 2, 7 do cells[k].source = "prose" end        -- 64 defining cells again: nothing left out
  render(nb)
  local j68
  for _, j in ipairs(fake.jobs) do if j.data:sub(-7) == "\\R^{68}" then j68 = j end end
  chk("M27.5 with 64 defining cells the formula below has its whole prelude, the \\renewcommand in it",
    j68 ~= nil and j68.data:find("\\renewcommand{\\R}{\\mathbb{Q}}", 1, true) ~= nil)
end)

section("M28. a width that is not a finite number", function()
  fresh(new_fake())
  local nb = new_nb({ md("nw", { "a" }) })
  activate(nb)
  local rctx = MI.begin(nb)
  local cctx = MI.cell(rctx, nb.cells[1], 1)
  local got, errs = {}, {}
  for i, sp in ipairs({ { width = 0 / 0 }, { width = math.huge }, { width = -math.huge },
                        { width = 80, indent = 0 / 0 }, { width = 80, indent = -math.huge } }) do
    sp.first, sp.last, sp.indent = 3 * i, 3 * i + 1, sp.indent or 0
    local okc, r = pcall(cctx.math_block, "a" .. i, sp)
    got[i] = r
    if not okc then errs[#errs + 1] = tostring(r) end
  end
  MI.cell_done(cctx)
  MI.finish(rctx)
  chk("M28.1 a width of NaN or an infinity, or such an indent: text, no error, no job",
    #errs == 0 and next(got) == nil and #fake.jobs == 0, vim.inspect({ errs, #fake.jobs }))
end)

-- ── C. setup() ──────────────────────────────────────────────────────────
section("C. setup validation", function()
  local function one(opts, field, default, name)
    notes = {}
    MI.setup(opts)
    local got = MI._S.cfg[field]
    local ok = #math_notes() == 1 and math_notes()[1].lvl == vim.log.levels.WARN
    if type(default) == "table" or default == nil then ok = ok and got == nil else ok = ok and got == default end
    chk("C " .. name .. " falls back to its default with one warning", ok,
      ("%d warnings, %s = %s"):format(#math_notes(), field, tostring(got)))
  end
  one({ renderer = "images" }, "renderer", "auto", "renderer = \"images\"")
  one({ renderer = 1 }, "renderer", "auto", "renderer = 1")
  one({ scale = 10 }, "scale", 1.0, "scale = 10")
  one({ scale = 0.1 }, "scale", 1.0, "scale = 0.1")
  one({ scale = 0 / 0 }, "scale", 1.0, "scale = nan")
  one({ scale = "2" }, "scale", 1.0, "scale = \"2\"")
  one({ align = "right" }, "align", "left", "align = \"right\"")
  one({ cell_px = { w = 2, h = 20 } }, "cell_px", nil, "cell_px.w = 2")
  one({ cell_px = { w = 10, h = 600 } }, "cell_px", nil, "cell_px.h = 600")
  one({ cell_px = { w = 10.5, h = 20 } }, "cell_px", nil, "cell_px.w = 10.5")
  one({ cell_px = "14x30" }, "cell_px", nil, "cell_px = \"14x30\"")
  notes = {}
  MI.setup({ colour = "red", renderer = "image" })
  chk("C an unknown key is named in the warning and ignored",
    #math_notes() == 1 and math_notes()[1].msg:find("colour", 1, true) ~= nil and MI._S.cfg.renderer == "image")
  notes = {}
  MI.setup({ renderer = "x", scale = 9, align = "up", cell_px = 3 })
  local m = math_notes()
  chk("C several bad entries: one warning naming each",
    #m == 1 and m[1].msg:find("renderer", 1, true) and m[1].msg:find("scale", 1, true)
      and m[1].msg:find("align", 1, true) and m[1].msg:find("cell_px", 1, true))
  notes = {}
  MI.setup(42)
  chk("C a setting that is not a table: one warning, the defaults",
    #math_notes() == 1 and MI._S.cfg.renderer == "auto")
  notes = {}
  MI.setup({ renderer = "image", scale = 2.5, align = "center", cell_px = { w = 12, h = 28 } })
  local c = MI._S.cfg
  chk("C good values are taken, with no warning",
    #math_notes() == 0 and c.renderer == "image" and c.scale == 2.5 and c.align == "center"
      and c.cell_px.w == 12 and c.cell_px.h == 28)
  notes = {}
  MI.setup(nil)
  chk("C setup(nil) is the defaults, with no warning",
    #math_notes() == 0 and MI._S.cfg.renderer == "auto" and MI._S.cfg.cell_px == nil)
  for _ = 1, 5 do MI.setup({}) end
  local au = vim.api.nvim_get_autocmds({ group = "jupynvim_mathimage" })
  local ev = {}
  for _, a in ipairs(au) do ev[a.event] = (ev[a.event] or 0) + 1 end
  chk("C setup() run again leaves one set of autocmds",
    #au == 4 and ev.VimResized == 1 and ev.UIEnter == 1 and ev.FocusGained == 1 and ev.ColorScheme == 1,
    vim.inspect(ev))
end)

if fails == 0 then
  io.write("\nALL MATH IMAGE UNIT CHECKS PASSED\n")
  vim.cmd("qa!")
else
  io.write(("\nMATH IMAGE UNIT: %d CHECK(S) FAILED\n"):format(fails))
  vim.cmd("cquit 1")
end
