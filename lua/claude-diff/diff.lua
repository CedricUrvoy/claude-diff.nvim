local M = {}
local cfg     = require("claude-diff.config")
local session = require("claude-diff.session")

local saved_diffopt = nil
local current_files = {}
local current_index = 1

local STYLES = { "side_by_side", "unified", "inline" }

function M.set_files(files, idx)
  current_files = files
  current_index = idx or 1
end

function M.get_files()
  return current_files, current_index
end

function M.close_diff()
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

function M.notify_file_position()
  if not cfg.values.notify_position or #current_files == 0 then return end
  vim.notify(
    string.format("[%d/%d] %s", current_index, #current_files,
      vim.fn.fnamemodify(current_files[current_index], ":~:.")),
    vim.log.levels.INFO,
    { title = "Claude Code" }
  )
end

-- Cycle ]d / [d: direction = 1 or -1
local function cycle_style(current_style, direction)
  local idx = 1
  for i, s in ipairs(STYLES) do
    if s == current_style then idx = i; break end
  end
  return STYLES[((idx - 1 + direction) % #STYLES) + 1]
end

-- Sets ]d / [d keymaps to cycle diff style for the given filepath
local function set_style_maps(buf, filepath, current_style)
  vim.keymap.set("n", "]d", function()
    M.open_diff_for_file(filepath, cycle_style(current_style, 1))
  end, { silent = true, buffer = buf, desc = "Next diff style" })
  vim.keymap.set("n", "[d", function()
    M.open_diff_for_file(filepath, cycle_style(current_style, -1))
  end, { silent = true, buffer = buf, desc = "Prev diff style" })
end

-- Sets navigation + revert keymaps. right_buf_fn() must return the real file buffer.
local function set_nav_maps(buf, filepath, right_buf_fn)
  vim.keymap.set("n", "q", M.close_diff, { silent = true, buffer = buf, desc = "Close Claude diff" })

  vim.keymap.set("n", "]c", function()
    local before = vim.api.nvim_win_get_cursor(0)
    vim.cmd("norm! ]c")
    local after = vim.api.nvim_win_get_cursor(0)
    if before[1] == after[1] and before[2] == after[2] then
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("norm! ]c")
    end
  end, { silent = true, buffer = buf, desc = "Next hunk (wrapping)" })

  vim.keymap.set("n", "[c", function()
    local before = vim.api.nvim_win_get_cursor(0)
    vim.cmd("norm! [c")
    local after = vim.api.nvim_win_get_cursor(0)
    if before[1] == after[1] and before[2] == after[2] then
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
      vim.cmd("norm! [c")
    end
  end, { silent = true, buffer = buf, desc = "Prev hunk (wrapping)" })

  vim.keymap.set("n", "]f", function()
    if #current_files == 0 then return end
    current_index = (current_index % #current_files) + 1
    M.open_diff_for_file(current_files[current_index])
    M.notify_file_position()
  end, { silent = true, buffer = buf, desc = "Next changed file" })

  vim.keymap.set("n", "[f", function()
    if #current_files == 0 then return end
    current_index = ((current_index - 2) % #current_files) + 1
    M.open_diff_for_file(current_files[current_index])
    M.notify_file_position()
  end, { silent = true, buffer = buf, desc = "Prev changed file" })

  vim.keymap.set("n", "<leader>cr", function()
    local rbuf = right_buf_fn()
    local original = session.get_original(filepath)
    if not original then return end
    vim.bo[rbuf].modifiable = true
    vim.api.nvim_buf_set_lines(rbuf, 0, -1, false, vim.split(original, "\n"))
    if cfg.values.auto_save_on_revert then
      vim.api.nvim_buf_call(rbuf, function() vim.cmd("write") end)
    end
    vim.notify("Reverted " .. vim.fn.fnamemodify(filepath, ":t") .. " to pre-Claude state")
    M.close_diff()
  end, { silent = true, buffer = buf, desc = "Revert file to pre-Claude state" })
end

-- ── Renderers ────────────────────────────────────────────────────────────────

local function open_side_by_side(filepath, original)
  local original_lines = vim.split(original, "\n")

  saved_diffopt = vim.o.diffopt
  vim.o.diffopt = "internal,filler,closeoff,algorithm:histogram,linematch:60,inline:simple"

  vim.cmd("edit " .. vim.fn.fnameescape(filepath))
  local right_win = vim.api.nvim_get_current_win()
  vim.cmd("diffthis")
  vim.wo[right_win].foldenable = false
  vim.wo[right_win].fillchars  = "diff: "

  vim.cmd("leftabove vsplit")
  local left_win = vim.api.nvim_get_current_win()
  local left_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, left_buf)
  vim.b[left_buf].claude_diff = true
  vim.api.nvim_buf_set_name(left_buf, "claude://original/" .. vim.fn.fnamemodify(filepath, ":t"))
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original_lines)
  vim.bo[left_buf].buftype    = "nofile"
  vim.bo[left_buf].bufhidden  = "wipe"
  vim.bo[left_buf].modifiable = false
  vim.bo[left_buf].filetype   = vim.filetype.match({ filename = filepath }) or ""
  vim.cmd("diffthis")
  vim.wo[left_win].foldenable = false
  vim.wo[left_win].fillchars  = "diff: "

  local right_buf = vim.api.nvim_win_get_buf(right_win)
  local function get_right() return right_buf end

  set_nav_maps(left_buf,  filepath, get_right)
  set_nav_maps(right_buf, filepath, get_right)
  set_style_maps(left_buf,  filepath, "side_by_side")
  set_style_maps(right_buf, filepath, "side_by_side")

  vim.api.nvim_set_current_win(right_win)
end

local function open_unified(filepath, original)
  local current = table.concat(vim.fn.readfile(filepath), "\n")
  local diff_text = vim.diff(original, current, { result_type = "unified", ctxlen = 3 }) or "(no diff)"

  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].claude_diff = true
  vim.api.nvim_buf_set_name(buf, "claude://unified/" .. vim.fn.fnamemodify(filepath, ":t"))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(diff_text, "\n"))
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype   = "diff"

  -- open in a new split so the user's original window is preserved
  vim.cmd("leftabove vsplit")
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo[0].foldenable = false

  -- for unified mode revert finds the real file by name
  local function get_right()
    return vim.fn.bufnr(filepath)
  end

  set_nav_maps(buf, filepath, get_right)
  set_style_maps(buf, filepath, "unified")
end

local function open_inline(filepath, original)
  local original_lines = vim.split(original, "\n")

  saved_diffopt = vim.o.diffopt
  vim.o.diffopt = "internal,filler,closeoff,algorithm:histogram,linematch:60,inline:only"

  vim.cmd("edit " .. vim.fn.fnameescape(filepath))
  local right_win = vim.api.nvim_get_current_win()
  local right_buf = vim.api.nvim_win_get_buf(right_win)
  vim.cmd("diffthis")

  -- open a temporary split for the original scratch buffer, diffthis, then close the split
  vim.cmd("leftabove vsplit")
  local left_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, left_buf)
  vim.b[left_buf].claude_diff = true
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original_lines)
  vim.bo[left_buf].buftype    = "nofile"
  vim.bo[left_buf].bufhidden  = "wipe"
  vim.bo[left_buf].modifiable = false
  vim.cmd("diffthis")
  vim.cmd("close") -- close the left split; inline diff remains on the right buffer

  vim.api.nvim_set_current_win(right_win)
  vim.wo[right_win].foldenable = false

  local function get_right() return right_buf end
  set_nav_maps(right_buf, filepath, get_right)
  set_style_maps(right_buf, filepath, "inline")
end

-- ── Public entry point ───────────────────────────────────────────────────────

function M.open_diff_for_file(filepath, style)
  style = style or cfg.values.diff_style
  M.close_diff()

  local original = session.get_original(filepath)
  if not original then
    vim.notify("No Claude session original found for " .. filepath, vim.log.levels.WARN)
    return
  end

  if style == "side_by_side" then
    open_side_by_side(filepath, original)
  elseif style == "unified" then
    open_unified(filepath, original)
  elseif style == "inline" then
    open_inline(filepath, original)
  else
    vim.notify("claude-diff: unknown diff_style '" .. style .. "'", vim.log.levels.WARN)
    open_side_by_side(filepath, original)
  end

  M.notify_file_position()
end

return M
