#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Persistence helper.
#
# Dockers top layer is ephemeral: anything Pi or Pi-Web writes to ~ or /root is
# gone on the next deploy. This command moves Pi-Web, Pi and every tool that
# keeps state under /data (the volume) and then reports what is still outside.
#
#   /app/scripts/stop-all.sh            -> move state, print a report
#   /app/scripts/stop-all.sh --dry-run  -> only report
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

MODE="${1:-apply}"
VOLUME_ROOT="${VOLUME_ROOT:-/data}"
HOME_DIR="${HOME_DIR:-/root}"
# Destination must live on the volume. The image exports PI_CODING_AGENT_DIR and
# PI_WEB_DATA_DIR globally, so only trust them when they already point inside
# VOLUME_ROOT; otherwise derive from VOLUME_ROOT (and say so).
pick_dir() { # <env value> <default under volume>
  local env_val="$1" fallback="$2"
  if [ -n "$env_val" ] && [ "${env_val#"$VOLUME_ROOT"/}" != "$env_val" ]; then
    printf '%s' "$env_val"
  else
    printf '%s' "$fallback"
  fi
}
PI_AGENT=$(pick_dir "${PI_CODING_AGENT_DIR:-}" "$VOLUME_ROOT/.pi/agent")
PI_WEB_DATA=$(pick_dir "${PI_WEB_DATA_DIR:-}" "$VOLUME_ROOT/pi-web")

ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; }
mv_(){ printf '  \033[36mmove\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33mwarn\033[0m %s\n' "$*"; }
skip(){ printf '  \033[90mskip\033[0m %s\n' "$*"; }

echo "persistence report (mode=$MODE)"
echo "volume: $VOLUME_ROOT"

if ! awk -v p="$VOLUME_ROOT" '$5 == p {found=1} END {exit !found}' /proc/self/mountinfo 2>/dev/null; then
  warn "$VOLUME_ROOT is not a mounted volume — anything written there dies with the container"
fi

# Each entry: "<dir under HOME>|<dir on the volume>"
MOVES=(
  ".pi|$PI_AGENT"
  ".pi-web|$PI_WEB_DATA"
  ".cache|$VOLUME_ROOT/home/.cache"
  ".npm|$VOLUME_ROOT/home/.npm"
  ".config|$VOLUME_ROOT/home/.config"
  ".local|$VOLUME_ROOT/home/.local"
  ".gitconfig|$VOLUME_ROOT/home/.gitconfig"
  ".docker|$VOLUME_ROOT/home/.docker"
  ".ssh|$VOLUME_ROOT/home/.ssh"
  ".bun|$VOLUME_ROOT/home/.bun"
  ".deno|$VOLUME_ROOT/home/.deno"
  ".cargo|$VOLUME_ROOT/home/.cargo"
  ".rustup|$VOLUME_ROOT/home/.rustup"
  ".gopath|$VOLUME_ROOT/home/.gopath"
)

for pair in "${MOVES[@]}"; do
  src="$HOME_DIR/${pair%%|*}"
  dst="${pair##*|}"
  name="${pair%%|*}"

  # already a symlink into the volume
  if [ -L "$src" ]; then
    target=$(readlink -f "$src" 2>/dev/null || true)
    case "$target" in
      "$VOLUME_ROOT"/*) ok "$name -> $target"; continue ;;
      *) mv_ "$name had a stale link -> $target"; ;;
    esac
  fi

  if [ -e "$src" ] && [ ! -L "$src" ]; then
    if [ "$MODE" = "--dry-run" ]; then
      mv_ "$name ($(du -sh "$src" 2>/dev/null | cut -f1)) -> $dst"
      continue
    fi
    mkdir -p "$dst"
    # merge without clobbering newer files on the volume
    cp -an "$src/." "$dst/" 2>/dev/null || true
    rm -rf "$src"
  fi

  if [ "$MODE" = "--dry-run" ]; then
    skip "$name (not present)"
    continue
  fi
  mkdir -p "$dst"
  ln -sfn "$dst" "$src"
  ok "$name -> $(readlink -f "$src")"
done

if [ "$MODE" != "--dry-run" ]; then
  # Everything still under HOME is outside the volume and will be lost.
  echo
  echo "still outside the volume:"
  found=0
  for entry in "$HOME_DIR"/* "$HOME_DIR"/.[!.]*; do
    [ -e "$entry" ] || continue
    [ -L "$entry" ] && continue
    printf '  - %s (%s)\n' "$(basename "$entry")" "$(du -sh "$entry" 2>/dev/null | cut -f1)"
    found=1
  done
  [ "$found" -eq 0 ] && echo "  (none)"
fi
