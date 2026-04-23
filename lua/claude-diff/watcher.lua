local M = {}
local cfg     = require("claude-diff.config")
local session = require("claude-diff.session")

local watcher      = nil
local notify_timer = nil
local callbacks    = {}

function M.on_change(fn)
  table.insert(callbacks, fn)
end

function M.off_change(fn)
  for i, cb in ipairs(callbacks) do
    if cb == fn then
      table.remove(callbacks, i)
      return
    end
  end
end

local function fire_callbacks()
  if #callbacks == 0 then
    vim.notify(
      "Claude modified files — <leader>cd to review",
      vim.log.levels.INFO,
      { title = "Claude Code" }
    )
  else
    for _, cb in ipairs(callbacks) do
      pcall(cb)
    end
  end
end

function M.start()
  local sdir    = session.session_dir()
  local trigger = sdir .. "/trigger"

  vim.fn.mkdir(sdir .. "/originals", "p")
  if vim.fn.filereadable(trigger) == 0 then
    vim.fn.writefile({ "" }, trigger)
  end

  if watcher then
    watcher:stop()
    watcher:close()
    watcher = nil
  end
  watcher = vim.uv.new_fs_event()
  watcher:start(trigger, {}, vim.schedule_wrap(function(err, _filename, _events)
    if err then return end
    if notify_timer then
      notify_timer:stop()
      notify_timer:close()
      notify_timer = nil
    end
    notify_timer = vim.uv.new_timer()
    notify_timer:start(cfg.values.debounce_ms, 0, vim.schedule_wrap(function()
      notify_timer:close()
      notify_timer = nil
      fire_callbacks()
    end))
  end))
end

function M.stop_all()
  if watcher then
    watcher:stop()
    watcher:close()
    watcher = nil
  end
  if notify_timer then
    notify_timer:stop()
    notify_timer:close()
    notify_timer = nil
  end
end

return M
