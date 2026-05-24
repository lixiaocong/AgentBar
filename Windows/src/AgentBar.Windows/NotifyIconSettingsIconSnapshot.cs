using System.IO;
using Microsoft.Win32;

namespace AgentBar.Windows;

internal static class NotifyIconSettingsIconSnapshot
{
    private const string NotifyIconSettingsKey = @"Control Panel\NotifyIconSettings";
    private const string ProductExecutablePrefix = "AgentBar.Windows";

    public static void UpdateCurrentProcessSnapshot()
    {
        try
        {
            var processPath = Environment.ProcessPath;
            if (string.IsNullOrWhiteSpace(processPath) || !File.Exists(processPath))
            {
                return;
            }

            var snapshot = ApplicationIconResource.CreatePngSnapshot();
            if (snapshot is null)
            {
                return;
            }

            using var root = Registry.CurrentUser.OpenSubKey(NotifyIconSettingsKey, writable: true);
            if (root is null)
            {
                return;
            }

            var normalizedProcessPath = NormalizePath(processPath);
            var staleKeys = new List<string>();
            foreach (var name in root.GetSubKeyNames())
            {
                using var key = root.OpenSubKey(name, writable: true);
                if (key?.GetValue("ExecutablePath") is not string executablePath)
                {
                    continue;
                }

                var normalizedExecutablePath = NormalizePath(executablePath);
                if (string.Equals(
                        normalizedExecutablePath,
                        normalizedProcessPath,
                        StringComparison.OrdinalIgnoreCase))
                {
                    key.SetValue("IconSnapshot", snapshot, RegistryValueKind.Binary);
                }
                else if (IsSameProductExecutable(normalizedExecutablePath))
                {
                    staleKeys.Add(name);
                }
            }

            foreach (var staleKey in staleKeys)
            {
                root.DeleteSubKeyTree(staleKey, throwOnMissingSubKey: false);
            }
        }
        catch (Exception exception)
        {
            ShellLog.Write(exception, "NotifyIconSettings snapshot sync failed");
            // Windows settings will fall back to its own cached tray icon snapshot.
        }
    }

    private static bool IsSameProductExecutable(string executablePath)
    {
        var fileName = Path.GetFileName(executablePath);
        return fileName.Equals($"{ProductExecutablePrefix}.exe", StringComparison.OrdinalIgnoreCase) ||
               fileName.StartsWith($"{ProductExecutablePrefix}.", StringComparison.OrdinalIgnoreCase);
    }

    private static string NormalizePath(string path)
    {
        try
        {
            return Path.GetFullPath(path);
        }
        catch
        {
            return path.Trim();
        }
    }
}
