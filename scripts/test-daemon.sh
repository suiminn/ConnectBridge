#!/bin/bash
# Host-side tests for the parts of the daemon and of the librespot patch that do not need an iPhone:
#   daemon/route_policy.h   decisions about giving the AirPlay route back
#   daemon/marker.h         the "holding" marker file
#   src/volume_logic.rs     volume sync state machine (from librespot/ios-bridge.patch)
#   src/guard_logic.rs      the route guard's pause record (same)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# rustc comes from rustup, which is not on the PATH by default: env.sh puts it there.
if ! command -v rustc >/dev/null 2>&1 && [ -f "$ROOT/env.sh" ]; then
    # shellcheck disable=SC1091
    source "$ROOT/env.sh"
fi
if ! command -v rustc >/dev/null 2>&1; then
    echo "error: rustc not found, even after loading env.sh." >&2
    echo "  Install rustup (brew install rustup && rustup toolchain install stable --profile minimal --target aarch64-apple-ios)" >&2
    echo "  and make sure its bin directory is in the PATH (see env.sh)." >&2
    exit 1
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$OUT/modules}"

clang -std=c11 -Wall -Wextra -Werror -o "$OUT/route_policy_test" "$ROOT/daemon/tests/route_policy_test.c"
"$OUT/route_policy_test"

clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-function -framework Foundation -o "$OUT/marker_test" "$ROOT/daemon/tests/marker_test.m"
"$OUT/marker_test"

# The volume sync logic only uses std; take it out of the patch (git apply works outside a repository).
mkdir "$OUT/rust"
( cd "$OUT/rust" && git apply --include='src/volume_logic.rs' "$ROOT/librespot/ios-bridge.patch" )
rustc --edition 2021 --test -o "$OUT/volume_logic_test" "$OUT/rust/src/volume_logic.rs"
"$OUT/volume_logic_test" --quiet

( cd "$OUT/rust" && git apply --include='src/guard_logic.rs' "$ROOT/librespot/ios-bridge.patch" )
rustc --edition 2021 --test -o "$OUT/guard_logic_test" "$OUT/rust/src/guard_logic.rs"
"$OUT/guard_logic_test" --quiet
