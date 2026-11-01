ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS download

ARG APP_VERSION
ARG PACKAGE_VERSION
ARG TARGETARCH

RUN --mount=type=secret,id=github_token \
    set -eu; \
    : "${APP_VERSION:?APP_VERSION must be set}"; \
    github_auth=""; \
    if [ -s /run/secrets/github_token ]; then \
        github_auth="Authorization: Bearer $(cat /run/secrets/github_token)"; \
    fi; \
    apk add --no-cache ca-certificates curl jq; \
    case "$TARGETARCH" in amd64) arch=x64 ;; arm64) arch=arm64 ;; *) exit 1 ;; esac; \
    curl --header "$github_auth" --fail --location --retry 3 \
        "https://api.github.com/repos/Sonarr/Sonarr/releases/tags/v${APP_VERSION}" -o /tmp/release.json; \
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
    printf 'UpdateMethod=docker\nBranch=%s\nPackageVersion=%s\nPackageAuthor=[Tuxcrate](https://tuxcrate.com)\n' "$branch" "${PACKAGE_VERSION:-${APP_VERSION}-local}" > /package_info

FROM ${BASE_IMAGE}

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

# Sonarr only reads ../package_info when its application directory is named bin.
COPY --from=download /sonarr /opt/sonarr/bin
COPY --from=download /package_info /opt/sonarr/package_info

USER 1000:1000
WORKDIR /config

EXPOSE 8989
ENTRYPOINT ["/opt/sonarr/bin/Sonarr", "-nobrowser", "-data=/config"]
