using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using AgentBar.Core;
using Forms = System.Windows.Forms;

namespace AgentBar.Windows;

public sealed class SettingsWindow : Window
{
    private readonly RefreshCoordinator _coordinator;
    private readonly CodexBrowserLoginService _codexLogin;
    private readonly GitHubCopilotBrowserLoginService _copilotLogin;
    private readonly GeminiBrowserLoginService _geminiLogin;
    private readonly System.Windows.Controls.ListBox _accounts = new();
    private readonly StackPanel _trayChecks = new();
    private readonly System.Windows.Controls.TextBox _junieToken = new();
    private readonly System.Windows.Controls.TextBox _refreshInterval = new();
    private readonly TextBlock _status = new();

    public SettingsWindow(
        RefreshCoordinator coordinator,
        CodexBrowserLoginService codexLogin,
        GitHubCopilotBrowserLoginService copilotLogin,
        GeminiBrowserLoginService geminiLogin)
    {
        _coordinator = coordinator;
        _codexLogin = codexLogin;
        _copilotLogin = copilotLogin;
        _geminiLogin = geminiLogin;
        Title = "AgentBar Settings";
        Width = 620;
        SizeToContent = SizeToContent.Height;
        MaxHeight = Math.Min(760, SystemParameters.WorkArea.Height - 80);
        MinWidth = 560;
        Content = BuildContent();
    }

    public void Render()
    {
        _accounts.ItemsSource = _coordinator.AccountStatuses
            .Select(status => new AccountListItem(status.Id, $"{status.Provider.Title()} - {status.DisplayLabel ?? status.DisplayPath}"))
            .ToArray();
        _refreshInterval.Text = _coordinator.Settings.RefreshIntervalSeconds.ToString();
        RenderTrayChecks();
    }

    private UIElement BuildContent()
    {
        var root = new DockPanel { Margin = new Thickness(16) };
        _status.Foreground = System.Windows.Media.Brushes.DimGray;
        _status.Margin = new Thickness(0, 10, 0, 0);
        _status.Visibility = Visibility.Collapsed;
        DockPanel.SetDock(_status, Dock.Bottom);
        root.Children.Add(_status);

        var stack = new StackPanel();
        root.Children.Add(new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Padding = new Thickness(0, 0, 8, 0),
            Content = stack
        });

        stack.Children.Add(Heading("Accounts"));
        _accounts.Height = 150;
        stack.Children.Add(_accounts);

        var loginGrid = new UniformGrid { Columns = 3, Margin = new Thickness(0, 10, 0, 0) };
        loginGrid.Children.Add(Button("Sign in Codex", async () => await RunAsync(async () =>
        {
            var session = await _codexLogin.SignInAsync();
            await _coordinator.AddStoredAccountAsync(session);
            await _coordinator.RefreshNowAsync();
        })));
        loginGrid.Children.Add(Button("Sign in Copilot", async () => await RunAsync(async () =>
        {
            var session = await _copilotLogin.SignInAsync(message => ShowStatus(message, System.Windows.Media.Brushes.DimGray));
            await _coordinator.AddStoredAccountAsync(session);
            await _coordinator.RefreshNowAsync();
        })));
        loginGrid.Children.Add(Button("Sign in Gemini", async () => await RunAsync(async () =>
        {
            var session = await _geminiLogin.SignInAsync();
            await _coordinator.AddStoredAccountAsync(session);
            await _coordinator.RefreshNowAsync();
        })));
        stack.Children.Add(loginGrid);

        var manualGrid = new Grid { Margin = new Thickness(0, 10, 0, 0) };
        manualGrid.ColumnDefinitions.Add(new ColumnDefinition());
        manualGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _junieToken.MinWidth = 320;
        _junieToken.Margin = new Thickness(0, 0, 8, 0);
        _junieToken.VerticalContentAlignment = VerticalAlignment.Center;
        _junieToken.ToolTip = "Junie API token";
        manualGrid.Children.Add(_junieToken);
        var addJunie = Button("Add Junie Token", async () => await RunAsync(async () =>
        {
            await _coordinator.AddJunieTokenAsync(_junieToken.Text);
            _junieToken.Text = "";
            await _coordinator.RefreshNowAsync();
        }));
        Grid.SetColumn(addJunie, 1);
        manualGrid.Children.Add(addJunie);
        stack.Children.Add(manualGrid);

