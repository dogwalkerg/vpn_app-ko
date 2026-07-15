# Android native dependencies

## Xray

- Release: AndroidLibXrayLite `v25.3.31`
- Source: `https://github.com/2dust/AndroidLibXrayLite/releases/download/v25.3.31/libv2ray.aar`
- SHA256: `e4cf94de1099a96fb8ed06b1b8c59993f06afc1f7571ac4c16762c7c5f8b8213`
- Xray API: legacy `V2RayPoint` API with `VpnService.protect(socket)` support

The formal release inventory from `v25.3.31` through `v26.7.11` was collected
from the GitHub releases pages. Fully downloaded AAR evidence is listed below;
each row passed ZIP integrity validation before its SHA256, `classes.jar`, and
arm64 `libgojni.so` program headers were inspected.

| Release | Size | SHA256 | Java API | PT_LOAD alignment |
| --- | ---: | --- | --- | --- |
| `v25.3.31` | 51,003,708 | `e4cf94de1099a96fb8ed06b1b8c59993f06afc1f7571ac4c16762c7c5f8b8213` | `V2RayPoint` + `V2RayVPNServiceSupportsSet.protect(long)` | `0x1000` |
| `v25.4.17` | 51,099,638 | `5a8715813c5aa2e9b2d755dbc42fc2cf2506bffe32873729a74e2b8c4b70d839` | first release using `CoreController`; old drop-in API removed | `0x1000` |
| `v25.8.3` | 52,044,212 | `627914ec7b0e72173bc2f45c986a7fac9ca84b91fcb578efb7ed0593741fa4c0` | `CoreController`; no protect callback | `0x4000` |
| `v25.10.15` | 52,673,048 | `b2fbc1edf70ed9432a6685885b95e2c7804779d81bf97db0c9746b52c26a3374` | `CoreController`; no protect callback | `0x4000` |
| `v26.1.23` | 53,646,281 | `17387858d760b6a24b7dc3805eaf8554fe5041f5356945e637fdcbe3cea455fa` | `CoreController`; no protect callback | `0x4000` |
| `v26.4.13` | 55,409,518 | `e35602ec34508db46fa7e9c29168920e846b9a0eedba778a689f0ea912a3b72a` | `CoreController`; no old protect API | `0x4000` |
| `v26.4.15` | 55,364,865 | `d7ee050de7dded7a01e037a40f7da2a1d26de1256aa0d47438875ce923c313ef` | `CoreController`; no old protect API | `0x4000` |
| `v26.4.17` | 55,363,754 | `57d9852fc2990b7e1f02ef0c1f764ac91ee3659c5c10f8de313d60acedabdbe5` | `CoreController`; no old protect API | `0x4000` |
| `v26.4.19` | 55,364,287 | `7c1eca515e3d9910e6f7de4aa26de315164885ad2d0f36ef4d440db66e0846ec` | `CoreController`; no old protect API | `0x4000` |
| `v26.5.3` | 55,788,688 | `b87cfd9172767e78082743f46e9deec22c9580affb01513ebaebc9af724d6ec3` | `CoreController`; no old protect API | `0x4000` |
| `v26.5.9` | 55,819,502 | `322a37e4f8d07c939d0af85799d3692612834441cf36bee5086f6b577c8e028a` | `CoreController`; no old protect API | `0x4000` |
| `v26.7.11` | 58,684,287 | `0c79bb52dc4329aaa266601e56ce4f0cc756b43f97a43dccd08d4a4bfc9aa352` | `CoreController`; no protect callback | `0x4000` |

`v25.4.17` is the first formal release after `v25.3.31` and is the first
drop-in API break. It still has a differently shaped protect callback on
`CoreCallbackHandler`, but remains 4 KB aligned. The fully verified 16 KB
releases no longer expose the protect integration used by this plugin. The
intermediate release assets were enumerated but could not all be downloaded
reliably during this audit, so no unverified candidate is installed. Keep
`v25.3.31` until a 16 KB AAR with an equivalent protected-socket contract is
fully verified and the Java integration is deliberately migrated.

Formal releases enumerated but not installed:
`v25.4.18`, `v25.4.30`, `v25.5.7`, `v25.5.16`, `v25.6.7`, `v25.6.8`,
`v25.6.19`, `v25.7.24`, `v25.7.25`, `v25.7.26`, `v25.8.29`, `v25.8.31`,
`v25.9.5`, `v25.9.10`, `v25.9.11`, `v25.12.1`, `v25.12.2`, `v25.12.8`,
`v26.1.13`, `v26.1.18`, `v26.1.31`, `v26.2.2`, `v26.2.4`, `v26.2.6`,
`v26.3.9`, `v26.3.23`, `v26.3.27`, `v26.4.25`, `v26.5.19`, `v26.6.1`,
`v26.6.2`, `v26.6.14`, `v26.6.22`, `v26.6.27`, and `v26.7.5`.

## HEV Socks5 Tunnel

- Release: `2.15.0`
- Source: `https://github.com/heiher/hev-socks5-tunnel/releases/download/2.15.0/hev-socks5-tunnel-2.15.0.tar.xz`
- Source SHA256: `8ebee22282b8f952ebae330c8d9957a5fd1e15fb1aa67e059b8334b2b09c17f6`
- Toolchain: Android NDK `28.2.13676358`
- ELF maximum page size: `0x4000` (16 KB) for every ABI
- SPDX license identifier: `MIT`
- Upstream license text: `licenses/hev-socks5-tunnel-LICENSE.txt`
- Bundled HEV core, task-system, and YAML code: `MIT` (same upstream text)
- Bundled lwIP code: `BSD-3-Clause`; `licenses/lwip-LICENSE.txt`

Built library SHA256 values:

- `arm64-v8a`: `d43d6e8b21d326897184a92740c8a201395b8ac2553fb737d3c444c2c1312369`
- `armeabi-v7a`: `386e7cd4876c8a8b53d7e50250b31295306ba548129fdae85b54c269a610a58f`
- `x86`: `bb2f84c0101c60548ae3946508dfca52d6d53c0a66b9fbaf44d117788ec4ff97`
- `x86_64`: `453ab8ddcb84d4c01fae08f42da367920eef5114f1a18451e56096a3e376a17d`

Run `tool/build_hev_android.ps1` to reproduce the HEV binaries.
