import Foundation

/// Where the backend is. The simulator shares the Mac's loopback, so the default works
/// without any setup. A physical device needs the Mac's LAN address (and the backend's
/// Origin check has to allow it).
enum Backend {
    static let defaultURL = URL(string: "http://127.0.0.1:8000")!
    private static let key = "backend.baseURL"

    static var url: URL {
        get {
            if let raw = UserDefaults.standard.string(forKey: key), let url = URL(string: raw) {
                return url
            }
            return defaultURL
        }
        set {
            UserDefaults.standard.set(newValue.absoluteString, forKey: key)
        }
    }
}
