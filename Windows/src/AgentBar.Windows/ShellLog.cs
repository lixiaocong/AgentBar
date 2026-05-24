using System.IO;

namespace AgentBar.Windows;

internal static class ShellLog
{
    private static readonly object Gate = new();
    private static readonly string LogFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "AgentBar",
        "windows-shell.log");

    public static void Write(string message)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LogFile)!);
                File.AppendAllText(LogFile, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
            }
        }
        catch
        {
        }
    }

    public static void Write(Exception exception, string context) =>
        Write($"{context}: {exception}");
}
