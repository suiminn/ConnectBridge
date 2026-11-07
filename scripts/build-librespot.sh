#!/bin/bash
# Builds the patched librespot for iOS (arm64, iOS 15+) into build/librespot.
#
# Needs: rustup with the aarch64-apple-ios target, Xcode (iPhoneOS SDK), ldid.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/env.sh" ]] && source "$ROOT/env.sh"
SRC="$ROOT/build/librespot-src"
PIN="99b6088bf3ea028f90192676ac1a337fa4b2ed12"   # librespot 0.8.0 (dev, 2026-10-21)

if [[ "$ROOT" == *" "* ]]; then
	echo "The project path must not contain spaces (Theos refuses such paths)." >&2
	exit 1
fi

mkdir -p "$ROOT/build"
if [[ ! -d "$SRC/.git" ]]; then
	git clone https://github.com/librespot-org/librespot.git "$SRC"
fi
git -C "$SRC" fetch --quiet origin
git -C "$SRC" checkout --quiet --force "$PIN"
[[ -d "$SRC/.git" ]] || { echo "$SRC is not a git checkout" >&2; exit 1; }
git -C "$SRC" clean -fdq
git -C "$SRC" apply "$ROOT/librespot/ios-bridge.patch"

# libmdns 0.10.1 with librespot/libmdns-ios.patch (no IPv6 responder on iOS: its multicast sends fail with
# "No route to host"). ios-bridge.patch points [patch.crates-io] at ../libmdns.
MDNS="$ROOT/build/libmdns"
MDNS_SHA256="a00dbe871d2cf9df13f68d152b949fca8cafc854b60ffd259fc6df6e8663d8d7"
rm -rf "$MDNS" "$ROOT/build/libmdns.crate"
curl -fsSL -o "$ROOT/build/libmdns.crate" https://static.crates.io/crates/libmdns/libmdns-0.10.1.crate
[[ "$(shasum -a 256 "$ROOT/build/libmdns.crate" | cut -d' ' -f1)" == "$MDNS_SHA256" ]] || { echo "libmdns checksum mismatch" >&2; exit 1; }
mkdir "$MDNS"
tar -xzf "$ROOT/build/libmdns.crate" -C "$MDNS" --strip-components=1
patch -p1 -s -d "$MDNS" < "$ROOT/librespot/libmdns-ios.patch"

export IPHONEOS_DEPLOYMENT_TARGET=15.0
( cd "$SRC" && cargo build --release --locked --target aarch64-apple-ios \
	--no-default-features --features "native-tls,rodio-backend,with-libmdns" )

cp "$SRC/target/aarch64-apple-ios/release/librespot" "$ROOT/build/librespot"
echo "built: $ROOT/build/librespot"
