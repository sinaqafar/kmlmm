#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Pi-Web boot for Railway
#
#   1. fails loudly if /data is not a Railway Volume (else everything is lost)
#   2. seeds / tops up the Pi package set baked into the image
#   3. reads the container's real RAM/CPU limits and sizes Node to them
#   4. starts the session daemon, then the web server, both on 127.0.0.1
#   5. exposes the stack on $PORT through the Basic-Auth gateway
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

log() { printf '\033[1m[pi-web]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[pi-web]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[pi-web] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

STATE_ROOT=/data
DATA_DIR="${PI_WEB_DATA_DIR:-$STATE_ROOT/pi-web}"
AGENT_DIR="${PI_CODING_AGENT_DIR:-$STATE_ROOT/.pi/agent}"
SEED_DIR="${PI_SEED_DIR:-/opt/pi-seed}"
PORT="${PORT:-8080}"
PI_WEB_PORT="${PI_WEB_PORT:-8504}"
HEAP_PERCENT="${HEAP_PERCENT:-95}"
SETUP_MODE="${SETUP_MODE:-auth}"
# First-boot workspace. Created once, never touched again: an existing project
# is left exactly as it is, and no model is ever pinned for you.
PROJECT_PATH="${PROJECT_PATH:-$STATE_ROOT/project}"
PROJECT_NAME="${PROJECT_NAME:-}"
PROJECT_GIT_URL="${PROJECT_GIT_URL:-}"
BOOTSTRAP_SESSION="${BOOTSTRAP_SESSION:-1}"
export PROJECT_PATH PROJECT_NAME PROJECT_GIT_URL BOOTSTRAP_SESSION

export PI_CODING_AGENT_DIR="$AGENT_DIR"
export PI_WEB_DATA_DIR="$DATA_DIR"
export PI_WEB_CONFIG="${PI_WEB_CONFIG:-$DATA_DIR/config.json}"
export PI_WEB_HOST=127.0.0.1
export PI_WEB_PORT
export PI_WEB_DEFAULTS_CONFIG="${PI_WEB_DEFAULTS_CONFIG:-/app/defaults.json}"

# ── 1. persistence guard ─────────────────────────────────────────────────────
# ── 0. validate inputs early, with messages that say what to change ──────────
[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT='$PORT' is not a number. Railway sets it; do not override it."
[[ "$PI_WEB_PORT" =~ ^[0-9]+$ ]] || die "PI_WEB_PORT='$PI_WEB_PORT' is not a number."
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "PORT=$PORT is out of range."
[ "$PI_WEB_PORT" -ge 1 ] && [ "$PI_WEB_PORT" -le 65535 ] || die "PI_WEB_PORT=$PI_WEB_PORT is out of range."
[ "$PORT" != "$PI_WEB_PORT" ] || die "PORT and PI_WEB_PORT are both $PORT. The gateway proxies to Pi-Web on PI_WEB_PORT, so they must differ (leave PI_WEB_PORT at 8504)."
BOOTSTRAP_PROJECT="${BOOTSTRAP_PROJECT:-1}"
case "$BOOTSTRAP_PROJECT" in 0|1) ;; *) die "BOOTSTRAP_PROJECT='$BOOTSTRAP_PROJECT' must be 0 or 1." ;; esac
case "$BOOTSTRAP_SESSION" in 0|1) ;; *) die "BOOTSTRAP_SESSION='$BOOTSTRAP_SESSION' must be 0 or 1." ;; esac
export BOOTSTRAP_PROJECT
[[ "$HEAP_PERCENT" =~ ^[0-9]+$ ]] && [ "$HEAP_PERCENT" -ge 20 ] && [ "$HEAP_PERCENT" -le 100 ] \
  || die "HEAP_PERCENT='$HEAP_PERCENT' must be a whole number between 20 and 100."
case "$SETUP_MODE" in auth|direct) ;; *) die "SETUP_MODE='$SETUP_MODE' must be 'auth' or 'direct'."; esac
if [ "$SETUP_MODE" = "auth" ]; then
  case "${AUTH_USERNAME:-pi}" in *:*) die "AUTH_USERNAME cannot contain ':' (HTTP Basic Auth splits credentials on the first colon)." ;; esac
fi

mkdir -p "$STATE_ROOT" 2>/dev/null || die "cannot create $STATE_ROOT"

