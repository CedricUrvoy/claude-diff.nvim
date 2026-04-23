local M = {}

local defaults = {
  debounce_ms         = 500,
  auto_save_on_revert = true,
  notify_position     = true,
  base_dir            = vim.fn.expand("~/.local/share/claude-diff"),
}

local config = {}
local watcher = nil
local notify_timer = nil
local saved_diffopt = nil

local function session_dir()
  return config.base_dir .. "/" .. vim.fn.sha256(vim.fn.getcwd()):sub(1, 8)
end

local function read_manifest()
  local path = session_dir() .. "/manifest.json"
  if vim.fn.filereadable(path) == 0 then return {} end
  local ok, data = pcall(vim.fn.json_decode, table.concat(vim.fn.readfile(path), "\n"))
  return (ok and type(data) == "table") and data or {}
end

local function get_original(filepath)
  local key = filepath:gsub("/", "_"):gsub("^_", "")
  local orig_path = session_dir() .. "/originals/" .. key
  if vim.fn.filereadable(orig_path) == 0 then return nil end
  return table.concat(vim.fn.readfile(orig_path), "\n")
end

local function close_diff()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].claude_diff then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  vim.cmd("diffoff!")
  if saved_diffopt then
    vim.o.diffopt = saved_diffopt
    saved_diffopt = nil
  end
end

local current_files = {}
local current_index = 1

local function notify_file_position()
  if not config.notify_position or #current_files == 0 then return end
  vim.notify(
    string.format("[%d/%d] %s", current_index, #current_files,
      vim.fn.fnamemodify(current_files[current_index], ":~:.")),
    vim.log.levels.INFO,
    { title = "Claude Code" }
  )
end

