import CryptoKit
import Foundation

/// BundleStamp — provenance for every shared artifact (TF1.3): schema
/// version, app build, device, OS, capture time. A bundle must be
/// self-identifying; "which build made this?" was previously
/// unanswerable from the files alone.
enum BundleStamp {

    static let schema = 3

    static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static func dict() -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNo = info?["CFBundleVersion"] as? String ?? "?"
        // Configuration matters enormously for the perf block: -Onone runs
        // closure/array-heavy kernels 20-30× slower than -O. The stamp
        // makes every bundle say which one produced its numbers.
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        return [
            "schema": schema,
            "build": "\(version) (\(buildNo))",
            "configuration": config,
            "device": deviceModel(),
            "os": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "orientation": "portrait-cw: decoded planes + palette order rotated 90° CW; bands/σ-inputs stay sensor-native",
        ]
    }

    /// One-line form for the log's META header.
    static func line() -> String {
        let d = dict()
        return "schema \(d["schema"] ?? "?") build \(d["build"] ?? "?") "
            + "\(d["configuration"] ?? "?") "
            + "device \(d["device"] ?? "?") os \(d["os"] ?? "?") at \(d["capturedAt"] ?? "?")"
    }

    /// manifest.json (TF1.4): name + bytes + SHA-256 per file — a
    /// partial AirDrop becomes detectable instead of confusing.
    static func manifest(of urls: [URL]) -> [String: Any] {
        let files = urls.compactMap { url -> [String: Any]? in
            guard let d = try? Data(contentsOf: url) else { return nil }
            return ["name": url.lastPathComponent,
                    "bytes": d.count,
                    "sha256": SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()]
        }
        return ["schema": schema, "files": files]
    }

    /// Bundle directory name: readable, sortable.
    static func bundleName(_ prefix: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "\(prefix)-\(f.string(from: Date()))"
    }
}
