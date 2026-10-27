# AgentBar Linux Web

Linux 版通过浏览器查看 Agent 配额，后台独立采样，SQLite 历史与浏览器是否打开无关。
需要 Python 3.8+，无需 pip、Node、桌面环境或构建。macOS/Windows 的界面和登录行为保持原样。

## 运行

```bash
cd /home/ubuntu/code/AgentBar/Linux
python3 -m agentbar --host 0.0.0.0 --port 8765
```

浏览器打开 `http://<服务器地址>:8765`。输入 Web 访问密钥（默认位于
`~/.local/share/agentbar/web-access-key`），然后点击「添加账户」，从扫描到的本地凭据中选择。
首次运行没有启用任何账户。Web 访问密钥用于保护用量数据，与 Agent 的 CLI 登录分开。
密钥仅通过密码输入框提交，不放在 URL、浏览器本地存储或日志中。
直接暴露到不受信任网络时，使用 HTTPS 反向代理，或传入 `--tls-cert` 和 `--tls-key`。
也可以使用默认的 `127.0.0.1` 监听地址，通过 SSH 转发访问。

## 本机凭据

在**运行服务的同一 Linux 用户**下执行 `codex login`、`gemini` 或其他 CLI 的登录命令。
AgentBar **只读**凭据，定期重新扫描，不执行 OAuth 登录、token 刷新、登出或修改凭据。
过期或失效时，更新 CLI 登录即可；采样会自动重试，已有历史保留。

登录失效卡片会给出对应命令，在运行 AgentBar 的同一 Linux 用户下执行：

| Provider | 服务器终端命令 | 后续步骤 |
| --- | --- | --- |
| Codex | `codex login --device-auth` | 根据终端链接和设备码完成 ChatGPT 登录；也可用 `codex login` |
| Gemini | `NO_BROWSER=true gemini` | 进入后输入 `/auth`，选择 **Sign in with Google** |
| GitHub Copilot | `copilot login` | 根据终端链接完成 GitHub 授权 |
| Claude Code | `claude auth login` | 选择 Claude 订阅账户；旧版可运行 `claude` 后输入 `/login` |

完成后自动重新读取凭据。若登录的是不同账户，在「添加账户」中选择新账户。
这些命令是操作指引，AgentBar 不会执行它们。

| Provider | 默认读取位置 |
| --- | --- |
| Codex | `${CODEX_HOME:-~/.codex}/auth.json` 的 `tokens`，需 ChatGPT OAuth 登录 |
| Claude Code | `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json` 的 `claudeAiOauth`；`~/.claude.json` 提供账户标签 |
| Gemini | `~/.gemini/oauth_creds.json` |
| GitHub Copilot | `${COPILOT_HOME:-~/.copilot}/config.json` 或 Copilot CLI 的系统钥匙串；兼容 `${XDG_CONFIG_HOME:-~/.config}/github-copilot/apps.json`、`hosts.json` |

Codex API key 模式、Codex 系统钥匙串和 CLI 自己加密的凭据不在当前支持范围。
Gemini 使用 CLI 的 Code Assist 配额，不包含 API key 计费账户。
Copilot 优先读取新版 CLI 的登录，其系统钥匙串通过已安装 npm 版 Copilot 自带的
`keytar` 模块只读访问（需要该 CLI 使用的 Node）；没有可用模块时仍支持文件凭据。
不会要求用户将钥匙串中的 token 导出成明文。
只有存在非空访问 token 的凭据才会列入可选账户；同一 provider 的同一账户会去重。
账户身份基于 provider 和用户/工作区标识，CLI 切换到不同身份后需重新添加。
无法识别身份的凭据以源路径作为标识。

其他位置或多个 CLI profile 可在 `~/.config/agentbar/config.json` 中指定，文件只保存路径：

```json
{
  "accounts": [
    {"provider": "codex", "credentials_file": "/home/me/profiles/work/auth.json", "label": "工作账户"},
    {"provider": "zai", "credentials_file": "/home/me/.config/zai/credential.json", "label": "Z.ai"},
    {"provider": "junie", "credentials_file": "/home/me/.config/junie/credential.json", "label": "Junie"}
  ]
}
```

Z.ai/Junie 文件接受 `access_token` 或 `token` 字段；AgentBar 不提供新增凭据的页面。
Z.ai 使用国际站 Coding Plan monitor API。Junie 在 API 只返回余额、没有总额度时仅显示余额，
不会猜测配额百分比。自定义路径通过 `--config` 指定。

