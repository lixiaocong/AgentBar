import AppKit

enum MenuBarStatusImage {
    enum Emphasis {
        case idle
        case normal
        case warning
        case critical
    }

    static func make(
        usedPercents: [Double?],
        emphasis: Emphasis
    ) -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let values = usedPercents.isEmpty ? [nil] : usedPercents
        let barHeight: CGFloat = 12
        let spacing: CGFloat = values.count > 3 ? 1.5 : 2.5
        let availableWidth = size.width - spacing * CGFloat(max(values.count - 1, 0))
        let barWidth = min(4, max(2, availableWidth / CGFloat(values.count)))
        let totalWidth = barWidth * CGFloat(values.count) + spacing * CGFloat(max(values.count - 1, 0))
        let startX = (size.width - totalWidth) / 2

        for (index, value) in values.enumerated() {
            let x = startX + CGFloat(index) * (barWidth + spacing)
            let rect = NSRect(x: x, y: 1, width: barWidth, height: barHeight)
            drawBar(in: rect, usedPercent: value, emphasis: emphasis)
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func drawBar(
        in rect: NSRect,
        usedPercent: Double?,
        emphasis: Emphasis
    ) {
        let trackPath = NSBezierPath(roundedRect: rect, xRadius: 1.6, yRadius: 1.6)
        NSColor.black.withAlphaComponent(trackOpacity(for: usedPercent)).setFill()
        trackPath.fill()

        let fillFraction = fillFraction(for: usedPercent)
        let fillRect = NSRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: max(2, rect.height * fillFraction)
        )
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1.6, yRadius: 1.6)
        NSColor.black.withAlphaComponent(fillOpacity(for: usedPercent, emphasis: emphasis)).setFill()
        fillPath.fill()
    }

    private static func fillFraction(for usedPercent: Double?) -> CGFloat {
        guard let usedPercent else { return 0.24 }
        return max(0.18, min(1, CGFloat(usedPercent / 100)))
    }

    private static func trackOpacity(for usedPercent: Double?) -> CGFloat {
        usedPercent == nil ? 0.28 : 0.42
    }

    private static func fillOpacity(for usedPercent: Double?, emphasis: Emphasis) -> CGFloat {
        guard usedPercent != nil else { return 0.72 }

        switch emphasis {
        case .idle:
            return 0.84
        case .normal:
            return 1
        case .warning:
            return 0.84
        case .critical:
            return 1
        }
    }
}
