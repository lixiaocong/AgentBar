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
        (AgentProviderKind Provider, string Eyebrow, string Title, System.Windows.Media.Color Tint) style,
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
            Child = ProviderLogo(style.Provider)
        };
    }

    private static UIElement AccountBadge(string value, System.Windows.Media.Color tint)
    {
        return new Border
        {
            CornerRadius = new CornerRadius(7),
            Background = Brush(tint, 0.14),
            BorderBrush = Brush(tint, 0.20),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(8, 3, 8, 3),
            Margin = new Thickness(0, 0, 5, 0),
            Child = Text(value, 12, FontWeights.ExtraBold, Brush(tint), TextWrapping.NoWrap, trim: true)
        };
    }

    private static UIElement ProviderLogo(AgentProviderKind provider)
    {
        var logo = ProviderLogoGeometry(provider);
        var canvas = new Canvas
        {
            Width = logo.Width,
            Height = logo.Height
        };

        foreach (var path in logo.Paths)
        {
            canvas.Children.Add(new System.Windows.Shapes.Path
            {
                Data = Geometry.Parse(path.Data),
                Fill = Brush(path.Fill)
            });
        }

        return new Viewbox
        {
            Width = 21,
            Height = 21,
            Stretch = Stretch.Uniform,
            Child = canvas
        };
    }

    private static ProviderLogoDefinition ProviderLogoGeometry(AgentProviderKind provider) => provider switch
    {
        AgentProviderKind.Codex => new ProviderLogoDefinition(
            20,
            20,
            [
                new ProviderLogoPath(
                    "M11.248 18.25q-.825 0-1.568-.314a4.3 4.3 0 0 1-1.32-.874a4 4 0 0 1-1.304.214a4 4 0 0 1-2.046-.544a4.27 4.27 0 0 1-1.518-1.485a4 4 0 0 1-.56-2.095q0-.48.131-1.04A4.4 4.4 0 0 1 2.04 10.71a4.07 4.07 0 0 1 .017-3.4a4.2 4.2 0 0 1 1.056-1.418a3.8 3.8 0 0 1 1.6-.842a3.9 3.9 0 0 1 .76-1.683q.593-.759 1.451-1.188a4.04 4.04 0 0 1 1.832-.429q.825 0 1.567.313q.742.314 1.32.875a4 4 0 0 1 1.304-.215q1.106 0 2.046.545a4.14 4.14 0 0 1 1.501 1.485q.578.941.578 2.095q0 .48-.132 1.04q.66.61 1.023 1.419q.363.792.363 1.666q0 .892-.38 1.717a4.3 4.3 0 0 1-1.072 1.435a3.8 3.8 0 0 1-1.584.825a3.8 3.8 0 0 1-.775 1.683a4.06 4.06 0 0 1-1.436 1.188a4.04 4.04 0 0 1-1.832.429m-4.076-2.062q.825 0 1.435-.347l3.103-1.782a.36.36 0 0 0 .164-.313v-1.42L7.881 14.62a.67.67 0 0 1-.726 0l-3.118-1.798a.5.5 0 0 1-.017.115v.198q0 .841.396 1.551q.413.693 1.139 1.089a3.2 3.2 0 0 0 1.617.412m.165-2.69a.4.4 0 0 0 .181.05q.083 0 .165-.05l1.238-.71l-3.977-2.31a.7.7 0 0 1-.363-.643v-3.58q-.825.362-1.32 1.122a2.9 2.9 0 0 0-.495 1.65q0 .809.413 1.55q.412.743 1.072 1.123zm3.91 3.663q.875 0 1.585-.396a2.96 2.96 0 0 0 1.534-2.64v-3.564a.32.32 0 0 0-.165-.297l-1.254-.726v4.604a.7.7 0 0 1-.363.643l-3.119 1.799a3 3 0 0 0 1.783.577m.627-6.039V8.878L10.01 7.822L8.129 8.878v2.244l1.881 1.056zM7.057 5.859a.7.7 0 0 1 .363-.644l3.119-1.798a3 3 0 0 0-1.782-.578q-.874 0-1.584.396A2.96 2.96 0 0 0 6.05 4.324a3.07 3.07 0 0 0-.396 1.551v3.547q0 .199.165.314l1.237.726zm8.383 7.887q.825-.364 1.303-1.123q.495-.758.495-1.65a3.15 3.15 0 0 0-.412-1.55q-.413-.743-1.073-1.123l-3.086-1.782q-.099-.065-.181-.049a.3.3 0 0 0-.165.05l-1.238.692l3.993 2.327a.6.6 0 0 1 .264.264a.64.64 0 0 1 .1.363zm-3.317-8.382a.63.63 0 0 1 .726 0l3.135 1.831v-.297q0-.792-.396-1.501a2.86 2.86 0 0 0-1.105-1.155q-.71-.43-1.65-.43q-.825 0-1.436.347L8.294 5.941a.36.36 0 0 0-.165.314v1.418z",
                    System.Windows.Media.Color.FromRgb(20, 20, 20))
            ]),
        AgentProviderKind.GitHubCopilot => new ProviderLogoDefinition(
            24,
            24,
            [
                new ProviderLogoPath(
                    "M23.922 16.997C23.061 18.492 18.063 22.02 12 22.02 5.937 22.02.939 18.492.078 16.997A.641.641 0 0 1 0 16.741v-2.869a.883.883 0 0 1 .053-.22c.372-.935 1.347-2.292 2.605-2.656c.167-.429.414-1.055.644-1.517a10.098 10.098 0 0 1-.052-1.086c0-1.331.282-2.499 1.132-3.368c.397-.406.89-.717 1.474-.952C7.255 2.937 9.248 1.98 11.978 1.98c2.731 0 4.767.957 6.166 2.093c.584.235 1.077.546 1.474.952c.85.869 1.132 2.037 1.132 3.368c0 .368-.014.733-.052 1.086c.23.462.477 1.088.644 1.517c1.258.364 2.233 1.721 2.605 2.656a.841.841 0 0 1 .053.22v2.869a.641.641 0 0 1-.078.256Zm-11.75-5.992h-.344a4.359 4.359 0 0 1-.355.508c-.77.947-1.918 1.492-3.508 1.492c-1.725 0-2.989-.359-3.782-1.259a2.137 2.137 0 0 1-.085-.104L4 11.746v6.585c1.435.779 4.514 2.179 8 2.179c3.486 0 6.565-1.4 8-2.179v-6.585l-.098-.104s-.033.045-.085.104c-.793.9-2.057 1.259-3.782 1.259c-1.59 0-2.738-.545-3.508-1.492a4.359 4.359 0 0 1-.355-.508Zm2.328 3.25c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1c-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm-5 0c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1c-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm3.313-6.185c.136 1.057.403 1.913.878 2.497c.442.544 1.134.938 2.344.938c1.573 0 2.292-.337 2.657-.751c.384-.435.558-1.15.558-2.361c0-1.14-.243-1.847-.705-2.319c-.477-.488-1.319-.862-2.824-1.025c-1.487-.161-2.192.138-2.533.529c-.269.307-.437.808-.438 1.578v.021c0 .265.021.562.063.893Zm-1.626 0c.042-.331.063-.628.063-.894v-.02c-.001-.77-.169-1.271-.438-1.578c-.341-.391-1.046-.69-2.533-.529c-1.505.163-2.347.537-2.824 1.025c-.462.472-.705 1.179-.705 2.319c0 1.211.175 1.926.558 2.361c.365.414 1.084.751 2.657.751c1.21 0 1.902-.394 2.344-.938c.475-.584.742-1.44.878-2.497Z",
                    System.Windows.Media.Color.FromRgb(20, 20, 20))
            ]),
        AgentProviderKind.Gemini => new ProviderLogoDefinition(
            24,
            24,
            [
                new ProviderLogoPath(
                    "M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68q.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58a12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68q-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96q2.19.93 3.81 2.55t2.55 3.81",
                    System.Windows.Media.Color.FromRgb(142, 117, 178))
            ]),
        AgentProviderKind.Claude => new ProviderLogoDefinition(
            24,
            24,
            [
                new ProviderLogoPath(
                    "m4.7144 15.9555l4.7174-2.6471l.079-.2307l-.079-.1275h-.2307l-.7893-.0486l-2.6956-.0729l-2.3375-.0971l-2.2646-.1214l-.5707-.1215l-.5343-.7042l.0546-.3522l.4797-.3218l.686.0608l1.5179.1032l2.2767.1578l1.6514.0972l2.4468.255h.3886l.0546-.1579l-.1336-.0971l-.1032-.0972L6.973 9.8356l-2.55-1.6879l-1.3356-.9714l-.7225-.4918l-.3643-.4614l-.1578-1.0078l.6557-.7225l.8803.0607l.2246.0607l.8925.686l1.9064 1.4754l2.4893 1.8336l.3643.3035l.1457-.1032l.0182-.0728l-.164-.2733l-1.3539-2.4467l-1.445-2.4893l-.6435-1.032l-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335L6.6997 0l.9957.1336l.419.3642l.6192 1.4147l1.0018 2.2282l1.5543 3.0296l.4553.8985l.2429.8318l.091.255h.1579v-.1457l.1275-1.706l.2368-2.0947l.2307-2.6957l.0789-.7589l.3764-.9107l.7468-.4918l.5828.2793l.4797.686l-.0668.4433l-.2853 1.8517l-.5586 2.9021l-.3643 1.9429h.2125l.2429-.2429l.9835-1.3053l1.6514-2.0643l.7286-.8196l.85-.9046l.5464-.4311h1.0321l.759 1.1293l-.34 1.1657l-1.0625 1.3478l-.8804 1.1414l-1.2628 1.7l-.7893 1.36l.0729.1093l.1882-.0183l2.8535-.607l1.5421-.2794l1.8396-.3157l.8318.3886l.091.3946l-.3278.8075l-1.967.4857l-2.3072.4614l-3.4364.8136l-.0425.0304l.0486.0607l1.5482.1457l.6618.0364h1.621l3.0175.2247l.7892.522l.4736.6376l-.079.4857l-1.2142.6193l-1.6393-.3886l-3.825-.9107l-1.3113-.3279h-.1822v.1093l1.0929 1.0686l2.0035 1.8092l2.5075 2.3314l.1275.5768l-.3218.4554l-.34-.0486l-2.2039-1.6575l-.85-.7468l-1.9246-1.621h-.1275v.17l.4432.6496l2.3436 3.5214l.1214 1.0807l-.17.3521l-.6071.2125l-.6679-.1214l-1.3721-1.9246L14.38 17.959l-1.1414-1.9428l-.1397.079l-.674 7.2552l-.3156.3703l-.7286.2793l-.6071-.4614l-.3218-.7468l.3218-1.4753l.3886-1.9246l.3157-1.53l.2853-1.9004l.17-.6314l-.0121-.0425l-.1397.0182l-1.4328 1.9672l-2.1796 2.9446l-1.7243 1.8456l-.4128.164l-.7164-.3704l.0667-.6618l.4008-.5889l2.386-3.0357l1.4389-1.882l.929-1.0868l-.0062-.1579h-.0546l-6.3385 4.1164l-1.1293.1457l-.4857-.4554l.0608-.7467l.2307-.2429l1.9064-1.3114Z",
                    System.Windows.Media.Color.FromRgb(217, 119, 87))
            ]),
        AgentProviderKind.Junie => new ProviderLogoDefinition(
            69,
            69,
            [
                new ProviderLogoPath("M46.0724 23.0702H68.9861V26.8861C68.9861 53.5886 57.5291 68.8525 26.9868 68.8525H23.168V45.9566H26.9868C40.3532 45.9566 46.0817 40.2327 46.0817 26.8768V23.0608L46.0724 23.0702Z", System.Windows.Media.Color.FromRgb(72, 224, 84)),
                new ProviderLogoPath("M22.9997 23.0718H0.0859375V45.9677H22.9997V23.0718Z", System.Windows.Media.Color.FromRgb(72, 224, 84)),
                new ProviderLogoPath("M45.9128 0.185181H22.999V23.081H45.9128V0.185181Z", System.Windows.Media.Color.FromRgb(72, 224, 84))
            ]),
        _ => new ProviderLogoDefinition(
            24,
            24,
            [
                new ProviderLogoPath("M12 2L22 20H2L12 2Z", System.Windows.Media.Color.FromRgb(58, 113, 238))
            ])
    };

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

    private static (AgentProviderKind Provider, string Eyebrow, string Title, System.Windows.Media.Color Tint) ProviderHeaderStyle(AgentProviderKind provider) => provider switch
    {
        AgentProviderKind.Codex => (provider, "OPENAI", "Codex", System.Windows.Media.Color.FromRgb(226, 159, 0)),
        AgentProviderKind.GitHubCopilot => (provider, "GITHUB", "Copilot", System.Windows.Media.Color.FromRgb(41, 148, 89)),
        AgentProviderKind.Gemini => (provider, "GOOGLE", "Gemini", System.Windows.Media.Color.FromRgb(41, 148, 89)),
        AgentProviderKind.Claude => (provider, "ANTHROPIC", "Claude", System.Windows.Media.Color.FromRgb(142, 91, 184)),
        AgentProviderKind.Junie => (provider, "JETBRAINS", "Junie", System.Windows.Media.Color.FromRgb(226, 159, 0)),
        _ => (provider, "AGENT", provider.Title(), System.Windows.Media.Color.FromRgb(58, 113, 238))
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

    private sealed record ProviderLogoDefinition(
        double Width,
        double Height,
        IReadOnlyList<ProviderLogoPath> Paths);

    private sealed record ProviderLogoPath(
        string Data,
        System.Windows.Media.Color Fill);

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
