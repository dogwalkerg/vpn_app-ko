// swift-tools-version: 5.9

import PackageDescription
let xrayReleaseTag = "xray-ios-v26.6.27"
let xrayChecksum = "c4611c9ce9d9fc44956bc96f1886396507da34fd3892b94ebe96982721575774"
let xrayLocalPath = "XRay.xcframework"

let package = Package(
    name: "flutter_vless",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "flutter-vless-tunnel-support", targets: ["flutter_vless_tunnel_support"])
    ],
    dependencies: [
        .package(url: "https://github.com/EbrahimTahernejad/Tun2SocksKit", exact: "4.11.0")
    ],
    targets: [
        .target(
            name: "flutter_vless_tunnel_support",
            dependencies: [
                "XRay",
                .product(name: "Tun2SocksKit", package: "Tun2SocksKit"),
                .product(name: "Tun2SocksKitC", package: "Tun2SocksKit")
            ],
            linkerSettings: [
                .linkedLibrary("resolv")
            ]
        ),
        .binaryTarget(name: "XRay", path: xrayLocalPath),
        .testTarget(
            name: "flutter_vless_tunnel_supportTests",
            dependencies: ["flutter_vless_tunnel_support"]
        )
    ]
)
