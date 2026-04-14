#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
ARCHIVE_URL="https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.6.0-c73b779f-dd8bfdba.tar.xz"
ARCHIVE_PATH="$WORK_DIR/VLCKit.tar.xz"
UNPACK_DIR="$WORK_DIR/unpack"
TARGET_DIR="$ROOT_DIR/Vendor/VLCKitSPM/Binaries"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$UNPACK_DIR" "$TARGET_DIR"

curl -L "$ARCHIVE_URL" -o "$ARCHIVE_PATH"
tar -xf "$ARCHIVE_PATH" -C "$UNPACK_DIR"

rm -rf "$TARGET_DIR/VLCKit.xcframework"
cp -R "$UNPACK_DIR/VLCKit - binary package/VLCKit.xcframework" "$TARGET_DIR/VLCKit.xcframework"

echo "Installed VLCKit.xcframework to $TARGET_DIR"
