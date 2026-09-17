import Foundation
import MetricKit

/// Collects MetricKit crash and hang reports, so a kill like build 20's 0x8BADF00D no longer needs the .ips file
/// dug out of Settings. Reports land in Documents/Tanılama, which Files shows under "On My iPad / OptiPDF", and
/// "Tanılama kayıtlarını paylaş" shares the newest ones.
final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsCollector()

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Tanılama", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let directory = Self.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        for (offset, payload) in payloads.enumerated() {
            let name = formatter.string(from: payload.timeStampEnd) + (offset == 0 ? "" : "-\(offset)") + ".json"
            try? payload.jsonRepresentation().write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {}

    /// Newest reports first.
    static func reports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
