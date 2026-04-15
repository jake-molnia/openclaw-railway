# OpenClaw Railway Template
# Optimized 2-stage build with npm install, optional features, and fast startup

# ==============================================================================
# Stage 1: Build the wrapper server (with node-pty native module)
# ==============================================================================
FROM node:24-bookworm-slim AS wrapper-builder

# Install native build deps for node-pty. Python is provided by uv (not apt) —
# we use uv for every Python operation in this image, including feeding
# node-gyp a Python interpreter via a symlink on PATH.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

RUN apt-get update && apt-get install -y --no-install-recommends \
    make \
    g++ \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && UV_PYTHON_INSTALL_DIR=/opt/uv-python uv python install 3.12 \
    && ln -sf "$(UV_PYTHON_INSTALL_DIR=/opt/uv-python uv python find 3.12)" /usr/local/bin/python3 \
    && ln -sf /usr/local/bin/python3 /usr/local/bin/python

ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    UV_PYTHON_PREFERENCE=only-managed

WORKDIR /app

# Copy package files for wrapper server
COPY package.json ./
RUN npm install --omit=dev

# Copy wrapper server source
COPY src/ ./src/

# ==============================================================================
# Stage 2: Production runtime
# ==============================================================================
FROM node:24-bookworm-slim AS runtime

# Build args for version and optional features
ARG OPENCLAW_VERSION=2026.4.14
ARG INSTALL_SIGNAL_CLI=false
ARG INSTALL_BROWSER=true
ARG SIGNAL_CLI_VERSION=0.13.24

# Install base runtime dependencies + operator tooling baked into the image.
# Base runtime:
# - tini: proper PID 1 handling for signal forwarding
# - curl, wget, ca-certificates: HTTP(S) fetches and health checks
# - git, make, g++: required for npm install -g (in-app upgrades, native modules)
# Python is NOT installed via apt — uv owns every Python operation in this
# image, including providing the interpreter that node-gyp uses.
# Operator tooling (debugging, SSH, net, files, archives, process inspection):
# - openssh-client, iputils-ping, netcat-openbsd, dnsutils, rsync
# - jq, ripgrep, fd-find (exposed as `fd`), tmux, zip, unzip, less, procps
# - gnupg + apt-transport-https: required to add the GitHub CLI apt source
RUN apt-get update && apt-get install -y --no-install-recommends \
    tini \
    curl \
    wget \
    ca-certificates \
    git \
    make \
    g++ \
    openssh-client \
    iputils-ping \
    netcat-openbsd \
    dnsutils \
    rsync \
    jq \
    ripgrep \
    fd-find \
    tmux \
    zip \
    unzip \
    less \
    procps \
    gnupg \
    apt-transport-https \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# Install uv (Astral's Python package + interpreter manager). uv is the
# single entry point for every Python operation in this container — we do
# not `apt install python3`. uv installs a managed CPython under
# UV_PYTHON_INSTALL_DIR; we symlink it as /usr/local/bin/python{,3} so
# node-gyp and anything else looking for `python3` on PATH finds it.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    UV_PYTHON_PREFERENCE=only-managed

RUN uv python install 3.12 \
    && ln -sf "$(uv python find 3.12)" /usr/local/bin/python3 \
    && ln -sf /usr/local/bin/python3 /usr/local/bin/python \
    && python3 --version \
    && uv --version

# Install GitHub CLI (gh) from the official apt repo
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install Railway CLI globally via npm so the `railway` command is on PATH.
# Done BEFORE NPM_CONFIG_PREFIX is flipped to /data, so the install lands in
# /usr/local and is baked into the image.
RUN npm install -g @railway/cli \
    && railway --version

# Install OpenClaw from npm (pre-built, ~30-60s instead of ~12min source build)
# Install to default /usr/local prefix BEFORE setting NPM_CONFIG_PREFIX to /data
# so it's baked into the image and not hidden by the Railway volume mount.
RUN npm install -g openclaw@${OPENCLAW_VERSION}

