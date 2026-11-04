# Pi-Web on Railway — complete deploy guide

Pi-Web is the web UI for **Pi Coding Agent**: it keeps agent sessions alive on a
server so you can supervise them from any browser, and it reuses your existing
Pi install, auth and model config (`~/.pi/agent`).

This repo is a ready-to-deploy Railway service: Pi + Pi-Web + 16 Pi packages +
NVIDIA NIM + an **auth gateway**, with Pi-Web never exposed to the internet
directly.

---

## Why there is a gateway (read this first)

Pi-Web has **no authentication**. From its own docs:

> PI WEB is designed for trusted users and trusted server paths. Do not expose it
> directly to the public internet.

`pi-web.dev/install` says the same, and recommends an SSH tunnel or VPN. On
Railway your service sits on a public domain, so a bare Pi-Web deploy means:
**anyone with the URL gets a shell with your API keys and your code.**

So the architecture here is:

```
Railway public domain  →  $PORT  →  gateway (HTTP Basic Auth)  →  127.0.0.1:8504 Pi-Web
                                                                  └─ session daemon (unix socket)
```

The gateway also proxies WebSockets (`/api/machines/<id>/events`), which is how
Pi-Web streams agent output and terminal I/O. Without that, the UI loads but
nothing streams.

---

## What's inside

| Piece | Notes |
| --- | --- |
| `Dockerfile` | Node 22 + Pi + Pi-Web + 16 Pi packages, all installed at build time |
| `start.sh` | Boot script: volume check, package seeding, RAM/CPU sizing, health-wait |
| `gateway/server.js` | Zero-dependency Basic-Auth reverse proxy (HTTP + WebSocket) |
| `defaults.json` | Read-only Pi-Web policy (path access, spawn/sub sessions) |
| `agents/` | pi-subagents council roles on NVIDIA NIM models |
| `railway.json` | Dockerfile builder + `/healthz` healthcheck |

**Deliberately not included:**

- **No `VOLUME`** — Railway rejects Dockerfiles containing it. Attach a Railway
  Volume instead (step 3). Pi state lives at `/data` so the volume actually
  matters: without it every deploy wipes your projects, sessions and Pi memory.
- **No `HEALTHCHECK`** — Railway ignores it. Use `railway.json` → `healthcheckPath`.

### The 16 Pi packages

Self-improvement / memory: `pi-hermes-memory`, `pi-observational-memory`-class
memory is covered by hermes-memory; context: `billion-context`; research/web:
`pi-web-access`; multi-agent: `pi-subagents`; tools: `pi-mcp-adapter`,
`pi-lens`, `pi-agent-browser-native`, `pi-goal`, `pi-autoresearch`;
integrations: `@gwynnnplaine/pi-github`, `@feniix/pi-devtools`, `@piex-dev/dap`;
safety: `cc-safety-net`, `@oisin-ee/pi-guardrails`;
UX: `@juicesharp/rpiv-ask-user-question`; provider: `pi-nvidia-nim`.

> Only **one** memory package should be active. `pi-hermes-memory` is included;
> do not add `pi-memory` / `pi-hindsight` on top of it.

---

## What has actually been verified

CI (`.github/workflows/image.yml`) builds this exact Dockerfile and boots the
resulting container with a published port — the same path Railway takes:

| Check | How |
| --- | --- |
| Image builds | `docker/build-push-action` on every push (≈3.5 min) |
| 16 Pi packages resolve from `/data/.pi/agent` | `pi list` inside the container |
| `node-pty` native module loads | resolved via pi-web's module root (terminals work) |
| Council agents parse | 4 files with valid frontmatter, `model:` pinned |
| Session daemon + web server boot | socket created, `/api/pi-web/health` returns 200 |
| Public surface | `401` without auth, `200` with, `ok` on `/healthz` |
| Pi-Web not internet-facing | bound to `127.0.0.1`, not `0.0.0.0` |
| No volume mounted | loud warning, never a silent data loss |
| Redeploy keeps state | package top-up, auth and agents survive |

