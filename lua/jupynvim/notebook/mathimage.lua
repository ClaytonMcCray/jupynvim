-- Display math in markdown cells as images.
--
-- libjupynvim typesets one formula per job on its worker threads and answers
-- with a PNG (base64) and the grid of terminal cells it fills; image.lua
-- sends it to the terminal under the block's slot key, and markdown.lua
-- draws the Kitty placeholder rows in place of the block's text. This module
-- holds everything with state: the config, whether images are on for a
-- render, the terminal's cell size in pixels, the ink colour, the macros
-- that markdown cells define for the cells below them, the cache of typeset
-- results, the jobs, and the image slots and their lifetime. It never draws
-- an extmark.
--
-- Nothing here waits for the library. The first render that wants an image
-- asks native.lua to open it away from the UI thread (when_ready); every
-- formula is a job (submit), and a block shows its text rendering until its
-- result has come back. The one synchronous library call is the terminal
-- size question (MATH_CELL, a few system calls), made only once the library
-- is loaded. Every failure leaves a block with its text rendering.
--
-- Whatever a notebook holds, what it can cost is bounded: at most
-- MAX_INFLIGHT jobs at once, each cancelled after JOB_MS; per render at most
-- MAX_TX_PER_RENDER transmits and render_bytes of base64 (one transmit always
-- goes, so a notebook settles); an image of at most image_b64 bytes, and
-- cache_bytes of base64 cached across every notebook; the macro prelude
-- from at most MAX_DEF_CELLS cells. A render that put nothing new on the
-- terminal asks for no other, and nothing is retried on a timer.
--
-- render.lua calls, per render: begin (once), then cell and cell_done around
-- markdown.render of each markdown cell that is not being edited, then
-- finish. markdown.render calls ctx.math_block for each display block.

local log = require("jupynvim.log")
local Image = require("jupynvim.notebook.image")

local M = {}

