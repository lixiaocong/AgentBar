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
@MainActor
func unavailableMenuBarStatusImageMarksErrorAcrossBar() throws {
    let image = MenuBarStatusImage.make(
        bars: [
            MenuBarStatusImage.Bar(provider: .codex, label: "cx", remainingPercent: nil, isError: true),
        ]
    )

    let representation = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: representation))
    var strongRightSideRedPixels = 0

    for x in 46..<bitmap.pixelsWide {
        for y in 0..<bitmap.pixelsHigh {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.alphaComponent > 0.55,
               color.redComponent > 0.65,
               color.greenComponent < 0.45,
               color.blueComponent < 0.45 {
                strongRightSideRedPixels += 1
            }
        }
    }

    #expect(strongRightSideRedPixels > 0)
}

@Test
func nonHyphenatingLabelDoesNotInsertBreaksOrHyphens() {
    let label = "xiaocong.li@newsbreak.com"
    let displayText = NonHyphenatingLabel.displayText(for: label)

    #expect(displayText == label)
    #expect(!displayText.contains("\n"))
    #expect(!displayText.contains(".-"))
}