Run it yourself on any machine with Docker:

```bash
docker build -t pi-web-railway .
docker run --rm -e SMOKE_TEST=1 pi-web-railway /app/scripts/smoke-test.sh
```

---

## Deploy

### 1. Push this repo to GitHub

```bash
git init
git add .
git commit -m "pi-web on railway"
gh repo create pi-web-railway --private --source=. --push
```

(Windows: drag the folder into a new GitHub repo instead, or use PowerShell.)

### 2. Create the Railway service

railway.com → **New Project** → **Deploy from GitHub repo** → pick the repo.
`railway.json` makes Railway build the `Dockerfile`.

Build takes a few minutes (native `node-pty` compile + 16 packages).

### 3. Attach the volume — before first use

Service → **Volumes** → **New Volume** → mount path **`/data`**

If you start Pi-Web without this, `start.sh` prints a loud warning in the deploy
log, because everything will be lost on the next deploy.

### 4. Set variables

Minimum:

```
NVIDIA_NIM_API_KEY=nvapi-...        # build.nvidia.com → Get API Key
```

Optional but recommended — pin your own login:

```
AUTH_USERNAME=pi
AUTH_PASSWORD_HASH=sha256:<hex>
```

Generate the hash locally (no tools needed):

```bash
printf %s 'your-long-password' | sha256sum
```

If you set neither `AUTH_PASSWORD` nor `AUTH_PASSWORD_HASH`, the gateway
generates a strong password once, prints it **in the deploy log**, and saves it
to `/data/.pi-web-gateway-password` (mode 600). Read it later with a one-off
shell or from the Railway volume.

