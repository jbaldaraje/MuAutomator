import XCTest
@testable import AutomationCore

final class GamePagePolicyTests: XCTestCase {
    func testOpenMUOriginAndVersionedGamePaths() {
        for address in ["https://open.mu", "https://open.mu/versions/20261006042155/index.html",
                        "https://OPEN.MU:443/game?mode=play#canvas"] {
            XCTAssertTrue(GamePagePolicy.allows(address), address)
        }
    }

    func testOtherPagesAndMisleadingAddressesAreRejected() {
        for address in [nil, "open.mu", "MU Online — open.mu", "http://open.mu/game",
                        "https://open.mu.evil.example/game", "https://evilopen.mu/game",
                        "https://example.com/?redirect=https://open.mu", "https://example.com/open.mu",
                        "https://open.mu@example.com", "https://user@open.mu/game",
                        "https://www.open.mu/game", "https://open.mu:8443/game", "file:///tmp/open.mu"] {
            XCTAssertFalse(GamePagePolicy.allows(address), address ?? "nil")
        }
    }
}
