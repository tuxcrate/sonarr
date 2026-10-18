#!/bin/sh
set -eu

# Run during every architecture's build as the final non-root user.
data="$(mktemp -d)"
pid=
cleanup() {
    if [ -n "$pid" ]; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" || true
    fi
    rm -rf "$data"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

test "$(id -u)" != 0
test ! -w /opt/sonarr
/opt/sonarr/ffprobe -version
/opt/sonarr/Sonarr -nobrowser "-data=$data" > "$data/startup.log" 2>&1 &
pid=$!
attempt=0
until grep -q 'Now listening on:' "$data/startup.log"; do
    if ! kill -0 "$pid" 2>/dev/null || [ "$attempt" -ge 120 ]; then
        cat "$data/startup.log"
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 1
done
grep -F "Version $1" "$data/startup.log"
test -s "$data/sonarr.db"
test -s "$data/config.xml"
kill -TERM "$pid"
wait "$pid"
pid=
