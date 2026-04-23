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
if [ "$NEEDS_NVIM" = "trigger_touched" ] && [ -n "${TMUX:-}" ]; then
  if ! tmux list-panes -s -F "#{pane_current_command}" 2>/dev/null | grep -qE "^n?vim$"; then
    tmux new-window -d -n "claude-diff" -c "$PWD" "nvim"
  fi
fi
