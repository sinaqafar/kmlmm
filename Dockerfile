# Pi-Web + Pi Coding Agent + NVIDIA NIM, on Railway
#
# Deliberate omissions:
#   * no VOLUME  — Railway rejects it; attach a Railway Volume at /data instead
#   * no HEALTHCHECK — Railway ignores it; healthcheckPath lives in railway.json
#
# Layout:
#   /data/.pi/agent     Pi config, auth, sessions, installed Pi packages
#   /data/pi-web        Pi-Web state (projects, session daemon socket, logs)
#   /app/defaults.json  read-only Pi-Web policy (path access, spawn flags)
#   /app/gateway        Basic-Auth reverse proxy; Pi-Web itself stays on loopback

FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PI_CODING_AGENT_DIR=/data/.pi/agent \
    PI_WEB_DATA_DIR=/data/pi-web \
    PI_WEB_CONFIG=/data/pi-web/config.json \
    PI_WEB_DEFAULTS_CONFIG=/app/defaults.json \
    PI_SEED_DIR=/opt/pi-seed \
    NODE_ENV=production

# node-pty (Pi-Web terminals) builds from source: needs python3 + make + g++
RUN apt-get update && apt-get install -y --no-install-recommends \
      git bash ca-certificates curl jq python3 make g++ procps ripgrep \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# --allow-scripts=node-pty lets npm run node-pty's install script; without it
# Pi-Web's Terminal plugin silently loses PTY support.
RUN npm install -g @jmfederico/pi-web @earendil-works/pi-coding-agent \
      --allow-scripts=node-pty \
    && pi-web --version && pi --version

# ---- Seed the Pi package set into a staging dir ----
# start.sh copies this into the /data volume on first boot and tops up packages
# that a newer image adds later, so redeploys never wipe installed packages.
RUN mkdir -p "$PI_SEED_DIR/agent" && \
    PI_CODING_AGENT_DIR="$PI_SEED_DIR/agent" bash -c 'set -e; \
      for pkg in \
        pi-hermes-memory \
        pi-web-access \
        pi-subagents \
        pi-mcp-adapter \
        pi-lens \
        pi-agent-browser-native \
        pi-goal \
        pi-autoresearch \
        pi-nvidia-nim \
        billion-context \
        cc-safety-net \
        @gwynnnplaine/pi-github \
        @feniix/pi-devtools \
        @piex-dev/dap \
        @oisin-ee/pi-guardrails \
        @juicesharp/rpiv-ask-user-question ; \
      do echo "installing $pkg"; pi install "npm:$pkg" || echo "WARN: $pkg failed, continuing"; done; \
      echo "--- seeded ---"; pi list'

COPY defaults.json /app/defaults.json
COPY start.sh /app/start.sh
COPY gateway/server.js /app/gateway/server.js
COPY agents/ /app/agents-seed/
RUN chmod +x /app/start.sh

WORKDIR /data
EXPOSE 8080
CMD ["/app/start.sh"]
