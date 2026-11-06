import Foundation

/// 这台手机上装着的是哪一份包（spec #120）：按种类记下导入那个 `.eidolonpkg` 的 sha256。
/// 服务器页据此判断「服务器上那份就是我已经装的」，不再让人重复下载几百 MB。
///
/// 只认指纹不认版本号：文件名里的版本是给人看的，内容一样才是真的没变。
enum InstalledPackages {
    private static let key = "server.installedSHA"
    private static let versionKey = "server.installedVersion"

    static var all: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func sha(for kind: String) -> String? { all[kind] }

    static func remember(_ sha: String, for kind: String) {
        var dictionary = all
        dictionary[kind] = sha.lowercased()
        UserDefaults.standard.set(dictionary, forKey: key)
    }

    static func isInstalled(_ sha: String, kind: String) -> Bool {
        self.sha(for: kind) == sha.lowercased()
    }

    /// 装的是哪一版（给界面看的说法）。从服务器下的那份知道版本号；从别处导入的有可能不知道。
    static func version(for kind: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: versionKey) as? [String: String])?[kind]
    }

    static func remember(version: String, for kind: String) {
        var dictionary = UserDefaults.standard.dictionary(forKey: versionKey) as? [String: String] ?? [:]
        dictionary[kind] = version
        UserDefaults.standard.set(dictionary, forKey: versionKey)
    }
}
