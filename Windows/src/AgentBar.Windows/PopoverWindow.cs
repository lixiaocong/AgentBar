using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using AgentBar.Core;
using Forms = System.Windows.Forms;

namespace AgentBar.Windows;

public sealed class PopoverWindow : Window
{
    private const double ProviderColumnWidth = 264;
    private const double ProviderColumnSpacing = 14;
    private const double MetricBarWidth = 244;
    private const double WindowChromeWidth = 56;

    private readonly RefreshCoordinator _coordinator;
    private readonly Action _showSettings;
    private readonly StackPanel _content = new();
    private readonly List<FrameworkElement> _providerColumns = [];
    private WrapPanel? _providerPanel;
    private bool _isPositioning;
    private int _activeColumnCount = 1;

    public PopoverWindow(RefreshCoordinator coordinator, Action showSettings)
    {
        _coordinator = coordinator;
        _showSettings = showSettings;
        Width = ProviderColumnWidth + WindowChromeWidth;
        MinHeight = 220;
        MaxHeight = 760;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = true;
        SizeToContent = SizeToContent.Height;
        AllowsTransparency = true;
        Background = System.Windows.Media.Brushes.Transparent;
        Deactivated += (_, _) =>
        {
            if (!_isPositioning && IsVisible)
            {
                Hide();
            }
        };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Escape)
            {
                Hide();
                e.Handled = true;
            }
        };

        Content = new Border
        {
            Margin = new Thickness(8),
            CornerRadius = new CornerRadius(20),
            BorderThickness = new Thickness(1),
            BorderBrush = Brush(System.Windows.Media.Color.FromRgb(215, 210, 218)),
            Background = Brush(System.Windows.Media.Color.FromArgb(248, 255, 248, 252)),
            Padding = new Thickness(18, 18, 18, 18),
            Effect = new DropShadowEffect
            {
                BlurRadius = 24,
                ShadowDepth = 4,
                Direction = 270,
                Opacity = 0.24,
                Color = System.Windows.Media.Color.FromRgb(42, 38, 48)
            },
            Child = _content
        };
    }

    public void ShowNearAnchor(System.Drawing.Point anchorPoint)
    {
        _isPositioning = true;
        try
        {
            WindowState = WindowState.Normal;
            SizeToContent = SizeToContent.Manual;

            var originalOpacity = Opacity;
            if (!IsVisible)
            {
                Opacity = 0;
                Show();
                UpdateLayout();
            }

            var workingArea = Forms.Screen.FromPoint(anchorPoint).WorkingArea;
            var fromDevice = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
            var workTopLeft = fromDevice.Transform(new System.Windows.Point(workingArea.Left, workingArea.Top));
            var workBottomRight = fromDevice.Transform(new System.Windows.Point(workingArea.Right, workingArea.Bottom));
            var anchor = fromDevice.Transform(new System.Windows.Point(anchorPoint.X, anchorPoint.Y));
            var workLeft = workTopLeft.X;
            var workTop = workTopLeft.Y;
            var workRight = workBottomRight.X;
            var workBottom = workBottomRight.Y;
            var workWidth = workRight - workLeft;
            var workHeight = workBottom - workTop;

            var columns = PreferredColumnCount(workWidth);
            _activeColumnCount = columns;
            ApplyProviderLayout(_activeColumnCount);
            Width = PreferredWidth(columns, workWidth);
            var root = (FrameworkElement)Content;
            root.Measure(new System.Windows.Size(Width, double.PositiveInfinity));
            Height = root.DesiredSize.Height;

            Left = Clamp(anchor.X - Width / 2, workLeft + 8, workRight - Width - 8);
            Top = anchor.Y - Height - 12;
            if (Top < workTop + 8)
            {
                Top = anchor.Y + 12;
            }

            Top = Height > workHeight - 16
                ? workTop + 8
                : Clamp(Top, workTop + 8, workBottom - Height - 8);
            ShellLog.Write($"Popover positioned anchorX={anchorPoint.X} anchorY={anchorPoint.Y} dipAnchorX={anchor.X} dipAnchorY={anchor.Y} workArea={workingArea} left={Left} top={Top} width={Width} height={Height}");

            Opacity = originalOpacity;
            Show();
            ForceVisible();
            Topmost = false;
            Topmost = true;
            Activate();
            Focus();
        }
        finally
        {
            _isPositioning = false;
        }
    }

    public void Render()
    {
        _content.Children.Clear();
        _providerColumns.Clear();
        _providerPanel = null;
        _content.Margin = new Thickness(0);
        _content.Children.Add(Header());

        var statuses = _coordinator.AccountStatuses;
        var visibleProviders = AgentProviderKindExtensions.All
            .Where(provider => statuses.Any(status => status.Provider == provider))
            .ToArray();

        if (visibleProviders.Length == 0)
        {
            _content.Children.Add(EmptyTile());
            _content.Children.Add(Controls());
            return;
        }

        _providerPanel = new WrapPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            Margin = new Thickness(0, 0, 0, 8)
        };

        for (var index = 0; index < visibleProviders.Length; index++)
        {
            var provider = visibleProviders[index];
            var providerStatuses = statuses
                .Where(status => status.Provider == provider)
                .ToArray();
            var column = ProviderColumn(provider, providerStatuses);
            _providerColumns.Add(column);
            _providerPanel.Children.Add(column);
        }

        _content.Children.Add(_providerPanel);
        ApplyProviderLayout(_activeColumnCount);
        _content.Children.Add(Controls());
    }

    private int PreferredColumnCount(double workWidth)
    {
        var providerCount = Math.Max(1, AgentProviderKindExtensions.All.Count(provider =>
            _coordinator.AccountStatuses.Any(status => status.Provider == provider)));
        var availableContentWidth = Math.Max(ProviderColumnWidth, workWidth - WindowChromeWidth - 16);
        var maxColumns = Math.Max(1, (int)Math.Floor((availableContentWidth + ProviderColumnSpacing) / (ProviderColumnWidth + ProviderColumnSpacing)));
        return Math.Min(providerCount, maxColumns);
    }

    private double PreferredWidth(int columns, double workWidth)
    {
        var contentWidth = columns * ProviderColumnWidth + Math.Max(0, columns - 1) * ProviderColumnSpacing;
        return Clamp(contentWidth + WindowChromeWidth, ProviderColumnWidth + WindowChromeWidth, Math.Max(ProviderColumnWidth + WindowChromeWidth, workWidth - 16));
    }

    private void ApplyProviderLayout(int columns)
    {
        if (_providerPanel is null)
        {
            return;
        }

        columns = Math.Clamp(columns, 1, Math.Max(1, _providerColumns.Count));
        var contentWidth = columns * ProviderColumnWidth + Math.Max(0, columns - 1) * ProviderColumnSpacing;
        _providerPanel.Width = contentWidth;
        for (var index = 0; index < _providerColumns.Count; index++)
        {
            var isLastColumnInRow = (index + 1) % columns == 0;
            var isLastRow = index >= _providerColumns.Count - (_providerColumns.Count % columns == 0 ? columns : _providerColumns.Count % columns);
            _providerColumns[index].Margin = new Thickness(
                0,
                0,
                isLastColumnInRow ? 0 : ProviderColumnSpacing,
                isLastRow ? 0 : 12);
        }
    }

    private UIElement Header()
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 16) };
        grid.ColumnDefinitions.Add(new ColumnDefinition());

        var titleStack = new StackPanel { Orientation = System.Windows.Controls.Orientation.Vertical };
        titleStack.Children.Add(Text("AgentBar", 22, FontWeights.Bold, Brush(System.Windows.Media.Color.FromRgb(47, 50, 66)), TextWrapping.NoWrap));
        titleStack.Children.Add(Text("Agent usage", 12, FontWeights.Medium, Brush(System.Windows.Media.Color.FromRgb(118, 122, 138)), TextWrapping.NoWrap));
        grid.Children.Add(titleStack);
        return grid;
    }

    private UIElement Controls()
    {
        var wrapper = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Vertical,
            Margin = new Thickness(0, 2, 0, 0)
        };
        wrapper.Children.Add(new Border
        {
            Height = 1,
            Background = Brush(System.Windows.Media.Color.FromRgb(223, 219, 226), 0.85),
            Margin = new Thickness(0, 2, 0, 10)
        });

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var settings = FooterButton("Settings");
        settings.Click += (_, _) => _showSettings();
        grid.Children.Add(settings);

        var exit = FooterButton("Exit", isDestructive: true);
        exit.Click += (_, _) => System.Windows.Application.Current.Shutdown();
        Grid.SetColumn(exit, 2);
        grid.Children.Add(exit);
        wrapper.Children.Add(grid);
        return wrapper;
    }

    private static UIElement EmptyTile()
    {
        var panel = new StackPanel();
        panel.Children.Add(Text("No accounts configured.", 14, FontWeights.SemiBold, Brush(System.Windows.Media.Color.FromRgb(47, 50, 66))));
        panel.Children.Add(Text("Open Settings to add Codex, Copilot, Gemini, Claude, or Junie.", 12, FontWeights.Normal, Brush(System.Windows.Media.Color.FromRgb(118, 122, 138))));
        return new Border
        {
            CornerRadius = new CornerRadius(14),
            BorderThickness = new Thickness(1),
            BorderBrush = Brush(System.Windows.Media.Color.FromRgb(233, 230, 235)),
            Background = Brush(System.Windows.Media.Color.FromArgb(245, 255, 255, 255)),
            Padding = new Thickness(14, 12, 14, 12),
            Child = panel
        };
    }

    private static StackPanel ProviderColumn(AgentProviderKind provider, IReadOnlyList<AgentAccountStatus> statuses)
    {
        var snapshot = SummarySnapshot(statuses);
        var error = snapshot is null ? statuses.Select(status => status.ErrorMessage).FirstOrDefault(error => error is not null) : null;
        var column = new StackPanel
        {
            Width = ProviderColumnWidth
        };
        column.Children.Add(ProviderHeader(provider, statuses.Count, snapshot, error));

        if (statuses.Count == 0)
        {
            column.Children.Add(Text("No configured accounts are visible for this provider.", 12, FontWeights.Normal, Brush(System.Windows.Media.Color.FromRgb(118, 122, 138))));
            return column;
        }

        foreach (var status in statuses)
        {
            column.Children.Add(AccountSection(status));
        }

        return column;
    }

    private static UIElement ProviderHeader(
        AgentProviderKind provider,
        int accountCount,
        AgentQuotaSnapshot? snapshot,
        string? error)
    {
        var style = ProviderHeaderStyle(provider);
        var tint = PanelTint(snapshot?.HighlightMetric, error, style.Tint);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(ProviderIconBadge(style, tint));

        var titleStack = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Vertical,
            Margin = new Thickness(10, 0, 8, 0)
        };
        titleStack.Children.Add(Text(style.Eyebrow, 10, FontWeights.Black, Brush(tint), TextWrapping.NoWrap));
        titleStack.Children.Add(Text(style.Title, 17, FontWeights.ExtraBold, PrimaryBrush(), TextWrapping.NoWrap));
        titleStack.Children.Add(Text(accountCount == 1 ? "1 account" : $"{accountCount} accounts", 11, FontWeights.Medium, Brush(System.Windows.Media.Color.FromRgb(118, 122, 138)), TextWrapping.NoWrap));
        Grid.SetColumn(titleStack, 1);
        grid.Children.Add(titleStack);

        var statusStack = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Vertical,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right
        };
        var (value, label) = SnapshotStatus(snapshot, error, large: true);
        statusStack.Children.Add(Text(value, 28, FontWeights.Bold, Brush(tint), TextWrapping.NoWrap));
        statusStack.Children.Add(Text(label, 11, FontWeights.SemiBold, Brush(System.Windows.Media.Color.FromRgb(118, 122, 138)), TextWrapping.NoWrap));
        Grid.SetColumn(statusStack, 2);
        grid.Children.Add(statusStack);

        return new Border
        {
            CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(1),
            BorderBrush = Brush(tint, 0.16),
            Background = Brush(tint, 0.07),
            Padding = new Thickness(10, 9, 10, 9),
            Margin = new Thickness(0, 0, 0, 10),
            Child = grid
        };
    }

    private static UIElement AccountSection(AgentAccountStatus status)
    {
        var style = ProviderHeaderStyle(status.Provider);
        var tint = PanelTint(status.Snapshot?.HighlightMetric, status.ErrorMessage, style.Tint);
        var panel = new StackPanel { Orientation = System.Windows.Controls.Orientation.Vertical };
        panel.Children.Add(AccountHeader(status, tint));

        if (status.Snapshot is { } snapshot)
        {
            if (snapshot.Metrics.Count == 0)
            {
                panel.Children.Add(Text(snapshot.SourceSummary, 12, FontWeights.Normal, Brush(System.Windows.Media.Color.FromRgb(118, 122, 138))));
            }
            else
            {
                for (var index = 0; index < snapshot.Metrics.Count; index++)
                {
                    if (index > 0)
                    {
                        panel.Children.Add(new Border
                        {
                            Height = 1,
                            Background = Brush(System.Windows.Media.Color.FromRgb(118, 122, 138), 0.20),
                            Margin = new Thickness(0, 0, 0, 8)
                        });
                    }

                    panel.Children.Add(MetricBlock(snapshot.Metrics[index]));
                }
            }
        }
        else if (status.ErrorMessage is not null)
        {
            panel.Children.Add(Text(status.ErrorMessage, 12, FontWeights.Normal, Brush(System.Windows.Media.Color.FromRgb(160, 45, 45))));
        }
        else
        {
            panel.Children.Add(Text("Loading account usage...", 12, FontWeights.Normal, Brush(System.Windows.Media.Color.FromRgb(118, 122, 138))));
        }

        return new Border
        {
            CornerRadius = new CornerRadius(9),
            BorderThickness = new Thickness(1),
            BorderBrush = Brush(tint, 0.13),
            Background = Brush(tint, 0.045),
            Padding = new Thickness(10, 9, 10, 9),
            Margin = new Thickness(0, 0, 0, 10),
            Child = panel
        };
    }

    private static UIElement AccountHeader(AgentAccountStatus status, System.Windows.Media.Color tint)
    {
        var labelStack = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Vertical,
            Margin = new Thickness(0, 0, 0, 8)
        };
        var badges = AccountBadges(status.Provider, status.Snapshot);
        var stateLabel = CompactAccountStateLabel(status);
        if (badges.Count > 0 || stateLabel is not null)
        {
            var badgePanel = new StackPanel
            {
                Orientation = System.Windows.Controls.Orientation.Horizontal,
                Margin = new Thickness(0, 0, 0, 4)
            };

            if (badges.Count == 0 && stateLabel is not null)
            {
                badgePanel.Children.Add(AccountBadge(stateLabel, tint));
            }
            else
            {
                foreach (var badge in badges)
                {
                    badgePanel.Children.Add(AccountBadge(badge, tint));
                }
            }

            labelStack.Children.Add(badgePanel);
        }

        var accountLabel = status.Snapshot?.AccountLabel ?? status.AccountLabel ?? "Configured account";
        labelStack.Children.Add(Text(accountLabel, 14, FontWeights.ExtraBold, PrimaryBrush(), TextWrapping.NoWrap, trim: true));
        return labelStack;
    }

    private static UIElement MetricBlock(AgentQuotaMetric metric)
    {
        var tint = QuotaTint(metric.RemainingPercent);
        var panel = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Vertical,
            Margin = new Thickness(0, 2, 0, 10)
        };
        var titleRow = new Grid();
        titleRow.ColumnDefinitions.Add(new ColumnDefinition());
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        titleRow.Children.Add(Text(metric.Title, 12, FontWeights.Bold, PrimaryBrush(), TextWrapping.NoWrap, trim: true));
        var remaining = Text(CompactRemainingLabel(metric.RemainingLabel), 12, FontWeights.Bold, Brush(tint), TextWrapping.NoWrap, trim: true);
        remaining.Margin = new Thickness(8, 0, 0, 0);
        Grid.SetColumn(remaining, 1);
        titleRow.Children.Add(remaining);
        panel.Children.Add(titleRow);
        panel.Children.Add(QuotaBar(metric.RemainingPercent, tint));

        var footer = new Grid { Margin = new Thickness(0, 4, 0, 0) };
        footer.ColumnDefinitions.Add(new ColumnDefinition());
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.Children.Add(Text(metric.UsedLabel, 11, FontWeights.Medium, Brush(System.Windows.Media.Color.FromRgb(118, 122, 138)), TextWrapping.NoWrap, trim: true));
        if (metric.ResetsAt is { } resetsAt)
        {
            var reset = Text($"Resets {RelativeTime(resetsAt)} at {resetsAt.LocalDateTime.ToString("t", CultureInfo.CurrentCulture)}", 11, FontWeights.Medium, Brush(System.Windows.Media.Color.FromRgb(118, 122, 138)), TextWrapping.NoWrap, trim: true);
            reset.Margin = new Thickness(8, 0, 0, 0);
            Grid.SetColumn(reset, 1);
            footer.Children.Add(reset);
        }
        panel.Children.Add(footer);

        return panel;
    }

    private static UIElement QuotaBar(double remainingPercent, System.Windows.Media.Color tint)
    {
        var progress = Math.Clamp(remainingPercent, 0, 100) / 100;
        var width = progress <= 0 ? 0 : Math.Max(3, MetricBarWidth * progress);
        var grid = new Grid
        {
            Width = MetricBarWidth,
            Height = 5,
            Margin = new Thickness(0, 6, 0, 0),
            HorizontalAlignment = System.Windows.HorizontalAlignment.Left
        };
        grid.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(2.5),
            Background = Brush(System.Windows.Media.Color.FromRgb(104, 108, 122), 0.20)
        });
        grid.Children.Add(new Border
        {
            Width = width,
            CornerRadius = new CornerRadius(2.5),
            Background = Brush(tint),
            HorizontalAlignment = System.Windows.HorizontalAlignment.Left
        });
        return grid;
    }

    private static TextBlock Text(
        string value,
        double size,
        FontWeight weight,
        System.Windows.Media.Brush brush,
        TextWrapping wrapping = TextWrapping.Wrap,
        bool trim = false)
    {
        return new TextBlock
        {
            Text = value,
            FontSize = size,
            FontWeight = weight,
            Foreground = brush,
            TextWrapping = wrapping,
            TextTrimming = trim ? TextTrimming.CharacterEllipsis : TextTrimming.None
        };
    }

    private static System.Windows.Controls.Button FooterButton(string label, bool isDestructive = false)
    {
        var normal = Brush(System.Windows.Media.Color.FromArgb(168, 255, 255, 255));
        var hover = Brush(System.Windows.Media.Color.FromArgb(225, 255, 255, 255));
        var pressed = Brush(System.Windows.Media.Color.FromRgb(235, 232, 239));
        var normalBorder = Brush(System.Windows.Media.Color.FromRgb(218, 215, 222), 0.90);
        var hoverBorder = Brush(System.Windows.Media.Color.FromRgb(193, 188, 200));
        var foreground = isDestructive
            ? Brush(System.Windows.Media.Color.FromRgb(151, 54, 68))
            : Brush(System.Windows.Media.Color.FromRgb(51, 55, 71));
        var button = new System.Windows.Controls.Button
        {
            Content = label,
            Padding = new Thickness(11, 5, 11, 5),
            MinWidth = 72,
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            Foreground = foreground,
            Background = normal,
            BorderBrush = normalBorder,
            BorderThickness = new Thickness(1),
            Cursor = System.Windows.Input.Cursors.Hand,
            RenderTransform = new TranslateTransform(0, 0),
            Template = RoundedButtonTemplate(8)
        };
        button.MouseEnter += (_, _) =>
        {
            button.Background = hover;
            button.BorderBrush = hoverBorder;
        };
        button.MouseLeave += (_, _) =>
        {
            button.Background = normal;
            button.BorderBrush = normalBorder;
            button.RenderTransform = new TranslateTransform(0, 0);
        };
        button.PreviewMouseDown += (_, _) =>
        {
            button.Background = pressed;
            button.RenderTransform = new TranslateTransform(0, 1);
        };
        button.PreviewMouseUp += (_, _) =>
        {
            button.Background = button.IsMouseOver ? hover : normal;
            button.BorderBrush = button.IsMouseOver ? hoverBorder : normalBorder;
            button.RenderTransform = new TranslateTransform(0, 0);
        };
        return button;
    }

    private static ControlTemplate RoundedButtonTemplate(double radius)
    {
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(radius));
        border.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding(nameof(System.Windows.Controls.Control.Background)) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.SetBinding(Border.BorderBrushProperty, new System.Windows.Data.Binding(nameof(System.Windows.Controls.Control.BorderBrush)) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.SetBinding(Border.BorderThicknessProperty, new System.Windows.Data.Binding(nameof(System.Windows.Controls.Control.BorderThickness)) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });

        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(ContentPresenter.HorizontalAlignmentProperty, System.Windows.HorizontalAlignment.Center);
        presenter.SetValue(ContentPresenter.VerticalAlignmentProperty, System.Windows.VerticalAlignment.Center);
        presenter.SetBinding(ContentPresenter.MarginProperty, new System.Windows.Data.Binding(nameof(System.Windows.Controls.Control.Padding)) { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        border.AppendChild(presenter);

        return new ControlTemplate(typeof(System.Windows.Controls.Button)) { VisualTree = border };
    }

    private static UIElement ProviderIconBadge(
        (string Eyebrow, string Title, string IconLabel, System.Windows.Media.Color Tint) style,
        System.Windows.Media.Color tint)
    {
        return new Border
        {
            Width = 34,
            Height = 34,
            CornerRadius = new CornerRadius(8),
            Background = Brush(System.Windows.Media.Color.FromArgb(210, 255, 255, 255)),
            BorderBrush = Brush(tint, 0.18),
            BorderThickness = new Thickness(1),
            Child = new TextBlock
            {
                Text = style.IconLabel,
                FontSize = 11,
                FontWeight = FontWeights.Black,
                Foreground = Brush(tint),
                HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                TextAlignment = TextAlignment.Center
            }
        };
    }

    private static UIElement AccountBadge(string value, System.Windows.Media.Color tint)
    {
        return new Border
        {
            CornerRadius = new CornerRadius(999),
            Background = Brush(tint, 0.14),
            BorderBrush = Brush(tint, 0.20),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(9, 3, 9, 3),
            Margin = new Thickness(0, 0, 5, 0),
            Child = Text(value, 12, FontWeights.ExtraBold, Brush(tint), TextWrapping.NoWrap, trim: true)
        };
    }

    private static AgentQuotaSnapshot? SummarySnapshot(IReadOnlyList<AgentAccountStatus> statuses)
    {
        return statuses
            .Select(status => status.Snapshot)
            .OfType<AgentQuotaSnapshot>()
            .OrderByDescending(snapshot => snapshot.HighlightMetric?.UsedPercent ?? -1)
            .FirstOrDefault();
    }

    private static (string Value, string Label) SnapshotStatus(AgentQuotaSnapshot? snapshot, string? error, bool large)
    {
        if (snapshot?.HighlightMetric is { } metric)
        {
            return (metric.PercentText, "remaining");
        }

        if (snapshot is not null)
        {
            return ("Ready", "linked");
        }

        if (error is not null)
        {
            return ("!", "error");
        }

        return (large ? "..." : "--", "loading");
    }

    private static IReadOnlyList<string> AccountBadges(AgentProviderKind provider, AgentQuotaSnapshot? snapshot)
    {
        var values = provider == AgentProviderKind.Codex
            ? new[] { Clean(snapshot?.SpaceLabel), UserFacingPlanLabel(snapshot?.PlanType) }
            : new[] { UserFacingPlanLabel(snapshot?.PlanType), Clean(snapshot?.SpaceLabel) };
        var badges = new List<string>();
        foreach (var value in values)
        {
            if (value is not null && !badges.Contains(value, StringComparer.OrdinalIgnoreCase))
            {
                badges.Add(value);
            }
        }

        return badges;
    }

    private static string? UserFacingPlanLabel(string? value)
    {
        var cleaned = Clean(value);
        if (cleaned is null)
        {
            return null;
        }

        return string.Equals(cleaned, "prolite", StringComparison.OrdinalIgnoreCase)
            ? null
            : cleaned;
    }

    private static string? CompactAccountStateLabel(AgentAccountStatus status)
    {
        if (status.Snapshot?.Metrics.Count > 0)
        {
            return null;
        }

        if (status.Snapshot is not null)
        {
            return "Ready";
        }

        return status.ErrorMessage is not null ? "Error" : "Loading";
    }

    private static string CompactRemainingLabel(string label)
    {
        var trimmed = label.Trim();
        var normalized = trimmed.Replace(" / ", "/", StringComparison.Ordinal);
        return normalized.EndsWith(" monthly credits left", StringComparison.OrdinalIgnoreCase)
            ? normalized[..^" monthly credits left".Length] + " left"
            : normalized;
    }

    private static string? Clean(string? value)
    {
        var trimmed = value?.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }

    private static System.Windows.Media.Color PanelTint(AgentQuotaMetric? metric, string? error, System.Windows.Media.Color fallback)
    {
        if (error is not null)
        {
            return System.Windows.Media.Color.FromRgb(211, 61, 61);
        }

        return metric is null ? fallback : QuotaTint(metric.RemainingPercent);
    }

    private static System.Windows.Media.Color QuotaTint(double remainingPercent)
    {
        var rgb = AgentQuotaDisplayColor.ForRemainingPercent(remainingPercent);
        return System.Windows.Media.Color.FromRgb(
            ToByte(rgb.Red),
            ToByte(rgb.Green),
            ToByte(rgb.Blue));
    }

    private static (string Eyebrow, string Title, string IconLabel, System.Windows.Media.Color Tint) ProviderHeaderStyle(AgentProviderKind provider) => provider switch
    {
        AgentProviderKind.Codex => ("OPENAI", "Codex", "AI", System.Windows.Media.Color.FromRgb(226, 159, 0)),
        AgentProviderKind.GitHubCopilot => ("GITHUB", "Copilot", "GH", System.Windows.Media.Color.FromRgb(41, 148, 89)),
        AgentProviderKind.Gemini => ("GOOGLE", "Gemini", "G", System.Windows.Media.Color.FromRgb(41, 148, 89)),
        AgentProviderKind.Claude => ("ANTHROPIC", "Claude", "C", System.Windows.Media.Color.FromRgb(142, 91, 184)),
        AgentProviderKind.Junie => ("JETBRAINS", "Junie", "JB", System.Windows.Media.Color.FromRgb(226, 159, 0)),
        _ => ("AGENT", provider.Title(), "AG", System.Windows.Media.Color.FromRgb(58, 113, 238))
    };

    private static string RelativeTime(DateTimeOffset date)
    {
        var delta = date.ToLocalTime() - DateTimeOffset.Now;
        var future = delta.TotalSeconds >= 0;
        var duration = delta.Duration();
        var value = duration.TotalDays >= 1
            ? $"{Math.Round(duration.TotalDays):0}d"
            : duration.TotalHours >= 1
                ? $"{Math.Round(duration.TotalHours):0}h"
                : duration.TotalMinutes >= 1
                    ? $"{Math.Round(duration.TotalMinutes):0}m"
                    : "now";

        if (value == "now")
        {
            return "now";
        }

        return future ? $"in {value}" : $"{value} ago";
    }

    private static SolidColorBrush Brush(System.Windows.Media.Color color, double opacity = 1)
    {
        var brush = new SolidColorBrush(color) { Opacity = opacity };
        brush.Freeze();
        return brush;
    }

    private static SolidColorBrush PrimaryBrush() =>
        Brush(System.Windows.Media.Color.FromRgb(47, 50, 66));

    private static byte ToByte(double value) =>
        (byte)Math.Clamp((int)Math.Round(value * 255), 0, 255);

    private static double Clamp(double value, double min, double max)
    {
        if (max < min)
        {
            return min;
        }

        return Math.Min(Math.Max(value, min), max);
    }

    private void ForceVisible()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero)
        {
            return;
        }

        ShowWindow(handle, 5);
        SetForegroundWindow(handle);
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);
}
