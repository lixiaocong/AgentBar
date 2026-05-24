using AgentBar.Core;

namespace AgentBar.Core.Tests;

public sealed class TrayIconRendererTests
{
    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    public void RendererProducesStableNonBlankPieIcon(int count)
    {
        var bars = Enumerable.Range(0, count)
            .Select(index => new TrayStatusBar(AgentProviderKind.Codex, $"C{index}", 80 - index * 20))
            .ToArray();
        var renderer = new TrayIconRenderer();

        var result = renderer.Render(bars, 32);

        using (result.Icon)
        {
            Assert.Equal(32, result.Width);
            Assert.Equal(32, result.Height);
            Assert.True(result.HasNonTransparentPixels);
        }
    }

    [Fact]
    public void RendererAcceptsMultipleStatusesButDrawsOneIcon()
    {
        var renderer = new TrayIconRenderer();

        var result = renderer.Render(
            [
                new TrayStatusBar(AgentProviderKind.Codex, "C", 60),
                new TrayStatusBar(AgentProviderKind.GitHubCopilot, "P", 20),
                new TrayStatusBar(AgentProviderKind.Gemini, "G", 90)
            ],
            32);

        using (result.Icon)
        {
            Assert.Equal(32, result.Width);
            Assert.Equal(32, result.Height);
            Assert.True(result.HasNonTransparentPixels);
        }
    }

    [Fact]
    public void RendererDrawsErrorState()
    {
        var renderer = new TrayIconRenderer();

        var result = renderer.Render([new TrayStatusBar(AgentProviderKind.GitHubCopilot, "P", null, true)], 32);

        using (result.Icon)
        {
            Assert.True(result.HasNonTransparentPixels);
        }
    }
}
