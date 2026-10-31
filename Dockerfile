# syntax=docker/dockerfile:1.7
# Build steps run as root; the resulting container runs as the unprivileged
# developer account (UID/GID 10001). Writable dirs are also group-0 writable so
# a platform-assigned arbitrary UID with GID 0 still works.
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH

# Pinned toolchain versions. Bump version and checksums together.
ARG GO_VERSION=1.27.3
ARG GO_SHA256_AMD64=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40
ARG GO_SHA256_ARM64=a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49
ARG NODE_VERSION=24.22.2
ARG NODE_SHA256_AMD64=48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75
ARG NODE_SHA256_ARM64=eb187837a2230d4047161ac0be008584e16b46f726e9c9490ee35dc6b17d9ba8
ARG PNPM_VERSION=12.16.1
ARG BUN_VERSION=1.4.4
ARG CODE_SERVER_VERSION=4.144.0
ARG CODE_SERVER_SHA256_AMD64=45f5533b502edac68b7eb09c5cec44fd281f80264af9a87fde0bfb2c5e190615
ARG CODE_SERVER_SHA256_ARM64=6baef72b340da08e76e5cf1e9504f657d00e80c8776bdaf86e97c30a80cd48e8
ARG VSCODE_CLI_COMMIT=2c33b50b16c472efe58357d1d2a8a5414bc23fbf
ARG VSCODE_CLI_SHA256_AMD64=3ab9a8187d55433aca392fc0fa7e4e60a0450d4ae386a40dca639ddd59ccb1ee
ARG VSCODE_CLI_SHA256_ARM64=14216157112c112691a580969b6c00eaaacb0afe7d07a4436c8be62e38f0b542
ARG AWSCLI_VERSION=2.39.3
ARG AWSCLI_SHA256_AMD64=14cb35809ad7547dd3c69fa9899a3975fbd850b6a6791f3fe264856490cd9a63
ARG AWSCLI_SHA256_ARM64=f6eb845fbacb11bee87de3f5fbe8043773cbe89d0414607b44b71e216eb9226b
ARG COMPOSER_VERSION=2.11.1
ARG COMPOSER_SHA256=6f1b891e1d4927d62740276c540fb490e47689e19e102c49e8da849794882f8c

# HOME is deliberately NOT set here: root build steps must not write into the
# developer's home. It is set right before USER at the end.
ENV TZ=Asia/Jakarta \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    WORKSPACE=/workspace \
    PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Create the runtime account first so nothing else can claim its home directory.
RUN groupadd --gid 10001 developer \
    && useradd --uid 10001 --gid 10001 --create-home --shell /bin/zsh developer

