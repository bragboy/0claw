# syntax=docker/dockerfile:1.7

ARG NODE_MAJOR=22
ARG ZEROCLAW_VERSION=v0.8.4

# Since v0.8.x the release tarball ships a prebuilt `web/dist` alongside the
# binaries, so there is no dashboard build stage: the dashboard is installed
# straight from the same verified tarball as `zeroclaw` itself. (Building it
# from the source tarball is not possible anyway - `web/src/lib/api-generated`
# and friends are codegen outputs that are not included in the source archive.)

FROM debian:bookworm-slim
ARG TARGETARCH
ARG ZEROCLAW_VERSION
ARG NODE_MAJOR

ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/usr/local/bin:${PATH}" \
    ZEROCLAW_HOME=/root/.zeroclaw \
    CLAUDE_HOME=/root/.claude \
    WORKSPACE=/workspace \
    ZEROCLAW_WEB_DIST_DIR=/opt/zeroclaw/web-dist

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      git \
      jq \
      sqlite3 \
      tini \
      xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && node --version && npm --version

RUN npm install -g --omit=dev \
      @anthropic-ai/claude-code \
      @google/gemini-cli \
 && npm cache clean --force

RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) ZC_TRIPLE="x86_64-unknown-linux-gnu" ;; \
      arm64) ZC_TRIPLE="aarch64-unknown-linux-gnu" ;; \
      arm)   ZC_TRIPLE="armv7-unknown-linux-gnueabihf" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    BASE="https://github.com/zeroclaw-labs/zeroclaw/releases/download/${ZEROCLAW_VERSION}"; \
    TARBALL="zeroclaw-${ZC_TRIPLE}.tar.gz"; \
    cd /tmp; \
    curl -fsSLO "${BASE}/${TARBALL}"; \
    curl -fsSLO "${BASE}/SHA256SUMS"; \
    grep " ${TARBALL}$" SHA256SUMS | sha256sum -c -; \
    tar -xzf "${TARBALL}"; \
    install -m 0755 "$(find . -maxdepth 3 -type f -name zeroclaw | head -n1)" /usr/local/bin/zeroclaw; \
    ZC_CODE="$(find . -maxdepth 3 -type f -name zerocode | head -n1)"; \
    if [ -n "${ZC_CODE}" ]; then install -m 0755 "${ZC_CODE}" /usr/local/bin/zerocode; fi; \
    ZC_DIST="$(find . -maxdepth 4 -type d -path '*/web/dist' | head -n1)"; \
    test -n "${ZC_DIST}"; \
    mkdir -p /opt/zeroclaw; \
    cp -r "${ZC_DIST}" /opt/zeroclaw/web-dist; \
    test -f /opt/zeroclaw/web-dist/index.html; \
    rm -rf /tmp/zeroclaw* /tmp/zerocode /tmp/web /tmp/SHA256SUMS; \
    zeroclaw --version

COPY scripts/init-deepseek.sh    /usr/local/bin/init-deepseek.sh
COPY scripts/news-search.sh      /usr/local/bin/news-search
COPY scripts/crypto-price.sh     /usr/local/bin/crypto-price
COPY scripts/stock-price.sh      /usr/local/bin/stock-price
COPY scripts/fx-rate.sh          /usr/local/bin/fx-rate
COPY scripts/weather-for.sh      /usr/local/bin/weather-for
COPY scripts/do-task.sh          /usr/local/bin/do-task
COPY scripts/deepseek-proxy.mjs  /usr/local/bin/deepseek-proxy.mjs
COPY scripts/start-zeroclaw.sh   /usr/local/bin/start-zeroclaw
RUN chmod +x /usr/local/bin/init-deepseek.sh \
             /usr/local/bin/news-search \
             /usr/local/bin/crypto-price \
             /usr/local/bin/stock-price \
             /usr/local/bin/fx-rate \
             /usr/local/bin/weather-for \
             /usr/local/bin/do-task \
             /usr/local/bin/deepseek-proxy.mjs \
             /usr/local/bin/start-zeroclaw

RUN mkdir -p "${ZEROCLAW_HOME}" "${CLAUDE_HOME}" "${WORKSPACE}"

WORKDIR /workspace

EXPOSE 42617

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["start-zeroclaw"]
