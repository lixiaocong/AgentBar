import Foundation

func sharedFixtureData(_ components: String...) throws -> Data {
    var directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()

    for _ in 0 ..< 8 {
        let candidate = components.reduce(
            directory.appending(path: "Shared", directoryHint: .isDirectory)
                .appending(path: "AgentBarFixtures", directoryHint: .isDirectory)
        ) { url, component in
            url.appending(path: component)
        }

        if FileManager.default.fileExists(atPath: candidate.path) {
            return try Data(contentsOf: candidate)
        }

        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path {
            break
        }
        directory = parent
    }

    throw CocoaError(.fileNoSuchFile)
}
