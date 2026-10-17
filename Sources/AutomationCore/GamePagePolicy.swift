import Foundation

public enum GamePagePolicy {
    /// Match the actual HTTPS origin, not a title, substring, or link in page content.
    public static func allows(_ address: String?) -> Bool {
        guard let address, let url = URLComponents(string: address),
              url.scheme?.lowercased() == "https", url.host?.lowercased() == "open.mu",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }
}
