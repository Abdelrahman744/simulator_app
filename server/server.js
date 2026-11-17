// server/server.js - Simulated teaching lab server
// Uses only Node.js built-in modules (http, zlib). Zero npm packages.

const http = require('http');
const zlib = require('zlib');

const PORT = 8080;
const HOST = '0.0.0.0';

let mode = 'normal';
let flakyFailures = 0;

const VALID_MODES = ['normal', 'slow', 'flaky', 'hangs'];

const server = http.createServer((req, res) => {
  // Prevent server crashes when a client disconnects mid-request (e.g., on timeout)
  req.on('error', () => {});
  res.on('error', () => {});

  try {
    const url = new URL(req.url, 'http://localhost');

    // Enable CORS for testing flexibility
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    // GET /mode - return current mode
    if (req.method === 'GET' && url.pathname === '/mode') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ mode }));
      console.log(`[${mode}] GET /mode -> 200`);
      return;
    }

    // POST /mode?set=normal|slow|flaky|hangs - update mode & reset flaky counter
    if (req.method === 'POST' && url.pathname === '/mode') {
      const targetMode = url.searchParams.get('set');
      if (targetMode && VALID_MODES.includes(targetMode)) {
        mode = targetMode;
        flakyFailures = 0;
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ mode }));
        console.log(`[server] Mode changed to "${mode}" (flakyFailures reset to 0)`);
      } else {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: `Unknown mode. Valid modes: ${VALID_MODES.join(', ')}` }));
        console.log(`[server] Invalid mode change attempt: "${targetMode}" -> 400`);
      }
      return;
    }

    // GET /data - returns items according to current mode
    if (req.method === 'GET' && url.pathname === '/data') {
      const sendGzipSuccess = () => {
        try {
          const payload = JSON.stringify({
            servedAt: new Date().toISOString(),
            items: ['Item 1', 'Item 2', 'Item 3', 'Item 4', 'Item 5'],
          });
          const gzipped = zlib.gzipSync(Buffer.from(payload, 'utf-8'));
          res.writeHead(200, {
            'Content-Type': 'application/json',
            'Content-Encoding': 'gzip',
            'Content-Length': gzipped.length,
          });
          res.end(gzipped);
        } catch (_) {}
      };

      if (mode === 'normal') {
        console.log('[normal] GET /data -> 200 (immediate)');
        sendGzipSuccess();
        return;
      }

      if (mode === 'slow') {
        console.log('[slow] GET /data -> waiting 2s...');
        setTimeout(() => {
          console.log('[slow] GET /data -> 200 after 2s delay');
          sendGzipSuccess();
        }, 2000);
        return;
      }

      if (mode === 'flaky') {
        if (flakyFailures < 2) {
          flakyFailures++;
          console.log(`[flaky] GET /data -> 503 (failure ${flakyFailures} of 2)`);
          res.writeHead(503, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Service Unavailable (simulated flaky failure)' }));
        } else {
          flakyFailures = 0;
          console.log('[flaky] GET /data -> 200 (attempt 3 succeeded, counter reset to 0)');
          sendGzipSuccess();
        }
        return;
      }

      if (mode === 'hangs') {
        console.log('[hangs] GET /data -> holding connection open (never replying)');
        // Close after 60s as cleanup; never throw
        const timeoutId = setTimeout(() => {
          try {
            res.destroy();
          } catch (_) {}
        }, 60000);

        req.on('close', () => {
          clearTimeout(timeoutId);
          console.log('[hangs] Client disconnected or timed out');
        });
        return;
      }
    }

    // Default 404 for unknown endpoints
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not Found' }));
    console.log(`[server] ${req.method} ${url.pathname} -> 404`);
  } catch (err) {
    console.error('[server] Internal error handling request:', err);
    try {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Internal Server Error' }));
    } catch (_) {}
  }
});

server.listen(PORT, HOST, () => {
  console.log(`=========================================`);
  console.log(`Resilient App Lab Server`);
  console.log(`Listening on http://${HOST}:${PORT}`);
  console.log(`Available modes: ${VALID_MODES.join(', ')} (default: ${mode})`);
  console.log(`=========================================`);
});
