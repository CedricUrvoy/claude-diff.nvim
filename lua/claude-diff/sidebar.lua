local M = {}

local session = require("claude-diff.session")
local watcher = require("claude-diff.watcher")

-- Review state: filepath -> "unreviewed" | "reviewed" | "reverted"
local review_state = {}
-- Sidebar window and buffer handles
local sidebar_win = nil
local sidebar_buf = nil
-- Maps line number (1-based) -> filepath for lines that represent a file
local file_lines = {}

local ICON_UNREVIEWED = "●"
local ICON_REVIEWED   = "○"
local ICON_REVERTED   = "✗"

local function content_to_lines(s)
  local lines = vim.split(s, "\n")
  if lines[#lines] == "" then table.remove(lines) end
  return lines
end

local function icon_for(filepath)
  local state = review_state[filepath]
  if state == "reverted" then return ICON_REVERTED end
  if state == "reviewed"  then return ICON_REVIEWED  end
  return ICON_UNREVIEWED
end

-- Returns groups table { dir -> [filepath, ...] } and sorted dirs list.
local function group_by_dir(manifest)
  local groups = {}
  for filepath, _ in pairs(manifest) do
    local dir = vim.fn.fnamemodify(filepath, ":.:h")
    if not groups[dir] then groups[dir] = {} end
    table.insert(groups[dir], filepath)
  end
  for _, files in pairs(groups) do
    table.sort(files)
  end
  local dirs = vim.tbl_keys(groups)
  table.sort(dirs)
  return groups, dirs
end

function M.render()
  if not sidebar_buf or not vim.api.nvim_buf_is_valid(sidebar_buf) then return end

  local manifest = session.read_manifest()
  local groups, dirs = group_by_dir(manifest)
  local total = vim.tbl_count(manifest)

  local lines = {}
  local new_file_lines = {}

  table.insert(lines, string.format(" Changes (%d)", total))
  table.insert(lines, " Help: ?")
  table.insert(lines, "")

  for _, dir in ipairs(dirs) do
    table.insert(lines, " ▶ " .. dir .. "/")
    for _, filepath in ipairs(groups[dir]) do
      local fname = vim.fn.fnamemodify(filepath, ":t")
      local is_new = manifest[filepath] and manifest[filepath].new
      local label = is_new and (fname .. " [new]") or fname
      table.insert(lines, "   " .. icon_for(filepath) .. " " .. label)
      new_file_lines[#lines] = filepath
    end
  end

  if total == 0 then
    table.insert(lines, "   (no changes)")
  end

  -- preserve cursor position
  local saved_line = 1
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    saved_line = vim.api.nvim_win_get_cursor(sidebar_win)[1]
  end

  vim.bo[sidebar_buf].modifiable = true
  vim.api.nvim_buf_set_lines(sidebar_buf, 0, -1, false, lines)
  vim.bo[sidebar_buf].modifiable = false

  file_lines = new_file_lines

  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    local max_line = vim.api.nvim_buf_line_count(sidebar_buf)
    vim.api.nvim_win_set_cursor(sidebar_win, { math.min(saved_line, max_line), 0 })
  end
end

local function filepath_at_cursor()
  if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return nil end
  local row = vim.api.nvim_win_get_cursor(sidebar_win)[1]
  return file_lines[row]
end

local function sorted_filepaths()
  local files = vim.tbl_values(file_lines)
  table.sort(files)
  return files
end

local function set_keymaps()
  local buf = sidebar_buf
  local opts = { silent = true, buffer = buf, nowait = true }

  local function open_current()
    local fp = filepath_at_cursor()
    if not fp then return end
    M.mark_reviewed(fp)
    local diff = require("claude-diff.diff")
    local files = sorted_filepaths()
    local idx = 1
    for i, f in ipairs(files) do
      if f == fp then idx = i; break end
    end
    diff.set_files(files, idx)
    vim.cmd("wincmd p")
    diff.open_diff_for_file(fp)
  end

  vim.keymap.set("n", "<CR>", open_current, vim.tbl_extend("force", opts, { desc = "Open diff for file" }))
  vim.keymap.set("n", "o",    open_current, vim.tbl_extend("force", opts, { desc = "Open diff for file" }))

  vim.keymap.set("n", "j", function()
    if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return end
    local row = vim.api.nvim_win_get_cursor(sidebar_win)[1]
    local max = vim.api.nvim_buf_line_count(sidebar_buf)
    for r = row + 1, max do
      if file_lines[r] then
        vim.api.nvim_win_set_cursor(sidebar_win, { r, 0 })
        return
      end
    end
  end, vim.tbl_extend("force", opts, { desc = "Next file" }))

  vim.keymap.set("n", "k", function()
    if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return end
    local row = vim.api.nvim_win_get_cursor(sidebar_win)[1]
    for r = row - 1, 1, -1 do
      if file_lines[r] then
        vim.api.nvim_win_set_cursor(sidebar_win, { r, 0 })
        return
      end
    end
  end, vim.tbl_extend("force", opts, { desc = "Prev file" }))

  vim.keymap.set("n", "r", function()
    local fp = filepath_at_cursor()
    if not fp then return end
    local original = session.get_original(fp)
    if not original then
      vim.notify("No original found for " .. fp, vim.log.levels.WARN)
      return
    end
    local cfg = require("claude-diff.config")
    local bufnr = vim.fn.bufnr(fp)
    if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content_to_lines(original))
      if cfg.values.auto_save_on_revert then
        vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
      end
    else
      vim.fn.writefile(content_to_lines(original), fp)
    end
    M.mark_reverted(fp)
    vim.notify("Reverted " .. vim.fn.fnamemodify(fp, ":t") .. " to pre-Claude state")
  end, vim.tbl_extend("force", opts, { desc = "Revert file under cursor" }))

  vim.keymap.set("n", "R", function()
    local cfg = require("claude-diff.config")
    local manifest = session.read_manifest()
    for fp, _ in pairs(manifest) do
      local original = session.get_original(fp)
      if original then
        local bufnr = vim.fn.bufnr(fp)
        if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
          vim.bo[bufnr].modifiable = true
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content_to_lines(original))
          if cfg.values.auto_save_on_revert then
            vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
          end
        else
          vim.fn.writefile(content_to_lines(original), fp)
        end
        M.mark_reverted(fp)
      end
    end
    vim.notify("Reverted all files to pre-Claude state")
  end, vim.tbl_extend("force", opts, { desc = "Revert all files" }))

  local function close_all()
    local diff = require("claude-diff.diff")
    diff.close_diff()
    M.close()
  end
  vim.keymap.set("n", "q",          close_all, vim.tbl_extend("force", opts, { desc = "Close sidebar and diff" }))
  vim.keymap.set("n", "<leader>cc", close_all, vim.tbl_extend("force", opts, { desc = "Close sidebar and diff" }))

  vim.keymap.set("n", "?", function()
    vim.notify(
      "<CR>/o: open diff  j/k: navigate  r: revert  R: revert all  q/<leader>cc: close  <leader>cd: toggle",
      vim.log.levels.INFO,
      { title = "Claude Diff Help" }
    )
  end, vim.tbl_extend("force", opts, { desc = "Show keymap help" }))
