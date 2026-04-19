# syntax=docker/dockerfile:1.7

FROM debian:bookworm-slim

ARG TARGETARCH
ARG ZEROCLAW_VERSION=v0.7.3
ARG NODE_MAJOR=22

ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/usr/local/bin:${PATH}" \
    ZEROCLAW_HOME=/root/.zeroclaw \
    CLAUDE_HOME=/root/.claude \
    WORKSPACE=/workspace

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      git \
      jq \
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
    rm -rf /tmp/zeroclaw* /tmp/SHA256SUMS; \
    zeroclaw --version

COPY scripts/init-zen.sh /usr/local/bin/init-zen.sh
RUN chmod +x /usr/local/bin/init-zen.sh

RUN mkdir -p "${ZEROCLAW_HOME}" "${CLAUDE_HOME}" "${WORKSPACE}"

WORKDIR /workspace

EXPOSE 42617

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["zeroclaw", "daemon"]
