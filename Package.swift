// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    // Pure Foundation: event parsing, session state machine, hook installers,
    // Codex rollout tailing. Builds and tests on Linux too.
    .target(name: "TurboCore"),
    .testTarget(name: "TurboCoreTests", dependencies: ["TurboCore"]),
]
var products: [Product] = [.library(name: "TurboCore", targets: ["TurboCore"])]

#if os(macOS)
targets.append(.executableTarget(name: "Turbo", dependencies: ["TurboCore"]))
products.append(.executable(name: "Turbo", targets: ["Turbo"]))
#endif

let package = Package(
    name: "Turbo",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