end

local function on_trigger()
  M.render()
end

function M.open()
  watcher.off_change(on_trigger)  -- defensive dedup before re-registering

  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    vim.api.nvim_set_current_win(sidebar_win)
    return
  end

  sidebar_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[sidebar_buf].buftype    = "nofile"
  vim.bo[sidebar_buf].bufhidden  = "wipe"
  vim.bo[sidebar_buf].modifiable = false
  vim.bo[sidebar_buf].filetype   = "claude-diff-sidebar"
  vim.b[sidebar_buf].claude_diff_sidebar = true
  vim.api.nvim_buf_set_name(sidebar_buf, "claude://sidebar")

  vim.cmd("topleft vsplit")
  sidebar_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(sidebar_win, sidebar_buf)
  vim.api.nvim_win_set_width(sidebar_win, 32)

  vim.wo[sidebar_win].number         = false
  vim.wo[sidebar_win].relativenumber = false
  vim.wo[sidebar_win].signcolumn     = "no"
  vim.wo[sidebar_win].wrap           = false
  vim.wo[sidebar_win].cursorline     = true
  vim.wo[sidebar_win].winfixwidth    = true

  set_keymaps()

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer   = sidebar_buf,
    once     = true,
    callback = function()
      watcher.off_change(on_trigger)
      sidebar_win = nil
      sidebar_buf = nil
      file_lines  = {}
    end,
  })

  watcher.on_change(on_trigger)
  M.render()

  -- auto-open diff for the first file (lowest line number = topmost in sidebar)
  local first_line, first_fp = math.huge, nil
  for line, fp in pairs(file_lines) do
    if line < first_line then first_line, first_fp = line, fp end
  end
  if first_fp then
    local files = sorted_filepaths()
    M.mark_reviewed(first_fp)
    local diff = require("claude-diff.diff")
    diff.set_files(files, 1)
    vim.cmd("wincmd p")
    diff.open_diff_for_file(first_fp)
    vim.cmd("wincmd p")  -- return focus to sidebar
  end
end

function M.close()
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    vim.api.nvim_win_close(sidebar_win, true)
  end
end

function M.toggle()
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    M.close()
  else
    M.open()
  end
end

function M.mark_reviewed(filepath)
  if review_state[filepath] ~= "reverted" then
    review_state[filepath] = "reviewed"
  end
  M.render()
end

function M.mark_reverted(filepath)
  review_state[filepath] = "reverted"
  M.render()
end

function M.sync_cursor(filepath)
  if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return end
  for line, fp in pairs(file_lines) do
    if fp == filepath then
      vim.api.nvim_win_set_cursor(sidebar_win, { line, 0 })
      return
    end
  end
end

function M.reset_state()
  review_state = {}
  file_lines   = {}
end

return M
