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

    /// Compare document addresses independently of mutable browser/page titles.
    /// Preserve path, query and fragment so another open.mu page is not accepted.
    public static func sameDocument(_ first: String?, _ second: String?) -> Bool {
        guard allows(first), allows(second), let first, let second else { return false }
        func normalized(_ address: String) -> URLComponents? {
            guard var components = URLComponents(string: address) else { return nil }
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            if components.port == 443 { components.port = nil }
            if components.path.isEmpty { components.path = "/" }
            return components
        }
        return normalized(first) == normalized(second)
    }
}
