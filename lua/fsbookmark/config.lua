local M = {}

---@class FSBookmarkConfig
local defaults = {
  -- Where bookmarks are persisted. Defaults to
  -- stdpath("data")/fsbookmark/bookmarks, holding global.json and workspace/.
  ---@type string|nil
  dir = nil,

  workspace = {
    -- Resolve a workspace root and keep its bookmarks in a separate file.
    -- With this off, everything lives in global.json.
    enabled = true,
  },

  shared = {
    -- Read a checked-in bookmark file from the workspace root, so a repository
    -- can ship its own map of "where to start reading".
    enabled = true,
    -- Relative to the workspace root. Nothing is ever written here implicitly:
    -- bookmarks move in only via `:FSBookmark share`.
    file = ".fsbookmark.json",
  },

  -- Save to disk automatically after every mutation.
  autosave = true,

  -- Track renames/deletes so broken bookmarks can be surfaced.
  watch = true,

  icons = {
    bookmark = "★",
    broken = "⚠",
    directory = "",
    file = "",
    global = "🌍",
    workspace = "📁",
    shared = "👥",
  },

  picker = {
    -- Which picker to open: "auto" takes the first installed of snacks,
    -- telescope, fzf-lua. Set it explicitly to pin one.
    ---@type "auto"|"snacks"|"telescope"|"fzf-lua"
    backend = "auto",

    -- Snacks picker keymaps, in the list window (normal mode) only. The picker
    -- opens with focus on the list, like the Snacks explorer; `/` or `i`
    -- moves focus to the search input. `?` is Snacks' help. Set a value to
    -- false to disable it.
    keys = {
      edit = "e",
      share = "c", -- cycle scope: workspace -> shared -> global
      delete = "x",
      reload = "l",
      yank = "y",
      reveal = "o",
    },
  },

  explorer = {
    -- Register the toggle keymap in supported explorer buffers.
    enabled = true,
    key = "mb",
    -- Toggle a global bookmark for the path under the cursor. false disables it.
    global_key = "mB",
  },

  keys = {
    -- Register the which-key group. Set `enabled = false` to opt out entirely.
    enabled = true,
    -- `<leader>m` rather than `<leader>b`: LazyVim already owns `<leader>b`
    -- as its buffer group, and which-key auto-expands buffer-local maps into it.
    prefix = "<leader>m",
  },

  -- How directories are opened from the picker.
  ---@type fun(path: string)|nil
  open_directory = nil,
}

---@type FSBookmarkConfig
M.options = vim.deepcopy(defaults)

M.defaults = defaults

-- Whether setup() ran. Surfaced by `:checkhealth fsbookmark`.
M.configured = false

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  M.configured = true
  return M.options
end

---@return string
function M.dir()
  return M.options.dir or vim.fs.joinpath(vim.fn.stdpath("data"), "fsbookmark", "bookmarks")
end

return M
