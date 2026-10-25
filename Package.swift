// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MCSManagerAPI",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .visionOS(.v1),
        .watchOS(.v9),
        .tvOS(.v16),
    ],
    products: [
        .library(name: "MCSMAPI", targets: ["MCSMAPI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.11.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.11.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.5.1"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "6.2.4"),
    ],
    targets: [
        .target(
            name: "MCSMAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        .testTarget(
            name: "MCSMAPITests",
            dependencies: [
                "MCSMAPI",
                .product(name: "Testing", package: "swift-testing"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ]
        ),
    ]
)
