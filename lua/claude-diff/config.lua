local M = {}

M.defaults = {
  debounce_ms         = 500,
  auto_save_on_revert = true,
  notify_position     = true,
  diff_style          = "side_by_side", -- "side_by_side" | "unified" | "inline"
  base_dir            = vim.fn.expand("~/.local/share/claude-diff"),
  auto_open_sidebar   = true,
}

M.values = {}

function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