local MAX_TEX = 16384          -- bytes of TeX in one block (the library's limit)
local MAX_PRELUDE = 65536      -- bytes of macro-defining source sent with a formula
local MAX_DEF_CELLS = 64       -- macro-defining cells read for the prelude, from the top
local MAX_ROWS = 60            -- the tallest image, in terminal rows
local MAX_COLS = 297           -- the widest image, in terminal columns (placeholder limit)
local MAX_INFLIGHT = 64        -- jobs at once; the blocks beyond wait for a slot to free up
local MAX_TX_PER_RENDER = 16   -- transmits in one render; the rest go in the next ones
local CACHE_MAX = 1024         -- formula records kept before the oldest are dropped
local FIT_MAX = 4              -- widths a formula that had to shrink keeps results for
local JOB_MS = 10000           -- a job in flight longer than this is cancelled
local WATCH_MS = 1000          -- begin looks for such jobs at most this often

-- The byte bounds (the spec lowers them to test them).
M._limits = {
  image_b64 = 4 * math.ceil(1048576 / 3),  -- one image: the base64 of 1 MiB of PNG
  cache_bytes = 64 * 1048576,              -- base64 of every cached result together
  render_bytes = 2 * 1048576,              -- base64 transmitted by one render
}

M.stats = { blocks = 0, hits = 0, submits = 0, done = 0, fails = 0, cancels = 0,
            transmits = 0, deferred = 0, timeouts = 0, budget = 0, evict_scans = 0 }

-- Seams for the tests.
M._native = nil                -- a stand-in for require("jupynvim.native")
M._nominal = { w = 18, h = 40 }
M._now = function() return vim.uv.hrtime() / 1e6 end   -- milliseconds
-- Placeholder rows drawn as overlays on the block's concealed lines (true),
-- or all of them as virtual lines above it (false). Not a config key.
M._overlay = true

local RENDERERS = { auto = true, image = true, text = true }
local ALIGNS = { left = true, center = true }

-- cache[prelude][tex] = F, for the current variant only. F is one formula
-- with one prelude:
--   { used = tick, users = { [buf] = tick }, err = msg|nil, nat = R|nil,
--     fit = { [avail] = R | { pending = id } | { err = msg, budget = bool } },
--     fit_order = { avail, ... }, waiters = { [buf] = true },
--     bytes = <base64 bytes of its results>, pre = prelude, tex = tex }
-- users[buf] is the tick of the last render of that buffer that used it; F
-- is in use while it is that buffer's latest render (B.tick).
-- R is one typeset result:
--   { id = "jm<serial>", b64 = string, rows = n, cols = n, shrunk = bool }
-- B is one notebook buffer:
--   { buf, nb, tick, has = { [cell_key] = { src, has } }, def_src = {},
--     def_idx = {}, prefix = {}, cells = { [cell_key] = <slot count> },
--     span = { [slot_key] = { first, last } } }
local S = {
  cfg = { renderer = "auto", scale = 1.0, align = "left", cell_px = nil },
  lib = "unasked",                 -- "unasked" | "wait" | "ok" | "off"
  lib_state = nil,                 -- the loader's state when lib became "off"
  cell = nil,                      -- { w, h, source }
  vkey = nil,                      -- the current variant key
  cache = {},
  n = 0,                           -- number of F records
  bytes = 0,                       -- base64 bytes of every R in the cache
  dry = nil,                       -- { n, bytes, tick } of an eviction scan that left it over
  jobs = {},                       -- job id -> { F, avail, cw, ch, tex, t0 }
  inflight = 0,
  starved = {},                    -- buf -> true: wanted a job while every slot was taken
  watch_at = nil,                  -- when begin last looked for overdue jobs
  tick = 0, serial = 0,
  bufs = {},                       -- buf -> B
  why = nil,                       -- why the last begin returned nil
}
M._S = S

local function native()
  return M._native or require("jupynvim.native")
end

-- ── refreshes ───────────────────────────────────────────────────────────

local function refresh(nb)
  if not (nb and nb.buf and vim.api.nvim_buf_is_valid(nb.buf)) then return end
  local ok, Render = pcall(require, "jupynvim.notebook.render")
  if ok and type(Render) == "table" and Render.refresh then
    pcall(Render.refresh, nb, vim.fn.bufwinid(nb.buf))
  end
end

-- the same a little later, at most one waiting per buffer: the transmits a
-- render held back (see finish). A buffer forgotten meanwhile is not.
local later = {}
local function later_refresh(nb)
  local buf = nb and nb.buf
  if not buf or later[buf] then return end
  local token = {}
  later[buf] = token
  vim.defer_fn(function()
    if later[buf] ~= token then return end
    later[buf] = nil
    refresh(nb)
  end, 20)
end

-- the notebooks of a set of buffers ({ [buf] = true }), but `except`
local function refresh_set(set, except)
  for buf in pairs(set) do
    local B = S.bufs[buf]
    if buf ~= except and B and B.nb and vim.api.nvim_buf_is_valid(buf) then refresh(B.nb) end
  end
end

-- A job slot came free: the notebooks that wanted one render again (each
-- once: Render.refresh coalesces). This, not a timer, ends a wait for a slot.
local function slots_freed(except)
  if next(S.starved) == nil then return end
  local set = S.starved
  S.starved = {}
  refresh_set(set, except)
end

-- every notebook this module has seen (each render calls begin first)
local function refresh_all()
  for buf, B in pairs(S.bufs) do
    if B.nb and vim.api.nvim_buf_is_valid(buf) then refresh(B.nb) end
  end
end

-- ── slots ───────────────────────────────────────────────────────────────

-- One display block of one cell in one buffer, by its position in the cell.
-- Not made with Image.output_key: clearing a cell's outputs never frees it.
local function slot_key(buf, cell_key, n)
  return ("%d\31%s\31math%d"):format(buf, cell_key, n)
end

local function free_slot(B, key)
  Image.clear_for_cell(key)
  B.span[key] = nil
end

local function free_buffer_slots(B)
  for id, n in pairs(B.cells) do
    for k = 1, n do free_slot(B, slot_key(B.buf, id, k)) end
  end
  B.cells = {}
  for key in pairs(B.span) do free_slot(B, key) end
end

local function buffer_state(nb)
  local buf = nb.buf
  local B = S.bufs[buf]
  if not B then
    B = { buf = buf, tick = 0, has = {}, def_src = {}, def_idx = {}, prefix = {}, cells = {}, span = {} }
    S.bufs[buf] = B
  end
  B.nb = nb
  return B
end

-- Is any line of the image of `key` in a window, with one line of margin?
-- Without this the Neovim 0.11 heal would place every formula of the
-- notebook again once a second.
local function on_screen(buf, key)
  local B = S.bufs[buf]
  local sp = B and B.span[key]
  if not sp then return false end
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    local top, bot = vim.fn.line("w0", w) - 2, vim.fn.line("w$", w)
    if sp[2] >= top and sp[1] <= bot then return true end
  end
  return false
end

-- ── config ──────────────────────────────────────────────────────────────

local function whole_in(v, lo, hi)
  return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

local function setup_autocmds()
  local group = vim.api.nvim_create_augroup("jupynvim_mathimage", { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "UIEnter", "FocusGained" }, {
    group = group,
    callback = function() pcall(M.refresh_cell_px) end,
  })
  -- the ink colour is read in begin: a render picks the new one up
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      vim.schedule(function() if S.lib == "ok" then refresh_all() end end)
    end,
  })
end

