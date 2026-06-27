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
            case .zai:
                return "za"
            case .junie:
                return "jn"
            case nil:
                return "--"
            }
        }
    }

    static func make(bars: [Bar]) -> NSImage {
        let values = Array((bars.isEmpty ? [Bar(provider: nil, remainingPercent: nil)] : bars).prefix(3))
        let labelWidth = labelWidth(for: values)
        let size = imageSize(labelWidth: labelWidth)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let spacing: CGFloat = values.count == 1 ? 0 : 2
        let availableHeight = size.height - 2 - spacing * CGFloat(max(values.count - 1, 0))
        let barHeight = min(maxBarHeight(for: values.count), floor(availableHeight / CGFloat(values.count)))
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

    private static let horizontalPadding: CGFloat = 1
    private static let labelGap: CGFloat = 2
    private static let barWidth: CGFloat = 38
    private static let imageHeight: CGFloat = 18
    private static let minimumLabelWidth: CGFloat = 8

    private static func imageSize(labelWidth: CGFloat) -> NSSize {
        NSSize(width: horizontalPadding * 2 + labelWidth + labelGap + barWidth, height: imageHeight)
    }

    private static func labelWidth(for bars: [Bar]) -> CGFloat {
        let rowCount = max(bars.count, 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont(rowCount: rowCount)
        ]
        let measuredWidth = bars
            .map { ceil(($0.label as NSString).size(withAttributes: attributes).width) }
            .max() ?? minimumLabelWidth

        return max(minimumLabelWidth, measuredWidth)
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

        guard let remainingPercent = bar.remainingPercent else {
            if bar.isError {
                drawUnavailableMarker(in: rect, color: fillColor(for: bar))
            }
            return
        }

        let fillFraction = fillFraction(for: remainingPercent)
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

    private static func drawUnavailableMarker(
        in rect: NSRect,
        color: NSColor
    ) {
        let markerRect = rect.insetBy(dx: 1.4, dy: max(0.5, rect.height * 0.18))
        let markerPath = NSBezierPath()
        markerPath.lineWidth = max(1, min(1.4, rect.height * 0.35))
        markerPath.lineCapStyle = .round
        markerPath.move(to: NSPoint(x: markerRect.minX, y: markerRect.minY))
        markerPath.line(to: NSPoint(x: markerRect.maxX, y: markerRect.maxY))
        markerPath.move(to: NSPoint(x: markerRect.minX, y: markerRect.maxY))
        markerPath.line(to: NSPoint(x: markerRect.maxX, y: markerRect.minY))
        color.setStroke()
        markerPath.stroke()
    }

    private static func drawLabel(
        for bar: Bar,
        in rect: NSRect,
        rowCount: Int
    ) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right

        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont(rowCount: rowCount),
            .foregroundColor: fillColor(for: bar),
            .paragraphStyle: paragraphStyle
        ]

        bar.label.draw(in: rect, withAttributes: attributes)
    }

    private static func labelFont(rowCount: Int) -> NSFont {
        NSFont.monospacedSystemFont(
            ofSize: labelFontSize(rowCount: rowCount),
            weight: .bold
        )
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

    private static func fillFraction(for remainingPercent: Double) -> CGFloat {
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

        return color(from: AgentQuotaDisplayColor.color(for: remainingPercent))
    }

    private static func color(from rgb: AgentQuotaDisplayRGB) -> NSColor {
        NSColor(
            calibratedRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: 1
        )
    }

}
