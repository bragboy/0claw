#!/usr/bin/env node
// deepseek-proxy.mjs
//
// Localhost HTTP proxy that sits between ZeroClaw (and any in-container
// Claude CLI invocation) and DeepSeek's Anthropic-compatible endpoint.
// It rewrites every POST .../v1/messages request:
//
//   1. Injects `thinking: {type: "disabled"}` so deepseek-v4-flash returns
//      a single text block instead of a thinking + text pair.
//   2. Strips any historical `thinking` / `redacted_thinking` content blocks
//      from messages[].content so stale thinking content from past sessions
//      cannot trigger DeepSeek's "content[].thinking in the thinking mode
//      must be passed back to the API" 400 error.
//
// With these mutations the cheapest model (v4-flash, $0.14/M in, $0.28/M out)
// works on multi-turn conversations and never charges for reasoning tokens.
//
// Listens on 127.0.0.1 only; not exposed outside the container.
//
// Env:
//   DEEPSEEK_PROXY_PORT (default 8089)

import http from 'node:http';
import { Readable } from 'node:stream';

const UPSTREAM_HOST = 'https://api.deepseek.com';
const UPSTREAM_PATH_PREFIX = '/anthropic';
const PORT = parseInt(process.env.DEEPSEEK_PROXY_PORT || '8089', 10);

const SYSTEM_OVERRIDE = `ABSOLUTE OVERRIDE (private DM channel, allowlisted users only):
- Every user message in this channel gets a real, user-facing reply. NEVER
  emit "NO_REPLY", "NO_REPLY:", or any other suppression marker. The
  "prefer NO_REPLY when not addressed to the assistant" rule from the
  default system prompt does not apply here -- every message in this DM
  is addressed to you.
- Direct yes/no questions get a direct yes/no answer, even if you think
  the topic was already covered. Repeated questions get fresh answers
  from current state, never "already answered" silence.
- Cron / schedule answers: when asked "what crons", "what's scheduled",
  "list jobs", "any other reminders", or similar, the answer MUST be
  EXACTLY what \`cron_list\` returns -- no more, no less. Memory about
  what the user "wants" or previously requested is NOT evidence that a
  cron exists. If \`cron_list\` returns N jobs, your answer mentions
  exactly those N jobs. Never invent, infer, or recall jobs that the
  tool did not return. If \`cron_list\` returns nothing, reply
  "No cron jobs are scheduled".`;

function rewrite(body) {
  if (Array.isArray(body.messages)) {
    for (const m of body.messages) {
      if (Array.isArray(m.content)) {
        m.content = m.content.filter(
          (b) => b.type !== 'thinking' && b.type !== 'redacted_thinking'
        );
      }
    }
  }
  body.thinking = { type: 'disabled' };

  // Append our hard override to the system prompt. ZeroClaw's stock prompt
  // tells the model "prefer NO_REPLY when not addressed to the assistant",
  // which the model uses as an exit hatch in our DM channel even though
  // SOUL.md forbids it. Injecting at the proxy level guarantees the
  // override is present on every request, irrespective of session caches
  // or stale prompt assembly inside ZeroClaw.
  if (typeof body.system === 'string') {
    body.system = body.system + '\n\n' + SYSTEM_OVERRIDE;
  } else if (Array.isArray(body.system)) {
    body.system.push({ type: 'text', text: SYSTEM_OVERRIDE });
  } else {
    body.system = SYSTEM_OVERRIDE;
  }
  return body;
}

const server = http.createServer(async (req, res) => {
  if (req.url === '/_health') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('ok');
    return;
  }

  const chunks = [];
  for await (const c of req) chunks.push(c);
  const raw = Buffer.concat(chunks);

  let outBody = raw;
  if (req.method === 'POST' && req.url.endsWith('/v1/messages')) {
    try {
      const obj = JSON.parse(raw.toString('utf8'));
      rewrite(obj);
      outBody = Buffer.from(JSON.stringify(obj));
    } catch {
      // Non-JSON body: forward unchanged.
    }
  }

  const headers = { ...req.headers };
  delete headers.host;
  delete headers['content-length'];
  if (outBody.length > 0) headers['content-length'] = String(outBody.length);

  // ZeroClaw and the claude CLI POST to /v1/...; rewrite to upstream's
  // /anthropic/v1/... while leaving anything else (e.g. /_health probes) alone.
  const upstreamPath = req.url.startsWith('/v1/')
    ? UPSTREAM_PATH_PREFIX + req.url
    : req.url;

  let upstreamRes;
  try {
    upstreamRes = await fetch(UPSTREAM_HOST + upstreamPath, {
      method: req.method,
      headers,
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : outBody,
    });
  } catch (e) {
    res.writeHead(502, { 'content-type': 'text/plain' });
    res.end(`upstream error: ${e.message}`);
    return;
  }

  // Node's fetch() auto-decompresses, so the body bytes we forward are
  // uncompressed regardless of the upstream's Content-Encoding header. Drop
  // encoding/length headers that no longer match the actual payload, and
  // let Node re-chunk on its own. (Without this, ZeroClaw sees
  // `content-encoding: br` over already-decoded JSON and bails with
  // "error decoding response body".)
  const respHeaders = {};
  for (const [k, v] of upstreamRes.headers) {
    const lk = k.toLowerCase();
    if (lk === 'content-encoding' || lk === 'content-length' || lk === 'transfer-encoding') continue;
    respHeaders[k] = v;
  }
  res.writeHead(upstreamRes.status, respHeaders);

  if (upstreamRes.body) {
    Readable.fromWeb(upstreamRes.body).pipe(res);
  } else {
    res.end();
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(
    `deepseek-proxy listening on 127.0.0.1:${PORT} -> ${UPSTREAM_HOST}${UPSTREAM_PATH_PREFIX}`
  );
});
