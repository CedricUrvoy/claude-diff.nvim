# claude-diff.nvim

Review Claude Code's file edits in a side-by-side diff inside Neovim.

Claude Code's hook system snapshots every file before it's modified. The plugin watches for changes, notifies you, and opens a histogram-diff view with revert support.

## How it works

1. A `PreToolUse` hook saves the original file before every Write/Edit/MultiEdit.
2. A `PostToolUse` hook touches a trigger file and optionally opens Neovim in a new tmux window if none is running.
3. The plugin watches the trigger file with `vim.uv.fs_event` and notifies you when Claude modifies files.
4. `:ClaudeDiff` opens a picker listing all changed files with a unified-diff preview.
5. Selecting a file opens a diff view. The style is configurable (`side_by_side`, `unified`, or `inline`) and can be cycled live with `]d` / `[d`.

## Requirements

- Neovim ≥ 0.10
- [snacks.nvim](https://github.com/folke/snacks.nvim) (optional — falls back to quickfix)
- Python 3 (for the hook scripts)
- Claude Code CLI

## Installation

### lazy.nvim

```lua
{
  "CedricUrvoy/claude-diff.nvim",
  event = "VeryLazy",
  opts = {},
}
```

`opts = {}` is enough to use all defaults. lazy.nvim calls `setup(opts)` automatically.

### Install Claude Code hooks

Run once after installing the plugin:

```
:ClaudeDiffInstallHooks
```

This writes the `PreToolUse` / `PostToolUse` hook entries into `~/.claude/settings.json` pointing to the bundled scripts. Restart Claude Code afterwards.

## Configuration

All options and their defaults:

```lua
opts = {
  debounce_ms         = 500,           -- ms to wait before firing the "modified" notification
  auto_save_on_revert = true,          -- write the file to disk after reverting
  notify_position     = true,          -- show "[2/5] path/to/file" when cycling through files
  diff_style          = "side_by_side", -- default style: "side_by_side" | "unified" | "inline"
  base_dir            = vim.fn.expand("~/.local/share/claude-diff"),
}
```

## Commands

| Command | Description |
|---|---|
| `:ClaudeDiff` | Open picker of all files changed in the current Claude session |
| `:ClaudeDiffFile [path]` | Open diff view for a specific file (or picker if no arg) |
| `:ClaudeDiffReset` | Clear session data and restart the watcher |
| `:ClaudeDiffInstallHooks` | Write hook entries to `~/.claude/settings.json` |

## Keymaps (in diff view)

| Key | Action |
|---|---|
| `q` | Close diff |
| `]c` / `[c` | Next / prev hunk (wrapping) |
| `]f` / `[f` | Next / prev changed file |
| `]d` / `[d` | Next / prev diff style (side-by-side → unified → inline) |
| `<leader>cr` | Revert file to pre-Claude state |

## Session lifecycle

Each Claude Code session is identified by its `session_id`. When a new session starts, all snapshots from the previous one are wiped so diffs always reflect the current session only. Use `:ClaudeDiffReset` to clear manually.