# Optional: Install Java + signal-cli for Signal channel support
# Set INSTALL_SIGNAL_CLI=true in Railway build args if needed
RUN if [ "$INSTALL_SIGNAL_CLI" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        openjdk-17-jre-headless \
      && rm -rf /var/lib/apt/lists/* \
      && curl -L -o /tmp/signal-cli.tar.gz \
        "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}.tar.gz" \
      && tar xf /tmp/signal-cli.tar.gz -C /opt \
      && ln -sf /opt/signal-cli-${SIGNAL_CLI_VERSION}/bin/signal-cli /usr/local/bin/signal-cli \
      && rm /tmp/signal-cli.tar.gz; \
    else \
      echo "Skipping signal-cli (set INSTALL_SIGNAL_CLI=true to enable)"; \
    fi

# Create non-root user for security
RUN groupadd --system --gid 1001 openclaw && \
    useradd --system --uid 1001 --gid openclaw --shell /bin/bash --create-home openclaw

# Create openclaw CLI wrapper that ALWAYS runs first (PATH-priority via /opt/openclaw-bin).
# Injects OPENCLAW_GATEWAY_TOKEN so the CLI can authenticate with the gateway in ANY
# shell context (docker exec, Railway shell, web terminal, scripts).
# Delegates to the npm-upgraded version if available, otherwise the base npm install.
RUN mkdir -p /opt/openclaw-bin && \
    printf '#!/bin/bash\n\
if [ -z "$OPENCLAW_GATEWAY_TOKEN" ] && [ -f "${OPENCLAW_STATE_DIR:-/data/.openclaw}/gateway.token" ]; then\n\
  export OPENCLAW_GATEWAY_TOKEN=$(cat "${OPENCLAW_STATE_DIR:-/data/.openclaw}/gateway.token")\n\
fi\n\
if [ -z "$OPENCLAW_BUNDLED_SKILLS_DIR" ]; then\n\
  export OPENCLAW_BUNDLED_SKILLS_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}/skills"\n\
fi\n\
NPM_ENTRY="${NPM_CONFIG_PREFIX:-/data/.npm-global}/lib/node_modules/openclaw/dist/entry.js"\n\
NPM_PACKAGE_JSON="${NPM_CONFIG_PREFIX:-/data/.npm-global}/lib/node_modules/openclaw/package.json"\n\
if [ -f "$NPM_ENTRY" ] && [ -f "$NPM_PACKAGE_JSON" ]; then\n\
  exec node "$NPM_ENTRY" "$@"\n\
fi\n\
exec node /usr/local/lib/node_modules/openclaw/dist/entry.js "$@"\n' > /opt/openclaw-bin/openclaw && \
    chmod +x /opt/openclaw-bin/openclaw

# Optional: Install Playwright Chromium for browser automation
# Matches the playwright-core version that OpenClaw depends on
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN if [ "$INSTALL_BROWSER" = "true" ]; then \
      PW_VER=$(node -e "try{console.log(require('/usr/local/lib/node_modules/openclaw/node_modules/playwright-core/package.json').version)}catch(e){console.log('latest')}" 2>/dev/null) && \
      echo "Installing playwright@${PW_VER} chromium..." && \
      npx -y playwright@${PW_VER} install --with-deps chromium && \
      chmod -R o+rx /ms-playwright && \
      CHROME_BIN=$(find /ms-playwright -name "chrome" -type f \( -path "*/chrome-linux/*" -o -path "*/chrome-linux64/*" \) 2>/dev/null | head -1) && \
      if [ -n "$CHROME_BIN" ]; then \
        ln -sf "$CHROME_BIN" /usr/local/bin/chromium && \
        echo "Symlinked $CHROME_BIN -> /usr/local/bin/chromium"; \
      else \
        echo "WARNING: Playwright chrome binary not found for symlink"; \
      fi; \
    else \
      echo "Skipping Playwright/Chromium (set INSTALL_BROWSER=true to enable)"; \
    fi

WORKDIR /app

# Copy wrapper server from builder
COPY --from=wrapper-builder /app/node_modules ./node_modules
COPY --from=wrapper-builder /app/src ./src
COPY --from=wrapper-builder /app/package.json ./package.json

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Copy pre-bundled skills (Railway-optimized)
COPY skills/ /bundled-skills/

# Create data directory with proper permissions
RUN mkdir -p /data/.openclaw /data/workspace && \
    chmod 700 /data/.openclaw /data/workspace && \
    chown -R openclaw:openclaw /data /app

# Note: No VOLUME directive — Railway manages volumes externally
# Note: Running as root because Railway volumes mount as root.
# The entrypoint handles dropping privileges after fixing permissions.

# Default port (Railway overrides via PORT env var)
EXPOSE 8080

# Environment defaults
# NPM_CONFIG_PREFIX on the persistent volume so in-app upgrades survive restarts.
# PATH order: /opt/openclaw-bin (token-injecting wrapper) > /data/.npm-global/bin
# (npm upgrades) > system defaults.  The wrapper delegates to the npm-upgraded
# entry.js when available, so the upgraded code still runs.
ENV NODE_ENV=production \
    HOME=/home/openclaw \
    OPENCLAW_STATE_DIR=/data/.openclaw \
    OPENCLAW_WORKSPACE_DIR=/data/workspace \
    INTERNAL_GATEWAY_PORT=18789 \
    NPM_CONFIG_PREFIX=/data/.npm-global \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    PATH=/opt/openclaw-bin:/data/.npm-global/bin:$PATH

# Health check - checks wrapper server health endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:${PORT:-8080}/health || exit 1

# Use tini as init system for proper signal handling
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
