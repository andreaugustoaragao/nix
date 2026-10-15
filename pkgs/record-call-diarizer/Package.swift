// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecordCallDiarizer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "record-call-diarizer", targets: ["RecordCallDiarizer"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "19600a485baa4998812e4654b70d2bab8f2c9949")
    ],
    targets: [
        .executableTarget(name: "RecordCallDiarizer", dependencies: ["FluidAudio"])
    ]
)
