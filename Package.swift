// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "AutomationCore", targets: ["AutomationCore"])]
var targets: [Target] = [
    .target(name: "AutomationCore"),
    .testTarget(name: "AutomationCoreTests", dependencies: ["AutomationCore"], resources: [.copy("Fixtures")])
]
#if os(macOS)
products.append(.executable(name: "MUAutomator", targets: ["MUAutomator"]))
targets.append(.executableTarget(name: "MUAutomator", dependencies: ["AutomationCore"]))
targets.append(.testTarget(name: "MacAdapterTests", dependencies: ["MUAutomator", "AutomationCore"], resources: [.copy("Fixtures")]))
#endif

let package = Package(
    name: "MUAutomator",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
