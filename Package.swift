// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Voltra", platforms: [.macOS(.v14)], products: [.executable(name: "Voltra", targets: ["Voltra"])], targets: [.target(name: "AudioDSP"), .executableTarget(name: "Voltra", dependencies: ["AudioDSP"]), .testTarget(name: "VoltraTests", dependencies: ["Voltra", "AudioDSP"])])
