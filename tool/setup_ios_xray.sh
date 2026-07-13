#!/usr/bin/env bash
set -euo pipefail

readonly version="v26.6.27"
readonly release_tag="xray-ios-v26.6.27"
readonly checksum="c4611c9ce9d9fc44956bc96f1886396507da34fd3892b94ebe96982721575774"
readonly url="https://github.com/XIIIFOX/flutter_vless/releases/download/${release_tag}/XRay.xcframework.zip"
readonly root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ios_dir="${root}/third_party/flutter_vless_ios/ios"
readonly package_dir="${ios_dir}/flutter_vless"
readonly framework="${package_dir}/XRay.xcframework"

if [[ -f "${framework}/ios-arm64/XRay.framework/XRay" ]]; then
  echo "XRay ${version} is already available."
  exit 0
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive="${tmp_dir}/XRay.xcframework.zip"
curl --fail --location --retry 4 --retry-all-errors "${url}" --output "${archive}"
actual="$(shasum -a 256 "${archive}" | awk '{print $1}')"
if [[ "${actual}" != "${checksum}" ]]; then
  echo "XRay checksum mismatch: expected ${checksum}, got ${actual}" >&2
  exit 1
fi

rm -rf "${framework}"
unzip -q "${archive}" -d "${package_dir}"
test -f "${framework}/ios-arm64/XRay.framework/XRay"
echo "Installed XRay ${version}."
