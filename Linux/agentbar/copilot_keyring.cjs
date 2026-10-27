// 复用已安装 Copilot CLI 的只读凭据接口，不调用 CLI 登录或修改钥匙串。
'use strict';

(async () => {
  const keytar = require(process.argv[2]);
  const entries = await keytar.findCredentials('copilot-cli');
  const tokens = {};
  for (const entry of entries) {
    if (entry.account.startsWith('https://github.com:') && typeof entry.password === 'string') {
      tokens[entry.account] = entry.password;
    }
  }
  // stdout 仅供父进程捕获，不能转发到日志、终端或 HTTP 响应。
  process.stdout.write(JSON.stringify(tokens));
})().catch(() => { process.exitCode = 1; });
