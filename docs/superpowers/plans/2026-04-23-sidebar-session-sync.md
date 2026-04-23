# Sidebar + Session Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the snacks picker with a persistent left sidebar showing changed files grouped by directory, and fix session/cwd data bugs so the list is always correct.

**Architecture:** A new `sidebar.lua` module owns the sidebar window/buffer and review state; `watcher.lua` gains a callback registry so the sidebar can subscribe; `session.lua` reads cwd from a hook-written file to eliminate project-hash mismatches; the shell hooks get atomic manifest writes. Existing modules (`picker.lua`, `hooks.lua`, `config.lua`) are unchanged except `config.lua` gains one option.

**Tech Stack:** Lua (Neovim plugin), bash + Python 3 (shell hooks), `vim.uv` (libuv file watcher), `vim.api` (buffer/window management)

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lua/claude-diff/sidebar.lua` | **Create** | Sidebar window/buffer lifecycle, render, review state, keymap registration |
| `lua/claude-diff/watcher.lua` | Modify | Callback registry replacing hardcoded `vim.notify` |
| `lua/claude-diff/session.lua` | Modify | Read cwd from hook-written file; warn on corrupt manifest |
| `lua/claude-diff/diff.lua` | Modify | Scoped `diffoff`, per-call `diffopt` save, `sidebar.sync_cursor` call |
| `lua/claude-diff/config.lua` | Modify | Add `auto_open_sidebar = true` |
| `lua/claude-diff/init.lua` | Modify | Wire sidebar toggle, update DirChanged + VimEnter autocmds |
| `hooks/claude-pre-tool.sh` | Modify | Write `cwd` file; atomic manifest write |
| `hooks/claude-post-tool.sh` | Modify | Atomic manifest write |

---

## Task 1: Watcher callback registry

Refactor `watcher.lua` to replace the hardcoded `vim.notify` with a registered callback list. This is the foundation that lets the sidebar subscribe to trigger events.

**Files:**
- Modify: `lua/claude-diff/watcher.lua`

- [ ] **Step 1: Replace watcher.lua with callback-registry version**

Full new content of `lua/claude-diff/watcher.lua`:

```lua
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
  watcher:start(trigger, {}, vim.schedule_wrap(function(err, _, _)
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
```

- [ ] **Step 2: Verify no errors by opening Neovim and running `:lua require("claude-diff.watcher").start()`**

Expected: no errors, no crash. Touch the trigger file manually:
```bash
touch ~/.local/share/claude-diff/*/trigger
```
Expected: notification "Claude modified files — `<leader>cd` to review" appears (default callback, no sidebar registered yet).

- [ ] **Step 3: Commit**

```bash
git add lua/claude-diff/watcher.lua
git commit -m "refactor(watcher): replace hardcoded notify with callback registry"
```

---

## Task 2: Session cwd fix + manifest corruption warning

Fix the root cause of the empty/wrong diff list: `session_dir()` must use the same cwd the hook used, not Neovim's current cwd.

**Files:**
- Modify: `lua/claude-diff/session.lua`

- [ ] **Step 1: Update session.lua**

Full new content of `lua/claude-diff/session.lua`:

```lua
local M = {}
local cfg = require("claude-diff.config")

-- Returns the session directory for the given cwd string.
-- Uses the same SHA-256 hash algorithm as the shell hooks.
local function session_dir_for(cwd)
  return cfg.values.base_dir .. "/" .. vim.fn.sha256(cwd):sub(1, 8)
end

-- Reads the cwd the hook used from the cwd file (written by pre-hook).
-- Falls back to vim.fn.getcwd() so it still works before any hook has run.
function M.session_dir()
  local fallback_dir = session_dir_for(vim.fn.getcwd())
  local cwd_file = fallback_dir .. "/cwd"
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
```

- [ ] **Step 2: Verify in Neovim**

Run `:lua print(require("claude-diff.session").session_dir())` — should print a path under `~/.local/share/claude-diff/`. No errors.

- [ ] **Step 3: Commit**

```bash
git add lua/claude-diff/session.lua
git commit -m "fix(session): read cwd from hook-written file to fix project hash mismatch"
```

---

## Task 3: Shell hook — write cwd file + atomic manifest writes

Update both hooks so they write the `cwd` file on first run and use atomic manifest writes.

**Files:**
- Modify: `hooks/claude-pre-tool.sh`
- Modify: `hooks/claude-post-tool.sh`

- [ ] **Step 1: Update claude-pre-tool.sh**

Full new content of `hooks/claude-pre-tool.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

python3 -c "
import sys, json, os, shutil, hashlib

data = json.load(sys.stdin)
tool_input = data.get('tool_input') or data
filepath = tool_input.get('path') or tool_input.get('file_path') or ''

if not filepath:
    sys.exit(0)

cwd = os.getcwd()
project_hash = hashlib.sha256(cwd.encode()).hexdigest()[:8]
session_dir = os.path.expanduser(f'~/.local/share/claude-diff/{project_hash}')
originals_dir = os.path.join(session_dir, 'originals')
manifest_path = os.path.join(session_dir, 'manifest.json')
manifest_tmp  = manifest_path + '.tmp'
session_id_file = os.path.join(session_dir, 'session_id')
cwd_file = os.path.join(session_dir, 'cwd')

session_id = data.get('session_id', '')

# Wipe stale data when a new Claude session starts
if session_id:
    if os.path.exists(session_id_file):
        with open(session_id_file) as f:
            stored = f.read().strip()
        if stored != session_id:
            shutil.rmtree(originals_dir, ignore_errors=True)
            if os.path.exists(manifest_path):
                os.remove(manifest_path)

os.makedirs(originals_dir, exist_ok=True)

# Write cwd file so Neovim can derive the same project hash
if not os.path.exists(cwd_file):
    with open(cwd_file, 'w') as f:
        f.write(cwd)

if session_id:
    with open(session_id_file, 'w') as f:
        f.write(session_id)

key = filepath.lstrip('/').replace('/', '_')
orig_file = os.path.join(originals_dir, key)

# first write wins — preserve the pre-Claude state (empty for new files)
if not os.path.exists(orig_file):
    if os.path.isfile(filepath):
        shutil.copy2(filepath, orig_file)
    else:
        open(orig_file, 'w').close()

try:
    with open(manifest_path) as f:
        m = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    m = {}

if filepath not in m:
    is_new = not os.path.isfile(filepath)
    m[filepath] = {'original': orig_file, 'new': is_new}
    with open(manifest_tmp, 'w') as f:
        json.dump(m, f)
    os.replace(manifest_tmp, manifest_path)
"
```

- [ ] **Step 2: Update claude-post-tool.sh**

Full new content of `hooks/claude-post-tool.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

NEEDS_NVIM=$(python3 -c "
import sys, json, os, hashlib, time

data = json.load(sys.stdin)
tool_input = data.get('tool_input') or data
filepath = tool_input.get('path') or tool_input.get('file_path') or ''

if not filepath:
    sys.exit(0)

cwd = os.getcwd()
project_hash = hashlib.sha256(cwd.encode()).hexdigest()[:8]
session_dir = os.path.expanduser(f'~/.local/share/claude-diff/{project_hash}')
manifest_path = os.path.join(session_dir, 'manifest.json')
manifest_tmp  = manifest_path + '.tmp'
trigger_path = os.path.join(session_dir, 'trigger')

if os.path.exists(manifest_path):
    try:
        with open(manifest_path) as f:
            m = json.load(f)
        if filepath in m and not m[filepath].get('modified'):
            m[filepath]['modified'] = True
            with open(manifest_tmp, 'w') as f:
                json.dump(m, f)
            os.replace(manifest_tmp, manifest_path)
    except (json.JSONDecodeError, IOError):
        pass

os.makedirs(session_dir, exist_ok=True)
with open(trigger_path, 'w') as f:
    f.write(str(time.time()))
print('trigger_touched')
")

# If we're in tmux and no nvim pane exists, open one in a new background window.
if [ \"\$NEEDS_NVIM\" = \"trigger_touched\" ] && [ -n \"\${TMUX:-}\" ]; then
  if ! tmux list-panes -s -F \"#{pane_current_command}\" 2>/dev/null | grep -qE \"^n?vim\$\"; then
    tmux new-window -d -n \"claude-diff\" -c \"\$PWD\" \"nvim\"
  fi
fi
```

- [ ] **Step 3: Make hooks executable and verify syntax**

```bash
chmod +x hooks/claude-pre-tool.sh hooks/claude-post-tool.sh
bash -n hooks/claude-pre-tool.sh && echo "pre-hook syntax OK"
bash -n hooks/claude-post-tool.sh && echo "post-hook syntax OK"
```

Expected: both print `syntax OK`.

- [ ] **Step 4: Commit**

```bash
git add hooks/claude-pre-tool.sh hooks/claude-post-tool.sh
git commit -m "fix(hooks): write cwd file and use atomic manifest writes"
```

---

## Task 4: Fix diff.lua — scoped diffoff + per-call diffopt save

Two targeted fixes: `close_diff()` no longer blindly calls global `diffoff!`, and `diffopt` is saved/restored per open call (not a shared module-level variable).

**Files:**
- Modify: `lua/claude-diff/diff.lua`

- [ ] **Step 1: Replace `close_diff` and the `saved_diffopt` module variable, and add sidebar cursor sync**

In `lua/claude-diff/diff.lua`, make the following changes:

**Remove** the module-level `saved_diffopt = nil` line at the top.

**Replace** the `M.close_diff()` function:

```lua
function M.close_diff()
  -- collect diff windows before deleting buffers
  local diff_wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
      table.insert(diff_wins, win)
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].claude_diff then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  for _, win in ipairs(diff_wins) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
    end
  end
end
```

**Replace** the `open_side_by_side` function's `saved_diffopt` usage — pass it as a local and restore on close:

In `open_side_by_side`, replace:
```lua
saved_diffopt = vim.o.diffopt
vim.o.diffopt = "internal,filler,closeoff,algorithm:histogram,linematch:60,inline:simple"
```
with:
```lua
local saved_diffopt = vim.o.diffopt
vim.o.diffopt = "internal,filler,closeoff,algorithm:histogram,linematch:60,inline:simple"
```

And in the `q` keymap (inside `set_nav_maps`, called with `buf` for both left and right), the close action must restore diffopt. Since `set_nav_maps` doesn't know about `saved_diffopt`, thread it through `close_diff`. The cleanest approach: add a module-level `local restore_diffopt = nil` and set it inside each renderer, then restore in `close_diff`.

Full updated top of `diff.lua` (module-level state section only — lines 1–12):

```lua
local M = {}
local cfg     = require("claude-diff.config")
local session = require("claude-diff.session")

local restore_diffopt = nil  -- set by renderers that change diffopt; cleared by close_diff
local current_files = {}
local current_index = 1

local STYLES = { "side_by_side", "unified", "inline" }
```

Updated `close_diff`:

```lua
function M.close_diff()
  local diff_wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
      table.insert(diff_wins, win)
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].claude_diff then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  for _, win in ipairs(diff_wins) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
    end
  end
  if restore_diffopt then
    vim.o.diffopt = restore_diffopt
    restore_diffopt = nil
  end
end
```

In `open_side_by_side`, replace `saved_diffopt = vim.o.diffopt` with `restore_diffopt = vim.o.diffopt`.

In `open_inline`, replace `saved_diffopt = vim.o.diffopt` with `restore_diffopt = vim.o.diffopt`.

- [ ] **Step 2: Add sidebar cursor sync to `]f` / `[f` keymaps**

In `set_nav_maps`, update the `]f` keymap:

```lua
vim.keymap.set("n", "]f", function()
  if #current_files == 0 then return end
  current_index = (current_index % #current_files) + 1
  M.open_diff_for_file(current_files[current_index])
  M.notify_file_position()
  local ok, sidebar = pcall(require, "claude-diff.sidebar")
  if ok then sidebar.sync_cursor(current_files[current_index]) end
end, { silent = true, buffer = buf, desc = "Next changed file" })
```

And `[f`:

```lua
vim.keymap.set("n", "[f", function()
  if #current_files == 0 then return end
  current_index = ((current_index - 2) % #current_files) + 1
  M.open_diff_for_file(current_files[current_index])
  M.notify_file_position()
  local ok, sidebar = pcall(require, "claude-diff.sidebar")
  if ok then sidebar.sync_cursor(current_files[current_index]) end
end, { silent = true, buffer = buf, desc = "Prev changed file" })
```

- [ ] **Step 3: Verify — open Neovim, open a diff, close with `q`, verify diffopt is restored**

Run `:set diffopt?` before opening diff, note value, open a diff, press `q`, run `:set diffopt?` again — value should be the same.

- [ ] **Step 4: Commit**

```bash
git add lua/claude-diff/diff.lua
git commit -m "fix(diff): scoped diffoff, per-call diffopt save, sidebar cursor sync"
```

---

## Task 5: Add auto_open_sidebar config option

**Files:**
- Modify: `lua/claude-diff/config.lua`

- [ ] **Step 1: Add `auto_open_sidebar` to defaults**

Full new content of `lua/claude-diff/config.lua`:

```lua
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
```

- [ ] **Step 2: Commit**

```bash
git add lua/claude-diff/config.lua
git commit -m "feat(config): add auto_open_sidebar option (default true)"
```

---

## Task 6: Create sidebar.lua

The new module. Owns the sidebar window + buffer, renders the file list grouped by directory, tracks review state, and subscribes to watcher events.

**Files:**
- Create: `lua/claude-diff/sidebar.lua`

- [ ] **Step 1: Create lua/claude-diff/sidebar.lua**

```lua
local M = {}

local session = require("claude-diff.session")
local watcher = require("claude-diff.watcher")

-- Review state: filepath -> "unreviewed" | "reviewed" | "reverted"
local review_state = {}
-- Sidebar window and buffer handles
local sidebar_win = nil
local sidebar_buf = nil
-- Ordered flat list of filepaths currently shown (for cursor-to-file mapping)
local file_lines = {}  -- line number (1-based) -> filepath

local ICON_UNREVIEWED = "●"
local ICON_REVIEWED   = "○"
local ICON_REVERTED   = "✗"

local function icon_for(filepath)
  local state = review_state[filepath]
  if state == "reverted" then return ICON_REVERTED end
  if state == "reviewed"  then return ICON_REVIEWED  end
  return ICON_UNREVIEWED
end

-- Returns { dir -> [filepath, ...] } grouped, dirs sorted, files sorted within dir.
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

local function count_modified(manifest)
  local n = 0
  for _, entry in pairs(manifest) do
    if entry.modified then n = n + 1 end
  end
  return n
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
  local saved_line = sidebar_win and vim.api.nvim_win_is_valid(sidebar_win)
    and vim.api.nvim_win_get_cursor(sidebar_win)[1] or 1

  vim.bo[sidebar_buf].modifiable = true
  vim.api.nvim_buf_set_lines(sidebar_buf, 0, -1, false, lines)
  vim.bo[sidebar_buf].modifiable = false

  file_lines = new_file_lines

  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    local max_line = vim.api.nvim_buf_line_count(sidebar_buf)
    local restore = math.min(saved_line, max_line)
    vim.api.nvim_win_set_cursor(sidebar_win, { restore, 0 })
  end
end

local function filepath_at_cursor()
  if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return nil end
  local row = vim.api.nvim_win_get_cursor(sidebar_win)[1]
  return file_lines[row]
end

local function set_keymaps()
  local buf = sidebar_buf
  local opts = { silent = true, buffer = buf, nowait = true }

  -- open diff for file under cursor
  local function open_current()
    local fp = filepath_at_cursor()
    if not fp then return end
    M.mark_reviewed(fp)
    local diff = require("claude-diff.diff")
    local files = {}
    local idx = 1
    for _, v in pairs(file_lines) do
      local found = false
      for _, existing in ipairs(files) do
        if existing == v then found = true; break end
      end
      if not found then table.insert(files, v) end
    end
    table.sort(files)
    for i, f in ipairs(files) do
      if f == fp then idx = i; break end
    end
    diff.set_files(files, idx)
    diff.open_diff_for_file(fp)
  end

  vim.keymap.set("n", "<CR>", open_current, vim.tbl_extend("force", opts, { desc = "Open diff for file" }))
  vim.keymap.set("n", "o",    open_current, vim.tbl_extend("force", opts, { desc = "Open diff for file" }))

  -- move between files only (skip headers)
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

  -- revert file under cursor
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
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(original, "\n"))
      if cfg.values.auto_save_on_revert then
        vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
      end
    else
      -- file not loaded in a buffer — write directly
      vim.fn.writefile(vim.split(original, "\n"), fp)
    end
    M.mark_reverted(fp)
    vim.notify("Reverted " .. vim.fn.fnamemodify(fp, ":t") .. " to pre-Claude state")
  end, vim.tbl_extend("force", opts, { desc = "Revert file under cursor" }))

  -- revert all files
  vim.keymap.set("n", "R", function()
    local cfg = require("claude-diff.config")
    local manifest = session.read_manifest()
    for fp, _ in pairs(manifest) do
      local original = session.get_original(fp)
      if original then
        local bufnr = vim.fn.bufnr(fp)
        if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
          vim.bo[bufnr].modifiable = true
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(original, "\n"))
          if cfg.values.auto_save_on_revert then
            vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
          end
        else
          vim.fn.writefile(vim.split(original, "\n"), fp)
        end
        M.mark_reverted(fp)
      end
    end
    vim.notify("Reverted all files to pre-Claude state")
  end, vim.tbl_extend("force", opts, { desc = "Revert all files" }))

  -- close sidebar + diff
  local function close_all()
    local diff = require("claude-diff.diff")
    diff.close_diff()
    M.close()
  end
  vim.keymap.set("n", "q",           close_all, vim.tbl_extend("force", opts, { desc = "Close sidebar and diff" }))
  vim.keymap.set("n", "<leader>cc",  close_all, vim.tbl_extend("force", opts, { desc = "Close sidebar and diff" }))

  -- inline help
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
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    vim.api.nvim_set_current_win(sidebar_win)
    return
  end

  -- create scratch buffer
  sidebar_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[sidebar_buf].buftype    = "nofile"
  vim.bo[sidebar_buf].bufhidden  = "wipe"
  vim.bo[sidebar_buf].modifiable = false
  vim.bo[sidebar_buf].filetype   = "claude-diff-sidebar"
  vim.b[sidebar_buf].claude_diff_sidebar = true
  vim.api.nvim_buf_set_name(sidebar_buf, "claude://sidebar")

  -- open leftmost vertical split of fixed width
  vim.cmd("topleft vsplit")
  sidebar_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(sidebar_win, sidebar_buf)
  vim.api.nvim_win_set_width(sidebar_win, 32)

  -- window options
  vim.wo[sidebar_win].number         = false
  vim.wo[sidebar_win].relativenumber = false
  vim.wo[sidebar_win].signcolumn     = "no"
  vim.wo[sidebar_win].wrap           = false
  vim.wo[sidebar_win].cursorline     = true
  vim.wo[sidebar_win].winfixwidth    = true

  set_keymaps()

  -- clean up state when buffer is wiped
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = sidebar_buf,
    once   = true,
    callback = function()
      watcher.off_change(on_trigger)
      sidebar_win = nil
      sidebar_buf = nil
      file_lines  = {}
    end,
  })

  watcher.on_change(on_trigger)
  M.render()
end

function M.close()
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    vim.api.nvim_win_close(sidebar_win, true)
  end
  -- BufWipeout autocmd handles cleanup
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

-- Move sidebar cursor to the line showing `filepath`.
function M.sync_cursor(filepath)
  if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then return end
  for line, fp in pairs(file_lines) do
    if fp == filepath then
      vim.api.nvim_win_set_cursor(sidebar_win, { line, 0 })
      return
    end
  end
end

-- Reset review state (call on ClaudeDiffReset)
function M.reset_state()
  review_state = {}
  file_lines   = {}
end

return M
```

- [ ] **Step 2: Verify the module loads without errors**

In Neovim: `:lua require("claude-diff.sidebar").open()`

Expected: a ~32-col sidebar appears on the left with "Changes (0)" and "Help: ?".

- [ ] **Step 3: Commit**

```bash
git add lua/claude-diff/sidebar.lua
git commit -m "feat(sidebar): add persistent sidebar with directory grouping and review state"
```

---

## Task 7: Wire sidebar into init.lua

Connect the sidebar to the plugin lifecycle: `<leader>cd` toggle, auto-open on VimEnter, re-render on DirChanged, reset on ClaudeDiffReset.

**Files:**
- Modify: `lua/claude-diff/init.lua`

- [ ] **Step 1: Update init.lua**

Full new content of `lua/claude-diff/init.lua`:

```lua
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

  -- Global toggle
  vim.keymap.set("n", "<leader>cd", function()
    local ok, sidebar = pcall(require, "claude-diff.sidebar")
    if ok then sidebar.toggle() end
  end, { silent = true, desc = "Toggle Claude diff sidebar" })

  -- Diff view close-all binding (available outside sidebar)
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
```

- [ ] **Step 2: Verify full plugin loads without errors**

In Neovim with the plugin loaded via lazy.nvim: `:lua require("claude-diff").setup({})` — no errors.

Run `:ClaudeDiff` — opens picker (unchanged). Press `<leader>cd` — sidebar opens/closes.

- [ ] **Step 3: Commit**

```bash
git add lua/claude-diff/init.lua
git commit -m "feat(init): wire sidebar toggle, auto-open on VimEnter, DirChanged re-render"
```

---

## Task 8: End-to-end verification

Manual testing checklist to confirm the full flow works. No code changes — just verification.

- [ ] **Step 1: Install hooks and restart Claude Code**

```
:ClaudeDiffInstallHooks
```
Restart Claude Code. Verify `~/.claude/settings.json` has `PreToolUse` and `PostToolUse` entries pointing to the hook scripts.

- [ ] **Step 2: Ask Claude to edit 2-3 files, verify sidebar appears**

With Neovim open in a tmux pane, ask Claude to edit 2-3 files in the project. Within 500ms of the last edit:
- Sidebar should appear automatically on the left (or refresh if already open)
- Files listed with `●` icon, grouped by directory
- Header shows correct count

- [ ] **Step 3: Open a diff and verify review state updates**

Press `<CR>` on a file in the sidebar:
- Side-by-side diff opens in the remaining space
- File icon changes from `●` to `○` in the sidebar

Navigate with `]f`/`[f` in the diff view:
- Sidebar cursor follows the active file

- [ ] **Step 4: Revert a file and verify**

Press `<leader>cr` in the diff view:
- Buffer reverted to pre-Claude content
- File saved to disk (if `auto_save_on_revert = true`)
- Sidebar icon changes to `✗`

- [ ] **Step 5: Ask Claude to edit more files — sidebar updates in place**

Ask Claude to edit 1-2 more files while the sidebar is open:
- New files appear in the sidebar without losing cursor position or existing review state

- [ ] **Step 6: Verify cwd fix**

If possible, run Claude Code from a parent or sibling directory of the Neovim cwd. Diffs should still appear (verify `~/.local/share/claude-diff/*/cwd` file exists and matches Claude's cwd).

- [ ] **Step 7: Simulate corrupt manifest**

```bash
echo "bad json" > ~/.local/share/claude-diff/*/manifest.json
```

Run `:ClaudeDiff` or wait for a trigger. Expected: warning notification "claude-diff: manifest.json is corrupt — run :ClaudeDiffReset to clear" rather than silent failure.

- [ ] **Step 8: Toggle sidebar with `<leader>cd` and close with `q`**

- `<leader>cd` opens sidebar when closed, closes when open
- `q` inside sidebar closes sidebar + diff
- `<leader>cc` from anywhere closes sidebar + diff

- [ ] **Step 9: Final commit if any minor fixes needed**

```bash
git add -p
git commit -m "fix: end-to-end verification fixes"
```
