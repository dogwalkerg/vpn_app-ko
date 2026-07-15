#!/usr/bin/env bash
set -euo pipefail

readonly root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
readonly derived_data="${temp_root}/osca-macos-test-derived-data"
readonly result_bundle="${temp_root}/Osca-macOS-RunnerTests.xcresult"
readonly test_log="${temp_root}/Osca-macOS-RunnerTests.log"

test -d "${root}/macos/Runner.xcworkspace"
rm -rf "${derived_data}" "${result_bundle}"
rm -f "${test_log}"

xcodebuild -version 2>&1 | tee "${test_log}"

xcodebuild test \
  -workspace "${root}/macos/Runner.xcworkspace" \
  -scheme Runner \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "${derived_data}" \
  -resultBundlePath "${result_bundle}" \
  -parallel-testing-enabled NO \
  -only-testing:RunnerTests \
  MACOSX_DEPLOYMENT_TARGET=12.0 \
  2>&1 | tee -a "${test_log}"

test -d "${result_bundle}"
echo "macOS RunnerTests completed successfully."
