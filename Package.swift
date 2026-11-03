// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InputBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "inputbridge", targets: ["InputBridgeCLI"]),
        .executable(name: "inputbridge-ddc", targets: ["DDCProbe"]),
        .executable(name: "InputBridgeApp", targets: ["InputBridgeApp"])
    ],
    targets: [
        .target(name: "AppleSiliconDDCObjC", path: "ThirdParty/AppleSiliconDDCObjC", publicHeadersPath: "."),
        .target(name: "AppleSiliconDDC", dependencies: ["AppleSiliconDDCObjC"], path: "ThirdParty/AppleSiliconDDC", exclude: ["LICENSE"], linkerSettings: [.linkedFramework("CoreDisplay")]),
        .target(name: "DisplayBridge", linkerSettings: [.linkedFramework("CoreDisplay"), .linkedFramework("CoreGraphics")]),
        .target(name: "BridgeCore", dependencies: ["DisplayBridge"]),
        .executableTarget(name: "DDCProbe", dependencies: ["AppleSiliconDDC", "AppleSiliconDDCObjC", "BridgeCore"]),
        .executableTarget(name: "InputBridgeCLI", dependencies: ["BridgeCore"]),
        .executableTarget(name: "InputBridgeApp", dependencies: ["BridgeCore"], linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"])
    ]
)
