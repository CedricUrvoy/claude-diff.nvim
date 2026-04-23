local M = {}

local cfg     = require("claude-diff.config")
local session = require("claude-diff.session")
local diff    = require("claude-diff.diff")
local picker  = require("claude-diff.picker")
local watcher = require("claude-diff.watcher")
local hooks   = require("claude-diff.hooks")

function M.pick()
  picker.pick()
end

function M.open_file(filepath)
  local files = vim.tbl_keys(session.read_manifest())
  table.sort(files)
  local idx = vim.fn.index(files, filepath) + 1
  if idx == 0 then idx = 1 end
  diff.set_files(files, idx)
  diff.open_diff_for_file(filepath)
end

M.actions = {
  pick      = function() picker.pick() end,
  next_file = function()
    local files, idx = diff.get_files()
    if #files == 0 then picker.pick(); return end
    idx = (idx % #files) + 1
    diff.set_files(files, idx)
    diff.open_diff_for_file(files[idx])
    diff.notify_file_position()
    local ok, sidebar = pcall(require, "claude-diff.sidebar")
    if ok then sidebar.sync_cursor(files[idx]) end
  end,
  prev_file = function()
    local files, idx = diff.get_files()
    if #files == 0 then picker.pick(); return end
    idx = ((idx - 2) % #files) + 1
    diff.set_files(files, idx)
    diff.open_diff_for_file(files[idx])
    diff.notify_file_position()
    local ok, sidebar = pcall(require, "claude-diff.sidebar")
    if ok then sidebar.sync_cursor(files[idx]) end
  end,
  next_hunk = function()
    local before = vim.api.nvim_win_get_cursor(0)
    vim.cmd("norm! ]c")
    local after = vim.api.nvim_win_get_cursor(0)
    if before[1] == after[1] and before[2] == after[2] then
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("norm! ]c")
    end
  end,
  prev_hunk = function()
    local before = vim.api.nvim_win_get_cursor(0)
    vim.cmd("norm! [c")
    local after = vim.api.nvim_win_get_cursor(0)
    if before[1] == after[1] and before[2] == after[2] then
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
      vim.cmd("norm! [c")
    end
  end,
  revert = function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if not vim.b[buf].claude_diff and vim.wo[win].diff then
        local filepath = vim.api.nvim_buf_get_name(buf)
        local original = session.get_original(filepath)
        if original then
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(original, "\n"))
          if cfg.values.auto_save_on_revert then
            vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
          end
          vim.notify("Reverted " .. vim.fn.fnamemodify(filepath, ":t") .. " to pre-Claude state")
          diff.close_diff()
          local ok, sidebar = pcall(require, "claude-diff.sidebar")
          if ok then sidebar.mark_reverted(filepath) end
        end
        return
      end
    end
  end,
  close = function()
    diff.close_diff()
  end,
  reset = function()
    vim.fn.delete(session.session_dir(), "rf")
    watcher.start()
    local ok, sidebar = pcall(require, "claude-diff.sidebar")
    if ok then
      sidebar.reset_state()
      sidebar.render()
    end
    vim.notify("Claude diff session reset", vim.log.levels.INFO)
  end,
}

function M.setup(opts)
  cfg.setup(opts)

  watcher.start()

  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = vim.schedule_wrap(function()
      local files = vim.tbl_keys(session.read_manifest())
      if #files > 0 then
        if cfg.values.auto_open_sidebar then
          local ok, sidebar = pcall(require, "claude-diff.sidebar")
          if ok then sidebar.open() end
        else
          vim.notify(
            "Claude modified files — <leader>cd to review",
            vim.log.levels.INFO,
            { title = "Claude Code" }
          )
        end
      end
    end),
  })

  vim.api.nvim_create_autocmd("DirChanged", {
    callback = function()
      watcher.start()
      local ok, sidebar = pcall(require, "claude-diff.sidebar")
      if ok then sidebar.render() end
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = watcher.stop_all,
  })

  vim.keymap.set("n", "<leader>cd", function()
    local ok, sidebar = pcall(require, "claude-diff.sidebar")
    if ok then sidebar.toggle() end
  end, { silent = true, desc = "Toggle Claude diff sidebar" })

  vim.keymap.set("n", "<leader>cc", function()
    diff.close_diff()
    local ok, sidebar = pcall(require, "claude-diff.sidebar")
    if ok then sidebar.close() end
  end, { silent = true, desc = "Close Claude diff and sidebar" })

  vim.api.nvim_create_user_command("ClaudeDiff", function()
    M.pick()
  end, { desc = "Browse Claude session file changes" })

  vim.api.nvim_create_user_command("ClaudeDiffFile", function(args)
    if args.args and args.args ~= "" then
      M.open_file(args.args)
    else
      M.pick()
    end
  end, { nargs = "?", complete = "file", desc = "Open Claude diff for a specific file" })

  vim.api.nvim_create_user_command("ClaudeDiffReset", function()
    M.actions.reset()
  end, { desc = "Clear Claude session diff data" })

  vim.api.nvim_create_user_command("ClaudeDiffInstallHooks", function()
    hooks.install()
  end, { desc = "Install Claude Code hooks into ~/.claude/settings.json" })
end

return M
