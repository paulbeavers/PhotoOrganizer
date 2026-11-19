// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoOrganizer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PhotoOrganizer", targets: ["PhotoOrganizer"]),
    ],
    targets: [
        // UI-free logic: folder scanning, metadata reading, XMP sidecar tagging.
        .target(name: "PhotoOrganizerCore"),
        // The SwiftUI application.
        .executableTarget(name: "PhotoOrganizer", dependencies: ["PhotoOrganizerCore"]),
        .testTarget(name: "PhotoOrganizerCoreTests", dependencies: ["PhotoOrganizerCore"]),
    ]
)
