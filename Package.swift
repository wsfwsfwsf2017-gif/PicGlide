// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PicGlide",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PicGlide", targets: ["PicGlideApp"])],
    dependencies: [
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", exact: "1.6.0")
    ],
    targets: [
        .target(name: "PicGlideCore", dependencies: [
            .product(name: "libwebp", package: "libwebp-Xcode")
        ]),
        .executableTarget(name: "PicGlideApp", dependencies: ["PicGlideCore"]),
        .testTarget(name: "PicGlideCoreTests", dependencies: ["PicGlideCore"])
    ]
)
