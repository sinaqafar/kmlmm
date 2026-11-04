#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# First-boot project + session bootstrap.
#
# Creates a project (and one empty session inside it) automatically, so a fresh
# deploy lands in a usable workspace instead of an empty "Add Project" dialog.
#
# Runs after the web server is healthy and before the gateway is exposed.
# Idempotent: a registry hit is a no-op, so restarts and redeploys never
# duplicate anything.
#
#   PROJECT_PATH      project directory            (default /data/project)
#   PROJECT_NAME      display name                 (default: basename of path)
#   PROJECT_GIT_URL   optional: clone into the path when it is empty
#   PROJECT_BRANCH    optional: branch for the clone
#   BOOTSTRAP_SESSION 1 = also open one empty session (default 1)
#   BOOTSTRAP_MODEL   deliberately NOT supported — the model is chosen by you.
#
# Everything here is best effort: a failure is a warning, never a dead stack.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

API="http://127.0.0.1:${PI_WEB_PORT:-8504}/api"
PROJECT_PATH="${PROJECT_PATH:-/data/project}"
PROJECT_NAME="${PROJECT_NAME:-}"
PROJECT_GIT_URL="${PROJECT_GIT_URL:-}"
PROJECT_BRANCH="${PROJECT_BRANCH:-}"
BOOTSTRAP_SESSION="${BOOTSTRAP_SESSION:-1}"

# Log destination must follow the configured data dir, never a hard-coded path:
# if it does not exist, a shell redirection fails and takes the clone with it.
LOG_DIR="${PI_WEB_DATA_DIR:-/tmp}/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR=/tmp
PROJECT_LOG="$LOG_DIR/project.log"

log()  { printf '\033[1m[project]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[project]\033[0m %s\n' "$*" >&2; }

# Trim trailing slashes so /data/project and /data/project/ are one project.
PROJECT_PATH="${PROJECT_PATH%/}"
[ -n "$PROJECT_PATH" ] || { warn "PROJECT_PATH is empty — skipping"; exit 0; }
[ -n "$PROJECT_NAME" ] || PROJECT_NAME="$(basename "$PROJECT_PATH")"

api() { # <method> <path> [json-body] — prints the body even on a 4xx/5xx
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -m 30 -X "$method" "$API$path" \
      -H 'content-type: application/json' --data-binary "$body" 2>/dev/null
  else
    curl -sS -m 30 -X "$method" "$API$path" 2>/dev/null
  fi
}

# Turn an API response into something a human can act on.
explain() {
  local body="${1:-}"
  if [ -z "$body" ]; then
    printf 'no response'
    return
  fi
  printf '%s' "$body" | jq -r '.error // .message // empty' 2>/dev/null \
    | head -1 | grep . || printf '%s' "$body" | head -c 200
}

# ── 1. optional clone ────────────────────────────────────────────────────────
if [ -n "$PROJECT_GIT_URL" ] && [ ! -d "$PROJECT_PATH/.git" ]; then
  if [ -d "$PROJECT_PATH" ] && [ -n "$(ls -A "$PROJECT_PATH" 2>/dev/null)" ]; then
    warn "$PROJECT_PATH is not empty — not cloning $PROJECT_GIT_URL into it"
  else
    log "cloning $PROJECT_GIT_URL → $PROJECT_PATH"
    mkdir -p "$(dirname "$PROJECT_PATH")"
    clone_args=(--depth 1)
    [ -n "$PROJECT_BRANCH" ] && clone_args+=(--branch "$PROJECT_BRANCH")
    if ! git clone "${clone_args[@]}" "$PROJECT_GIT_URL" "$PROJECT_PATH" \
        >>"$PROJECT_LOG" 2>&1; then
      reason=$(tail -1 "$PROJECT_LOG" 2>/dev/null)
      warn "clone failed: ${reason:-see $PROJECT_LOG} — continuing with an empty folder"
      rm -rf "$PROJECT_PATH"
    fi
  fi
fi

# ── 2. register the project ──────────────────────────────────────────────────
existing=$(api GET /projects)
if [ -z "$existing" ]; then
  warn "cannot reach the web API at $API — skipping project creation"
  exit 0
fi

if ! printf '%s' "$existing" | jq -e . >/dev/null 2>&1; then
  warn "unexpected /projects response — skipping"
  exit 0
fi

# Compare resolved paths: the server stores realpaths, so a symlinked or
# differently-spelled path would otherwise be registered twice.
want_path=$(realpath -m "$PROJECT_PATH" 2>/dev/null || echo "$PROJECT_PATH")
project_id=$(printf '%s' "$existing" \
  | jq -r --arg p "$want_path" --arg raw "$PROJECT_PATH" \
      '.[] | select(.path == $p or .path == $raw) | .id' 2>/dev/null | head -1)

if [ -n "$project_id" ]; then
  log "project already registered: $PROJECT_NAME ($project_id)"
else
  if [ -e "$PROJECT_PATH" ] && [ ! -d "$PROJECT_PATH" ]; then
    warn "$PROJECT_PATH exists but is not a directory — skipping"
    exit 0
  fi
  # create:true makes the folder if it is missing. Without it the API returns
  # "Project path must be a directory" and onboarding stalls on a fresh volume.
  payload=$(jq -nc --arg p "$PROJECT_PATH" --arg n "$PROJECT_NAME" \
    '{path:$p, name:$n, create:true}')
  created=$(api POST /projects "$payload")
  project_id=$(printf '%s' "$created" | jq -r '.id // empty' 2>/dev/null)

  if [ -z "$project_id" ]; then
    warn "could not create the project: $(explain "$created")"
    exit 0
  fi
  log "created project: $PROJECT_NAME → $PROJECT_PATH ($project_id)"
fi

# ── 3. one empty session ─────────────────────────────────────────────────────
if [ "$BOOTSTRAP_SESSION" != "1" ]; then
  log "BOOTSTRAP_SESSION=$BOOTSTRAP_SESSION — not opening a session"
  exit 0
fi

session_cwd=$(realpath -m "$PROJECT_PATH" 2>/dev/null || echo "$PROJECT_PATH")
sessions=$(api GET "/sessions?cwd=$(printf '%s' "$session_cwd" | jq -sRr @uri)")

if [ -n "$sessions" ] && printf '%s' "$sessions" | jq -e 'length > 0' >/dev/null 2>&1; then
  log "session already exists in $session_cwd — not creating another"
  exit 0
fi

# No model is sent on purpose: Pi opens with whatever default you pick in the
# UI, so this never pins a model you did not choose.
opened=$(api POST /sessions "$(jq -nc --arg c "$session_cwd" '{cwd:$c}')")
session_id=$(printf '%s' "$opened" | jq -r '.id // empty' 2>/dev/null)

if [ -n "$session_id" ]; then
  log "opened an empty session: $session_id"
else
  warn "could not open a session: $(explain "$opened")"
fi
