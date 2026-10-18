ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS download

ARG APP_VERSION
ARG TARGETARCH
ARG SONARR_BRANCH=main

RUN set -eux; \
    : "${APP_VERSION:?APP_VERSION must be set}"; \
    . /etc/os-release; \
    case "$ID" in \
        alpine) apk add --no-cache ca-certificates curl jq; platform=linux-musl ;; \
        debian) apt-get update; apt-get install -y --no-install-recommends ca-certificates curl jq; platform=linux ;; \
        *) exit 1 ;; \
    esac; \
    case "$TARGETARCH" in amd64) arch=x64 ;; arm64) arch=arm64 ;; *) exit 1 ;; esac; \
    case "$SONARR_BRANCH" in main) prerelease=false ;; develop) prerelease=true ;; *) exit 1 ;; esac; \
    asset="Sonarr.${SONARR_BRANCH}.${APP_VERSION}.${platform}-${arch}.tar.gz"; \
    curl --fail --location --retry 3 \
        "https://api.github.com/repos/Sonarr/Sonarr/releases/tags/v${APP_VERSION}" -o /tmp/release.json; \
    jq -e --argjson prerelease "$prerelease" '.prerelease == $prerelease and .draft == false' /tmp/release.json; \
    digest="$(jq -er --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest | select(test("^sha256:[0-9a-f]{64}$"))' /tmp/release.json)"; \
    curl --fail --location --retry 3 \
        "https://github.com/Sonarr/Sonarr/releases/download/v${APP_VERSION}/${asset}" -o /tmp/sonarr.tar.gz; \
    printf '%s  /tmp/sonarr.tar.gz\n' "${digest#sha256:}" | sha256sum -c -; \
    mkdir /sonarr; \
    tar -xzf /tmp/sonarr.tar.gz -C /sonarr --strip-components=1; \
    rm -rf /sonarr/Sonarr.Update; \
    printf 'UpdateMethod=docker\nBranch=%s\nPackageAuthor=[Tuxcrate](https://tuxcrate.com)\n' "$SONARR_BRANCH" > /package_info

FROM ${BASE_IMAGE}

ARG APP_VERSION

ENV HOME=/config \
    XDG_CONFIG_HOME=/config/xdg \
    COMPlus_EnableDiagnostics=0

RUN set -eux; \
    . /etc/os-release; \
    case "$ID" in \
        alpine) \
            apk upgrade --no-cache; \
            apk add --no-cache ca-certificates icu-data-full icu-libs libgcc libstdc++ libssl3 sqlite-libs tzdata zlib; \
            addgroup -g 1000 tuxcreate; \
            adduser -D -u 1000 -G tuxcreate -h /config -s /sbin/nologin tuxcreate ;; \
        debian) \
            apt-get update; \
            apt-get upgrade -y; \
            apt-get install -y --no-install-recommends ca-certificates libgcc-s1 libicu76 libssl3t64 libsqlite3-0 libstdc++6 tzdata zlib1g; \
            rm -rf /var/lib/apt/lists/*; \
            groupadd -g 1000 tuxcreate; \
            useradd -u 1000 -g tuxcreate -d /config -s /usr/sbin/nologin tuxcreate ;; \
        *) exit 1 ;; \
    esac; \
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
