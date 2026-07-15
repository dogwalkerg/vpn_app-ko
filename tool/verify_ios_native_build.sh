#!/usr/bin/env bash
set -euo pipefail

readonly root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
readonly package_dir="${root}/third_party/flutter_vless_ios/ios/flutter_vless"
readonly package_derived_data="${temp_root}/osca-ios-package-derived-data"
readonly app_derived_data="${temp_root}/osca-ios-app-derived-data"
readonly source_packages="${temp_root}/osca-ios-source-packages"
readonly scheme_json="${temp_root}/Osca-iOS-SwiftPackage-schemes.json"
readonly package_log="${temp_root}/Osca-iOS-SwiftPackage.log"
readonly package_result_bundle="${temp_root}/Osca-iOS-SwiftPackage.xcresult"
readonly app_log="${temp_root}/Osca-iOS-PacketTunnel.log"
readonly app_result_bundle="${temp_root}/Osca-iOS-PacketTunnel.xcresult"

test -f "${package_dir}/Package.swift"
test -d "${package_dir}/XRay.xcframework"
test -d "${root}/ios/Runner.xcworkspace"

rm -rf \
  "${package_derived_data}" \
  "${app_derived_data}" \
  "${package_result_bundle}" \
  "${app_result_bundle}"
rm -f "${scheme_json}" "${package_log}" "${app_log}"
mkdir -p "${source_packages}"

{
  xcodebuild -version
  swift --version
} 2>&1 | tee "${package_log}"

# SwiftPM-generated scheme names have changed between Xcode releases. Discover
# the scheme instead of binding CI to one Xcode version's naming convention.
(
  cd "${package_dir}"
  xcodebuild -list -json \
    -clonedSourcePackagesDirPath "${source_packages}" \
    > "${scheme_json}" 2>> "${package_log}"
)
package_scheme="$(python3 - "${scheme_json}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

schemes = []
for container in ("workspace", "project"):
    schemes.extend(data.get(container, {}).get("schemes", []))

preferred = (
    "flutter-vless-tunnel-support",
    "flutter_vless-Package",
    "flutter_vless",
)
for candidate in preferred:
    if candidate in schemes:
        print(candidate)
        break
else:
    matching = [
        scheme for scheme in schemes
        if "flutter" in scheme.lower() and "vless" in scheme.lower()
    ]
    if len(matching) != 1:
        raise SystemExit(f"Unable to select Swift package scheme from: {schemes}")
    print(matching[0])
PY
)"
echo "Using Swift package scheme ${package_scheme}."

# Build the package tests for a generic iOS device. This catches Swift source
# and binary-target regressions without depending on a named simulator image.
(
  cd "${package_dir}"
  xcodebuild -resolvePackageDependencies \
    -scheme "${package_scheme}" \
    -clonedSourcePackagesDirPath "${source_packages}" \
    2>&1 | tee -a "${package_log}"
  xcodebuild build-for-testing \
    -scheme "${package_scheme}" \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "${package_derived_data}" \
    -clonedSourcePackagesDirPath "${source_packages}" \
    -resultBundlePath "${package_result_bundle}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    2>&1 | tee -a "${package_log}"
)

package_test_bundle="$(find "${package_derived_data}/Build/Products" -type d -name '*Tests.xctest' -print -quit)"
test -n "${package_test_bundle}"

# Build the workspace as Xcode sees it so the local package product must link
# into XrayTunnel and the extension must embed into Runner.app.
xcodebuild -resolvePackageDependencies \
  -workspace "${root}/ios/Runner.xcworkspace" \
  -scheme Runner \
  -clonedSourcePackagesDirPath "${source_packages}" \
  2>&1 | tee "${app_log}"
xcodebuild build \
  -workspace "${root}/ios/Runner.xcworkspace" \
  -scheme Runner \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${app_derived_data}" \
  -clonedSourcePackagesDirPath "${source_packages}" \
  -resultBundlePath "${app_result_bundle}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee -a "${app_log}"

readonly app="${app_derived_data}/Build/Products/Debug-iphoneos/Runner.app"
readonly tunnel="${app}/PlugIns/XrayTunnel.appex"
test -f "${app}/Runner"
test -f "${tunnel}/XrayTunnel"

echo "Swift package tests compiled and XrayTunnel embedded successfully."
