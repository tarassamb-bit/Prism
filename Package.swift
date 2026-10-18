// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Relio", targets: ["RelioApp"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .executableTarget(name: "RelioApp", dependencies: ["CSQLite"])
    ]
)
