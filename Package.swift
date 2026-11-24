// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "touchrun",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "touchrun", targets: ["touchrun"])
  ],
  targets: [
    .target(
      name: "TouchRunCore",
      linkerSettings: [
        .linkedFramework("Security"),
        .linkedFramework("LocalAuthentication"),
      ]
    ),
    .executableTarget(
      name: "touchrun",
      dependencies: ["TouchRunCore"]
    ),
    .executableTarget(
      name: "TouchRunTests",
      dependencies: ["TouchRunCore"]
    ),
  ]
)
