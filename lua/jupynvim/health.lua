-- :checkhealth jupynvim
local M = {}

local WITHOUT = "; everything works without it"

-- The in-process library. Checking it loads it, as its first use would,
-- with the first open away from this Neovim first (macOS): this is what the
-- loader's notice says to run, often in a fresh session, so a library that
-- kills the process that loads it, or whose load never returns, is
-- reported here and never loaded into the editor. It never asks for an
-- install. The advice is the loader's own (status().fix), the same text its
-- one notice gives: for a file JUPYNVIM_NATIVE or native.path named, the
-- setting; for the plugin's own place, the install or the rebuild.
function M._library(h, J, Install)
  h.start("jupynvim: in-process library (libjupynvim)")
  local okn, N = pcall(require, "jupynvim.native")
  if not okn then
    h.warn("libjupynvim: the loader failed: " .. tostring(N) .. WITHOUT)
    return
  end
  N._load_waiting()
  local st = N.status()
  if st.state == "ok" then
    local n = tonumber(st.workers) or 0
    h.ok(("libjupynvim v%s (ABI %s) at %s, %d worker thread%s"):format(
      tostring(st.version), tostring(st.abi), tostring(st.path), n, n == 1 and "" or "s"))
  elseif st.state == "missing" and not st.path then
    h.warn("libjupynvim " .. tostring(st.reason) .. WITHOUT)
  elseif st.state == "missing" then
    local msg = "libjupynvim is not installed at " .. st.path .. WITHOUT
    if st.source ~= "plugin" or Install._lib_target() then
      h.warn(msg, { st.fix })
    else
      h.info("no libjupynvim prebuilt is made for this platform; cargo build --release in core/ builds it" .. WITHOUT)
    end
  elseif st.state == "disabled" then
    h.info("libjupynvim is " .. tostring(st.reason))
  elseif st.state == "unsupported" then
    h.info("libjupynvim " .. tostring(st.reason) .. WITHOUT)
  elseif st.state == "mismatch" or st.state == "error" then
    h.warn("libjupynvim " .. tostring(st.reason), { st.fix })
  elseif st.state == "unloaded" then
    h.info("libjupynvim is still being opened for the first time; run :checkhealth jupynvim again")
  else
    h.info(("libjupynvim is %s%s"):format(tostring(st.state), st.reason and (": " .. st.reason) or ""))
  end
end

-- The palette (lua/jupynvim/palette.lua): the tokens derived from the
-- colorscheme in use, with what is known right now, and the canvas the terminal
-- must tell. Its own section, after the library's. It derives synchronously
-- from the highlight groups and the terminal's last answer, makes no
-- notice, loads nothing that is not loaded, and changes nothing the editor
-- draws.
function M._palette(h)
  h.start("jupynvim: palette")
  local WITHOUT = "palette: needs libjupynvim; without it everything keeps today's colors"
  -- only a library that is up: the loader's own open of it was reported above
  local okn, N = pcall(require, "jupynvim.native")
  local state = okn and N.status().state or nil
  if state ~= "ok" then
    if state == "unloaded" then
      -- the library section above says the same: it is not an absent library
      h.info("palette: libjupynvim is still being opened for the first time; run :checkhealth jupynvim again")
    else
      h.info(WITHOUT)
    end
    return
  end
  local okp, P = pcall(require, "jupynvim.palette")
  if not okp then
    h.warn("palette: the module failed to load: " .. tostring(P))
    return
  end
  local r, err = P._derive_now_for_health()
  if not r then
    -- the library is up: it is the derivation that failed
    h.info("palette: could not be derived (" .. tostring(err) .. "); everything keeps today's colors")
    return
  end
  local info, tokens = r.info, r.tokens
  local name = info.colors_name or "no colorscheme"
  h.ok(("palette: %d tokens from %s (background %s), theme %s"):format(#P.TOKENS, name, tostring(info.kind),
    tostring(info.theme_id)))
  local canvas = tokens.canvas
  if info.canvas_source == "Normal.bg" then
    h.ok(("canvas %s from Normal.bg"):format(canvas))
  elseif info.canvas_source == "terminal" then
    h.ok(("canvas %s from the terminal (OSC 11)"):format(canvas))
  elseif info.canvas_source == "override" then
    h.info(("canvas %s set in setup()"):format(canvas))
  else
    h.warn(("canvas %s is a guess: %s"):format(canvas, tostring(r.guess)),
      { "Set palette = { canvas = \"#rrggbb\" } in setup() to your terminal's background" })
  end
  if info.port then
    h.info(("known VS Code port: %s (%s)"):format(info.port_label, info.port_source))
  else
    h.info(("no known VS Code port for %s: Neovim groups and VS Code's formulas"):format(
      info.colors_name or "an unnamed colorscheme"))
  end
  if #r.overrides > 0 then h.info("overrides: " .. table.concat(r.overrides, ", ")) end
  for _, what in ipairs(r.ignored) do h.warn("palette: ignored " .. what) end
