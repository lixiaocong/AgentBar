import AppKit

#if canImport(AgentBarCore)
import AgentBarCore
#endif

enum MenuBarStatusImage {
    struct Bar: Equatable {
        let provider: AgentProviderKind?
        let label: String
        let remainingPercent: Double?
        let isError: Bool

        init(
            provider: AgentProviderKind?,
            label: String? = nil,
            remainingPercent: Double?,
            isError: Bool = false
        ) {
            self.provider = provider
            self.label = label ?? Self.defaultLabel(for: provider)
            self.remainingPercent = remainingPercent
            self.isError = isError
        }

        private static func defaultLabel(for provider: AgentProviderKind?) -> String {
            switch provider {
            case .codex:
                return "cx"
            case .githubCopilot:
                return "cp"
            case .gemini:
                return "gm"
            case .claude:
                return "cl"
            case nil:
                return "--"
            }
        }
    }

    static func make(bars: [Bar]) -> NSImage {
        let size = imageSize
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let values = Array((bars.isEmpty ? [Bar(provider: nil, remainingPercent: nil)] : bars).prefix(3))
        let horizontalPadding: CGFloat = 2
        let labelWidth = labelWidth
        let labelGap: CGFloat = 3
        let spacing: CGFloat = values.count == 1 ? 0 : 2
        let availableHeight = size.height - 2 - spacing * CGFloat(max(values.count - 1, 0))
        let barHeight = min(maxBarHeight(for: values.count), floor(availableHeight / CGFloat(values.count)))
        let barWidth = size.width - horizontalPadding * 2 - labelWidth - labelGap
        let totalHeight = barHeight * CGFloat(values.count) + spacing * CGFloat(max(values.count - 1, 0))
        let startY = (size.height - totalHeight) / 2

        for (index, value) in values.enumerated() {
            let y = startY + CGFloat(values.count - index - 1) * (barHeight + spacing)
            let labelRect = NSRect(x: horizontalPadding, y: y - 1, width: labelWidth, height: barHeight + 3)
            let rect = NSRect(
                x: horizontalPadding + labelWidth + labelGap,
                y: y,
                width: barWidth,
                height: barHeight
            )
            drawLabel(for: value, in: labelRect, rowCount: values.count)
            drawBar(in: rect, bar: value)
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static var imageSize: NSSize {
        NSSize(width: 66, height: 18)
    }

    private static var labelWidth: CGFloat {
        21
    }

    private static func maxBarHeight(for rowCount: Int) -> CGFloat {
        switch rowCount {
        case 1:
            return 8
        case 2:
            return 7
        default:
            return 4
        }
    }

    private static func drawBar(
        in rect: NSRect,
        bar: Bar
    ) {
        let trackPath = NSBezierPath(roundedRect: rect, xRadius: 1.6, yRadius: 1.6)
        trackColor(for: bar).setFill()
        trackPath.fill()

        let fillFraction = fillFraction(for: bar.remainingPercent)
        let fillRect = NSRect(
            x: rect.minX,
            y: rect.minY,
            width: max(2, rect.width * fillFraction),
            height: rect.height
        )
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1.6, yRadius: 1.6)
        fillColor(for: bar).setFill()
        fillPath.fill()
    }

    private static func drawLabel(
        for bar: Bar,
        in rect: NSRect,
        rowCount: Int
    ) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(
                ofSize: labelFontSize(rowCount: rowCount),
                weight: .bold
            ),
            .foregroundColor: fillColor(for: bar),
            .paragraphStyle: paragraphStyle
        ]

        bar.label.draw(in: rect, withAttributes: attributes)
    }

    private static func labelFontSize(rowCount: Int) -> CGFloat {
        switch rowCount {
        case 1:
            8.8
        case 2:
            7.4
        default:
            5.8
        }
    }

    private static func fillFraction(for remainingPercent: Double?) -> CGFloat {
        guard let remainingPercent else { return 0.24 }
        return max(0, min(1, CGFloat(remainingPercent / 100)))
    }

    private static func trackColor(for bar: Bar) -> NSColor {
        if bar.isError {
            return NSColor.systemRed.withAlphaComponent(0.2)
        }

        return NSColor.labelColor.withAlphaComponent(bar.remainingPercent == nil ? 0.18 : 0.22)
    }

    private static func fillColor(for bar: Bar) -> NSColor {
        if bar.isError {
            return NSColor.systemRed.withAlphaComponent(0.9)
        }

        return progressColor(for: bar.remainingPercent).withAlphaComponent(bar.remainingPercent == nil ? 0.5 : 1)
    }

    private static func progressColor(for remainingPercent: Double?) -> NSColor {
        guard let remainingPercent else { return .labelColor }

        switch remainingPercent {
        case 75...:
            return .systemGreen
        case 45..<75:
            return .systemYellow
        case 20..<45:
            return .systemOrange
        default:
            return .systemRed
        }
    }

}
