#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Post-build smoke test. Runs INSIDE the built image:
#
#   docker run --rm -e SMOKE_TEST=1 myimage /app/scripts/smoke-test.sh
#
# It boots the real stack the way start.sh does (volume layout, seeded
# packages, loopback Pi-Web) and fails on anything a deploy would lose sleep
# over: missing packages, unparsable agents, dead daemon, unhealthy web, or an
# auth gateway that either leaks or blocks too much.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

PASS=0
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

STATE=/smoke
DATA_DIR="$STATE/pi-web"
AGENT_DIR="$STATE/.pi/agent"
export PI_CODING_AGENT_DIR="$AGENT_DIR"
export PI_WEB_DATA_DIR="$DATA_DIR"
export PI_WEB_CONFIG="$DATA_DIR/config.json"
export PI_WEB_DEFAULTS_CONFIG=/app/defaults.json
export PI_WEB_HOST=127.0.0.1
export PI_WEB_PORT=8504
export PI_WEB_ALLOWED_HOSTS='["127.0.0.1","localhost"]'
export PORT=8080
export AUTH_USERNAME=smoke
export AUTH_PASSWORD=smoke-pass

rm -rf "$STATE"
mkdir -p "$DATA_DIR/logs" "$AGENT_DIR"

cleanup() {
  [ -n "${WEB_PID:-}" ] && kill "$WEB_PID" 2>/dev/null || true
  [ -n "${SD_PID:-}" ] && kill "$SD_PID" 2>/dev/null || true
  [ -n "${GW_PID:-}" ] && kill "$GW_PID" 2>/dev/null || true
  if [ "$FAIL" -gt 0 ]; then
    printf '\n\033[1m---- diagnostics ----\033[0m\n'
    for f in "$DATA_DIR"/logs/*.log; do
      [ -f "$f" ] || continue
      printf '\n### %s (last 25 lines)\n' "$f"
      tail -25 "$f"
    done
  fi
}
trap cleanup EXIT

step "toolchain"
command -v pi      >/dev/null && ok "pi on PATH ($(pi --version 2>&1 | head -1))"      || bad "pi missing"
command -v pi-web  >/dev/null && ok "pi-web on PATH ($(pi-web --version 2>&1 | head -1))" || bad "pi-web missing"
command -v jq      >/dev/null && ok "jq present"  || bad "jq missing (start.sh needs it)"
command -v rg      >/dev/null && ok "ripgrep present" || bad "ripgrep missing"
command -v git     >/dev/null && ok "git present" || bad "git missing"
node -e 'const v=process.versions.node.split(".").map(Number);process.exit(v[0]>22||(v[0]===22&&v[1]>=19)?0:1)' \
  && ok "node $(node -v) satisfies pi-web >=22.19" || bad "node $(node -v) too old"
# node-pty is not a global module: it lives under pi-web's own node_modules.
# Resolve it from there, the way pi-web's terminal plugin does.
PIWEB_ROOT=$(npm root -g)/@jmfederico/pi-web
node -e "
  const { createRequire } = require('node:module');
  const r = createRequire('$PIWEB_ROOT/package.json');
  const p = r('node-pty');
  if (!p || typeof p.spawn !== 'function') process.exit(1);
  console.log('   resolved:', r.resolve('node-pty'));
" 2>/dev/null \
  && ok "node-pty native module loads (terminals work)" \
  || bad "node-pty does not load (terminal plugin will be broken)"

step "image seed"
SEED="${PI_SEED_DIR:-/opt/pi-seed}/agent/settings.json"
[ -f "$SEED" ] && ok "seed settings.json present" || { bad "seed settings.json missing"; exit 1; }
EXPECTED=$(jq -r '[.packages[] | select(startswith("npm:"))] | length' "$SEED")
[ "$EXPECTED" -ge 16 ] && ok "seed declares $EXPECTED npm packages" || bad "only $EXPECTED packages seeded"
if jq -r '.packages[]' "$SEED" | grep -q '^/root/'; then
  bad "seed contains absolute /root paths (runtime will fail to resolve them)"
else
  ok "seed has no /root absolute paths"
fi

step "first-boot seeding (what start.sh does)"
cp -a "${PI_SEED_DIR:-/opt/pi-seed}/agent/." "$AGENT_DIR/"
jq '(.. | strings) |= gsub("/root/.pi/agent"; $dir)' --arg dir "$AGENT_DIR" \
   "$AGENT_DIR/settings.json" > "$AGENT_DIR/s.tmp" && mv "$AGENT_DIR/s.tmp" "$AGENT_DIR/settings.json"
if jq -r '.packages[]' "$AGENT_DIR/settings.json" | grep -q '^/root/'; then
  bad "path rewrite left /root paths"
else
  ok "seeded package paths point at the volume profile"
fi

RESOLVED=$(pi list 2>/dev/null | grep -c "^  npm:" || true)
[ "$RESOLVED" -ge 16 ] && ok "pi resolves $RESOLVED npm packages from the volume" || bad "pi resolves only $RESOLVED packages"
if pi list 2>&1 | grep -qiE "error|cannot find|ENOENT"; then
  bad "pi list reported resolution errors"
else
  ok "pi list is clean"
fi

step "agent definitions"
[ -d /app/agents-seed ] && ok "agents shipped at /app/agents-seed" || bad "no /app/agents-seed"
COUNT=$(ls /app/agents-seed/*.md 2>/dev/null | wc -l)
[ "$COUNT" -ge 4 ] && ok "$COUNT council agent files" || bad "only $COUNT agent files"
for f in /app/agents-seed/*.md; do
  head -1 "$f" | grep -qx -- '---' && ok "frontmatter: $(basename "$f")" || bad "no frontmatter: $(basename "$f")"
  grep -q '^name:'  "$f" && ok "  name set: $(basename "$f")"  || bad "missing name: $(basename "$f")"
  grep -q '^model:' "$f" && ok "  model pinned: $(basename "$f")" || bad "missing model: $(basename "$f")"
done

step "defaults.json policy"
jq empty /app/defaults.json 2>/dev/null && ok "defaults.json is valid JSON" || bad "defaults.json invalid"
[ "$(jq -r '.host' /app/defaults.json)" = "127.0.0.1" ] \
  && ok "defaults bind to loopback" || bad "defaults do not bind to loopback"

step "boot: session daemon"
echo '{"host":"127.0.0.1","port":8504}' > "$PI_WEB_CONFIG"
pi-web-sessiond >>"$DATA_DIR/logs/sessiond.log" 2>&1 &
SD_PID=$!
for _ in $(seq 1 90); do [ -S "$DATA_DIR/sessiond.sock" ] && break; sleep 1; done
[ -S "$DATA_DIR/sessiond.sock" ] && ok "session daemon socket created" \
  || { bad "session daemon never opened its socket"; tail -5 "$DATA_DIR/logs/sessiond.log"; }

step "boot: web server"
pi-web-server >>"$DATA_DIR/logs/web.log" 2>&1 &
WEB_PID=$!
for _ in $(seq 1 90); do
  curl -fsS "http://127.0.0.1:8504/api/pi-web/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:8504/api/pi-web/health" >/dev/null \
  && ok "web server healthy on loopback" || { bad "web server unhealthy"; tail -5 "$DATA_DIR/logs/web.log"; }

curl -fsS http://127.0.0.1:8504/api/config | jq -e '.effectiveConfig.pathAccess.allowedPaths | index("/data")' >/dev/null \
  && ok "read-only defaults applied (pathAccess includes /data)" || bad "defaults.json not applied"

step "boot: auth gateway"
node /app/gateway/server.js >>"$DATA_DIR/logs/gateway.log" 2>&1 &
GW_PID=$!
for _ in $(seq 1 30); do curl -fsS -m 1 http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break; sleep 1; done

CODE=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)
[ "$CODE" = "401" ] && ok "unauthenticated request rejected (401)" || bad "unauthenticated got $CODE (expected 401)"

CODE=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u smoke:wrong http://127.0.0.1:8080/ || true)
[ "$CODE" = "401" ] && ok "wrong password rejected" || bad "wrong password got $CODE"

CODE=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -u smoke:smoke-pass http://127.0.0.1:8080/ || true)
[ "$CODE" = "200" ] && ok "authenticated UI served" || bad "authenticated got $CODE (expected 200)"

CODE=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u smoke:smoke-pass http://127.0.0.1:8080/api/pi-web/status || true)
[ "$CODE" = "200" ] && ok "authenticated API reachable through proxy" || bad "API through proxy got $CODE"

BODY=$(curl -s -m 5 http://127.0.0.1:8080/healthz || true)
[ "$BODY" = "ok" ] && ok "healthz public and unauthenticated" || bad "healthz returned '$BODY'"

step "gateway: generated password mode"
export AUTH_PASSWORD_FILE=/smoke-generate-pw
rm -f "$AUTH_PASSWORD_FILE"
AUTH_USERNAME=gen AUTH_PASSWORD= AUTH_PASSWORD_HASH= PORT=8081 node /app/gateway/server.js \
  >>"$DATA_DIR/logs/gateway-gen.log" 2>&1 &
GEN_PID=$!
for _ in $(seq 1 30); do curl -fsS -m 1 http://127.0.0.1:8081/healthz >/dev/null 2>&1 && break; sleep 1; done
GEN_PW=$(sed -n 's/^   password: //p' "$DATA_DIR/logs/gateway-gen.log" | head -1)
[ -n "$GEN_PW" ] && ok "generated a password without AUTH_PASSWORD_HASH" || bad "no generated password in the log"
[ -s "$AUTH_PASSWORD_FILE" ] && ok "generated password persisted to disk" || bad "generated password not persisted"
[ "$(stat -c '%a' "$AUTH_PASSWORD_FILE" 2>/dev/null)" = "600" ] && ok "password file mode 600" || bad "password file readable by others"
CODE=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u "gen:$GEN_PW" http://127.0.0.1:8081/ || true)
[ "$CODE" = "200" ] && ok "generated password authenticates" || bad "generated password got $CODE"
kill "$GEN_PID" 2>/dev/null || true

step "persistence helper"
[ -x /app/scripts/stop-all.sh ] && ok "stop-all.sh installed and executable" || bad "stop-all.sh missing"
FH=$(mktemp -d); FV=$(mktemp -d); mkdir -p "$FH/.pi" "$FH/.npm"
echo '{}' > "$FH/.pi/settings.json"
HOME_DIR="$FH" VOLUME_ROOT="$FV" /app/scripts/stop-all.sh >/dev/null 2>&1 \
  && ok "stop-all.sh runs" || bad "stop-all.sh failed"
[ -L "$FH/.pi" ] && [ -f "$FV/.pi/agent/settings.json" ] \
  && ok "Pi state moved onto the volume and symlinked" || bad "Pi state not relocated"
[ -L "$FH/.npm" ] && ok "npm cache relocated" || bad "npm cache not relocated"
HOME_DIR="$FH" VOLUME_ROOT="$FV" /app/scripts/stop-all.sh >/dev/null 2>&1
[ -f "$FV/.pi/agent/settings.json" ] && ok "stop-all.sh is idempotent" || bad "second run lost data"
rm -rf "$FH" "$FV"

step "maintenance scripts"
[ -x /app/scripts/update.sh ] && ok "update.sh installed" || bad "update.sh missing"
/app/scripts/update.sh --help >/dev/null 2>&1 && ok "update.sh --help works" || bad "update.sh --help broken"
/app/scripts/update.sh --dry-run >/dev/null 2>&1 && ok "update.sh --dry-run works" || bad "update.sh --dry-run broken"
/app/scripts/update.sh --bogus >/dev/null 2>&1 && bad "update.sh accepted an unknown flag" || ok "update.sh rejects unknown flags"

step "supervisor wiring"
grep -q "supervise" /app/start.sh && ok "start.sh supervises children" || bad "no supervisor in start.sh"
grep -q "exit 1" /app/start.sh && ok "supervisor can fail the container" || bad "supervisor cannot fail the container"
grep -q "trap 'cleanup; exit 0' INT TERM" /app/start.sh && ok "SIGTERM exits 0 (graceful)" || bad "SIGTERM would look like a crash"

step "public surface"
if (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | awk '{print $4}' | grep -qE '(^|:)8504$' \
   && (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q '0.0.0.0:8504'; then
  bad "Pi-Web is listening on 0.0.0.0:8504 (must be loopback only)"
else
  ok "Pi-Web is not bound to 0.0.0.0"
fi

printf '\n────────────────────────────────────────\n'
printf ' smoke test: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '────────────────────────────────────────\n'
[ "$FAIL" -eq 0 ]
