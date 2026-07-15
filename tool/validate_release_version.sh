#!/usr/bin/env bash
set -euo pipefail

readonly version="${1:-}"
readonly root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::Release version must use numeric major.minor.patch format, got '${version}'." >&2
  exit 1
fi

pubspec_version="$(sed -nE 's/^version:[[:space:]]*([^+[:space:]]+).*$/\1/p' "${root}/pubspec.yaml")"
if [[ -z "${pubspec_version}" || "${pubspec_version}" != "${version}" ]]; then
  echo "::error::Release version '${version}' does not match pubspec version '${pubspec_version:-missing}'." >&2
  exit 1
fi

echo "Validated release and pubspec version ${version}."