is_mountpoint() {
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$1" 2>/dev/null
    return $?
  fi
  # util-linux may be absent; ask the kernel directly.
  awk -v p="$1" '$5 == p {found=1} END {exit !found}' /proc/self/mountinfo 2>/dev/null
}

if ! is_mountpoint "$STATE_ROOT"; then
  warn "════════════════════════════════════════════════════════════════"
  warn " $STATE_ROOT is NOT a mounted Railway Volume."
  warn " Projects, sessions, Pi memory and auth will be WIPED on every deploy."
  warn " Railway → your service → Volumes → New Volume → mount path /data"
  warn "════════════════════════════════════════════════════════════════"
fi

mkdir -p "$DATA_DIR/logs" "$AGENT_DIR" "$STATE_ROOT/projects"

# ── 2. Pi packages: seed on first boot, top up afterwards ────────────────────
seed_missing() {
  [ -f "$SEED_DIR/agent/settings.json" ] || { log "no package seed in image"; return 0; }

  if [ ! -f "$AGENT_DIR/settings.json" ]; then
    log "first boot — seeding Pi packages and auth from image"
    mkdir -p "$AGENT_DIR"
    cp -a "$SEED_DIR/agent/." "$AGENT_DIR/"
    # The image was built with HOME=/root, so packages live in a shared npm
    # cache outside the profile. Rewrite that path, otherwise Pi looks for the
    # seed directory that does not exist on the volume.
    local seeded="$AGENT_DIR/settings.json"
    if jq -e '.packages | type == "array"' "$seeded" >/dev/null 2>&1; then
      jq '(.. | strings) |= gsub("/root/.pi/agent"; $dir)' \
        --arg dir "$AGENT_DIR" "$seeded" >"$seeded.tmp" \
        && mv "$seeded.tmp" "$seeded" \
        && log "rewrote seeded package paths to $AGENT_DIR"
    else
      warn "seeded settings.json is not valid JSON — leaving it untouched"
    fi
    return 0
  fi

  local wanted have pkg h found
  mapfile -t wanted < <(jq -r '.packages // [] | .[] | strings | select(startswith("npm:"))' \
                          "$SEED_DIR/agent/settings.json" 2>/dev/null)
  mapfile -t have   < <(jq -r '.packages // [] | .[] | strings | select(startswith("npm:"))' \
                          "$AGENT_DIR/settings.json" 2>/dev/null)

  for pkg in "${wanted[@]:-}"; do
    [ -n "$pkg" ] || continue
    found=0
    for h in "${have[@]:-}"; do [ "$h" = "$pkg" ] && found=1 && break; done
    if [ "$found" -eq 0 ]; then
      log "new package from image: $pkg"
      pi install "$pkg" >>"$DATA_DIR/logs/install.log" 2>&1 \
        || warn "could not install $pkg (see $DATA_DIR/logs/install.log)"
    fi
  done
}
seed_missing

# Agent definitions (pi-subagents council roles) shipped in the image.
if [ -d /app/agents-seed ] && [ -n "$(ls -A /app/agents-seed 2>/dev/null)" ]; then
  mkdir -p "$AGENT_DIR/agents"
  cp -an /app/agents-seed/. "$AGENT_DIR/agents/" 2>/dev/null || true
fi

# ── 3. resource sizing ───────────────────────────────────────────────────────
detect_ram_mb() {
  local v
  for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
    if [ -r "$f" ]; then
      v=$(cat "$f" 2>/dev/null || echo max)
      if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -lt 1125899906842624 ]; then
        echo $(( v / 1024 / 1024 )); return
      fi
    fi
  done
  awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024
}

TOTAL_RAM_MB=$(detect_ram_mb); [ "${TOTAL_RAM_MB:-0}" -ge 256 ] || TOTAL_RAM_MB=1024
TOTAL_CPU=$(nproc 2>/dev/null || echo 1); [ "${TOTAL_CPU:-0}" -ge 1 ] || TOTAL_CPU=1

# Reserve real headroom: git, node-pty shells, subagent children and page cache
# all live in the same cgroup. 95% of the limit to V8 is a good trade.
HEAP_MB=$(( TOTAL_RAM_MB * HEAP_PERCENT / 100 ))
[ "$HEAP_MB" -gt 4096 ] && HEAP_MB=$(( HEAP_MB - 256 ))
[ "$HEAP_MB" -lt 256 ] && HEAP_MB=256

export NODE_OPTIONS="--max-old-space-size=${HEAP_MB}"
export UV_THREADPOOL_SIZE=$(( TOTAL_CPU * 2 ))

