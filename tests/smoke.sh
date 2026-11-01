#!/usr/bin/env bash
set -euo pipefail

image=${1:?A locally loaded image is required}
version=${2:?The expected application version is required}
platform=${3:?The image platform is required}
package_version=${PACKAGE_VERSION:-${version}-local}
container=
phase='starting the container with its default entrypoint and user'
cleanup() {
    status=$?
    if [[ -n $container ]]; then
        if ((status != 0)); then
            printf 'Sonarr smoke test failed while %s (exit status %s).\n' "$phase" "$status" >&2
            docker inspect --format '{{json .State}}' "$container" >&2 || true
            docker logs "$container" >&2 || true
            docker exec "$container" ls -la /config >&2 || true
        fi
        docker rm --force --volumes "$container" > /dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

container=$(docker create --pull=never --platform "$platform" --network none \
    --label "com.tuxcrate.smoke-test=${TUXCRATE_TEST_ID:-manual-sonarr-$$}" "$image")
docker start "$container" > /dev/null
phase='checking runtime prerequisites as the configured user'
docker exec "$container" sh -eu -c '
    test "$(id -u)" = 1000
    test "$(id -g)" = 1000
    test "$(id -un)" = tuxcrate
    test "$(id -gn)" = tuxcrate
    test ! -w /opt/sonarr
    test -w /config
    test ! -e /usr/local/bin/sonarr-smoke-test
    /opt/sonarr/bin/ffprobe -version
'

phase='waiting for nonempty sonarr.db and config.xml and an OK /ping response'
attempt=0
while :; do
    if [[ $(docker inspect --format '{{.State.Running}}' "$container") != true ]]; then
        echo 'Sonarr exited before becoming ready.' >&2
        exit 1
    fi
    if response=$(docker exec "$container" sh -eu -c '
        test -s /config/sonarr.db
        test -s /config/config.xml
        wget -T 2 -q -O - http://127.0.0.1:8989/ping
    ' 2>/dev/null) && grep -Eq '"status"[[:space:]]*:[[:space:]]*"OK"' <<< "$response"; then
        break
    fi
    if ((attempt >= 120)); then
        printf 'Timed out waiting for Sonarr readiness. Last ping response: %s\n' "${response:-[empty]}" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 1
done

phase='checking the installed version'
installed_version=$(docker logs "$container" 2>&1 | sed -n 's/.*Bootstrap: Starting Sonarr .* - Version \([^ ]*\).*/\1/p')
if [[ $installed_version != "$version" ]]; then
    printf 'Expected Sonarr %s, got %s.\n' "$version" "$installed_version" >&2
    exit 1
fi
phase='checking package version and the Tuxcrate author link in the status API'
for attempt in {1..4}; do
    if system_status=$(docker exec "$container" sh -eu -c '
        api_key=$(sed -n "s:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p" /config/config.xml)
        if [ -z "$api_key" ]; then
            echo "Generated status API key is not yet available." >&2
            exit 1
        fi
        wget -T 10 -O - --header "X-Api-Key: $api_key" http://127.0.0.1:8989/api/v3/system/status
    '); then
        break
    else
        request_status=$?
        printf 'Status API request %s/4 failed (exit status %s).\n' "$attempt" "$request_status" >&2
    fi
    if ((attempt == 4)); then
        echo 'Status API remained unavailable after four requests.' >&2
        exit 1
    fi
    sleep 2
done
package_author='[Tuxcrate](https://tuxcrate.com)'
if ! jq -e --arg version "$package_version" --arg author "$package_author" \
    '.packageVersion == $version and .packageAuthor == $author' <<< "$system_status" > /dev/null; then
    printf 'Expected packageVersion=%s and packageAuthor=%s; status API returned:\n' "$package_version" "$package_author" >&2
    jq '{packageVersion, packageAuthor}' <<< "$system_status" >&2 || echo 'Status API response is not a valid metadata object.' >&2
    exit 1
fi

phase='checking graceful shutdown'
docker stop --time 30 "$container" > /dev/null
exit_code=$(docker wait "$container")
if [[ $exit_code != 0 ]]; then
    printf 'Sonarr shutdown returned exit status %s.\n' "$exit_code" >&2
    exit 1
fi
