local M = {}
local cfg = require("claude-diff.config")

-- Returns the session directory for the given cwd string.
local function session_dir_for(cwd)
  return cfg.values.base_dir .. "/" .. vim.fn.sha256(cwd):sub(1, 8)
end

-- Reads the cwd the hook used from the cwd file (written by pre-hook).
-- Falls back to vim.fn.getcwd() so it still works before any hook has run.
function M.session_dir()
  local fallback_dir = session_dir_for(vim.fn.getcwd())
  local cwd_file = fallback_dir .. "/cwd"
  -- Note: cwd-file lookup only works when Neovim's cwd matches Claude's cwd (same hash).
  -- When they differ, the cwd file lives under Claude's hash, not Neovim's, so the
  -- fallback is used. A global index would be needed to handle fully divergent cwds.
  if vim.fn.filereadable(cwd_file) == 1 then
    local lines = vim.fn.readfile(cwd_file)
    if lines and lines[1] and lines[1] ~= "" then
      return session_dir_for(lines[1])
    end
  end
  return fallback_dir
end

function M.read_manifest()
  local path = M.session_dir() .. "/manifest.json"
  if vim.fn.filereadable(path) == 0 then return {} end
  local ok, data = pcall(vim.fn.json_decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" then
    vim.notify(
      "claude-diff: manifest.json is corrupt — run :ClaudeDiffReset to clear",
      vim.log.levels.WARN,
      { title = "Claude Code" }
    )
    return {}
  end
  return data
end

-- Returns the raw original file content as a string, or nil if not found.
function M.get_original(filepath)
  local key = filepath:gsub("/", "_"):gsub("^_", "")
  local orig_path = M.session_dir() .. "/originals/" .. key
  if vim.fn.filereadable(orig_path) == 0 then return nil end
  return table.concat(vim.fn.readfile(orig_path), "\n")
end

return M
