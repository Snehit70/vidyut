#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  echo "usage: $0 APK VERSION_NAME VERSION_CODE CERT_SHA256 [MAX_BYTES]" >&2
  exit 2
fi

apk="$1"
expected_version="$2"
expected_code="$3"
expected_cert="$(printf '%s' "$4" | tr '[:upper:]' '[:lower:]' | tr -d ':')"
max_bytes="${5:-83886080}"
expected_package="dev.snehit.vidyut.vidyut"
expected_abi="arm64-v8a"

if [ ! -f "$apk" ]; then
  echo "APK not found: $apk" >&2
  exit 1
fi

android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$android_sdk" ] || [ ! -d "$android_sdk/build-tools" ]; then
  echo "ANDROID_HOME or ANDROID_SDK_ROOT must point to an Android SDK." >&2
  exit 1
fi

build_tools="$(
  find "$android_sdk/build-tools" -mindepth 1 -maxdepth 1 -type d |
    sort -V |
    tail -1
)"
aapt="$build_tools/aapt"
apksigner="$build_tools/apksigner"
if [ ! -x "$aapt" ] || [ ! -x "$apksigner" ]; then
  echo "aapt and apksigner are required in $build_tools." >&2
  exit 1
fi

badging="$("$aapt" dump badging "$apk")"
package_line="$(printf '%s\n' "$badging" | sed -n '1p')"
actual_package="$(
  printf '%s\n' "$package_line" |
    sed -n "s/^package: name='\\([^']*\\)'.*/\\1/p"
)"
actual_code="$(
  printf '%s\n' "$package_line" |
    sed -n "s/^package: name='[^']*' versionCode='\\([^']*\\)'.*/\\1/p"
)"
actual_version="$(
  printf '%s\n' "$package_line" |
    sed -n "s/^package: name='[^']*' versionCode='[^']*' versionName='\\([^']*\\)'.*/\\1/p"
)"
actual_abis="$(
  printf '%s\n' "$badging" |
    sed -n "s/^native-code: //p" |
    tr -d "'" |
    xargs
)"
actual_cert="$(
  "$apksigner" verify --print-certs "$apk" |
    sed -nE 's/^(Signer #1|V2 Signer): certificate SHA-256 digest: //p' |
    head -1 |
    tr '[:upper:]' '[:lower:]' |
    tr -d ':'
)"
actual_bytes="$(stat -c '%s' "$apk")"

check_equal() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$actual" != "$expected" ]; then
    echo "$label mismatch: expected '$expected', got '$actual'." >&2
    exit 1
  fi
}

check_equal "Package ID" "$expected_package" "$actual_package"
check_equal "Version name" "$expected_version" "$actual_version"
check_equal "Version code" "$expected_code" "$actual_code"
check_equal "Native ABI" "$expected_abi" "$actual_abis"
check_equal "Signing certificate" "$expected_cert" "$actual_cert"

if [ "$actual_bytes" -gt "$max_bytes" ]; then
  echo "APK is $actual_bytes bytes; maximum allowed is $max_bytes." >&2
  exit 1
fi

echo "Verified $apk"
echo "  package=$actual_package"
echo "  version=$actual_version+$actual_code"
echo "  abi=$actual_abis"
echo "  certificate=$actual_cert"
echo "  bytes=$actual_bytes"
