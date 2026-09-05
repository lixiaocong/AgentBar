import AppKit
import Foundation
import Vision

enum RedactionError: Error, CustomStringConvertible {
    case invalidArguments
    case unreadableImage(String)
    case noMatchingText
    case renderFailed

    var description: String {
        switch self {
        case .invalidArguments:
            return "Usage: swift scripts/redact-screenshot.swift <input.png> <output.png> [text-to-redact ...]"
        case let .unreadableImage(path):
            return "Could not read image at \(path)"
        case .noMatchingText:
            return "No email address or requested text was found"
        case .renderFailed:
            return "Could not render the redacted PNG"
        }
    }
}

guard CommandLine.arguments.count >= 3 else {
    throw RedactionError.invalidArguments
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let requestedText = CommandLine.arguments.dropFirst(3).map(normalize)

guard
    let image = NSImage(contentsOf: inputURL),
    let sourceImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    throw RedactionError.unreadableImage(inputURL.path)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false

let handler = VNImageRequestHandler(cgImage: sourceImage, orientation: .up)
try handler.perform([request])

let observations = request.results ?? []
let redactions = observations.compactMap { observation -> (String, CGRect)? in
    guard let candidate = observation.topCandidates(1).first else { return nil }
    let recognizedText = candidate.string
    let normalizedText = normalize(recognizedText)
    let isEmail = recognizedText.range(
        of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil
    let matchesRequestedText = requestedText.contains { requested in
        !requested.isEmpty && (normalizedText.contains(requested) || requested.contains(normalizedText))
    }

    guard isEmail || matchesRequestedText else { return nil }
    return (recognizedText, observation.boundingBox)
}

guard !redactions.isEmpty else {
    throw RedactionError.noMatchingText
}

let width = sourceImage.width
let height = sourceImage.height
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    throw RedactionError.renderFailed
}

context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
context.setFillColor(NSColor.black.cgColor)

for (_, normalizedBounds) in redactions {
    let bounds = VNImageRectForNormalizedRect(normalizedBounds, width, height)
        .insetBy(dx: -8, dy: -5)
        .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    context.fill(bounds)
    print("Redacted sensitive text at \(NSStringFromRect(bounds))")
}

guard let outputImage = context.makeImage() else {
    throw RedactionError.renderFailed
}

let bitmap = NSBitmapImageRep(cgImage: outputImage)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    throw RedactionError.renderFailed
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)

func normalize(_ text: String) -> String {
    text
        .lowercased()
        .filter { $0.isLetter || $0.isNumber || "@._+-".contains($0) }
}
