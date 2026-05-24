using System.Windows;
using AgentBar.Core;

namespace AgentBar.Windows;

public partial class App : System.Windows.Application
{
    private TrayController? _trayController;
    private RefreshCoordinator? _coordinator;
    private CancellationTokenSource? _timerCts;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var paths = AgentBarPaths.Default;
        var authStore = new DpapiAuthSessionStore(paths);
        var settingsStore = new JsonSettingsStore(paths);
        var serviceFactory = new AgentQuotaServiceFactory(authStore);
        _coordinator = new RefreshCoordinator(settingsStore, authStore, serviceFactory, paths);

        var browser = new WindowsBrowserLauncher();
        var callbackServer = new TcpLocalCallbackServer();
        _trayController = new TrayController(
            _coordinator,
            new TrayIconRenderer(),
            new CodexBrowserLoginService(authStore, browser, callbackServer),
            new GitHubCopilotBrowserLoginService(authStore, browser),
            new GeminiBrowserLoginService(authStore, browser, callbackServer));

        await _coordinator.InitializeAsync();
        _trayController.Show();
        _ = RefreshIgnoringErrorsAsync();
        StartRefreshLoop();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _timerCts?.Cancel();
        _trayController?.Dispose();
        base.OnExit(e);
    }

    private void StartRefreshLoop()
    {
        _timerCts = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            while (!_timerCts.IsCancellationRequested)
            {
                var delay = TimeSpan.FromSeconds(_coordinator?.Settings.RefreshIntervalSeconds ?? 60);
                await Task.Delay(delay, _timerCts.Token);
                await RefreshIgnoringErrorsAsync();
            }
        }, _timerCts.Token);
    }

    private async Task RefreshIgnoringErrorsAsync()
    {
        if (_coordinator is null)
        {
            return;
        }

        try
        {
            await _coordinator.RefreshNowAsync();
        }
        catch
        {
            // Account-level failures are represented in RefreshCoordinator statuses.
        }
    }
}