「移除」仅更新 AgentBar 的启用名单：停止展示和后续采样，CLI 凭据和已有历史保留。
启用名单位于数据目录下的 `accounts.json`，其中不包含 token。
后台只扫描启用账户所属的 Provider，未启用或已移除账户的凭据读取错误不会显示在主页面。
「添加账户」仍扫描全部本地凭据，并在该窗口中显示扫描诊断；启用账户的读取错误显示在其卡片上。

## 常驻运行

在当前 Linux 用户下安装 systemd 用户服务：

```bash
cd /home/ubuntu/code/AgentBar/Linux
bash install-service.sh
systemctl --user status agentbar.service
journalctl --user -u agentbar.service -n 30
```

默认监听 `0.0.0.0:8765`，每 60 秒轮询。安装脚本写入仓库的绝对路径，移动仓库后需重新安装。
修改 unit 后使用 `systemctl --user daemon-reload` 和 `systemctl --user restart agentbar`。
希望 SSH 退出后和开机后仍运行，可由机器管理员执行 `loginctl enable-linger <用户名>`。
停止使用 `systemctl --user disable --now agentbar.service`。不支持 systemd 的机器可用现有进程管理器运行上述 Python 命令。

## 历史语义

- 只采集用户启用的账户；各账户并发查询，独立失败与退避（最长一小时）。
- 浏览器仅查询采样结果，不触发额外的 provider API 请求。重启后从启用名单继续采集。
- 每次成功查询都会写入各配额窗口的实际观测，即使余额和重置时间未变化。默认每 60 秒一轮，记录成功响应的时间。
- Linux 与 macOS 的采样存储策略独立：Linux 持续保存完整成功采样，macOS 保留原有变化去重及 15 分钟心跳。
- 失败请求不写入配额点，也不以缓存快照补点。查询时仍需后续成功样本确认额度恢复、突然耗尽和周期变化。
- 查询时过滤未确认的额度恢复/耗尽尖峰；重置周期需后续样本确认，5 分钟内的抖动或滚动倒计时不计作重置。
- GPT reserve 作为附加额度展示和记录。动态窗口或账户消失后，已有记录继续可查。
- 历史图按时间桶保留首尾、极值和重置事件；曲线表示**观测到的剩余配额**，不是精确 token、请求次数或账单。
- 历史少于所选范围时，横轴从首条已有记录开始；此前已有记录时保留范围左边界的延续值。
- 鼠标在绘图区悬浮时按时间选择最近的真实采样点，显示指示线、采样时间、剩余比例和原始配额标签。
  范围边界的延续点会注明实际采样时间；也支持触屏点选及左右方向键查看，Escape 隐藏提示。
- 服务停止、网络错误或登录过期期间不能补采。CLI 更新凭据后恢复采样；文件不会自动清理。

## 桌面显示一致性

Linux Web 保留自适应布局和服务器账户管理，Provider 分栏、原始 SVG 图标、账户徽章、配额标签及 reset 信息对齐桌面版。
颜色计算移植自 `AgentQuotaDisplayColor.swift`：有可用时间窗口时比较剩余额度和剩余工作日时间基准，按浏览器本地时区处理周末及夏令时；
无有效时间窗口时使用同样的 75% / 45% / 20% 四档阈值。进度条上的细线表示时间基准。

配额行显示剩余额度、已用额度，以及 `Resets <倒计时> at <本地时间>`。Codex 可选读取 reset credits 接口，
显示可用次数和最早到期的三条记录；该接口不可用时继续显示主要配额。这里只展示信息，不执行重置。
Provider 合计只计算所有账户共有的窗口，使用平均剩余额度及最早重置时间，排除 GPT reserve 附加额度。

默认数据目录 `${XDG_DATA_HOME:-~/.local/share}/agentbar` 包含 `quota-history.sqlite3`（WAL）、启用名单、
Web 密钥和进程锁。目录/文件限制为当前用户。历史只保存账户标签和归一化配额，不保存凭据或完整 API 响应。
备份运行中的数据库需使用 SQLite backup API；停服后可以复制整个数据目录。
Linux 数据库独立于 macOS 的数据库，当前不提供两者的导入或同步。

## 开发验证

```bash
cd Linux
python3 -m unittest discover -s tests -v
node --check agentbar/static/app.js  # 可选，仅开发需要 Node
node --test tests/quota-display.test.cjs  # 桌面颜色、时区、DST、重置标签和合计规则
```

Linux 测试复用 `Shared/AgentBarFixtures`，验证 provider 解析、只读凭据、账户选择、历史规则、
无浏览器持续采集、重启持久化，以及 HTTP 身份验证和凭据隔离。
