#!/bin/bash
set -e

# ============================================
# 95% MODE - بهینه‌ترین - 95% رم + 5% رزرو امن
# ============================================

detect_ram_mb() {
  local cgroup_mem=""
  local host_mem=""
  if [ -f "/sys/fs/cgroup/memory.max" ]; then
    cgroup_mem=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo "")
    if [[ "$cgroup_mem" != "max" && "$cgroup_mem" =~ ^[0-9]+$ ]]; then
      echo $(( cgroup_mem / 1024 / 1024 ))
      return
    fi
  fi
  if [ -f "/sys/fs/cgroup/memory/memory.limit_in_bytes" ]; then
    cgroup_mem=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo "")
    if [[ "$cgroup_mem" =~ ^[0-9]+$ && "$cgroup_mem" -lt 999999999999 ]]; then
      echo $(( cgroup_mem / 1024 / 1024 ))
      return
    fi
  fi
  if [ -f "/proc/meminfo" ]; then
    host_mem=$(grep -i MemTotal /proc/meminfo | awk '{print $2}')
    if [[ "$host_mem" =~ ^[0-9]+$ ]]; then
      echo $(( host_mem / 1024 ))
      return
    fi
  fi
  echo 1024
}

detect_cpu() {
  if command -v nproc &> /dev/null; then
    nproc --all 2>/dev/null || nproc || echo 1
  else
    grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1
  fi
}

TOTAL_RAM_MB=$(detect_ram_mb)
TOTAL_CPU=$(detect_cpu)

# 95% - درخواست تو
HEAP_PERCENT=${HEAP_PERCENT:-95}
HEAP_MB=$(( TOTAL_RAM_MB * HEAP_PERCENT / 100 ))
if [ "$HEAP_MB" -lt 256 ]; then HEAP_MB=256; fi

MAX_SESSIONS=$(( TOTAL_CPU * 4 ))
if [ "$MAX_SESSIONS" -lt 4 ]; then MAX_SESSIONS=4; fi
if [ "$MAX_SESSIONS" -gt 32 ]; then MAX_SESSIONS=32; fi

UV_THREADS=$(( TOTAL_CPU * 4 ))
WORKERS=$TOTAL_CPU

export NODE_OPTIONS="--max-old-space-size=${HEAP_MB} --max-semi-space-size=256"
export UV_THREADPOOL_SIZE=$UV_THREADS
export PI_WEB_HOST=0.0.0.0
export PI_WEB_PORT=${PORT:-8504}
export PI_WEB_CONFIG=/app/config.json
export PI_WORKERS=$WORKERS

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚡ 95% MODE فعال:"
echo "   RAM کل: ${TOTAL_RAM_MB}MB → Heap Node: ${HEAP_MB}MB (${HEAP_PERCENT}%)"
echo "   رزرو سیستم: $(( TOTAL_RAM_MB - HEAP_MB ))MB (5% امن)"
echo "   CPU: ${TOTAL_CPU} core → Max Sessions: ${MAX_SESSIONS} | Workers: ${WORKERS} | UV Threads: ${UV_THREADS}"
echo "   Pi-Web: ${PI_WEB_HOST}:${PI_WEB_PORT}"
echo "   NODE_OPTIONS: $NODE_OPTIONS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -f "/app/config.json" ]; then
  if command -v jq &> /dev/null; then
    tmp=$(mktemp)
    jq --arg port "$PI_WEB_PORT" --argjson maxSessions "$MAX_SESSIONS" --argjson workers "$WORKERS" \
      '.host = "0.0.0.0" | .port = ($port|tonumber) | .sessionDaemon.maxSessions = $maxSessions | .sessionDaemon.workers = $workers | .pathAccess.allowedPaths = ["/data","/app","/tmp","/root"]' \
      /app/config.json > "$tmp" && mv "$tmp" /app/config.json
    echo "✅ config.json 95% tuned:"
    cat /app/config.json
    echo "---"
  fi
fi

mkdir -p /data/pi-web /data/.pi/agent /root/.pi/agent /root/.config/pi-web
if [ ! -L /root/.pi ]; then rm -rf /root/.pi 2>/dev/null || true; ln -s /data/.pi /root/.pi || true; fi
if [ ! -L /root/.pi-web ]; then rm -rf /root/.pi-web 2>/dev/null || true; ln -s /data/pi-web /root/.pi-web || true; fi
if [ ! -f /data/.pi/agent/settings.json ]; then mkdir -p /data/.pi/agent; echo '{"packages":{}}' > /data/.pi/agent/settings.json; fi

echo "📊 System Info:"
free -h 2>/dev/null | grep Mem || echo "Mem: ${TOTAL_RAM_MB}MB"
lscpu 2>/dev/null | grep "CPU(s)" | head -1 || echo "CPU: $TOTAL_CPU"
echo "---"

echo "🔍 pi-web doctor:"
pi-web doctor || true
echo "---"

echo "▶️ Starting pi-web-sessiond (95% power)..."
pi-web-sessiond &
SESSION_PID=$!
sleep 4
echo "✅ sessiond PID: $SESSION_PID (maxSessions=$MAX_SESSIONS)"

echo "▶️ Starting pi-web-server on 0.0.0.0:$PI_WEB_PORT (heap ${HEAP_MB}MB - 95%)..."
exec pi-web-server
