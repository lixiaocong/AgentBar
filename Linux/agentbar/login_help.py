"""Manual recovery instructions only; AgentBar never performs these logins."""
from .models import PROVIDERS


def login_help(provider):
    help_by_provider = {
        "codex": dict(command="codex login --device-auth",
                      instructions="用运行 AgentBar 的 Linux 用户执行，按终端链接和设备码完成 ChatGPT 登录。也可使用 codex login。",
                      docsUrl="https://developers.openai.com/codex/auth"),
        "githubCopilot": dict(command="copilot login",
                              instructions="用运行 AgentBar 的 Linux 用户执行，按终端显示的链接完成 GitHub 授权。",
                              docsUrl="https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference"),
        "gemini": dict(command="NO_BROWSER=true gemini", interactiveCommand="/auth",
                       instructions="在服务器启动后，在 Gemini 交互界面输入 /auth，选择 Sign in with Google，按终端提示完成授权。",
                       docsUrl="https://geminicli.com/docs/reference/commands/#auth"),
        "claude": dict(command="claude auth login",
                       instructions="用运行 AgentBar 的 Linux 用户执行，选择 Claude 订阅账户并完成授权。旧版可运行 claude 后输入 /login。",
                       docsUrl="https://code.claude.com/docs/en/cli-reference"),
    }
    return help_by_provider.get(provider, dict(command=None,
        instructions="%s 使用本地 token 文件。请更新配置所指向文件中的有效 token，然后重新扫描账户。" % PROVIDERS[provider]))
