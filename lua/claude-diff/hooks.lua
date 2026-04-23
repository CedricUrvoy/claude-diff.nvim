local M = {}

local function upsert_hook(settings, event, matcher, cmd)
  local list = settings.hooks[event] or {}
  list = vim.tbl_filter(function(entry)
    if not (entry.hooks and entry.hooks[1]) then return true end
    return not entry.hooks[1].command:find("claude%-pre%-tool%.sh") and
           not entry.hooks[1].command:find("claude%-post%-tool%.sh")
  end, list)
  table.insert(list, { matcher = matcher, hooks = { { type = "command", command = cmd } } })
  settings.hooks[event] = list
end

function M.install()
  -- resolve the hooks/ dir relative to this file: lua/claude-diff/hooks.lua → ../../hooks/
  local src         = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fn.fnamemodify(src, ":h:h:h")
  local hooks_dir   = plugin_root .. "/hooks"
  local pre_script  = hooks_dir .. "/claude-pre-tool.sh"
  local post_script = hooks_dir .. "/claude-post-tool.sh"

  if vim.fn.filereadable(pre_script) == 0 or vim.fn.filereadable(post_script) == 0 then
    vim.notify("claude-diff: hook scripts not found at " .. hooks_dir, vim.log.levels.ERROR)
    return
  end

  local settings_path = vim.fn.expand("~/.claude/settings.json")
  local settings      = {}
  if vim.fn.filereadable(settings_path) == 1 then
    local ok, decoded = pcall(vim.fn.json_decode, table.concat(vim.fn.readfile(settings_path), "\n"))
    if ok and type(decoded) == "table" then settings = decoded end
  end

  settings.hooks = settings.hooks or {}

  upsert_hook(settings, "PreToolUse",  "Write|Edit|MultiEdit", "bash " .. pre_script)
  upsert_hook(settings, "PostToolUse", "Write|Edit|MultiEdit", "bash " .. post_script)

  vim.fn.mkdir(vim.fn.fnamemodify(settings_path, ":h"), "p")
  vim.fn.writefile({ vim.fn.json_encode(settings) }, settings_path)
  vim.notify(
    "claude-diff: hooks installed → " .. settings_path .. "\nRestart Claude Code to apply.",
    vim.log.levels.INFO,
    { title = "Claude Code" }
  )
end

return M
