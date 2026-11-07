#!/bin/bash
# Snapshot of the bridge on the iPhone, for the overnight test (docs/overnight-test.md).
#
#   scripts/overnight-check.sh before   <iPhone IP>    # in the evening
#   scripts/overnight-check.sh after    <iPhone IP>    # in the morning (also prints the comparison)
set -euo pipefail

MODE="${1:?usage: $0 before|after <iPhone IP>}"
HOST="${2:?usage: $0 before|after <iPhone IP>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/overnight"
mkdir -p "$OUT"

D=/var/mobile/Library/ConnectBridge
snapshot() {
	ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$HOST" "
		# Counts in the log and in its rotated copy (.1): the logs rotate at 2 MB, which a night with
		# Verbose on can reach. grep -c prints 0 and fails when nothing matches, and prints nothing when
		# the file is missing. (Only one generation is kept: after two rotations the oldest lines are gone.)
		cnt() { t=0; for f in \"\$2\" \"\$2.1\"; do n=\$(grep -c \"\$1\" \"\$f\" 2>/dev/null); t=\$((t + \${n:-0})); done; echo \$t; }
		echo \"time: \$(date '+%F %T %z')\"
		echo \"uptime: \$(uptime | sed 's/^ *//')\"
		for name in connectbridged librespot; do
			ps -ax -o pid,rss,etime,command | grep \"connectbridge/\$name\" | grep -v grep | while read pid rss etime rest; do
				echo \"proc \$name pid=\$pid rss_kb=\$rss elapsed=\$etime\"
			done
		done
		echo \"state: \$(cat $D/state 2>/dev/null || echo none)\"
		echo \"daemon_starts: \$(cnt 'connectbridged starting' $D/daemon.log)\"
		echo \"librespot_starts: \$(cnt 'librespot started' $D/daemon.log)\"
		echo \"librespot_exits: \$(cnt 'librespot exited' $D/daemon.log)\"
		echo \"strays_removed: \$(cnt 'removing stray' $D/daemon.log)\"
		echo \"route_selecting: \$(cnt 'route: selecting' $D/daemon.log)\"
		echo \"route_not_found: \$(cnt 'not found' $D/daemon.log)\"
		echo \"guard_events: \$(cnt 'route guard' $D/librespot.log)\"
		echo \"interruptions: \$(cnt 'audio session interruption' $D/librespot.log)\"
		echo \"authenticated: \$(cnt 'Authenticated as' $D/librespot.log)\"
		# DEBUG lines of the volume bridge: they are only in the log while Verbose is on
		echo \"volume_to_connect: \$(cnt 'volume bridge: route -> connect' $D/librespot.log)\"
		echo \"volume_to_route: \$(cnt 'volume bridge: connect [0-9]* -> route' $D/librespot.log)\"
		echo \"connection_lost: \$(cnt 'connection to Spotify lost' $D/librespot.log)\"
		echo \"librespot_errors: \$(cnt ' ERROR ' $D/librespot.log)\"
		echo \"daemon_log_bytes: \$(wc -c < $D/daemon.log)\"
		echo \"librespot_log_bytes: \$(wc -c < $D/librespot.log)\"
		# Identity of the rotated copy (.1): a rotation replaces it, and what was in the old one is gone
		# from the counts above, whatever it held. A changed value means: rotated since the other snapshot.
		gen() { ls -i \"\$1.1\" 2>/dev/null | cut -d' ' -f1 | grep . || echo none; }
		echo \"log_gen_daemon: \$(gen $D/daemon.log)\"
		echo \"log_gen_librespot: \$(gen $D/librespot.log)\"
		echo \"last_daemon_lines:\"; tail -5 $D/daemon.log | cut -c1-160
	"
}

STAMP="$(date +%Y%m%d-%H%M%S)"
FILE="$OUT/$STAMP-$MODE.txt"
snapshot > "$FILE"
ln -sf "$(basename "$FILE")" "$OUT/latest-$MODE.txt"
cat "$FILE"

if [[ "$MODE" == "after" && -e "$OUT/latest-before.txt" ]]; then
	echo
	echo "=== comparison with the evening snapshot ($(readlink "$OUT/latest-before.txt")) ==="
	for key in log_gen_daemon log_gen_librespot; do
		b="$(sed -n "s/^$key: //p" "$OUT/latest-before.txt")"
		a="$(sed -n "s/^$key: //p" "$OUT/latest-after.txt")"
		if [[ "$b" != "$a" ]]; then
			echo "WARNING: ${key#log_gen_} log was rotated during the night: the counts above lost the oldest lines, so a smaller number than in the evening is not a problem by itself."
		fi
	done
	diff <(grep -E '^(proc|state|daemon_starts|librespot_starts|librespot_exits|strays_removed|route_|guard_|interruptions|authenticated|volume_|connection_|librespot_errors|daemon_log_bytes|librespot_log_bytes)' "$OUT/latest-before.txt") \
	     <(grep -E '^(proc|state|daemon_starts|librespot_starts|librespot_exits|strays_removed|route_|guard_|interruptions|authenticated|volume_|connection_|librespot_errors|daemon_log_bytes|librespot_log_bytes)' "$OUT/latest-after.txt") || true
fi
