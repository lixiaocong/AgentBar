using System.Drawing;
using System.Drawing.Imaging;
using System.IO;

namespace AgentBar.Windows;

internal static class ApplicationIconResource
{
    private const string ResourceName = "AgentBar.Windows.AppIcon.ico";

    public static Icon? LoadIcon()
    {
        using var resource = typeof(ApplicationIconResource).Assembly.GetManifestResourceStream(ResourceName);
        if (resource is not null)
        {
            using var icon = new Icon(resource, 32, 32);
            return (Icon)icon.Clone();
        }

        var processPath = Environment.ProcessPath;
        return string.IsNullOrWhiteSpace(processPath)
            ? null
            : Icon.ExtractAssociatedIcon(processPath);
    }

    public static byte[]? CreatePngSnapshot()
    {
        using var icon = LoadIcon();
        if (icon is null)
        {
            return null;
        }

        using var bitmap = icon.ToBitmap();
        using var stream = new MemoryStream();
        bitmap.Save(stream, ImageFormat.Png);
        return stream.ToArray();
    }
}
