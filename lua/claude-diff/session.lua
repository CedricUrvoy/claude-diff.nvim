local M = {}
local cfg = require("claude-diff.config")

function M.session_dir()
  return cfg.values.base_dir .. "/" .. vim.fn.sha256(vim.fn.getcwd()):sub(1, 8)
end

function M.read_manifest()
  local path = M.session_dir() .. "/manifest.json"
  if vim.fn.filereadable(path) == 0 then return {} end
  local ok, data = pcall(vim.fn.json_decode, table.concat(vim.fn.readfile(path), "\n"))
  return (ok and type(data) == "table") and data or {}
end

-- Returns the raw original file content as a string, or nil if not found.
function M.get_original(filepath)
  local key = filepath:gsub("/", "_"):gsub("^_", "")
  local orig_path = M.session_dir() .. "/originals/" .. key
  if vim.fn.filereadable(orig_path) == 0 then return nil end
  return table.concat(vim.fn.readfile(orig_path), "\n")
end

return M
