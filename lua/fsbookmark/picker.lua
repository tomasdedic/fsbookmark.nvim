local config = require("fsbookmark.config")
local util = require("fsbookmark.util")

local M = {}

---@return table|nil
local function snacks()
  local ok, mod = pcall(require, "snacks")
  if not ok or not mod.picker then
    util.notify("snacks.nvim with the picker enabled is required for the picker", vim.log.levels.ERROR)
    return nil
  end
  return mod
end

--- Build picker items for the current prompt.
---
--- The source runs `live`, so the whole prompt arrives here as
--- `ctx.filter.search` and Snacks' own matcher sits idle with an empty pattern.
--- That is what lets `label:core` mean what `search.lua` says it means instead
--- of being fuzzy-matched as literal text — and it means the ranking below is
--- the display order, since an empty matcher pattern preserves finder order.
---@param _opts table|nil
---@param ctx table|nil
---@return table[]
local function finder(_opts, ctx)
  local fsbookmark = require("fsbookmark")
  local query = ctx and ctx.filter and ctx.filter.search or ""
  local workspace = fsbookmark.workspace()
  local items = {}

  for index, bookmark in ipairs(fsbookmark.search(query)) do
    table.insert(items, {
      idx = index,
      -- Required to be a non-nil string; filtering already happened above, so
      -- this only feeds the formatter and tie-break sorting.
      text = util.display_path(bookmark.path),
      file = bookmark.path,
      dir = bookmark.type == "directory",
      bookmark = bookmark,
      broken = fsbookmark.is_broken(bookmark),
      show_scope = workspace ~= nil,
    })
  end

  return items
end

--- Re-run the finder and keep the cursor on `path`. A scope change moves the
--- bookmark to another file, which also changes its position in the list.
---@param picker table
---@param path string
local function refind(picker, path)
  picker:find({
    on_done = function()
      if picker.closed then
        return
      end
      for item, idx in picker:iter() do
        if item.file == path then
          picker.list:view(idx)
          return
        end
      end
    end,
  })
end

--- Usable width of the picker's list window, or a sane guess.
---@param picker table|nil
---@return integer
local function list_width(picker)
  local win = picker and picker.list and picker.list.win
  if win and win:valid() then
    local ok, width = pcall(vim.api.nvim_win_get_width, win.win)
    if ok and width > 0 then
      return width
    end
  end
  return 60
end

---@param item table
---@param picker table|nil
---@return table[]
local function format(item, picker)
  local Snacks = require("snacks")
  local align = Snacks.picker.util.align
  local icons = config.options.icons
  local bookmark = item.bookmark
  local out = {}

  -- Fixed column widths overflow a narrow list and push the path off the far
  -- right, where it is invisible. Scale them instead, and never let the two
  -- columns claim more than half the row.
  local width = list_width(picker)
  local name_width = math.max(12, math.min(28, math.floor(width * 0.25)))
  local desc_width = math.max(0, math.min(34, math.floor(width * 0.28)))

  -- The scope column only appears when there is a workspace to contrast with;
  -- without one every row would carry the same marker.
  if item.show_scope then
    table.insert(out, { (icons[bookmark.scope] or icons.global) .. " ", "SnacksPickerSpecial" })
  end

  local icon = item.broken and icons.broken or icons.bookmark
  table.insert(out, { icon .. " ", item.broken and "SnacksPickerLinkBroken" or "SnacksPickerLabel" })

  local name = vim.fn.fnamemodify(bookmark.path, ":t")
  local name_hl = item.broken and "SnacksPickerPathHidden"
    or (bookmark.type == "directory" and "SnacksPickerDirectory" or "SnacksPickerFile")
  table.insert(out, { align(name, name_width, { truncate = true }), name_hl })
  table.insert(out, { " " })

  if desc_width > 0 then
    table.insert(out, { align(bookmark.description or "", desc_width, { truncate = true }), "SnacksPickerDesc" })
    table.insert(out, { " " })
  end

  for _, label in ipairs(bookmark.labels or {}) do
    table.insert(out, { label, "SnacksPickerLabel" })
    table.insert(out, { " " })
  end

  local path = util.display_path(bookmark.path)
  local used = 0
  for _, chunk in ipairs(out) do
    used = used + vim.fn.strdisplaywidth(chunk[1])
  end
  local room = width - used - 1
  if room > 4 then
    table.insert(out, { Snacks.picker.util.truncpath(path, room), "SnacksPickerPathHidden" })
  end
  return out
end

