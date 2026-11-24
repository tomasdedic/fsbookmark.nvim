local config = require("fsbookmark.config")
local util = require("fsbookmark.util")

local M = {}

M.group = nil

---@type table<string, fun(): string|nil>
M.providers = {}

--- Snacks explorer is a picker; the focused item carries the path. The keys
--- are mapped in every Snacks list (the bookmark picker too), so prefer the
--- focused picker over the explorer.
function M.providers.snacks()
  local ok, Snacks = pcall(require, "snacks")
  if not ok or not Snacks.picker then
    return nil
  end
  local picker
  for _, p in ipairs(Snacks.picker.get()) do
    if p:is_focused() then
      picker = p
      break
    end
  end
  picker = picker or (Snacks.picker.get({ source = "explorer" }) or {})[1]
  if not picker then
    return nil
  end

  -- `picker:current()` is the authority. A window cursor row is NOT an item
  -- index — Snacks renders a scrolled window over the item list and converts
  -- with `row2idx(row - topline + 1)` — so reading the row directly picks the
  -- wrong entry as soon as the tree is scrolled.
  local item = picker:current()
  return item and (item.file or item._path) or nil
end

M.providers["neo-tree"] = function()
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  if not ok or not manager.get_state_for_window then
    return nil
  end
  local state = manager.get_state_for_window(vim.api.nvim_get_current_win())
  local node = state and state.tree and state.tree:get_node()
  return node and node:get_id() or nil
end

function M.providers.oil()
  local ok, oil = pcall(require, "oil")
  if not ok then
    return nil
  end
  local entry = oil.get_cursor_entry()
  local dir = oil.get_current_dir()
  if not entry or not dir then
    return nil
  end
  return dir .. entry.name
end

--- Path under the cursor in whichever explorer is focused, else the buffer path.
---@return string|nil
function M.current_path()
  local filetype = vim.bo.filetype
  local by_filetype = {
    snacks_picker_list = "snacks",
    snacks_picker_input = "snacks",
    ["neo-tree"] = "neo-tree",
    oil = "oil",
  }

  local provider = M.providers[by_filetype[filetype] or ""]
  if provider then
    local path = provider()
    if path then
      return util.normalize(path)
    end
  end

  local name = vim.api.nvim_buf_get_name(0)
  return name ~= "" and util.normalize(name) or nil
end

--- Toggle the bookmark for the path under the cursor.
---@return boolean added
function M.toggle()
  local fsbookmark = require("fsbookmark")
  local path = M.current_path()
  if not path then
    util.notify("no path under cursor", vim.log.levels.WARN)
    return false
  end

  local added = fsbookmark.toggle(path)
  local icons = config.options.icons
  util.notify((added and icons.bookmark .. " added " or "removed ") .. util.display_path(path))
  M.refresh(path)
  return added
end

--- Toggle a global bookmark for the path under the cursor: a global one is
--- removed, anything else (missing, workspace, shared) becomes global.
---@return boolean global true when the path is now a global bookmark
function M.toggle_global()
  local fsbookmark = require("fsbookmark")
  local path = M.current_path()
  if not path then
    util.notify("no path under cursor", vim.log.levels.WARN)
    return false
  end

  local existing = fsbookmark.get(path)
  if existing and existing.scope == "global" then
    fsbookmark.remove(path)
    util.notify("removed " .. util.display_path(path))
    M.refresh(path)
    return false
  end

  local bookmark, err = fsbookmark.make_global(path)
  if not bookmark then
    util.notify(err or "could not make global", vim.log.levels.WARN)
    return false
  end
  util.notify(config.options.icons.global .. " global " .. util.display_path(path))
  M.refresh(path)
  return true
end

--- Ask the focused explorer to redraw so the marker updates.
---@param path string|nil keep the cursor on this item; a scope change can move
--- it to another row in the bookmark picker
function M.refresh(path)
  local ok, Snacks = pcall(require, "snacks")
  if ok and Snacks.picker then
    for _, source in ipairs({ "explorer", "fsbookmark" }) do
      for _, picker in ipairs(Snacks.picker.get({ source = source }) or {}) do
        -- `list:update()`/`list:render()` reuse the rendered rows, so the
        -- bookmark marker would not appear until the explorer was reopened.
        -- Only re-running the finder re-formats the tree — and that resets the
        -- cursor to the top unless the current position is pinned first, which
        -- is what Snacks' own explorer actions do around their refreshes.
        pcall(function()
          picker.list:set_target()
          picker:find({
            on_done = function()
              for item, idx in picker:iter() do
                if path and item.file == path then
                  picker.list:view(idx)
                  return
                end
              end
            end,
          })
        end)
      end
    end
  end

  if package.loaded["neo-tree.sources.manager"] then
    pcall(vim.cmd, "Neotree refresh")
  end
end

--- Open a directory in the best available explorer.
---@param path string
function M.open_directory(path)
  local ok, Snacks = pcall(require, "snacks")
  if ok and Snacks.explorer then
    return Snacks.explorer({ cwd = path })
  end
  if package.loaded["oil"] or pcall(require, "oil") then
    return require("oil").open(path)
  end
  if pcall(require, "neo-tree.command") then
    return require("neo-tree.command").execute({ action = "focus", dir = path })
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

--- Drop-in `format` for the Snacks explorer source that prefixes bookmarked
--- entries with the bookmark icon. Snacks has no chaining hook for decorations,
--- so this is last-writer-wins with any other plugin overriding the format.
---@param item table
---@param picker table
---@return table[]
function M.format(item, picker)
  local Snacks = require("snacks")
  local out = Snacks.picker.format.file(item, picker)

  local icon = config.options.icons.bookmark
  local bookmark = item.file and require("fsbookmark").get(item.file)

  -- The marker is a leading gutter, so it has to occupy the same width on
  -- every row — prepending it only to bookmarked entries pushes their tree
  -- indent one cell right of everyone else's. `virtual` keeps it out of the
  -- matcher's text either way.
  if bookmark then
    table.insert(out, 1, { icon .. " ", "SnacksPickerLabel", virtual = true })
  else
    table.insert(out, 1, { (" "):rep(vim.fn.strdisplaywidth(icon) + 1), virtual = true })
  end

  return out
end

--- Register the toggle keymap in explorer buffers.
function M.setup()
  local key = config.options.explorer.key
  local global_key = config.options.explorer.global_key
  if not key and not global_key then
    return
  end
  if M.group then
    return
  end
  M.group = vim.api.nvim_create_augroup("fsbookmark_explorer", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = M.group,
    pattern = { "snacks_picker_list", "neo-tree", "oil" },
    callback = function(args)
      if key then
        vim.keymap.set("n", key, M.toggle, { buffer = args.buf, desc = "Toggle bookmark", nowait = true })
      end
      if global_key then
        vim.keymap.set(
          "n",
          global_key,
          M.toggle_global,
          { buffer = args.buf, desc = "Toggle global bookmark", nowait = true }
        )
      end
    end,
  })
end

return M
