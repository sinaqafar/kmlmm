#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Update Pi or Pi-Web inside a running container.
#
# Why this script exists: the global npm packages live in the image layer. An
# update writes to the container's writable layer, which is thrown away on the
# next deploy, so a plain `npm i -g` looks like it worked and silently reverts.
#
#   /app/scripts/update.sh                 update Pi packages only
#   /app/scripts/update.sh --self          also update the global pi + pi-web
#   /app/scripts/update.sh --dry-run       show what would change
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

SELF=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --self) SELF=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

run() {
  if [ "$DRY" -eq 1 ]; then
    printf '  would run: %s\n' "$*"
  else
    printf '  $ %s\n' "$*"
    "$@"
  fi
}

echo "Pi packages on the volume (${PI_CODING_AGENT_DIR:-/data/.pi/agent}):"
run pi update

if [ "$SELF" -eq 1 ]; then
  echo
  echo "Global Pi / Pi-Web:"
  echo "  NOTE: the image owns these. A runtime upgrade only lasts until the next"
  echo "  deploy. To make it permanent, bump the image (rebuild) instead."
  run npm install -g @jmfederico/pi-web@latest @earendil-works/pi-coding-agent@latest \
      --allow-scripts=node-pty
fi

if [ "$DRY" -eq 0 ]; then
  cat <<'EOF'

Done. Active sessions keep running with the code they started with.
To pick up package changes:
  - ordinary extensions / skills / themes:  /reload inside an idle session
  - anything that adds a server plugin:     restart the container
EOF
fi
