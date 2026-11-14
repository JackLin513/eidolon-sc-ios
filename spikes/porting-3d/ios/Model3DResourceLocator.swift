import Foundation

/// Where the spike finds `mirai.usdz`. The app bundle is authoritative; Documents is
/// only a test fallback so a locally copied model can be used without rebuilding.
enum Model3DResourceLocator {
    static func locate(
        environment: [String: String],
        documents: URL,
        resourceRoot: URL?,
        fileName: String = "mirai.usdz",
        fileManager: FileManager = .default
    ) -> URL? {
        if let raw = environment["EIDOLON_3D_MODEL"], !raw.isEmpty {
            let candidate = raw.hasPrefix("/")
                ? URL(fileURLWithPath: raw)
                : documents.appending(path: raw)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        if let resourceRoot {
            let direct = resourceRoot.appending(path: fileName)
            if fileManager.fileExists(atPath: direct.path) {
                return direct
            }
            if let enumerator = fileManager.enumerator(
                at: resourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) {
                for case let url as URL in enumerator
                where url.lastPathComponent == fileName {
                    let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
                        ?? false
                    if isFile { return url }
                }
            }
        }

        let fallback = documents.appending(path: fileName)
        return fileManager.fileExists(atPath: fallback.path) ? fallback : nil
    }
}