-- setup({ math = ... }): opts is a table, nil, or false (false is renderer =
-- "text"). Every bad entry is named in one warning and its default used.
-- Loads nothing; a library found missing before is asked for again.
function M.setup(opts)
  local cfg = { renderer = "auto", scale = 1.0, align = "left", cell_px = nil }
  local bad = {}
  if opts == false then
    cfg.renderer = "text"
  elseif opts ~= nil and type(opts) ~= "table" then
    bad[#bad + 1] = "the setting (a table is wanted)"
  elseif type(opts) == "table" then
    local keys = {}
    for k in pairs(opts) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local v = opts[k]
      if k == "renderer" then
        if type(v) == "string" and RENDERERS[v] then cfg.renderer = v
        else bad[#bad + 1] = 'renderer (one of "auto", "image", "text")' end
      elseif k == "scale" then
        if type(v) == "number" and v >= 0.5 and v <= 3 then cfg.scale = v
        else bad[#bad + 1] = "scale (a number from 0.5 to 3)" end
      elseif k == "align" then
        if type(v) == "string" and ALIGNS[v] then cfg.align = v
        else bad[#bad + 1] = 'align ("left" or "center")' end
      elseif k == "cell_px" then
        if v == false then
          -- unset: ask the terminal
        elseif type(v) == "table" and whole_in(v.w, 4, 256) and whole_in(v.h, 4, 512) then
          cfg.cell_px = { w = v.w, h = v.h }
        else
          bad[#bad + 1] = "cell_px ({ w = 4..256, h = 4..512 }, whole numbers)"
        end
      else
        bad[#bad + 1] = ("%s (not a math setting)"):format(tostring(k))
      end
    end
  end
  if #bad > 0 then
    vim.notify("jupynvim: math: ignored " .. table.concat(bad, ", "), vim.log.levels.WARN)
  end
  local a, b = S.cfg.cell_px, cfg.cell_px
  local cell_changed = (a == nil) ~= (b == nil) or (a and b and (a.w ~= b.w or a.h ~= b.h))
  S.cfg = cfg
  -- measured again by the next render that shows images
  if cell_changed then S.cell = nil end
  if S.lib == "off" then S.lib = "unasked" end
  setup_autocmds()
end

-- ── terminal cell size ──────────────────────────────────────────────────

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- the four numbers of a MATH_CELL answer (library text, so patterns are fine)
local function parse_cell(out)
  if type(out) ~= "string" or out:sub(1, 6) ~= "JNC 1\n" then return nil end
  local t = {}
  for _, k in ipairs({ "cols", "rows", "xpixel", "ypixel" }) do
    t[k] = tonumber(out:match("\n" .. k .. " (%d+)\n"))
    if not t[k] then return nil end
  end
  return t
end

-- Asks the terminal for its cell size again (VimResized, UIEnter,
-- FocusGained). Does nothing until the library is loaded, so it never opens
-- it on the UI thread. Refreshes the notebooks when the size changed; the
-- first measurement only stores it.
function M.refresh_cell_px()
  if S.lib ~= "ok" then return end
  local w, h, source
  local cp = S.cfg.cell_px
  if cp then
    w, h, source = cp.w, cp.h, "config"
  else
    local N = native()
    local st = N.status and N.status()
    if type(st) == "table" and st.state == "ok" and N.KIND and N.KIND.MATH_CELL then
      local okc, ok, out = pcall(function() return N.call(N.KIND.MATH_CELL, "") end)
      local t = okc and ok and parse_cell(out)
      if t and t.cols > 0 and t.rows > 0 and t.xpixel > 0 and t.ypixel > 0 then
        w = clamp(math.floor(t.xpixel / t.cols + 0.5), 4, 256)
        h = clamp(math.floor(t.ypixel / t.rows + 0.5), 4, 512)
        source = "terminal"
      end
    end
    if not w then w, h, source = M._nominal.w, M._nominal.h, "nominal" end
  end
  local old = S.cell
  S.cell = { w = w, h = h, source = source }
  if old and (old.w ~= w or old.h ~= h) then refresh_all() end
end

-- ── the library ─────────────────────────────────────────────────────────

-- what the loader says about the library now ("ok", "missing", ...), or nil
local function loader_state()
  local N = native()
  local ok, st = pcall(function() return N.status and N.status() end)
  return ok and type(st) == "table" and st.state or nil
end

-- Opened away from the UI thread: the answer comes on the main loop.
local function ask_library()
  S.lib = "wait"
  local N = native()
  local okw = pcall(N.when_ready, function(ok)
    local good = false
    if ok then
      local okk, sup = pcall(function()
        return N.KIND ~= nil and N.KIND.MATH ~= nil
          and N.lib().jnv_kind_supported(N.KIND.MATH) == 1
      end)
      good = okk and sup == true
    end
    S.lib = good and "ok" or "off"
    S.lib_state = loader_state()
    if good then
      pcall(M.refresh_cell_px)
      refresh_all()
    end
  end)
  if not okw then
    S.lib = "off"
    S.lib_state = loader_state()
  end
end

-- Why images are off for a render, or nil. ask: start opening the library
-- when nobody has asked yet, or when it was off and the loader's state has
-- changed since (an install found it, say) (begin); status() never does.
local function inactive(ask)
  if S.cfg.renderer == "text" then return 'math.renderer is "text"' end
  local okc, cfg = pcall(function() return require("jupynvim").config end)
  local ir = okc and type(cfg) == "table" and cfg.image_renderer or nil
  if ir ~= "placeholder" then return 'image_renderer is not "placeholder"' end
  if S.cfg.renderer == "auto" then
    if not Image.supported() then return "the terminal is not kitty or Ghostty" end
    if vim.api.nvim_ui_send == nil then return "Neovim 0.11 (math.renderer = \"image\" turns images on)" end
  end
  if S.lib == "off" and ask and loader_state() ~= S.lib_state then S.lib = "unasked" end
  if S.lib == "unasked" then
    if not ask then return "libjupynvim has not been asked for yet" end
    ask_library()
  end
  if S.lib == "wait" then return "libjupynvim is still loading" end
  if S.lib ~= "ok" then return "libjupynvim with math support is not loaded" end
  return nil
end

-- ── colour, variant, prelude ────────────────────────────────────────────

local function fg_hex()
  for _, name in ipairs({ "JupynvimMathImage", "JupynvimMdMathBlock", "Normal" }) do
    local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false, create = false })
    if ok and type(h) == "table" and type(h.fg) == "number" then
      return ("#%06x"):format(h.fg % 0x1000000)
    end
  end
  return vim.o.background == "light" and "#24292e" or "#d0d0d0"
end

local function cancel_jobs()
  local N = native()
  for id in pairs(S.jobs) do pcall(N.cancel, id) end
  S.jobs = {}
  S.inflight = 0
end

local function empty_cache()
  S.cache = {}
  S.n = 0
  S.bytes = 0
  S.dry = nil
end

-- A new colour, cell size or scale: every result is for the old one. The
-- results of the dropped jobs find no entry in S.jobs and are ignored; each
-- slot keeps its old image until the new one replaces it.
local function switch_variant(vkey)
  cancel_jobs()
  empty_cache()
  S.vkey = vkey
end

-- Needles for "this cell may define macros", plain finds.
local DEF = { "\\newcommand", "\\renewcommand", "\\providecommand", "\\DeclareMathOperator",
              "\\def\\", "\\gdef\\", "\\let\\" }
local function may_define(src)
  for _, needle in ipairs(DEF) do
    if src:find(needle, 1, true) then return true end
  end
  return false
end

-- A cell's key, for its slots and its memo: unique in one render, since two
-- cells that shared one would take turns in the same image slots. Its id
-- when that is a string no cell above took; else "#<index>", with one more
-- "#" for as long as that is taken too. An id that is not a string counts
-- as absent.
local function fallback_key(taken, idx)
  local k = "#" .. tostring(idx)
  while taken[k] do k = k .. "#" end
  return k
end

-- The keys of the markdown cells (seen: the set; keys and at: by index),
-- and the sources of the cells that may define macros, in order: the first
-- MAX_DEF_CELLS of them while they come to at most MAX_PRELUDE bytes
-- together; the ones after are left out (those above keep working). The
-- cell being edited keeps the source it had when editing started: a
-- keystroke in a macro cell must not typeset every formula below it again.
local function scan_cells(B, nb, edit_idx)
  local seen, keys, at, list, idxs = {}, {}, {}, {}, {}
  local size, open = 0, true
  for i, cell in ipairs(nb.cells or {}) do
    if type(cell) == "table" and cell.cell_type == "markdown" then
      local id = cell.id
      local key
      if type(id) == "string" and not seen[id] then key = id else key = fallback_key(seen, i) end
      seen[key] = true
      keys[i], at[i] = key, cell
      local src = cell.source
      if type(src) ~= "string" then src = "" end
      local memo = B.has[key]
      if not memo or (memo.src ~= src and i ~= edit_idx) then
        memo = { src = src, has = may_define(src) }
        B.has[key] = memo
      end
      if memo.has and open then
        local add = #memo.src + (#list > 0 and 1 or 0)
        if #list < MAX_DEF_CELLS and size + add <= MAX_PRELUDE then
          list[#list + 1] = memo.src
          idxs[#idxs + 1] = i
          size = size + add
        else
          open = false
        end
      end
    end
  end
  local same = #list == #B.def_src
  if same then
    for k = 1, #list do
      if list[k] ~= B.def_src[k] then same = false; break end
    end
  end
  if not same then
    B.def_src = list
    B.prefix = {}
  end
  B.def_idx = idxs
  return seen, keys, at
end

-- The raw source of every collected macro-defining cell from the top down
-- to and including cell idx, joined with "\n" (the library takes only the
-- definitions out of it). "" when there is none.
local function prelude_for(B, idx)
  -- the number of collected cells at or above idx (def_idx is ascending)
  local lo, hi = 0, #B.def_idx
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if B.def_idx[mid] <= idx then lo = mid else hi = mid - 1 end
  end
  local k = lo
  if k == 0 then return "" end
  local p = B.prefix[k]
  if not p then
    p = table.concat(B.def_src, "\n", 1, k)
    if #p > MAX_PRELUDE then p = "" end
    B.prefix[k] = p
  end
  return p
end

-- ── the cache ───────────────────────────────────────────────────────────

-- F.bytes and S.bytes after F's results changed
local function account(F)
  local b = F.nat and #F.nat.b64 or 0
  for _, f in pairs(F.fit) do
    if f.b64 then b = b + #f.b64 end
  end
  S.bytes = S.bytes + b - (F.bytes or 0)
  F.bytes = b
end

local function has_pending(F)
  for _, f in pairs(F.fit) do
    if f.pending then return true end
  end
  return false
end

-- some notebook's latest render showed it or asked for it
local function in_use(F)
  for buf, t in pairs(F.users) do
    local B = S.bufs[buf]
    if B and B.tick == t then return true end
  end
  return false
end

local function drop_record(F)
  local P = S.cache[F.pre]
  if P and P[F.tex] == F then
    P[F.tex] = nil
    if next(P) == nil then S.cache[F.pre] = nil end
    S.n = S.n - 1
    S.bytes = S.bytes - (F.bytes or 0)
  end
end

-- Drops the least recently used records that no notebook's latest render
-- uses and that wait for no job, down to three quarters of CACHE_MAX and,
-- with `need` bytes more, of the byte budget. A scan that leaves the cache
-- over a bound is remembered, and the next one waits until the cache
-- changes size (strict: or another render may have stopped using a record).
local function evict(need, strict)
  need = need or 0
  local L = M._limits
  if S.n <= CACHE_MAX and S.bytes + need <= L.cache_bytes then return end
  local d = S.dry
  if d and d.n == S.n and d.bytes == S.bytes and (not strict or d.tick == S.tick) then return end
  M.stats.evict_scans = M.stats.evict_scans + 1
  local list = {}
  for _, P in pairs(S.cache) do
    for _, F in pairs(P) do
      if not in_use(F) and not has_pending(F) then list[#list + 1] = F end
    end
  end
  table.sort(list, function(a, b) return (a.used or 0) < (b.used or 0) end)
  local n_to = math.floor(CACHE_MAX * 3 / 4)
  local b_to = math.floor(L.cache_bytes * 3 / 4) - need
  for _, F in ipairs(list) do
    if S.n <= n_to and S.bytes <= b_to then break end
    drop_record(F)
  end
  if S.n > CACHE_MAX or S.bytes + need > L.cache_bytes then
    S.dry = { n = S.n, bytes = S.bytes, tick = S.tick }
  else
    S.dry = nil
  end
end

-- ── jobs ────────────────────────────────────────────────────────────────

local function drop_fit(F, avail)
  F.fit[avail] = nil
  for i = #F.fit_order, 1, -1 do
    if F.fit_order[i] == avail then table.remove(F.fit_order, i) end
  end
end

-- at most FIT_MAX widths, the oldest dropped first, never a pending one
local function trim_fit(F)
  local i = 1
  while #F.fit_order > FIT_MAX and i <= #F.fit_order do
    local a = F.fit_order[i]
    local f = F.fit[a]
    if f and f.pending then
      i = i + 1
    else
      F.fit[a] = nil
      table.remove(F.fit_order, i)
    end
  end
end

-- Keeps R for F at width avail, inside the byte budget: records nobody's
-- latest render uses go first, oldest first. When that does not make room,
-- R is refused as a size failure at this width (another width, or room made
-- by a notebook that goes away, can still take one). False when refused.
local function store(F, avail, R)
  local L = M._limits
  local need = #R.b64
  if S.bytes + need > L.cache_bytes then evict(need, true) end
  if S.bytes + need > L.cache_bytes then
    F.fit[avail] = { err = "math: size: image budget", budget = true }
    trim_fit(F)
    return false
  end
  if R.shrunk then
    F.fit[avail] = R
    trim_fit(F)
  else
    -- its natural size: valid for every width it fits in
    F.nat = R
    drop_fit(F, avail)
  end
  return true
end

-- ASCII digits only, at most 9 of them
local function uint(s)
  if type(s) ~= "string" or #s == 0 or #s > 9 then return nil end
  for i = 1, #s do
    local b = s:byte(i)
    if b < 48 or b > 57 then return nil end
  end
  return tonumber(s)
end

local function two(s)
  if type(s) ~= "string" then return nil end
  local sp = s:find(" ", 1, true)
  if not sp then return nil end
  local a, b = uint(s:sub(1, sp - 1)), uint(s:sub(sp + 1))
  if a and b then return a, b end
  return nil
end

-- A result is used only when the library's answer is whole and agrees with
-- what was asked; anything else is an error, never drawn. Plain finds on
-- the head; the base64 body is only measured (before it is copied) and
-- checked by image.lua. Nil, why and a class ("size" or "internal") when it
-- is not used.
local function parse_response(out, j)
  if type(out) ~= "string" then return nil, "no answer", "internal" end
  if out:sub(1, 6) ~= "JNM 1\n" then return nil, "the answer does not start with JNM 1", "internal" end
  local stop = out:find("\n\n", 1, true)
  if not stop then return nil, "the answer has no end of its head", "internal" end
  local f = {}
  local pos = 7
  while pos <= stop do
    local nl = out:find("\n", pos, true)
    local line = out:sub(pos, nl - 1)
    pos = nl + 1
    local sp = line:find(" ", 1, true)
    if not sp then return nil, "a head line without a value", "internal" end
    local key = line:sub(1, sp - 1)
    if f[key] ~= nil then return nil, "the head names " .. key .. " twice", "internal" end
    f[key] = line:sub(sp + 1)
  end
  local w, h = two(f.size)
  local cols, rows = two(f.grid)
  local n = uint(f.png)
  if not (w and cols and n and uint(f.base) and f.em and f.em ~= ""
          and (f.shrunk == "0" or f.shrunk == "1")) then
    return nil, "the head misses a field", "internal"
  end
  local most, len = M._limits.image_b64, #out - (stop + 1)
  if n > most or len > most then
    return nil, ("the image is %d bytes of base64, at most %d"):format(math.max(n, len), most), "size"
  end
  if rows < 1 or rows > MAX_ROWS or cols < 1 or cols > j.avail then
    return nil, ("a grid of %dx%d for %d columns"):format(cols, rows, j.avail), "internal"
  end
  if w ~= cols * j.cw or h ~= rows * j.ch then
    return nil, ("%dx%d pixels for %dx%d cells of %dx%d"):format(w, h, cols, rows, j.cw, j.ch), "internal"
  end
  local b64 = out:sub(stop + 2)
  if n <= 0 or #b64 ~= n then return nil, "the image is not as long as the head says", "internal" end
  if not Image._b64_ok(b64) then return nil, "the image is not base64", "internal" end
  S.serial = S.serial + 1
  return { id = "jm" .. S.serial, b64 = b64, rows = rows, cols = cols, shrunk = f.shrunk == "1" }
end

local function done(id, ok, out, status)
  local j = S.jobs[id]
  if not j then return end      -- dropped: another variant, reset, wipe or timeout
  S.jobs[id] = nil
  S.inflight = math.max(0, S.inflight - 1)
  local F = j.F
  local N = native()
  local cancelled = N.STATUS and N.STATUS.CANCELLED
  if ok then
    local R, why, class = parse_response(out, j)
    if R then
      if store(F, j.avail, R) then
        M.stats.done = M.stats.done + 1
      else
        M.stats.budget = M.stats.budget + 1
        M.stats.fails = M.stats.fails + 1
        log.debug(("math image: math: size: image budget, %d bytes (%s)"):format(#R.b64, j.tex))
      end
    elseif class == "size" then
      F.fit[j.avail] = { err = "math: size: " .. why }   -- another width may work
      M.stats.fails = M.stats.fails + 1
      log.debug(("math image: math: size: %s (%s)"):format(why, j.tex))
    else
      F.err = "math: internal: " .. why
      drop_fit(F, j.avail)
      M.stats.fails = M.stats.fails + 1
      log.debug(("math image: %s (%s)"):format(Image.log_text(F.err, 200), j.tex))
    end
  elseif cancelled ~= nil and status == cancelled then
    drop_fit(F, j.avail)        -- a later render asks again
    M.stats.cancels = M.stats.cancels + 1
  else
    local msg = tostring(out)
    -- the class, from the library's message (not notebook text)
    if msg:match("^math: (%a+):") == "size" then
      F.fit[j.avail] = { err = msg }      -- another width may work
    else
      F.err = msg                         -- final for this variant and prelude
      drop_fit(F, j.avail)
    end
    M.stats.fails = M.stats.fails + 1
    log.debug(("math image: %s (%s)"):format(Image.log_text(msg, 200), j.tex))
  end
  account(F)
  local waiters = F.waiters
  F.waiters = {}
  refresh_set(waiters)
  slots_freed()
end

-- With every job slot taken the block waits: its buffer is noted, and the
-- next completion (or timeout) renders it again.
local function submit(F, tex, prelude, avail, rctx, spec)
  if S.inflight >= MAX_INFLIGHT then
    S.starved[rctx.buf] = true
    return
  end
  local N = native()
  local cw, ch = S.cell.w, S.cell.h
  local req = ("JNM 1\nfg %s\ncell %d %d\nscale %s\nmax %d %d\npre %d\ntex %d\n\n"):format(
    rctx.fg, cw, ch, tostring(S.cfg.scale), avail, MAX_ROWS, #prelude, #tex)
    .. prelude .. tex
  local visible = rctx.top ~= nil and spec.last >= rctx.top - 50 and spec.first <= rctx.bot + 50
  -- declared first: the callback closes over it (it runs from the pump on
  -- the main loop, never before submit returns)
  local id, why
  local okc, r1, r2 = pcall(N.submit, N.KIND.MATH, req, { priority = visible and "visible" or "normal" },
    function(ok, out, status) done(id, ok, out, status) end)
  if okc then id, why = r1, r2 else why = r1 end
  if not id then
    F.err = "submit: " .. tostring(why)
    return
  end
  F.fit[avail] = { pending = id }
  F.fit_order[#F.fit_order + 1] = avail
  trim_fit(F)
  account(F)
  S.jobs[id] = { F = F, avail = avail, cw = cw, ch = ch, tex = Image.log_text(tex), t0 = M._now() }
  S.inflight = S.inflight + 1
  M.stats.submits = M.stats.submits + 1
end

-- A job in flight for longer than JOB_MS is cancelled, and its formula
-- fails for this variant: a slow formula, or a library that never answers,
-- cannot hold a job slot for good. Looked for from begin, at most once per
-- WATCH_MS. The notebooks that waited for it, or for a slot, render again
-- (but `except`, the one being rendered).
local function watchdog(except)
  if next(S.jobs) == nil then return end
  local now = M._now()
  if S.watch_at and now - S.watch_at < WATCH_MS then return end
  S.watch_at = now
  local N, waiters, any = nil, {}, false
  for id, j in pairs(S.jobs) do
    if now - j.t0 > JOB_MS then
      N = N or native()
      pcall(N.cancel, id)
      S.jobs[id] = nil
      S.inflight = math.max(0, S.inflight - 1)
      local F = j.F
      F.err = "math: internal: timed out"
      drop_fit(F, j.avail)
      account(F)
      for buf in pairs(F.waiters) do waiters[buf] = true end
      F.waiters = {}
      M.stats.timeouts = M.stats.timeouts + 1
      M.stats.fails = M.stats.fails + 1
      log.debug(("math image: %s after %d ms (%s)"):format(F.err, math.floor(now - j.t0), j.tex))
      any = true
    end
  end
  if any then
    refresh_set(waiters, except)
    slots_freed(except)
  end
end

-- ── one block ───────────────────────────────────────────────────────────

-- ctx.math_block of one cell: an image for the block, or nil for its text
-- rendering (pending, failed, too wide, or held back to a later render).
local function math_block(cctx, tex, spec)
  cctx.n = cctx.n + 1                                  -- the block's ordinal: its slot
  local rctx = cctx.rctx
  local B = rctx.B
  local key = slot_key(rctx.buf, cctx.cell_id, cctx.n)
  M.stats.blocks = M.stats.blocks + 1
  -- one block per slot in a render: a second one is text and touches nothing
  if rctx.used[key] then return nil end
  rctx.used[key] = true
  if type(tex) ~= "string" or type(spec) ~= "table" then free_slot(B, key); return nil end
  local first = tonumber(spec.first) or 0
  local last = tonumber(spec.last) or first
  local avail = math.min(MAX_COLS, math.floor((tonumber(spec.width) or 80) - (tonumber(spec.indent) or 0)))
  if #tex > MAX_TEX or avail < 1 then free_slot(B, key); return nil end

  local prelude = cctx.prelude
  local P = S.cache[prelude]
  if not P then P = {}; S.cache[prelude] = P end
  local F = P[tex]
  if not F then
    F = { fit = {}, fit_order = {}, waiters = {}, users = {}, bytes = 0, pre = prelude, tex = tex }
    P[tex] = F
    S.n = S.n + 1
  end
  F.used = S.tick
  F.users[rctx.buf] = S.tick

  local R
  if F.err then
    free_slot(B, key)                                  -- failed for good: text, no stale image
    return nil
  elseif F.nat and F.nat.cols <= avail then
    R = F.nat                                          -- the natural size fits this width
  else
    local f = F.fit[avail]
    if f == nil then
      submit(F, tex, prelude, avail, rctx, { first = first, last = last })
      if F.err then free_slot(B, key); return nil end
      local g = F.fit[avail]
      if g and g.pending then F.waiters[rctx.buf] = true end
      return nil                                       -- pending: the old image stays in its slot
    elseif f.pending then
      F.waiters[rctx.buf] = true
      return nil
    elseif f.err then
      free_slot(B, key)                                -- too wide or too large for this width
      return nil
    end
    R = f
  end

  M.stats.hits = M.stats.hits + 1
  local bottom = last + math.max(0, R.rows - (last - first + 1))
  local sp = B.span[key]
  if sp then sp[1], sp[2] = first, bottom else B.span[key] = { first, bottom } end
  if not Image.has_visible_probe(key) then
    local buf = rctx.buf
    Image.set_visible_probe(key, function() return on_screen(buf, key) end)
  end
  local sent = false
  if not Image.is_cached(key, R.b64, "placeholder", R.id) then
    -- a notebook's first transmits, over renders: at most a count and a
    -- number of bytes in one, but always one, so it gets there
    local size = #R.b64
    if rctx.tx >= MAX_TX_PER_RENDER or (rctx.tx > 0 and rctx.txb + size > M._limits.render_bytes) then
      M.stats.deferred = M.stats.deferred + 1
      rctx.deferred = true
      return nil
    end
    rctx.tx = rctx.tx + 1
    rctx.txb = rctx.txb + size
    M.stats.transmits = M.stats.transmits + 1
    local sync, nb = true, rctx.nb
    Image.ensure_transmitted(key, R.b64, function(id)
      if id and not sync then refresh(nb) end          -- it landed after this render: draw it
    end, { renderer = "placeholder", rows = R.rows, cols = R.cols, content_id = R.id })
    sync = false
    sent = true
  end
  local ph = Image.placeholder_rows(key, R.id)
  if not ph then return nil end                        -- not there yet (the callback refreshes)
  if sent then rctx.landed[#rctx.landed + 1] = { key, R.id } end
  return { rows = R.rows, cols = R.cols, hl = ph.hl, text = ph.rows }
end

-- ── the render API ──────────────────────────────────────────────────────

-- Once per render, before the cell loop. nb: the notebook; win: the window
-- the render measures; edit_idx: the index of the cell in the boxed editor,
-- or nil. A render context, or nil when math images are off for this render
-- (then every block is text and the buffer's slots are freed).
function M.begin(nb, win, edit_idx)
  S.tick = S.tick + 1
  local B = buffer_state(nb)
  watchdog(nb.buf)
  S.starved[nb.buf] = nil                              -- this render asks for what it can
  local why = inactive(true)
  if not why and S.cell == nil then
    M.refresh_cell_px()
    if S.cell == nil then why = "no cell size" end
  end
  S.why = why
  if why then
    free_buffer_slots(B)
    return nil
  end
  -- a bare :hi clear wiped the placeholders' highlight groups: set again
  Image.check_hl()
  local fg = fg_hex()
  local vkey = ("%s|%dx%d|%s"):format(fg, S.cell.w, S.cell.h, tostring(S.cfg.scale))
  if vkey ~= S.vkey then switch_variant(vkey) end
  local seen, keys, at = scan_cells(B, nb, edit_idx)
  local top, bot
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == nb.buf then
    top = vim.fn.line("w0", win) - 1
    bot = vim.fn.line("w$", win) - 1
  end
  B.tick = S.tick
  return { nb = nb, buf = nb.buf, B = B, fg = fg, seen = seen, keys = keys, at = at, used = {},
           top = top, bot = bot, tx = 0, txb = 0, deferred = false, landed = {} }
end

-- For one markdown cell that is rendered (not edited); idx is its index in
-- nb.cells. The ctx for markdown.render.
function M.cell(rctx, cell, idx)
  idx = tonumber(idx) or 0
  local key = rctx.keys[idx]
  if key == nil or rctx.at[idx] ~= cell then
    -- not the cell begin saw at idx: a key of its own all the same
    key = fallback_key(rctx.seen, idx)
    rctx.seen[key] = true
  end
  local cctx = {
    align = S.cfg.align, overlay = M._overlay, n = 0, rctx = rctx,
    cell_id = key, prelude = prelude_for(rctx.B, idx),
  }
  cctx.math_block = function(tex, spec) return math_block(cctx, tex, spec) end
  return cctx
end

-- After markdown.render of that cell: frees the slots above its block count.
function M.cell_done(cctx)
  local B = cctx.rctx.B
  local id = cctx.cell_id
  for k = cctx.n + 1, B.cells[id] or 0 do free_slot(B, slot_key(B.buf, id, k)) end
  B.cells[id] = cctx.n > 0 and cctx.n or nil
end

-- After the cell loop: frees the slots of cells that are gone or no longer
-- markdown, evicts old cache records, and when transmits were held back,
-- asks for another render, but only when this one put an image on the
-- terminal that is still there: a render that cannot make progress does
-- not repeat itself.
function M.finish(rctx)
  local B = rctx.B
  for id, n in pairs(B.cells) do
    if not rctx.seen[id] then
      for k = 1, n do free_slot(B, slot_key(B.buf, id, k)) end
      B.cells[id] = nil
    end
  end
  for id in pairs(B.has) do
    if not rctx.seen[id] then B.has[id] = nil end
  end
  evict()
  if rctx.deferred then
    for _, l in ipairs(rctx.landed) do
      if Image.is_cached(l[1], nil, "placeholder", l[2]) then
        later_refresh(rctx.nb)
        break
      end
    end
  end
end

-- BufWipeout: frees the buffer's slots and forgets it. The jobs that no
-- other notebook waits for are cancelled, and the records no other notebook
-- used are dropped; with no notebook left, the whole cache goes.
function M.forget_buffer(buf)
  local B = S.bufs[buf]
  if B then free_buffer_slots(B) end
  S.bufs[buf] = nil
  later[buf] = nil
  S.starved[buf] = nil
  if next(S.bufs) == nil then
    cancel_jobs()
    empty_cache()
    return
  end
  local N = native()
  local freed = false
  for id, j in pairs(S.jobs) do
    local F = j.F
    F.waiters[buf] = nil
    F.users[buf] = nil
    if next(F.users) == nil and next(F.waiters) == nil then
      pcall(N.cancel, id)
      S.jobs[id] = nil
      S.inflight = math.max(0, S.inflight - 1)
      drop_fit(F, j.avail)
      freed = true
    end
  end
  local dropped = false
  for _, P in pairs(S.cache) do
    for _, F in pairs(P) do
      F.waiters[buf] = nil
      F.users[buf] = nil
      if next(F.users) == nil and not has_pending(F) then
        drop_record(F)
        dropped = true
      end
    end
  end
  if dropped then
    -- room again: what the byte budget refused may fit now (asked once more)
    S.dry = nil
    for _, P in pairs(S.cache) do
      for _, F in pairs(P) do
        for a, f in pairs(F.fit) do
          if f.budget then drop_fit(F, a) end
        end
      end
    end
  end
  if freed then slots_freed() end
end

-- Frees every slot of every buffer, cancels every job and empties the cache
-- (mode switches, tests). The cell size is measured again, and a library
-- found missing before is asked for again.
function M.reset()
  for _, B in pairs(S.bufs) do free_buffer_slots(B) end
  cancel_jobs()
  empty_cache()
  S.starved = {}
  S.vkey = nil
  S.cell = nil
  if S.lib == "off" then S.lib = "unasked" end
end

-- For :checkhealth and tests. Never loads the library.
function M.status()
  local pending = 0
  for _ in pairs(S.jobs) do pending = pending + 1 end
  local slots = 0
  for _, B in pairs(S.bufs) do
    for _, n in pairs(B.cells) do slots = slots + n end
  end
  local why = inactive(false)
  local cell = S.cell
  if not cell and S.cfg.cell_px then
    cell = { w = S.cfg.cell_px.w, h = S.cfg.cell_px.h, source = "config" }
  end
  return {
    renderer = S.cfg.renderer,
    active = why == nil,
    why = why,
    lib = S.lib,
    cell = cell and { w = cell.w, h = cell.h, source = cell.source } or nil,
    fg = fg_hex(),
    records = S.n,
    bytes = S.bytes,
    pending = pending,
    slots = slots,
    stats = M.stats,
  }
end

return M