        var accountButtons = new UniformGrid { Columns = 2, Margin = new Thickness(0, 8, 0, 18) };
        accountButtons.Children.Add(Button("Add Claude Directory", async () => await RunAsync(async () =>
        {
            using var dialog = new Forms.FolderBrowserDialog
            {
                Description = "Choose a Claude config directory",
                SelectedPath = AgentBarPaths.ClaudeDefaultDirectory
            };
            if (dialog.ShowDialog() == Forms.DialogResult.OK)
            {
                await _coordinator.AddClaudeDirectoryAsync(dialog.SelectedPath);
                await _coordinator.RefreshNowAsync();
            }
        })));
        accountButtons.Children.Add(Button("Remove Selected", async () => await RunAsync(async () =>
        {
            if (_accounts.SelectedItem is AccountListItem item)
            {
                await _coordinator.RemoveAccountAsync(item.Id);
                await _coordinator.RefreshNowAsync();
            }
        })));
        stack.Children.Add(accountButtons);

        stack.Children.Add(Heading("Tray Icon Agent"));
        _trayChecks.Margin = new Thickness(0, 0, 0, 18);
        stack.Children.Add(_trayChecks);

        stack.Children.Add(Heading("Refresh"));
        var refreshPanel = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center
        };
        _refreshInterval.Width = 80;
        _refreshInterval.Height = 34;
        _refreshInterval.Margin = new Thickness(0, 0, 8, 0);
        _refreshInterval.Padding = new Thickness(8, 0, 8, 0);
        _refreshInterval.VerticalContentAlignment = VerticalAlignment.Center;
        refreshPanel.Children.Add(_refreshInterval);
        refreshPanel.Children.Add(Button("Save Interval", async () => await RunAsync(async () =>
        {
            if (int.TryParse(_refreshInterval.Text, out var seconds))
            {
                await _coordinator.SetRefreshIntervalAsync(seconds);
            }
        })));
        refreshPanel.Children.Add(Button("Refresh Now", async () => await RunAsync(async () => await _coordinator.RefreshNowAsync())));
        refreshPanel.Margin = new Thickness(0, 0, 0, 8);
        stack.Children.Add(refreshPanel);

        return root;
    }

    private void RenderTrayChecks()
    {
        _trayChecks.Children.Clear();
        _trayChecks.Children.Add(new TextBlock
        {
            Text = "Windows tray icon shows one selected agent as a quota pie.",
            Foreground = System.Windows.Media.Brushes.DimGray,
            Margin = new Thickness(0, 0, 0, 6)
        });
        var automatic = new System.Windows.Controls.RadioButton
        {
            Content = "Automatic first available account",
            IsChecked = _coordinator.Settings.MenuBarAccountIds.Count == 0,
            GroupName = "TrayIconAgent",
            Margin = new Thickness(0, 3, 0, 3)
        };
        automatic.Checked += async (_, _) => await RunAsync(async () => await _coordinator.ResetMenuBarSelectionAsync());
        _trayChecks.Children.Add(automatic);

        foreach (var status in _coordinator.AccountStatuses)
        {
            var check = new System.Windows.Controls.RadioButton
            {
                Content = $"{status.Provider.Title()} - {status.DisplayLabel ?? status.DisplayPath}",
                IsChecked = _coordinator.Settings.MenuBarAccountIds.Contains(status.Id, StringComparer.OrdinalIgnoreCase),
                GroupName = "TrayIconAgent",
                Tag = status.Id,
                Margin = new Thickness(0, 3, 0, 3)
            };
            check.Checked += async (_, _) => await RunAsync(async () => await _coordinator.SetAccountShownInMenuBarAsync((string)check.Tag, true));
            _trayChecks.Children.Add(check);
        }
    }

    private async Task RunAsync(Func<Task> action)
    {
        try
        {
            ShowStatus("Working...", System.Windows.Media.Brushes.DimGray);
            await action();
            Render();
            HideStatus();
        }
        catch (Exception ex)
        {
            ShowStatus(ex.Message, System.Windows.Media.Brushes.Firebrick);
        }
    }

    private void ShowStatus(string? message, System.Windows.Media.Brush brush)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            HideStatus();
            return;
        }

        _status.Text = message.Trim();
        _status.Foreground = brush;
        _status.Visibility = Visibility.Visible;
    }

    private void HideStatus()
    {
        _status.Text = "";
        _status.Visibility = Visibility.Collapsed;
    }

    private static TextBlock Heading(string text) =>
        new()
        {
            Text = text,
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 8, 0, 8)
        };

    private static System.Windows.Controls.Button Button(string text, Func<Task> action)
    {
        var button = new System.Windows.Controls.Button
        {
            Content = text,
            Margin = new Thickness(3),
            Padding = new Thickness(10, 5, 10, 5)
        };
        button.Click += async (_, _) => await action();
        return button;
    }

    private sealed record AccountListItem(string Id, string Display)
    {
        public override string ToString() => Display;
    }
}
