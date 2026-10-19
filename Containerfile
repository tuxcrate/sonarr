ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS download

ARG APP_VERSION
ARG TARGETARCH

RUN --mount=type=secret,id=github_release_json \
    set -eux; \
    : "${APP_VERSION:?APP_VERSION must be set}"; \
    apk add --no-cache ca-certificates curl jq; \
    case "$TARGETARCH" in amd64) arch=x64 ;; arm64) arch=arm64 ;; *) exit 1 ;; esac; \
    if [ -s /run/secrets/github_release_json ]; then \
        cp /run/secrets/github_release_json /tmp/release.json; \
    else \
        curl --fail --location --retry 3 \
            "https://api.github.com/repos/Sonarr/Sonarr/releases/tags/v${APP_VERSION}" -o /tmp/release.json; \
    fi; \
    jq -e --arg tag "v${APP_VERSION}" \
        '.tag_name == $tag and .draft == false and (.prerelease | type == "boolean")' /tmp/release.json; \
    jq -ce --arg suffix ".${APP_VERSION}.linux-musl-${arch}.tar.gz" \
        '[.assets[] | select(.name | startswith("Sonarr.") and endswith($suffix))] \
         | if length == 1 then .[0] else error("expected exactly one matching Sonarr asset") end' \
        /tmp/release.json > /tmp/asset.json; \
    asset="$(jq -er '.name' /tmp/asset.json)"; \
    branch="${asset#Sonarr.}"; \
    branch="${branch%%.*}"; \
    digest="$(jq -er '.digest' /tmp/asset.json)"; \
    url="$(jq -er '.browser_download_url' /tmp/asset.json)"; \
    curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
        "$url" -o /tmp/sonarr.tar.gz; \
    printf '%s  /tmp/sonarr.tar.gz\n' "${digest#sha256:}" | sha256sum -c -; \
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
