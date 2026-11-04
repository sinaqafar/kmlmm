#!/usr/bin/env node
/**
 * Pi-Web auth gateway.
 *
 * Pi-Web ships with no authentication and Pi runs with full shell access, so a
 * public domain without auth means "anyone with the URL gets a shell and your
 * API keys". This puts HTTP Basic Auth in front of it on the only port Railway
 * routes public traffic to.
 *
 * WebSocket upgrades are proxied too: Pi-Web streams agent output and terminal
 * I/O over /api/machines/<id>/events.
 *
 * Zero npm dependencies, so it can never drift from the Node in this image.
 *
 * Env:
 *   PORT                 public port (Railway injects it)
 *   PI_WEB_PORT          local Pi-Web port (default 8504)
 *   SETUP_MODE=direct    proxy with NO auth (dangerous; for a private network only)
 *   AUTH_USERNAME        default "pi"
 *   AUTH_PASSWORD        plaintext password
 *   AUTH_PASSWORD_HASH   "sha256:<hex>" — takes precedence over AUTH_PASSWORD
 *                        generate: printf %s 'pw' | sha256sum
 *
 * With neither AUTH_PASSWORD nor AUTH_PASSWORD_HASH set, a strong password is
 * generated once, written to /data/.pi-web-gateway-password (mode 600) and
 * printed to the deploy log. The service is never accidentally left open.
 */
"use strict";

const http = require("node:http");
const net = require("node:net");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const PORT = Number(process.env.PORT || 8080);
const UPSTREAM_HOST = "127.0.0.1";
const UPSTREAM_PORT = Number(process.env.PI_WEB_PORT || 8504);
const USERNAME = process.env.AUTH_USERNAME || "pi";
const DIRECT = String(process.env.SETUP_MODE || "").toLowerCase() === "direct";
const PASSWORD_FILE = process.env.AUTH_PASSWORD_FILE || "/data/.pi-web-gateway-password";

const sha256 = (s) => crypto.createHash("sha256").update(s, "utf8").digest("hex");

function safeEqual(a, b) {
  const ab = Buffer.from(String(a), "utf8");
  const bb = Buffer.from(String(b), "utf8");
  if (ab.length !== bb.length) return false;
  return crypto.timingSafeEqual(ab, bb);
}

// ── credentials ─────────────────────────────────────────────────────────────
function resolveCredentials() {
  let hash = (process.env.AUTH_PASSWORD_HASH || "").trim();
  let plain = process.env.AUTH_PASSWORD || "";

  if (hash && !hash.startsWith("sha256:")) {
    console.error(
      "AUTH_PASSWORD_HASH must be in the form sha256:<hex>.\n" +
        "Generate it with:  printf %s 'your-password' | sha256sum"
    );
    process.exit(1);
  }
  if (hash) return { hash: hash.slice(7).toLowerCase() };

  if (!plain) {
    try {
      plain = fs.readFileSync(PASSWORD_FILE, "utf8").trim();
    } catch {
      plain = "";
    }
    let generated = false;
    if (!plain) {
      plain = crypto.randomBytes(18).toString("base64url");
      generated = true;
    }
    if (generated) {
      try {
        fs.mkdirSync(path.dirname(PASSWORD_FILE), { recursive: true });
        fs.writeFileSync(PASSWORD_FILE, plain, { mode: 0o600 });
      } catch (err) {
        console.warn(`could not persist generated password: ${err.message}`);
      }
      console.log("──────────────────────────────────────────────────────────────");
      console.log(" Pi-Web gateway: no AUTH_PASSWORD / AUTH_PASSWORD_HASH set.");
      console.log(" Generated credentials (shown once, saved to the volume):");
      console.log("");
      console.log(`   username: ${USERNAME}`);
      console.log(`   password: ${plain}`);
      console.log("");
      try {
        // A long-lived token is not needed: the operator only has to read it
        // once. Keep a short-lived copy where the Pi-Web terminal can see it.
        const otp = `${PASSWORD_FILE}.otp`;
        fs.writeFileSync(otp, `${USERNAME}:${plain}\n`, { mode: 0o600 });
        setTimeout(() => { try { fs.unlinkSync(otp); } catch {} }, 30 * 60 * 1000).unref?.();
        console.log(` Visible for 30 min at ${otp}`);
      } catch {}
      console.log(` Re-read later:  cat ${PASSWORD_FILE}`);
      console.log(" Pin your own:   printf %s 'pw' | sha256sum  → AUTH_PASSWORD_HASH");
      console.log("──────────────────────────────────────────────────────────────");
    }
  }
  return { hash: sha256(plain) };
}

const CREDS = DIRECT ? null : resolveCredentials();

function authorized(req) {
  if (DIRECT) return true;
  const header = req.headers.authorization || "";
  if (!header.startsWith("Basic ")) return false;
  let decoded;
  try {
    decoded = Buffer.from(header.slice(6), "base64").toString("utf8");
  } catch {
    return false;
  }
  const sep = decoded.indexOf(":");
  if (sep < 0) return false;
  if (!safeEqual(decoded.slice(0, sep), USERNAME)) return false;
  return safeEqual(sha256(decoded.slice(sep + 1)), CREDS.hash);
}