# OS packages. GitHub CLI comes from its signed apt repository.
RUN install -d -m 0755 /etc/apt/keyrings \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
       wget unzip zip xz-utils git gh openssh-client less file rsync \
       zsh tmux neovim vim nano htop tree jq yq procps psmisc lsof \
       build-essential pkg-config make gcc g++ \
       python3 python3-venv python3-pip pipx \
       php-cli php-curl php-mbstring php-xml php-zip php-bcmath php-intl php-gd \
       php-pgsql php-mysql php-sqlite3 php-redis php-igbinary php-opcache sqlite3 \
       redis-server postgresql-client mysql-client redis-tools \
       dnsutils iputils-ping netcat-openbsd \
       supervisor tzdata \
    && rm -rf /var/lib/apt/lists/*

# Pinned, checksum-verified binary toolchains.
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) GO_SHA="${GO_SHA256_AMD64}"; NODE_ARCH=x64; NODE_SHA="${NODE_SHA256_AMD64}"; \
             CS_SHA="${CODE_SERVER_SHA256_AMD64}"; CLI_ARCH=x64; CLI_SHA="${VSCODE_CLI_SHA256_AMD64}"; \
             AWS_ARCH=x86_64; AWS_SHA="${AWSCLI_SHA256_AMD64}" ;; \
      arm64) GO_SHA="${GO_SHA256_ARM64}"; NODE_ARCH=arm64; NODE_SHA="${NODE_SHA256_ARM64}"; \
             CS_SHA="${CODE_SERVER_SHA256_ARM64}"; CLI_ARCH=arm64; CLI_SHA="${VSCODE_CLI_SHA256_ARM64}"; \
             AWS_ARCH=aarch64; AWS_SHA="${AWSCLI_SHA256_ARM64}" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSLo go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH:-amd64}.tar.gz"; \
    echo "${GO_SHA}  go.tgz" | sha256sum -c -; \
    tar -C /usr/local -xzf go.tgz; \
    curl -fsSLo node.txz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"; \
    echo "${NODE_SHA}  node.txz" | sha256sum -c -; \
    tar -C /usr/local --strip-components=1 --no-same-owner -xJf node.txz \
      --exclude='*/CHANGELOG.md' --exclude='*/README.md' --exclude='*/LICENSE'; \
    curl -fsSLo code-server.deb "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_${TARGETARCH:-amd64}.deb"; \
    echo "${CS_SHA}  code-server.deb" | sha256sum -c -; \
    dpkg -i code-server.deb; \
    curl -fsSLo vscode-cli.tgz "https://update.code.visualstudio.com/commit:${VSCODE_CLI_COMMIT}/cli-alpine-${CLI_ARCH}/stable"; \
    echo "${CLI_SHA}  vscode-cli.tgz" | sha256sum -c -; \
    tar -xzf vscode-cli.tgz -C /usr/local/bin code; \
    curl -fsSLo awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWSCLI_VERSION}.zip"; \
    echo "${AWS_SHA}  awscli.zip" | sha256sum -c -; \
    unzip -q awscli.zip; ./aws/install; \
    curl -fsSLo /usr/local/bin/composer "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar"; \
    echo "${COMPOSER_SHA256}  /usr/local/bin/composer" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/composer; \
    rm -rf /tmp/*

# JS package managers, pinned. npm cache is discarded.
RUN npm install --global --no-fund --no-audit "pnpm@${PNPM_VERSION}" "bun@${BUN_VERSION}" \
    && npm cache clean --force \
    && rm -rf /root/.npm /root/.cache

# Runtime files.
COPY config/zshrc /etc/skel-devbox/.zshrc
COPY config/supervisord.conf /etc/devbox/supervisord.conf
COPY config/redis.conf /etc/devbox/redis.conf
COPY scripts/ /usr/local/lib/devbox/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# Writable locations for UID 10001 and for any UID in GID 0 (OpenShift-style).
# The developer may install global npm packages and Go/pipx tools without root.
RUN set -eux; \
    for s in backup restore autobackup tunnel healthcheck status; do \
      ln -sf "/usr/local/lib/devbox/${s}.sh" "/usr/local/bin/devbox-${s}"; \
    done; \
    chmod 0755 /usr/local/lib/devbox/*.sh /usr/local/bin/entrypoint.sh; \
    install -d /workspace/projects; \
    cp /etc/skel-devbox/.zshrc /home/developer/.zshrc; \
    install -d /home/developer/.config /home/developer/.local/bin /home/developer/.local/share \
      /home/developer/.cache /home/developer/.npm-global /home/developer/go; \
    install -d -m 0700 /home/developer/.ssh; \
    chown -R 10001:0 /home/developer /workspace; \
    chmod -R g=u /home/developer /workspace; \
    chmod 0770 /home/developer; \
    chmod 0700 /home/developer/.ssh

ENV HOME=/home/developer \
    USER=developer \
    SHELL=/bin/zsh \
    EDITOR=nvim \
    GOPATH=/home/developer/go \
    NPM_CONFIG_PREFIX=/home/developer/.npm-global \
    PIPX_BIN_DIR=/home/developer/.local/bin \
    PATH=/home/developer/.local/bin:/home/developer/.npm-global/bin:/home/developer/go/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PORT=8080

WORKDIR /workspace
EXPOSE 8080

USER 10001:10001

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["/usr/local/bin/devbox-healthcheck"]

# supervisord becomes PID 1 (reaps zombies, forwards signals, restarts services).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