log "container: ${TOTAL_RAM_MB}MB RAM, ${TOTAL_CPU} CPU(s)"
log "node heap: ${HEAP_MB}MB (${HEAP_PERCENT}% of limit)"

# ── 4. Pi-Web config: writable part holds host/port; policy is read-only ─────
if [ ! -s "$PI_WEB_CONFIG" ]; then
  cat >"$PI_WEB_CONFIG" <<JSON
{
  "host": "127.0.0.1",
  "port": ${PI_WEB_PORT}
}
JSON
  log "wrote $PI_WEB_CONFIG"
fi

# ── 5. bring the stack up ────────────────────────────────────────────────────
WEB_PID=""
SESSIOND_PID=""
GW_PID=""
cleanup() {
  log "shutting down"
  [ -n "${GW_PID:-}" ] && kill "$GW_PID" 2>/dev/null || true
  [ -n "$WEB_PID" ] && kill "$WEB_PID" 2>/dev/null || true
  [ -n "$SESSIOND_PID" ] && kill "$SESSIOND_PID" 2>/dev/null || true
}
# A graceful stop should not look like a crash to the restart policy.
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

log "starting session daemon"
pi-web-sessiond >>"$DATA_DIR/logs/sessiond.log" 2>&1 &
SESSIOND_PID=$!

for _ in $(seq 1 90); do
  [ -S "$DATA_DIR/sessiond.sock" ] && break
  kill -0 "$SESSIOND_PID" 2>/dev/null || die "session daemon died — tail $DATA_DIR/logs/sessiond.log"
  sleep 1
done
[ -S "$DATA_DIR/sessiond.sock" ] || die "session daemon never opened its socket"
log "session daemon ready"

log "starting web server on 127.0.0.1:${PI_WEB_PORT}"
pi-web-server >>"$DATA_DIR/logs/web.log" 2>&1 &
WEB_PID=$!

for _ in $(seq 1 120); do
  curl -fsS "http://127.0.0.1:${PI_WEB_PORT}/api/pi-web/health" >/dev/null 2>&1 && break
  kill -0 "$WEB_PID" 2>/dev/null || die "web server died — tail $DATA_DIR/logs/web.log"
  sleep 1
done
curl -fsS "http://127.0.0.1:${PI_WEB_PORT}/api/pi-web/health" >/dev/null \
  || die "web server never became healthy"
log "web server healthy"

# ── 5b. first-boot project + session ─────────────────────────────────────────
# Runs while Pi-Web is reachable only on loopback, so the UI never shows an
# empty state. Best effort: a failure is logged and the stack still comes up.
LOG_DIR="$DATA_DIR/logs"
if [ "$BOOTSTRAP_PROJECT" = "1" ]; then
  bash /app/scripts/bootstrap-project.sh \
    || warn "project bootstrap failed (non-fatal) — see $LOG_DIR/project.log"
fi

# ── 6. public surface ────────────────────────────────────────────────────────
if [ "$SETUP_MODE" = "direct" ]; then
  warn "SETUP_MODE=direct — no authentication. Anyone with the URL has a shell."
  kill "$WEB_PID" 2>/dev/null || true
  wait "$WEB_PID" 2>/dev/null || true
  export PI_WEB_HOST=0.0.0.0 PI_WEB_PORT="$PORT"
  export PI_WEB_ALLOWED_HOSTS='true'
  log "re-binding web server to 0.0.0.0:${PORT}"
  exec pi-web-server
fi

log "starting auth gateway on 0.0.0.0:${PORT}"
node /app/gateway/server.js &
GW_PID=$!

# Supervisor: Railway only watches this pid. If the session daemon or the web
# server dies, the gateway would keep serving errors forever, so exit non-zero
# and let the restart policy bring the whole stack back.
supervise() {
  while kill -0 "$GW_PID" 2>/dev/null; do
    for pair in "session-daemon:$SESSIOND_PID" "web-server:$WEB_PID"; do
      name=${pair%%:*}; pid=${pair##*:}
      if ! kill -0 "$pid" 2>/dev/null; then
        warn "$name (pid $pid) exited — restarting the container"
        kill "$GW_PID" 2>/dev/null || true
        exit 1
      fi
    done
    sleep 5
  done
  # gateway itself died
  wait "$GW_PID" || true
  warn "auth gateway exited — restarting the container"
  exit 1
}
supervise
