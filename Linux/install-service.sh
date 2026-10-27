#!/usr/bin/env bash
set -euo pipefail

agentbar_linux_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
agentbar_unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
agentbar_data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/agentbar"
mkdir -p "$agentbar_unit_dir" "$agentbar_data_dir"
chmod 700 "$agentbar_data_dir"

# systemd 路径含特殊字符时需要转义；同时传入当前 XDG 路径，避免服务环境差异。
python3 - "$agentbar_linux_dir" "$agentbar_unit_dir/agentbar.service" "$agentbar_data_dir" <<'PY'
import os
import sys
from pathlib import Path

root, destination, data = sys.argv[1:]
def quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('\n', '\\n') + '"'
text = (Path(root) / 'agentbar.service').read_text()
if '\n' in root or '\r' in root:
    raise SystemExit('The checkout path must not contain a line break')
text = text.replace('@LINUX_DIR@', root.replace('%', '%%'))
text = text.replace('--port 8765', '--port 8765 --data-dir ' + quote(data))
text = text.replace('ReadWritePaths=%h/.local/share/agentbar', 'ReadWritePaths=' + quote(data))
config = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home() / '.config'))) / 'agentbar/config.json'
text = text.replace('--data-dir ' + quote(data), '--data-dir ' + quote(data) + ' --config ' + quote(str(config)))
for name in ('CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'COPILOT_HOME', 'XDG_CONFIG_HOME'):
    if name in os.environ:
        text = text.replace('[Service]\n', '[Service]\nEnvironment=' + quote(name + '=' + os.environ[name]) + '\n')
Path(destination).write_text(text)
PY
systemctl --user daemon-reload
systemctl --user enable agentbar.service
systemctl --user restart agentbar.service
printf 'AgentBar: http://<server-address>:8765\nWeb access key: %s/web-access-key\n' "$agentbar_data_dir"
printf 'Status: systemctl --user status agentbar.service\n'
