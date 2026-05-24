using System.Windows;
using AgentBar.Core;
using Forms = System.Windows.Forms;

namespace AgentBar.Windows;

public sealed class TrayController : IDisposable
{
    private readonly RefreshCoordinator _coordinator;
    private readonly ITrayIconRenderer _renderer;
    private readonly CodexBrowserLoginService _codexLogin;
    private readonly GitHubCopilotBrowserLoginService _copilotLogin;
    private readonly GeminiBrowserLoginService _geminiLogin;
    private readonly Forms.NotifyIcon _notifyIcon;
    private PopoverWindow? _popover;
    private SettingsWindow? _settings;
    private System.Drawing.Icon? _currentIcon;
    private DateTimeOffset _lastTrayActivation = DateTimeOffset.MinValue;
    private System.Drawing.Point _lastTrayAnchor = System.Drawing.Point.Empty;

    public TrayController(
        RefreshCoordinator coordinator,
        ITrayIconRenderer renderer,
        CodexBrowserLoginService codexLogin,
        GitHubCopilotBrowserLoginService copilotLogin,
        GeminiBrowserLoginService geminiLogin)
    {
        _coordinator = coordinator;
        _renderer = renderer;
        _codexLogin = codexLogin;
        _copilotLogin = copilotLogin;
        _geminiLogin = geminiLogin;
        _notifyIcon = new Forms.NotifyIcon
        {
            Visible = false,
            ContextMenuStrip = BuildMenu()
        };
        _notifyIcon.Click += NotifyIconOnClick;
        _notifyIcon.MouseDown += NotifyIconOnMouseDown;
        _notifyIcon.MouseUp += NotifyIconOnMouseUp;
        _notifyIcon.MouseClick += NotifyIconOnMouseClick;
        _notifyIcon.DoubleClick += NotifyIconOnDoubleClick;
        _coordinator.Updated += CoordinatorOnUpdated;
        UpdateTray();
    }

    public void Show()
    {
        _notifyIcon.Visible = true;
    }

    public void Dispose()
    {
        _coordinator.Updated -= CoordinatorOnUpdated;
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _currentIcon?.Dispose();
        _popover?.Close();
        _settings?.Close();
    }

    private Forms.ContextMenuStrip BuildMenu()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Opening += (_, _) => CaptureTrayAnchor();
        menu.Items.Add("Refresh", null, async (_, _) => await RefreshAsync());
        menu.Items.Add("Open", null, (_, _) => OpenPopoverFromTray(toggle: false));
        menu.Items.Add("Settings", null, (_, _) => ShowSettings());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => System.Windows.Application.Current.Shutdown());
        return menu;
    }

    private void NotifyIconOnClick(object? sender, EventArgs e)
    {
        if (Forms.Control.MouseButtons == Forms.MouseButtons.Left)
        {
            CaptureTrayAnchor();
            OpenPopoverFromTray(toggle: true);
        }
    }

    private void NotifyIconOnMouseDown(object? sender, Forms.MouseEventArgs e)
    {
        if (e.Button == Forms.MouseButtons.Left)
        {
            CaptureTrayAnchor();
            OpenPopoverFromTray(toggle: true);
        }
    }

    private void NotifyIconOnMouseUp(object? sender, Forms.MouseEventArgs e)
    {
        if (e.Button == Forms.MouseButtons.Left)
        {
            CaptureTrayAnchor();
            OpenPopoverFromTray(toggle: true);
        }
    }

    private void NotifyIconOnMouseClick(object? sender, Forms.MouseEventArgs e)
    {
        if (e.Button == Forms.MouseButtons.Left)
        {
            CaptureTrayAnchor();
            OpenPopoverFromTray(toggle: true);
        }
    }

    private void NotifyIconOnDoubleClick(object? sender, EventArgs e)
    {
        CaptureTrayAnchor();
        OpenPopoverFromTray(toggle: true);
    }

    private void CoordinatorOnUpdated(object? sender, EventArgs e)
    {
        System.Windows.Application.Current.Dispatcher.Invoke(() =>
        {
            UpdateTray();
            _popover?.Render();
            _settings?.Render();
        });
    }

    private void UpdateTray()
    {
        var rendered = _renderer.Render(_coordinator.TrayBars, 32);
        var previous = _currentIcon;
        _currentIcon = rendered.Icon;
        _notifyIcon.Icon = _currentIcon;
        _notifyIcon.Text = TooltipForNotifyIcon(_coordinator.TooltipText);
        previous?.Dispose();
    }

    private void OpenPopoverFromTray(bool toggle)
    {
        var now = DateTimeOffset.UtcNow;
        if (now - _lastTrayActivation < TimeSpan.FromMilliseconds(180))
        {
            return;
        }
        _lastTrayActivation = now;

        ShellLog.Write("OpenPopover requested.");
        try
        {
            var dispatcher = System.Windows.Application.Current.Dispatcher;
            var anchor = _lastTrayAnchor == System.Drawing.Point.Empty ? Forms.Cursor.Position : _lastTrayAnchor;
            if (dispatcher.CheckAccess())
            {
                ShowPopover(anchor, toggle);
            }
            else
            {
                dispatcher.Invoke(() => ShowPopover(anchor, toggle));
            }
        }
        catch (Exception ex)
        {
            ShellLog.Write(ex, "OpenPopover failed");
            System.Windows.MessageBox.Show(
                ex.Message,
                "AgentBar",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void CaptureTrayAnchor()
    {
        _lastTrayAnchor = Forms.Cursor.Position;
        ShellLog.Write($"Tray anchor captured x={_lastTrayAnchor.X} y={_lastTrayAnchor.Y}");
    }

    private void ShowPopover(System.Drawing.Point anchor, bool toggle)
    {
        ShellLog.Write($"ShowPopover entered. anchorX={anchor.X} anchorY={anchor.Y}");
        _popover ??= new PopoverWindow(_coordinator, ShowSettings);
        if (toggle && _popover.IsVisible)
        {
            _popover.Hide();
            ShellLog.Write("ShowPopover toggled existing window closed.");
            return;
        }

        _popover.Render();
        _popover.ShowNearAnchor(anchor);
        _popover.Activate();
        ShellLog.Write($"ShowPopover completed. Visible={_popover.IsVisible} Left={_popover.Left} Top={_popover.Top} Width={_popover.Width} Height={_popover.Height}");
    }

    private void ShowSettings()
    {
        _popover?.Hide();
        if (_settings is null)
        {
            _settings = new SettingsWindow(
                _coordinator,
                _codexLogin,
                _copilotLogin,
                _geminiLogin);
            _settings.Closed += (_, _) => _settings = null;
        }

        _settings.Render();
        _settings.Show();
        _settings.Activate();
    }

    private async Task RefreshAsync()
    {
        await _coordinator.RefreshNowAsync();
    }

    private static string TooltipForNotifyIcon(string text)
    {
        var singleLine = text.Replace(Environment.NewLine, " | ");
        return singleLine.Length <= 63 ? singleLine : singleLine[..60] + "...";
    }
}
