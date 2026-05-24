using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace AgentBar.Core;

public sealed class TrayIconRenderer : ITrayIconRenderer
{
    private static readonly Lazy<Bitmap?> AppIconBitmap = new(LoadAppIconBitmap);

    public IconRenderResult Render(IReadOnlyList<TrayStatusBar> bars, int size = 32)
    {
        var status = bars.FirstOrDefault() ?? new TrayStatusBar(null, "--", null);

        using var bitmap = new Bitmap(size, size);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.Transparent);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        graphics.CompositingQuality = CompositingQuality.HighQuality;

        var hasAppIcon = DrawAppIcon(graphics, size);
        var margin = hasAppIcon ? Math.Max(1.0f, size * 0.03f) : Math.Max(1.0f, size * 0.045f);
        var badgeSize = hasAppIcon ? Math.Max(14.0f, size * 0.48f) : size - margin * 2;
        var rect = hasAppIcon
            ? new RectangleF(size - badgeSize - margin, size - badgeSize - margin, badgeSize, badgeSize)
            : new RectangleF(margin, margin, size - margin * 2, size - margin * 2);
        using var trackBrush = new SolidBrush(TrackColor(status));
        using var fillBrush = new SolidBrush(FillColor(status));
        using var outlinePen = new Pen(
            hasAppIcon ? Color.FromArgb(230, 255, 255, 255) : Color.FromArgb(150, 255, 255, 255),
            Math.Max(1.0f, hasAppIcon ? size / 23f : size / 26f));

        graphics.FillEllipse(trackBrush, rect);
        if (status.IsError)
        {
            graphics.FillEllipse(fillBrush, rect);
            DrawCenteredText(graphics, "!", rect, size, Color.White);
        }
        else if (status.RemainingPercent is { } remaining)
        {
            var sweep = (float)Math.Clamp(remaining, 0, 100) / 100f * 360f;
            if (sweep >= 359.5f)
            {
                graphics.FillEllipse(fillBrush, rect);
            }
            else if (sweep > 0)
            {
                graphics.FillPie(fillBrush, rect, -90, sweep);
            }

            if (!string.IsNullOrWhiteSpace(status.Label) && size >= 24)
            {
                DrawCenteredText(graphics, CenterLabel(status), rect, size, CenterTextColor(status), hasAppIcon);
            }
        }
        else
        {
            using var unavailablePen = new Pen(fillBrush, Math.Max(2.0f, size / 9f))
            {
                StartCap = LineCap.Round,
                EndCap = LineCap.Round
            };
            var inset = size * 0.28f;
            graphics.DrawLine(unavailablePen, inset, size - inset, size - inset, inset);
            graphics.DrawLine(unavailablePen, inset, inset, size - inset, size - inset);
        }

        graphics.DrawEllipse(outlinePen, rect);

        var hasPixels = HasNonTransparentPixels(bitmap);
        var handle = bitmap.GetHicon();
        try
        {
            using var icon = Icon.FromHandle(handle);
            return new IconRenderResult((Icon)icon.Clone(), size, size, hasPixels);
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    private static bool DrawAppIcon(Graphics graphics, int size)
    {
        var icon = AppIconBitmap.Value;
        if (icon is null)
        {
            return false;
        }

        var iconInset = Math.Max(1.0f, size * 0.03f);
        graphics.DrawImage(icon, new RectangleF(iconInset, iconInset, size - iconInset * 2, size - iconInset * 2));
        return true;
    }

    private static Bitmap? LoadAppIconBitmap()
    {
        try
        {
            var processPath = Environment.ProcessPath;
            if (string.IsNullOrWhiteSpace(processPath) || !File.Exists(processPath))
            {
                return null;
            }

            using var icon = Icon.ExtractAssociatedIcon(processPath);
            return icon?.ToBitmap();
        }
        catch
        {
            return null;
        }
    }

    private static void DrawCenteredText(
        Graphics graphics,
        string text,
        RectangleF rect,
        int size,
        Color color,
        bool compact = false)
    {
        var fontSize = compact
            ? Math.Max(6.5f, rect.Width * 0.42f)
            : size >= 32 ? 12.5f : 9.5f;
        using var font = new Font(FontFamily.GenericSansSerif, fontSize, FontStyle.Bold, GraphicsUnit.Pixel);
        using var shadowBrush = new SolidBrush(Color.FromArgb(110, 0, 0, 0));
        using var textBrush = new SolidBrush(color);
        using var format = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center,
            Trimming = StringTrimming.None,
            FormatFlags = StringFormatFlags.NoWrap
        };
        var shadowRect = new RectangleF(rect.X, rect.Y + 1, rect.Width, rect.Height);
        graphics.DrawString(text, font, shadowBrush, shadowRect, format);
        graphics.DrawString(text, font, textBrush, rect, format);
    }

    private static string CenterLabel(TrayStatusBar status)
    {
        var label = string.IsNullOrWhiteSpace(status.Label)
            ? status.Provider?.MenuBarShortPrefix() ?? ""
            : status.Label.Trim();
        return label.Length <= 2 ? label : label[..2];
    }

    private static Color CenterTextColor(TrayStatusBar status)
    {
        if (status.RemainingPercent is >= 75)
        {
            return Color.FromArgb(245, 22, 52, 33);
        }

        return Color.White;
    }

    private static Color FillColor(TrayStatusBar status)
    {
        if (status.IsError)
        {
            return Color.FromArgb(255, 255, 59, 48);
        }

        if (status.RemainingPercent is null)
        {
            return Color.FromArgb(210, 210, 214, 220);
        }

        var rgb = AgentQuotaDisplayColor.ForRemainingPercent(status.RemainingPercent.Value);
        return Color.FromArgb(255, (int)(rgb.Red * 255), (int)(rgb.Green * 255), (int)(rgb.Blue * 255));
    }

    private static Color TrackColor(TrayStatusBar status) =>
        status.IsError ? Color.FromArgb(52, 255, 59, 48) : Color.FromArgb(90, 220, 222, 226);

    private static bool HasNonTransparentPixels(Bitmap bitmap)
    {
        for (var y = 0; y < bitmap.Height; y++)
        {
            for (var x = 0; x < bitmap.Width; x++)
            {
                if (bitmap.GetPixel(x, y).A > 0)
                {
                    return true;
                }
            }
        }

        return false;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr hIcon);
}
