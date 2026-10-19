ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS download

ARG APP_VERSION
ARG TARGETARCH
ARG UPSTREAM_PRERELEASE
ARG UPSTREAM_URL_AMD64
ARG UPSTREAM_SHA256_AMD64
ARG UPSTREAM_URL_ARM64
ARG UPSTREAM_SHA256_ARM64

RUN set -eux; \
    : "${APP_VERSION:?APP_VERSION must be set}"; \
    apk add --no-cache ca-certificates curl; \
    case "$UPSTREAM_PRERELEASE" in \
        true) branch=develop ;; false) branch=main ;; \
        *) echo "UPSTREAM_PRERELEASE must be true or false" >&2; exit 1 ;; \
    esac; \
    case "$TARGETARCH" in \
        amd64) url="$UPSTREAM_URL_AMD64"; checksum="$UPSTREAM_SHA256_AMD64" ;; \
        arm64) url="$UPSTREAM_URL_ARM64"; checksum="$UPSTREAM_SHA256_ARM64" ;; \
        *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    : "${url:?upstream asset URL must be set}" "${checksum:?upstream SHA-256 must be set}"; \
    curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
        "$url" -o /tmp/sonarr.tar.gz; \
    printf '%s  /tmp/sonarr.tar.gz\n' "$checksum" | sha256sum -c -; \
    mkdir /sonarr; \
    tar -xzf /tmp/sonarr.tar.gz -C /sonarr --strip-components=1; \
    rm -rf /sonarr/Sonarr.Update; \
    printf 'UpdateMethod=docker\nBranch=%s\nPackageAuthor=[Tuxcrate](https://tuxcrate.com)\n' "$branch" > /package_info

FROM ${BASE_IMAGE}

ARG APP_VERSION

ENV HOME=/config \
    XDG_CONFIG_HOME=/config/xdg \
    COMPlus_EnableDiagnostics=0

RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache ca-certificates icu-data-full icu-libs libgcc libstdc++ libssl3 sqlite-libs tzdata zlib; \
    addgroup -g 1000 tuxcreate; \
    adduser -D -u 1000 -G tuxcreate -h /config -s /sbin/nologin tuxcreate; \
    mkdir -p /config /data; \
    chown 1000:1000 /config /data

COPY --from=download /sonarr /opt/sonarr
COPY --from=download /package_info /opt/package_info
COPY tests/smoke.sh /usr/local/bin/sonarr-smoke-test

USER 1000:1000
WORKDIR /config

RUN sonarr-smoke-test "${APP_VERSION}"

EXPOSE 8989
ENTRYPOINT ["/opt/sonarr/Sonarr", "-nobrowser", "-data=/config"]
