import Foundation

enum AppLinks {
    static let home = URL(string: "https://github.com/cmortuus/halltone")!
    static let macDownload = URL(string: "https://github.com/cmortuus/halltone/releases/latest")!
    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
