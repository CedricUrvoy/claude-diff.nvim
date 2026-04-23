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
