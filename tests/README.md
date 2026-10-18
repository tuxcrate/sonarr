# Container checks

The Containerfile supports Alpine and Debian slim so the comparison can be
repeated with the same packaging and runtime tests. Release tracks use Alpine.

## Build and test locally

Pass the exact version and digest-pinned base from `meta.yaml`:

```sh
docker build -f Containerfile -t sonarr:test \
  --build-arg BASE_IMAGE=alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 \
  --build-arg APP_VERSION=4.0.20.3014 \
  --build-arg BUILDKIT_DOCKERFILE_CHECK=skip=InvalidDefaultArgInFrom .
python3 tests/runtime.py sonarr:test 4.0.20.3014
```

For develop, use `APP_VERSION=5.0.0.2668` and add
`--build-arg SONARR_BRANCH=develop`. A build fails if the selected upstream
release is not from the requested channel or is missing the matching asset or
SHA-256 digest. Downloads are verified against GitHub's release asset digest.

For Debian, replace `BASE_IMAGE` with
`debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f`.

`smoke.sh` runs during every architecture's build as UID/GID `1000:1000`.
It checks the installed version, database/configuration creation, HTTP listener
startup, non-writable application files, and clean SIGTERM handling.
The bundled ffprobe must also run successfully.

`runtime.py` requires Python 3 and Docker, with the host running as UID 1000 for
its bind-mount ownership check. It verifies the HTTP API and exact version,
configuration/database persistence across restarts, writes to `/data`, and clean
shutdown. Both the default user and an arbitrary UID without a passwd entry run
with a read-only root filesystem, all capabilities dropped, and no-new-privileges.
Containers and temporary test data are removed on completion or failure.

## Alpine / Debian comparison

Measured on linux/amd64 on 2026-10-18, including full ICU locale data and timezone
data. These are local uncompressed image sizes, not registry download sizes.

| Upstream | Alpine 3.24 | Debian trixie-slim |
| --- | ---: | ---: |
| Stable 4.0.20.3014 | 218,955,365 bytes (208.8 MiB) | 282,880,945 bytes (269.8 MiB) |
| Develop 5.0.0.2668 | 241,586,635 bytes (230.4 MiB) | 304,940,015 bytes (290.8 MiB) |

All four builds passed both smoke and runtime tests. Alpine is about 21–23%
smaller and has native upstream musl binaries, so no glibc compatibility layer
is needed. The download tools stay in the builder stage, and the in-app updater
is removed. Upstream license notices remain in `/opt/sonarr`.

The shared release workflow builds linux/amd64 and linux/arm64 with build-time
smoke checks for both tracks. Local comparison results above cover amd64 only.
