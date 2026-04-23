local M = {}
local cfg     = require("claude-diff.config")
local session = require("claude-diff.session")

local watcher      = nil
local notify_timer = nil

function M.start()
  local sdir    = session.session_dir()
  local trigger = sdir .. "/trigger"

  vim.fn.mkdir(sdir .. "/originals", "p")
  if vim.fn.filereadable(trigger) == 0 then
    vim.fn.writefile({ "" }, trigger)
  end

  if watcher then watcher:stop() end
  watcher = vim.uv.new_fs_event()
  watcher:start(trigger, {}, vim.schedule_wrap(function(err, _, _)
    if err then return end
    if notify_timer then
      notify_timer:stop()
      notify_timer:close()
    end
    notify_timer = vim.uv.new_timer()
    notify_timer:start(cfg.values.debounce_ms, 0, vim.schedule_wrap(function()
      notify_timer:close()
      notify_timer = nil
      vim.notify("Claude modified files — :ClaudeDiff to review", vim.log.levels.INFO, { title = "Claude Code" })
    end))
  end))
end

function M.stop_all()
  if watcher then watcher:stop() end
  if notify_timer then notify_timer:stop(); notify_timer:close() end
end

return M
