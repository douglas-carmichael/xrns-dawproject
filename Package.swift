// swift-tools-version: 5.9
import PackageDescription

// The pure-Swift core (XML, ZIP/DEFLATE, MIDI, and the Renoise/DAWproject/MIDI
// readers + writers) lives in ConverterKit. Legacy tracker modules are parsed by
// a vendored copy of libxmp (MIT-licensed C) in the CLibxmp target — a mature,
// broad parser whose events/samples are bridged into the IR. SwiftPM compiles
// the C cross-platform, so a single `swift build` still works on macOS, Linux
// and Windows.

let package = Package(
    name: "xrns-dawproject",
    platforms: [
        .macOS(.v12)  // only consulted on Apple platforms; ignored on Linux/Windows
    ],
    products: [
        // Repo/package is "xrns-dawproject"; the binary is the shorter "xrnsdaw".
        .executable(name: "xrnsdaw", targets: ["XrnsDawProjectCLI"]),
    ],
    targets: [
        .target(
            name: "CLibxmp",
            cSettings: [
                // Full format set, minus the packed-wrapper depackers / ProWizard
                // crackers (niche, and their sources use non-standalone includes).
                .define("LIBXMP_NO_DEPACKERS"),
                .define("LIBXMP_NO_PROWIZARD"),
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("loaders"),
            ]
        ),
        .target(name: "ConverterKit", dependencies: ["CLibxmp"]),
        .executableTarget(
            name: "XrnsDawProjectCLI",
            dependencies: ["ConverterKit"]
        ),
        .testTarget(
            name: "ConverterKitTests",
            dependencies: ["ConverterKit"]
        ),
    ]
)
