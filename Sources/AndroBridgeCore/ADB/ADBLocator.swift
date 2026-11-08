import Foundation

/// Finds the `adb` binary. Order: user override → copy bundled inside the app →
/// Android SDK → Homebrew → PATH.
public enum ADBLocator {
    public static func candidates(override: String?, bundle: Bundle = .main,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var list: [String] = []
        if let override, !override.isEmpty {
            list.append((override as NSString).expandingTildeInPath)
        }
        if let res = bundle.resourceURL {
            list.append(res.appendingPathComponent("platform-tools/adb").path)
        }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = environment[key], !sdk.isEmpty {
                list.append((sdk as NSString).appendingPathComponent("platform-tools/adb"))
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        list.append(home + "/Library/Android/sdk/platform-tools/adb")
        list.append("/opt/homebrew/bin/adb")
        list.append("/usr/local/bin/adb")
        if let path = environment["PATH"] {
            for dir in path.split(separator: ":") {
                list.append(String(dir) + "/adb")
            }
        }
        // De-duplicate, keep order.
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    public static func locate(override: String? = nil, bundle: Bundle = .main) -> URL? {
        let fm = FileManager.default
        for path in candidates(override: override, bundle: bundle) where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
