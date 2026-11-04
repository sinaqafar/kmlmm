FROM node:22-bookworm

RUN apt-get update && apt-get install -y \
    git bash python3 build-essential curl jq htop ripgrep fd-find \
    procps cgroup-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN npm install -g @earendil-works/pi-coding-agent @jmfederico/pi-web --allow-scripts=node-pty

RUN pi install npm:billion-context && \
    pi install npm:pi-hermes-memory && \
    pi install npm:pi-web-access && \
    pi install npm:pi-subagents && \
    pi install npm:pi-mcp-adapter && \
    pi install npm:pi-lens && \
    pi install npm:pi-agent-browser-native && \
    pi install npm:@gwynnnplaine/pi-github && \
    pi install npm:@feniix/pi-devtools && \
    pi install npm:@piex-dev/dap && \
    pi install npm:cc-safety-net && \
    pi install npm:@oisin-ee/pi-guardrails && \
    pi install npm:pi-goal && \
    pi install npm:pi-autoresearch && \
    pi install npm:@juicesharp/rpiv-ask-user-question && \
    pi install npm:pi-nvidia-nim || true

COPY config.json /app/config.json
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

VOLUME ["/data"]

ENV PI_WEB_HOST=0.0.0.0
ENV PI_WEB_CONFIG=/app/config.json
ENV NODE_ENV=production

EXPOSE 8504

# Healthcheck هم برداشته شد - محدودیت نیست
HEALTHCHECK --interval=60s --timeout=30s --start-period=120s --retries=10 \
  CMD curl -f http://localhost:${PORT:-8504}/ || exit 0

CMD ["/app/start.sh"]