local function open_diff_for_file(filepath)
  close_diff()

  local original = get_original(filepath)
  if not original then
    vim.notify("No Claude session original found for " .. filepath, vim.log.levels.WARN)
    return
  end

  local original_lines = vim.split(original, "\n")

  -- use histogram diff + intra-line word highlighting, restore on close
  saved_diffopt = vim.o.diffopt
  vim.o.diffopt = "internal,filler,closeoff,algorithm:histogram,linematch:60,inline:simple"

  vim.cmd("edit " .. vim.fn.fnameescape(filepath))
  local right_win = vim.api.nvim_get_current_win()
  vim.cmd("diffthis")
  vim.wo[right_win].foldenable = false
  vim.wo[right_win].fillchars = "diff: "

  vim.cmd("leftabove vsplit")
  local left_win = vim.api.nvim_get_current_win()
  local left_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, left_buf)
  vim.b[left_buf].claude_diff = true
  vim.api.nvim_buf_set_name(left_buf, "claude://original/" .. vim.fn.fnamemodify(filepath, ":t"))
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original_lines)
  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].modifiable = false
  vim.bo[left_buf].filetype = vim.filetype.match({ filename = filepath }) or ""
  vim.cmd("diffthis")
  vim.wo[left_win].foldenable = false
  vim.wo[left_win].fillchars = "diff: "

  local function set_maps(buf)
    vim.keymap.set("n", "q", close_diff, { silent = true, buffer = buf, desc = "Close Claude diff" })
    vim.keymap.set("n", "]c", function()
      local before = vim.api.nvim_win_get_cursor(0)
      vim.cmd("norm! ]c")
      local after = vim.api.nvim_win_get_cursor(0)
      -- cursor didn't move: we were on the last hunk, wrap to first
      if before[1] == after[1] and before[2] == after[2] then
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd("norm! ]c")
      end
    end, { silent = true, buffer = buf, desc = "Next hunk (wrapping)" })
    vim.keymap.set("n", "[c", function()
      local before = vim.api.nvim_win_get_cursor(0)
      vim.cmd("norm! [c")
      local after = vim.api.nvim_win_get_cursor(0)
      -- cursor didn't move: we were on the first hunk, wrap to last
      if before[1] == after[1] and before[2] == after[2] then
        vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
        vim.cmd("norm! [c")
      end
    end, { silent = true, buffer = buf, desc = "Prev hunk (wrapping)" })
    vim.keymap.set("n", "]f", function()
      if #current_files == 0 then return end
      current_index = (current_index % #current_files) + 1
      open_diff_for_file(current_files[current_index])
      notify_file_position()
    end, { silent = true, buffer = buf, desc = "Next changed file" })
    vim.keymap.set("n", "[f", function()
      if #current_files == 0 then return end
      current_index = ((current_index - 2) % #current_files) + 1
      open_diff_for_file(current_files[current_index])
      notify_file_position()
    end, { silent = true, buffer = buf, desc = "Prev changed file" })
    vim.keymap.set("n", "<leader>cr", function()
      local right_buf = vim.api.nvim_win_get_buf(right_win)
      vim.bo[right_buf].modifiable = true
      vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, original_lines)
      if config.auto_save_on_revert then
        vim.api.nvim_buf_call(right_buf, function() vim.cmd("write") end)
      end
      vim.notify("Reverted " .. vim.fn.fnamemodify(filepath, ":t") .. " to pre-Claude state")
      close_diff()
    end, { silent = true, buffer = buf, desc = "Revert file to pre-Claude state" })
  end

  set_maps(left_buf)
  set_maps(vim.api.nvim_win_get_buf(right_win))
  vim.api.nvim_set_current_win(right_win)
end

function M.pick()
  local manifest = read_manifest()
  local files = vim.tbl_keys(manifest)

  if #files == 0 then
    vim.notify("No files changed in current Claude session", vim.log.levels.INFO)
    return
  end

  table.sort(files)

  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.fn.setqflist({}, "r", {
      title = "Claude session changes",
      items = vim.tbl_map(function(f)
        return { filename = f, text = "Claude modified" }
      end, files),
    })
    vim.cmd("copen")
    return
  end

  snacks.picker({
    title = "Claude session changes",
    items = vim.tbl_map(function(f)
      local label = manifest[f] and manifest[f].new and "[new] " or ""
      return { text = label .. vim.fn.fnamemodify(f, ":~:."), file = f }
    end, files),
    format = "text",
    confirm = function(picker, item)
      picker:close()
      if item then
        current_files = files
        current_index = vim.fn.index(files, item.file) + 1
        open_diff_for_file(item.file)
      end
    end,
    preview = function(ctx)
      local item = ctx.item
      if not item then return end
      local original = get_original(item.file)
      if not original then return end
      local current = table.concat(vim.fn.readfile(item.file), "\n")
      local diff = vim.diff(original, current, { result_type = "unified", ctxlen = 3 })
      ctx.preview:set_lines(vim.split(diff or "(no diff)", "\n"))
      ctx.preview:highlight({ ft = "diff" })
      ctx.preview:wo({ foldenable = false })
    end,
  })
end

function M.open_file(filepath)
  local files = vim.tbl_keys(read_manifest())
  table.sort(files)
  current_files = files
  current_index = vim.fn.index(files, filepath) + 1
  if current_index == 0 then current_index = 1 end
  open_diff_for_file(filepath)
end

local function start_watcher()
  local sdir = session_dir()
  local trigger = sdir .. "/trigger"

  -- ensure session dir and trigger file exist so fs_event can watch it
  vim.fn.mkdir(sdir .. "/originals", "p")
  if vim.fn.filereadable(trigger) == 0 then
    vim.fn.writefile({ "" }, trigger)
  end

  if watcher then
    watcher:stop()
  end
  watcher = vim.uv.new_fs_event()
  watcher:start(trigger, {}, vim.schedule_wrap(function(err, _, _)
    if err then return end
    -- debounce: collapse rapid edits into a single notification
    if notify_timer then
      notify_timer:stop()
      notify_timer:close()
    end
    notify_timer = vim.uv.new_timer()
    notify_timer:start(config.debounce_ms, 0, vim.schedule_wrap(function()
      notify_timer:close()
      notify_timer = nil
      vim.notify("Claude modified files — :ClaudeDiff to review", vim.log.levels.INFO, { title = "Claude Code" })
    end))
  end))
end

M.actions = {
  pick       = function() M.pick() end,
  next_file  = function()
    if #current_files == 0 then M.pick() return end
    current_index = (current_index % #current_files) + 1
    open_diff_for_file(current_files[current_index])
    notify_file_position()
  end,
  prev_file  = function()
    if #current_files == 0 then M.pick() return end
    current_index = ((current_index - 2) % #current_files) + 1
    open_diff_for_file(current_files[current_index])
    notify_file_position()
  end,
  next_hunk  = function()
    local before = vim.api.nvim_win_get_cursor(0)
    vim.cmd("norm! ]c")
    local after = vim.api.nvim_win_get_cursor(0)
    if before[1] == after[1] and before[2] == after[2] then
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("norm! ]c")
    end
  end,
  prev_hunk  = function()
    local before = vim.api.nvim_win_get_cursor(0)
    vim.cmd("norm! [c")
    local after = vim.api.nvim_win_get_cursor(0)
    if before[1] == after[1] and before[2] == after[2] then
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
      vim.cmd("norm! [c")
    end
  end,
  revert     = function()
    -- find the right-side (current file) buffer among diff windows
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if not vim.b[buf].claude_diff and vim.wo[win].diff then
        local filepath = vim.api.nvim_buf_get_name(buf)
        local original = get_original(filepath)
        if original then
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(original, "\n"))
          if config.auto_save_on_revert then
            vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
          end
          vim.notify("Reverted " .. vim.fn.fnamemodify(filepath, ":t") .. " to pre-Claude state")
          close_diff()
        end
        return
      end
    end
  end,
  close      = close_diff,
  reset      = function()
    vim.fn.delete(session_dir(), "rf")
    start_watcher()
    vim.notify("Claude diff session reset", vim.log.levels.INFO)
  end,
}

local function install_hooks()
  -- resolve the hooks/ dir relative to this file: lua/claude-diff/init.lua → ../../hooks/
  local src = debug.getinfo(1, "S").source:sub(2) -- strip leading "@"
  local plugin_root = vim.fn.fnamemodify(src, ":h:h:h")
  local hooks_dir = plugin_root .. "/hooks"

  local pre_script  = hooks_dir .. "/claude-pre-tool.sh"
  local post_script = hooks_dir .. "/claude-post-tool.sh"

  if vim.fn.filereadable(pre_script) == 0 or vim.fn.filereadable(post_script) == 0 then
    vim.notify("claude-diff: hooks scripts not found at " .. hooks_dir, vim.log.levels.ERROR)
    return
  end

  local settings_path = vim.fn.expand("~/.claude/settings.json")
  local settings = {}
  if vim.fn.filereadable(settings_path) == 1 then
    local ok, decoded = pcall(vim.fn.json_decode, table.concat(vim.fn.readfile(settings_path), "\n"))
    if ok and type(decoded) == "table" then settings = decoded end
  end

  settings.hooks = settings.hooks or {}

  local function upsert_hook(event, matcher, cmd)
    local list = settings.hooks[event] or {}
    -- remove any existing claude-diff entry for this event
    list = vim.tbl_filter(function(entry)
      if not (entry.hooks and entry.hooks[1]) then return true end
      return not entry.hooks[1].command:find("claude%-pre%-tool%.sh") and
             not entry.hooks[1].command:find("claude%-post%-tool%.sh")
    end, list)
    table.insert(list, { matcher = matcher, hooks = { { type = "command", command = cmd } } })
    settings.hooks[event] = list
  end

  upsert_hook("PreToolUse",  "Write|Edit|MultiEdit", "bash " .. pre_script)
  upsert_hook("PostToolUse", "Write|Edit|MultiEdit", "bash " .. post_script)

  vim.fn.mkdir(vim.fn.fnamemodify(settings_path, ":h"), "p")
  vim.fn.writefile({ vim.fn.json_encode(settings) }, settings_path)
  vim.notify(
    "claude-diff: hooks installed → " .. settings_path .. "\nRestart Claude Code to apply.",
    vim.log.levels.INFO,
    { title = "Claude Code" }
  )
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})

  start_watcher()

  -- if nvim was launched with files already changed (e.g. by the post-tool hook), notify immediately
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = vim.schedule_wrap(function()
      local files = vim.tbl_keys(read_manifest())
      if #files > 0 then
        vim.notify("Claude modified files — :ClaudeDiff to review", vim.log.levels.INFO, { title = "Claude Code" })
      end
    end),
  })

  -- restart watcher when cwd changes (e.g. switching projects via project.nvim)
  vim.api.nvim_create_autocmd("DirChanged", {
    callback = start_watcher,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
      if watcher then watcher:stop() end
      if notify_timer then notify_timer:stop(); notify_timer:close() end
    end,
  })

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
    vim.fn.delete(session_dir(), "rf")
    start_watcher()
    vim.notify("Claude diff session reset", vim.log.levels.INFO)
  end, { desc = "Clear Claude session diff data" })

  vim.api.nvim_create_user_command("ClaudeDiffInstallHooks", function()
    install_hooks()
  end, { desc = "Install Claude Code hooks for claude-diff into ~/.claude/settings.json" })
end

return M