end

-- The ink colour a math image would have: "#rrggbb", as the math module
-- reports it, else from the highlight groups it reads.
local function math_fg(st)
  if type(st.fg) == "string" and st.fg:match("^#%x%x%x%x%x%x$") then return st.fg end
  for _, name in ipairs({ "JupynvimMathImage", "JupynvimMdMathBlock", "Normal" }) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false, create = false })
    if ok and type(hl) == "table" and type(hl.fg) == "number" then
      return ("#%06x"):format(hl.fg % 0x1000000)
    end
  end
  return vim.o.background == "light" and "#24292e" or "#d0d0d0"
end

-- Display math shown as images (lua/jupynvim/notebook/mathimage.lua): can a
-- formula be an image here, and if not, why. Its own section, after the
-- palette's, with the palette's gate: it reports only on a library that is
-- up, and it loads nothing. Its one typeset (x^2) runs on this thread; it is
-- the only synchronous typeset the plugin makes.
function M._math(h)
  h.start("jupynvim: math images")
  local okm, MI = pcall(require, "jupynvim.notebook.mathimage")
  if not (okm and type(MI) == "table" and type(MI.status) == "function") then
    h.info("math images are not available in this version; display math shows as text")
    return
  end
  local okn, N = pcall(require, "jupynvim.native")
  local state = okn and N.status().state or nil
  if state ~= "ok" then
    if state == "unloaded" then
      h.info("math images: libjupynvim is still being opened for the first time; run :checkhealth jupynvim again")
    else
      h.info("math images: needs libjupynvim; without it math shows as text")
    end
    return
  end
  local kind = N.KIND and N.KIND.MATH
  local okk, sup = pcall(function() return kind and N.lib().jnv_kind_supported(kind) end)
  if not (kind and okk and tonumber(sup) == 1) then
    h.warn("math images: this libjupynvim cannot typeset math; math shows as text",
      { "Update the library: :JupynvimInstall, or cargo build --release in core/" })
    return
  end
  local oks, st = pcall(MI.status)
  if not (oks and type(st) == "table") then
    h.warn("math images: the module's status failed: " .. tostring(st))
    return
  end
  local renderer = st.renderer
  if renderer == "text" then
    h.info("math images are turned off (math.renderer = \"text\")")
    return
  end
  h.info(("math.renderer = %q"):format(tostring(renderer)))
  local jc = require("jupynvim").config or {}
  if jc.image_renderer ~= "placeholder" then
    h.info(("math images need image_renderer = \"placeholder\" (it is %q); math shows as text"):format(
      tostring(jc.image_renderer)))
  end
  if renderer == "auto" then
    local oki, Image = pcall(require, "jupynvim.notebook.image")
    if oki and type(Image.supported) == "function" and not Image.supported() then
      h.info("the terminal is not kitty or Ghostty, so math.renderer = \"auto\" shows math as text"
        .. " (\"image\" skips this check)")
    end
    if vim.api.nvim_ui_send == nil then
      h.info("Neovim 0.11: math.renderer = \"auto\" shows math as text on Neovim older than 0.12"
        .. " (\"image\" turns images on anyway)")
    end
  end
  -- the cell size: measured when the module has not done it yet
  if type(st.cell) ~= "table" and type(MI.refresh_cell_px) == "function" then
    pcall(MI.refresh_cell_px)
    local ok2, st2 = pcall(MI.status)
    if ok2 and type(st2) == "table" then st = st2 end
  end
  local cell = type(st.cell) == "table" and st.cell or {}
  local w, ht = tonumber(cell.w), tonumber(cell.h)
  if not (w and ht) then
    local nominal = type(MI._nominal) == "table" and MI._nominal or {}
    w, ht = tonumber(nominal.w) or 18, tonumber(nominal.h) or 40
  end
  if cell.source == "terminal" then
    h.ok(("cell %dx%d px, from the terminal"):format(w, ht))
  elseif cell.source == "config" then
    h.ok(("cell %dx%d px, from math.cell_px"):format(w, ht))
  else
    h.warn(("the terminal reports no cell size in pixels; using %dx%d"):format(w, ht),
      { "Set math.cell_px = { w = ..., h = ... } in setup()" })
  end
  -- a typeset of x^2 at that cell size
  local cfg = type(jc.math) == "table" and jc.math or {}
  local scale = tonumber(cfg.scale)
  if not (scale and scale >= 0.5 and scale <= 3) then scale = 1 end
  local tex = "x^2"
  local req = ("JNM 1\nfg %s\ncell %d %d\nscale %s\nmax %d %d\npre 0\ntex %d\n\n%s"):format(
    math_fg(st), w, ht, tostring(scale), 297, 60, #tex, tex)
  local t0 = vim.uv.hrtime()
  local okc, ok, out = pcall(N.call, kind, req)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  if okc and ok then
    local cols, rows = tostring(out):match("\ngrid (%d+) (%d+)\n")
    if cols then
      h.ok(("typeset probe: %sx%s cells in %.1f ms"):format(cols, rows, ms))
    else
      h.warn("typeset probe: the library's answer has no grid line")
    end
  else
    h.warn("typeset probe failed: " .. tostring(okc and out or ok))
  end
end

function M.check()
  local h = vim.health
  local J = require("jupynvim")
  local Install = require("jupynvim.backend.install")

  h.start("jupynvim: backend")
  if vim.fn.has("nvim-0.11") ~= 1 then h.error("Neovim 0.11 or newer is required") end
  local root = J._plugin_root()
  local want = Install.source_version(root)
  -- first, so a report names the version even when the backend is missing
  if want then
    h.info(("jupynvim v%s at %s"):format(want, root))
  else
    h.warn("no version found in " .. root .. "/core/Cargo.toml")
  end
  local cfg_path = J.config and J.config.core_path
  local local_bin = root .. "/core/target/release/jupynvim-core"
  local dev_build = Install.is_dev_build(root)
  -- the binary locate_core would use, in its order
  local bin = cfg_path
    or (vim.fn.executable(local_bin) == 1 and local_bin)
    or (vim.fn.executable("jupynvim-core") == 1 and vim.fn.exepath("jupynvim-core"))
    or local_bin
  local fix = dev_build and "Rebuild it: cargo build --release in core/" or "Run :JupynvimInstall"
  if vim.fn.executable(bin) ~= 1 then
    h.error("jupynvim-core not found at " .. bin, cfg_path and { "core_path points at no executable" } or {
      "Run :JupynvimInstall",
      "Or leave auto_install on and open a notebook: it fetches the matching release",
      "Or set core_path in setup() to a binary you built",
    })
  else
    local have, err = J._binary_version(bin)
    if not have then
      h.error(bin .. " does not run here" .. (err and err ~= "" and (": " .. err) or ""), { fix })
    elseif want and have ~= want then
      h.warn(("jupynvim-core is v%s but the plugin is v%s"):format(have, want), { fix })
    else
      h.ok(("jupynvim-core v%s at %s"):format(have, bin))
    end
  end
  h.info("auto_install: " .. tostring(not (J.config and J.config.auto_install == false)))

  M._library(h, J, Install)
  M._palette(h)
  M._math(h)

  h.start("jupynvim: installing the prebuilt")
  local tag = want and ("v" .. want)
  local targets = Install._detect_targets()
  if #targets > 0 then
    h.ok("prebuilt targets for this platform, tried in order: " .. table.concat(targets, ", "))
    for _, t in ipairs(targets) do
      local bad = tag and Install.known_bad(tag, t)
      if bad then h.warn(("the %s %s prebuilt was refused: %s"):format(tag, t, bad)) end
    end
  else
    h.warn("no prebuilt is made for this platform",
      { "Install a Rust toolchain; :JupynvimInstall builds with cargo" })
  end
  local lt = Install._lib_target()
  if lt then
    h.ok("library prebuilt for this platform: " .. lt.target)
    local bad = tag and Install.known_bad(tag, "lib-" .. lt.target)
    if bad and tostring(bad):find("^not published") then
      h.info(("the %s release publishes no library prebuilt for %s; a notebook opened a day after that was found "
        .. "asks again, and :JupynvimInstall asks now"):format(tag, lt.target))
    elseif bad then
      h.warn(("the %s library prebuilt was refused: %s"):format(tag, bad))
    end
  end
  if vim.fn.executable("curl") == 1 then h.ok("curl found") else h.error("curl not found") end
  if vim.fn.executable("shasum") == 1 or vim.fn.executable("sha256sum") == 1 then
    h.ok("shasum found, downloads are SHA256-checked")
  else
    h.warn("neither shasum nor sha256sum found: jupynvim-core downloads cannot be SHA256-checked, "
      .. "and the library prebuilt is refused")
  end
  if vim.fn.executable("cargo") == 1 then
    h.ok("cargo found, a source build is possible")
  else
    h.info("cargo not found, only needed where no prebuilt runs")
  end
end

return M