Other supported variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `HEAP_PERCENT` | `95` | % of the container memory limit given to V8 (20–100) |
| `SETUP_MODE` | `auth` | `direct` = proxy with no auth (private networks only) |
| `AUTH_PASSWORD_FILE` | `/data/.pi-web-gateway-password` | where the generated password is stored |
| `PI_WEB_PORT` | `8504` | loopback port for Pi-Web; must differ from `PORT` |
| `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / … | – | any other Pi provider |
| `TZ` | – | e.g. `Asia/Tehran` for log timestamps |

Advanced (set by the image; change only if you know why): `PI_CODING_AGENT_DIR`
(`/data/.pi/agent`), `PI_WEB_DATA_DIR` (`/data/pi-web`),
`PI_WEB_CONFIG`, `PI_WEB_DEFAULTS_CONFIG` (`/app/defaults.json`),
`PI_SEED_DIR`, `PI_WEB_HOST` (loopback by design). Do **not** set `PORT` —
Railway injects it.

### 5. Domain

Service → **Networking** → **Generate Domain** → open it.
You'll get a Basic Auth prompt, then the Pi-Web UI.

`/healthz` stays unauthenticated (Railway treats `401` as unhealthy) and only
returns `ok`.

---

## After it's up

1. **Add a project**: `+ Add Project` → path `/data/<your-repo>`, or clone a repo
   in the terminal tab first.
2. **Pick a model**: inside a session, `/model` → search `nvidia-nim/`.
   Verified IDs from the installed extension include:
   `nvidia-nim/z-ai/glm4.7`, `nvidia-nim/z-ai/glm5`,
   `nvidia-nim/moonshotai/kimi-k2.6`,
   `nvidia-nim/deepseek-ai/deepseek-v4-pro` (1M context),
   `nvidia-nim/qwen/qwen3-coder-480b-a35b-instruct`,
   `nvidia-nim/minimaxai/minimax-m3`.
3. **Make it the default** for new sessions: star it in the model picker. That
   writes `defaultProvider` / `defaultModel` to `/data/.pi/agent/settings.json`.

### Multi-model council

> **One key, one rate limit.** All four council roles use `NVIDIA_NIM_API_KEY`
> and the free NIM tier rate-limits per account. Three advisors in parallel can
> hit `429`. Run two at a time, or add a second provider and point one advisor
> at it (see `MULTI-MODEL-GUIDE.md`).


Four pi-subagents roles ship in `agents/` and are copied to
`/data/.pi/agent/agents/` on boot:

- `council-nim-glm` → `nvidia-nim/z-ai/glm4.7`
- `council-nim-kimi` → `nvidia-nim/moonshotai/kimi-k2.6`
- `council-nim-deepseek` → `nvidia-nim/deepseek-ai/deepseek-v4-pro`
- `council-chair` → synthesises the reports, never edits code

Ask naturally in a session:

```
/parallel "audit the auth flow" --agents council-nim-glm,council-nim-kimi,council-nim-deepseek
```

then hand the reports to `council-chair` for the decision memo. See
`MULTI-MODEL-GUIDE.md` for the exact prompts and per-run model overrides.

---

## Operations

**Logs** — `start.sh` writes Pi-Web's own logs into the volume:

```
/data/pi-web/logs/sessiond.log
/data/pi-web/logs/web.log
/data/pi-web/logs/install.log
```

**Redeploys** keep the volume, so projects, sessions, auth and Pi packages
survive. `start.sh` tops up any package a newer image adds; it never deletes
packages you installed later.

**Update Pi packages** — inside a session terminal:

```bash
/app/scripts/update.sh            # extension packages (stored on /data)
/app/scripts/update.sh --self     # also pi + pi-web (lasts until the next deploy)
```

Do not run `npm i -g ...` by hand: global packages live in the image layer, so
the upgrade looks successful and silently reverts on the next deploy.

**Keep editor/tool state across deploys** — run once inside the terminal:

```bash
/app/scripts/stop-all.sh
```

It moves Pi state, npm/npm cache, git config, SSH keys, and Rust/Go/Bun/Deno
caches onto `/data` and symlinks them back, then prints anything still living
outside the volume. Use `--dry-run` to see the plan first.

**Sizing** — `start.sh` reads the cgroup memory limit, gives V8 95% of it
(minus 256 MB above 4 GB) and leaves the rest to git, `node-pty` shells and
subagent children. On a 1 GB plan expect ~900 MB heap; on 8 GB ~7.5 GB.

Scale up before adding many parallel subagents: each child is a real Pi session.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Build rejected: `VOLUME` not supported | You re-added `VOLUME`; Railway forbids it. Delete the line. |
| Deploy "unhealthy" | Healthcheck path must be `/healthz` (see `railway.json`), and `start.sh` must be the CMD. |
| 401 loop / no login prompt | Set `AUTH_USERNAME` + `AUTH_PASSWORD_HASH`, or read the generated password from the deploy log. |
| UI loads, nothing streams | WebSocket upgrade blocked — you're in `SETUP_MODE=direct` behind another proxy, or the gateway was replaced. |
| `session daemon died` in the log | Read `/data/pi-web/logs/sessiond.log`. A missing `PI_WEB_DEFAULTS_CONFIG` file is fatal by design. |
| Terminal tab broken | `node-pty` did not build: the image needs `python3`/`make`/`g++` (already installed) and `npm install --allow-scripts=node-pty`. |
| Everything gone after deploy | No volume mounted at `/data`. |
| `No API key found for the selected model` | Set the provider key (e.g. `NVIDIA_NIM_API_KEY`) and redeploy. |

---

## Security model, in one paragraph

The container runs as **root** inside Railway's VM and Pi can execute arbitrary
shell commands, read `/data` and use your provider keys. The only thing between
the internet and that shell is the Basic-Auth gateway on `$PORT`; Pi-Web itself
binds to `127.0.0.1`. Use a long password, keep the volume private, and prefer
`SETUP_MODE=auth` unless you put the service on a private network (Tailscale,
WireGuard) yourself.
