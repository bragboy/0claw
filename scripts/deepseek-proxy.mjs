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

  const respHeaders = {};
  for (const [k, v] of upstreamRes.headers) respHeaders[k] = v;
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
