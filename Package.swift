// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "Test",
  platforms: [.macOS(.v10_15)],
  products: [
    .executable(name: "App", targets: ["App"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-system", from: "1.0.0"),
  ],
  targets: [
    .executableTarget(
      name: "App",
      dependencies: [
        "Lib",
        "CLib",
        .product(name: "SystemPackage", package: "swift-system")
      ],
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency")
      ]
    ),
    .target(
      name: "Lib",
      dependencies: [
        "CLib",
        .product(name: "SystemPackage", package: "swift-system")
      ],
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency")
      ]
    ),
    .target(name: "CLib")
  ]
)
