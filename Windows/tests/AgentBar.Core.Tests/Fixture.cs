using System.Text.Json;
using AgentBar.Core;

namespace AgentBar.Core.Tests;

internal static class Fixture
{
    public static byte[] Bytes(params string[] parts) =>
        File.ReadAllBytes(PathFor(parts));

    public static string Text(params string[] parts) =>
        File.ReadAllText(PathFor(parts));

    public static void AssertSnapshotMatches(AgentQuotaSnapshot snapshot, params string[] expectedParts)
    {
        using var document = JsonDocument.Parse(Text(expectedParts));
        var root = document.RootElement;
        Assert.Equal(root.GetProperty("provider").GetString(), snapshot.Provider.StoredValue());
        Assert.Equal(root.GetProperty("accountLabel").GetString(), snapshot.AccountLabel);
        if (root.TryGetProperty("spaceLabel", out var spaceLabel))
        {
            Assert.Equal(spaceLabel.GetString(), snapshot.SpaceLabel);
        }

        Assert.Equal(root.GetProperty("planType").GetString(), snapshot.PlanType);
        Assert.Equal(root.GetProperty("sourceSummary").GetString(), snapshot.SourceSummary);

        var expectedMetrics = root.GetProperty("metrics").EnumerateArray().ToArray();
        Assert.Equal(expectedMetrics.Length, snapshot.Metrics.Count);
        for (var index = 0; index < expectedMetrics.Length; index++)
        {
            var expected = expectedMetrics[index];
            var actual = snapshot.Metrics[index];
            Assert.Equal(expected.GetProperty("id").GetString(), actual.Id);
            Assert.Equal(expected.GetProperty("title").GetString(), actual.Title);
            Assert.Equal(expected.GetProperty("usedPercent").GetDouble(), actual.UsedPercent, precision: 3);
            Assert.Equal(expected.GetProperty("usedLabel").GetString(), actual.UsedLabel);
            Assert.Equal(expected.GetProperty("remainingLabel").GetString(), actual.RemainingLabel);
        }
    }

    private static string PathFor(params string[] parts)
    {
        var candidates = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "AgentBarFixtures"),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "Shared", "AgentBarFixtures")),
            Path.GetFullPath(Path.Combine(Environment.CurrentDirectory, "Shared", "AgentBarFixtures"))
        };

        foreach (var root in candidates)
        {
            var path = Path.Combine(new[] { root }.Concat(parts).ToArray());
            if (File.Exists(path))
            {
                return path;
            }
        }

        throw new FileNotFoundException($"Fixture not found: {string.Join("/", parts)}");
    }
}