--- The Snacks source definition.
---
--- To expose `Snacks.picker.fsbookmark()`, register it as a *table* under
--- `picker.sources` — Snacks walks the sources table on setup, so a bare
--- function there raises before the picker ever opens:
---
--- ```lua
--- sources = {
---   fsbookmark = {
---     config = function(opts)
---       return require("fsbookmark.picker").source(opts)
---     end,
---   },
--- }
--- ```
---@param opts table|nil merged config to extend, when called as a source `config`
---@return table
function M.source(opts)
  local fsbookmark = require("fsbookmark")
  local keys = config.options.picker.keys

  local actions = {
    fsbookmark_edit = {
      desc = "Edit bookmark",
      action = function(picker, item)
        if not item then
          return
        end
        require("fsbookmark.edit").edit(item.bookmark.path, function()
          refind(picker, item.bookmark.path)
        end)
      end,
    },
    fsbookmark_delete = {
      desc = "Delete bookmark",
      action = function(picker, item)
        local selected = picker:selected({ fallback = true })
        for _, entry in ipairs(selected) do
          fsbookmark.remove(entry.bookmark.path)
        end
        picker.list:set_selected()
        picker:find()
      end,
    },
    fsbookmark_reload = {
      desc = "Reload bookmarks",
      action = function(picker)
        fsbookmark.load()
        picker:find()
      end,
    },
    -- One key cycles workspace -> shared -> global. A scope that is not
    -- available (shared disabled, path outside the root) is skipped.
    fsbookmark_share = {
      desc = "Cycle scope",
      action = function(picker, item)
        if not item then
          return
        end
        local order = { "workspace", "shared", "global" }
        local move = { workspace = fsbookmark.unshare, shared = fsbookmark.share, global = fsbookmark.make_global }
        local from = item.bookmark.scope
        local start = from == "shared" and 2 or from == "global" and 3 or 1
        for step = 1, #order - 1 do
          local target = order[(start + step - 1) % #order + 1]
          local bookmark = move[target](item.bookmark.path)
          if bookmark and bookmark.scope == target then
            util.notify(target .. " " .. util.display_path(bookmark.path))
            refind(picker, bookmark.path)
            return
          end
        end
        util.notify("no other scope available for " .. util.display_path(item.bookmark.path), vim.log.levels.WARN)
      end,
    },
    fsbookmark_reveal = {
      desc = "Show in explorer",
      action = function(picker, item)
        if not item then
          return
        end
        picker:close()
        local bookmark = item.bookmark
        -- Reveal the file's parent; a bookmarked directory reveals itself.
        local dir = bookmark.type == "directory" and bookmark.path or vim.fs.dirname(bookmark.path)
        require("fsbookmark.explorer").open_directory(dir)
      end,
    },
    fsbookmark_yank = {
      desc = "Copy path",
      action = function(_, item)
        if not item then
          return
        end
        vim.fn.setreg(vim.v.register or '"', item.bookmark.path)
        vim.fn.setreg("+", item.bookmark.path)
        util.notify("copied " .. item.bookmark.path)
      end,
    },
  }

  -- Single-letter keys, so they live in the list window only (normal mode);
  -- the search input keeps every letter for typing. `/` switches between the
  -- two, as in the Snacks explorer. `?` is Snacks' own help.
  local list_keys = {}
  local map = {
    edit = "fsbookmark_edit",
    delete = "fsbookmark_delete",
    reload = "fsbookmark_reload",
    yank = "fsbookmark_yank",
    reveal = "fsbookmark_reveal",
    share = "fsbookmark_share",
  }
  for name, action in pairs(map) do
    local key = keys[name]
    if key then
      -- Normalise to Snacks' own spelling (`<c-l>` -> `<C-L>`). Snacks does
      -- this to the registered source at setup, so emitting the raw form here
      -- would land a second entry for the same key and trigger its
      -- duplicate-mapping warning every time the picker opens.
      local ok, normalised = pcall(function()
        return require("snacks").util.normkey(key)
      end)
      -- `desc` here is what the `?` help shows; a bare action name would show as-is.
      list_keys[ok and normalised or key] = { action, desc = actions[action].desc }
    end
  end

  local _, workspace_name = fsbookmark.workspace()

  -- Start in the list, like the Snacks explorer. Before `opts` so a caller can
  -- pass `focus = "input"`.
  return vim.tbl_deep_extend("force", { focus = "list" }, opts or {}, {
    title = workspace_name and ("Bookmarks (%s)"):format(workspace_name) or "Bookmarks",
    -- `live` hands the raw prompt to the finder and keeps the built-in matcher
    -- out of the way; see the comment on `finder`.
    live = true,
    supports_live = true,
    -- Live sources must stay open on zero results, or a half-typed
    -- `label:c` would close the picker.
    show_empty = true,
    finder = finder,
    format = format,
    actions = actions,
    win = {
      list = { keys = list_keys },
    },
    confirm = function(picker, item)
      picker:close()
      if item then
        fsbookmark.open(item.bookmark)
      end
    end,
  })
end

--- Open the bookmark picker.
---@param opts table|nil forwarded to `Snacks.picker.pick`
--- Backends in preference order.
local BACKENDS = {
  { name = "snacks", plugin = "snacks" },
  { name = "telescope", plugin = "telescope" },
  { name = "fzf-lua", plugin = "fzf-lua" },
}

---@return string|nil
function M.backend()
  local configured = config.options.picker.backend
  if configured and configured ~= "auto" then
    return configured
  end
  for _, backend in ipairs(BACKENDS) do
    if pcall(require, backend.plugin) then
      return backend.name
    end
  end
  return nil
end

function M.open(opts)
  local backend = M.backend()

  -- The query language lives in `search.lua`, so every backend behaves the
  -- same; only the presentation layer differs.
  if backend == "telescope" then
    return require("fsbookmark.pickers.telescope").open(opts)
  elseif backend == "fzf-lua" then
    return require("fsbookmark.pickers.fzf_lua").open(opts)
  end

  local Snacks = snacks()
  if not Snacks then
    return
  end
  return Snacks.picker.pick(M.source(vim.tbl_deep_extend("force", { source = "fsbookmark" }, opts or {})))
end

return M