function unauthorized(res) {
  res.writeHead(401, {
    "WWW-Authenticate": 'Basic realm="Pi-Web", charset="UTF-8"',
    "Content-Type": "text/plain; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end("Authentication required.\n");
}

// ── http proxy ──────────────────────────────────────────────────────────────
const HOP_BY_HOP = new Set([
  "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
  "te", "trailer", "transfer-encoding", "upgrade",
]);

function forwardHeaders(req) {
  const out = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (!HOP_BY_HOP.has(k) && k !== "authorization" && k !== "host") out[k] = v;
  }
  out.host = `${UPSTREAM_HOST}:${UPSTREAM_PORT}`;
  out["x-forwarded-host"] = req.headers.host || "";
  out["x-forwarded-proto"] = req.headers["x-forwarded-proto"] || "https";
  out["x-forwarded-for"] = req.socket.remoteAddress || "";
  return out;
}

// The platform load balancer reuses upstream connections. Node's 5s default
// keepAliveTimeout closes them mid-flight behind a proxy, which shows up as
// sporadic 502s. Keep them open past any plausible proxy idle timeout.
const KEEP_ALIVE_MS = 75_000;

const server = http.createServer((req, res) => {
  const startedAt = Date.now();
  res.on("finish", () => {
    const ms = Date.now() - startedAt;
    if (ms > 30_000) {
      console.warn(`slow request ${req.method} ${req.url} took ${ms}ms`);
    }
  });
  // Railway's healthcheck treats 401 as unhealthy, so liveness stays public.
  if (req.url === "/healthz") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok\n");
    return;
  }
  if (!authorized(req)) {
    unauthorized(res);
    return;
  }

  const proxyReq = http.request(
    {
      host: UPSTREAM_HOST,
      port: UPSTREAM_PORT,
      method: req.method,
      path: req.url,
      headers: forwardHeaders(req),
      agent: upstreamAgent,
    },
    (proxyRes) => {
      const headers = { ...proxyRes.headers };
      for (const k of HOP_BY_HOP) delete headers[k];
      res.writeHead(proxyRes.statusCode || 502, headers);
      proxyRes.pipe(res);
    }
  );

  proxyReq.on("error", (err) => {
    if (!res.headersSent) {
      res.writeHead(502, { "Content-Type": "text/plain; charset=utf-8" });
      res.end(`Pi-Web upstream error: ${err.message}\n`);
    } else {
      res.destroy();
    }
  });

  // A closed tab or a dropped platform connection must abort the upstream
  // request too. Otherwise Pi keeps generating (and billing) for a conversation
  // nobody is reading, and an agent can keep editing files after you "stop".
  const abortUpstream = () => {
    if (!proxyReq.destroyed) proxyReq.destroy();
  };
  req.on("aborted", abortUpstream);
  res.on("close", () => {
    if (!res.writableEnded) abortUpstream();
  });

  req.pipe(proxyReq);
});

// ── websocket / raw upgrade proxy ───────────────────────────────────────────
server.on("upgrade", (req, socket, head) => {
  if (!authorized(req)) {
    socket.write(
      "HTTP/1.1 401 Unauthorized\r\n" +
        'WWW-Authenticate: Basic realm="Pi-Web", charset="UTF-8"\r\n' +
        "Connection: close\r\n\r\n"
    );
    socket.destroy();
    return;
  }

  const upstream = net.connect(UPSTREAM_PORT, UPSTREAM_HOST, () => {
    const lines = [`${req.method} ${req.url} HTTP/1.1`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      const name = req.rawHeaders[i];
      const value = req.rawHeaders[i + 1];
      if (name.toLowerCase() === "authorization") continue;
      if (name.toLowerCase() === "host") {
        lines.push(`Host: ${UPSTREAM_HOST}:${UPSTREAM_PORT}`);
        continue;
      }
      lines.push(`${name}: ${value}`);
    }
    lines.push("", "");
    upstream.write(lines.join("\r\n"));
    if (head && head.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });

  upstream.on("error", () => socket.destroy());
  socket.on("error", () => upstream.destroy());
  socket.on("close", () => upstream.destroy());
});

server.on("error", (err) => {
  if (err && err.code === "EADDRINUSE") {
    console.error(
      `FATAL: port ${PORT} is already in use. Railway injects PORT; if you set ` +
        `PORT yourself, unset it and let Railway choose.`
    );
  } else {
    console.error(`FATAL: gateway server error: ${err && err.message}`);
  }
  process.exit(1);
});

// Recycle idle upstream sockets so a half-closed one is never reused.
const upstreamAgent = new http.Agent({ keepAlive: true, timeout: KEEP_ALIVE_MS });
upstreamAgent.on("free", (_socket, options) => {
  if (options && typeof options === "object") options.reusedSocket = true;
});

server.on("clientError", (err, socket) => {
  if (socket.writable) socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
});

server.keepAliveTimeout = KEEP_ALIVE_MS;
server.headersTimeout = KEEP_ALIVE_MS + 5_000;
server.requestTimeout = 0; // agent streams and long tool runs legitimately take minutes

server.listen(PORT, "0.0.0.0", () => {
  console.log(
    `Pi-Web gateway on 0.0.0.0:${PORT} → ${UPSTREAM_HOST}:${UPSTREAM_PORT}` +
      (DIRECT ? "  [NO AUTH]" : `  [basic auth: ${USERNAME}]`)
  );
});
