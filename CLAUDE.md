# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

`claude-diff.nvim` is a Neovim plugin that hooks into Claude Code's `PreToolUse`/`PostToolUse` hook system to provide a side-by-side histogram diff of every file Claude modifies. Users can browse changed files, navigate hunks, and revert to pre-Claude state.

There is no build step, no test suite, and no CI. The plugin ships as-is via `lazy.nvim`.

## Commands

No build or lint commands exist. Manual testing is done by loading the plugin in Neovim and exercising the user commands (`:ClaudeDiff`, `:ClaudeDiffFile`, `:ClaudeDiffReset`, `:ClaudeDiffInstallHooks`).

## Architecture

### Lua module layout

```
lua/claude-diff/
  init.lua      -- M.setup(), user commands, autocmds, M.actions (thin wiring only)
  config.lua    -- M.defaults + M.values; cfg.setup(opts) merges opts once at startup
  session.lua   -- session_dir(), read_manifest(), get_original()
  watcher.lua   -- M.start(), M.stop_all() — uv fs_event + debounce timer
  diff.lua      -- open_diff_for_file(), close_diff(), set_files(), get_files()
  picker.lua    -- pick() — snacks picker + quickfix fallback
  hooks.lua     -- install() — reads/writes ~/.claude/settings.json
```

Dependency DAG (no cycles):
```
config ← session ← watcher
                 ← diff
                 ← picker ← diff
hooks  (no deps on other modules)
init   ← all of the above
```

All modules read live config via `require("claude-diff.config").values` — no module-level copies.

### Shell hooks

- `hooks/claude-pre-tool.sh` — `PreToolUse` Claude Code hook; snapshots files before edits
- `hooks/claude-post-tool.sh` — `PostToolUse` Claude Code hook; touches the trigger file

### Data flow

1. **Pre-hook** receives JSON from stdin (Claude's tool-call context). On first write per file per session, it copies the file to `~/.local/share/claude-diff/<project_hash>/originals/<key>` and records it in `manifest.json`. On new `session_id`, it wipes the previous session's data first.
2. **Post-hook** marks the file `modified: true` in `manifest.json`, writes a timestamp to the `trigger` file, and optionally spawns a tmux window running `nvim`.
3. **Lua watcher** (`vim.uv.new_fs_event`) watches the `trigger` file. Changes fire a debounced notification (default 500 ms).
4. **`:ClaudeDiff`** reads `manifest.json`, opens a `snacks.nvim` picker (with `vim.diff()` preview) or falls back to quickfix.
5. **`open_diff_for_file(filepath, style)`** dispatches to one of three renderers based on `style` (default `cfg.values.diff_style`):
   - `side_by_side` — `leftabove vsplit`, scratch buffer on left, real file on right, both `diffthis` with `algorithm:histogram,linematch:60,inline:simple`
   - `unified` — single read-only scratch buffer containing `vim.diff()` output, `ft=diff`
   - `inline` — real file with Neovim's built-in `inline:only` diff (temporary split for the original is closed immediately)
6. Inside any diff view, `]d`/`[d` cycle through the three styles for the current file without losing the file navigation list.

### Storage layout

```
~/.local/share/claude-diff/<sha256(cwd)[0:8]>/
  originals/<key>   # snapshot before first Claude edit (first-write-wins)
  manifest.json     # filepath → {original, new, modified}
  trigger           # touched by post-hook to wake the Lua watcher
  session_id        # Claude session ID for session-boundary detection
```

### Key invariants

- **First-write-wins**: the pre-hook only snapshots if no snapshot exists yet — the baseline is always the state before Claude touched the file in the current session.
- **Session isolation**: `session_id` from the hook context drives automatic wipe of stale session data when Claude starts a new session.
- **`diffopt` save/restore**: `open_diff_for_file` saves the user's `diffopt` and restores it when the diff is closed.
- **Per-cwd namespacing**: `DirChanged` autocmd restarts the watcher for the correct project hash when the user switches directories.
- **`snacks.nvim` is optional**: picker degrades to quickfix if not present.

### Hook installation

`:ClaudeDiffInstallHooks` locates the hook scripts relative to `hooks.lua` via `debug.getinfo`, then upserts `PreToolUse`/`PostToolUse` entries into `~/.claude/settings.json`. Claude Code must be restarted after installation.
