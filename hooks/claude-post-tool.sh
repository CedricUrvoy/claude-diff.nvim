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
trigger_path = os.path.join(session_dir, 'trigger')

if os.path.exists(manifest_path):
    try:
        with open(manifest_path) as f:
            m = json.load(f)
        if filepath in m and not m[filepath].get('modified'):
            m[filepath]['modified'] = True
            with open(manifest_path, 'w') as f:
                json.dump(m, f)
    except (json.JSONDecodeError, IOError):
        pass

# Always create/touch the trigger — even when nvim is not yet running so the
# bash block below can open it. The Lua start_watcher() will pick it up on
# VimEnter and notify immediately via the existing VimEnter autocmd.
os.makedirs(session_dir, exist_ok=True)
with open(trigger_path, 'w') as f:
    f.write(str(time.time()))
print('trigger_touched')
")

# If we're in tmux and no nvim pane exists, open one in a new background window.
# The lua plugin checks the manifest on VimEnter and notifies immediately.
if [ "$NEEDS_NVIM" = "trigger_touched" ] && [ -n "${TMUX:-}" ]; then
  if ! tmux list-panes -s -F "#{pane_current_command}" 2>/dev/null | grep -qE "^n?vim$"; then
    tmux new-window -d -n "claude-diff" -c "$PWD" "nvim"
  fi
fi
