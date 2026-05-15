import AppKit
import Testing
@testable import AgentBar

@Test
@MainActor
func menuBarStatusImageContainsVisiblePixels() throws {
    let image = MenuBarStatusImage.make(
        bars: [
            MenuBarStatusImage.Bar(provider: .codex, label: "cx", remainingPercent: 34),
            MenuBarStatusImage.Bar(provider: .githubCopilot, label: "cp", remainingPercent: 77),
        ]
    )

    let representation = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: representation))
    var visiblePixelCount = 0

    for x in 0..<bitmap.pixelsWide {
        for y in 0..<bitmap.pixelsHigh {
            guard let color = bitmap.colorAt(x: x, y: y) else { continue }
            if color.alphaComponent > 0.1 {
                visiblePixelCount += 1
            }
        }
    }

    #expect(visiblePixelCount > 50)
}

@Test
func nonHyphenatingLabelDoesNotInsertBreaksOrHyphens() {
    let label = "xiaocong.li@newsbreak.com"
    let displayText = NonHyphenatingLabel.displayText(for: label)

    #expect(displayText == label)
    #expect(!displayText.contains("\n"))
    #expect(!displayText.contains(".-"))
}
