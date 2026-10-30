#!/bin/sh
set -eu

: "${1:?Expected application version is required}"

# Run during every architecture's build as the final non-root user.
data="$(mktemp -d)"
pid=
phase='checking runtime prerequisites'
cleanup() {
    status=$?
    if [ -n "$pid" ]; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" || true
    fi
    if [ "$status" -ne 0 ]; then
        printf 'Sonarr smoke test failed while %s (exit status %s).\n' "$phase" "$status" >&2
        ls -la "$data" >&2 || true
        if [ -f "$data/startup.log" ]; then
            cat "$data/startup.log" >&2 || true
        fi
    fi
    rm -rf "$data"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

test "$(id -u)" != 0
test ! -w /opt/sonarr
/opt/sonarr/ffprobe -version
/opt/sonarr/Sonarr -nobrowser "-data=$data" > "$data/startup.log" 2>&1 &
pid=$!
phase='waiting for Sonarr to listen and create nonempty sonarr.db and config.xml'
attempt=0
while :; do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo 'Sonarr exited before becoming ready.' >&2
        exit 1
    fi
    if grep -q 'Now listening on:' "$data/startup.log" \
        && test -s "$data/sonarr.db" \
        && test -s "$data/config.xml"; then
        break
    fi
    if [ "$attempt" -ge 120 ]; then
        echo 'Timed out waiting for Sonarr readiness.' >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 1
done
phase='checking the installed version'
grep -F "Version $1" "$data/startup.log"
phase='stopping Sonarr'
kill -TERM "$pid"
if wait "$pid"; then
    pid=
else
    status=$?
    pid=
    printf 'Sonarr shutdown returned exit status %s.\n' "$status" >&2
    exit "$status"
fi
