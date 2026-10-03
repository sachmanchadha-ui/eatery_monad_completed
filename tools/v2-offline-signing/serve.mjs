// Serves the V2 offline signing check over HTTPS on the local network, so phones on the same Wi-Fi
// can open it without a claude.ai login. HTTPS is required: browsers disable WebCrypto on plain
// http:// LAN addresses. The certificate is self-signed (.cert/), so each phone shows a warning once.
// Saved results are appended to results.jsonl next to this file.
//
//   node tools/v2-offline-signing/serve.mjs            (port 8443)
import { createServer } from 'node:https'
import { appendFileSync, existsSync, readFileSync } from 'node:fs'
import { networkInterfaces } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const PORT = Number(process.env.PORT || 8443)
const resultsFile = join(here, 'results.jsonl')
const page =
  '<!doctype html><html><head><meta charset="utf-8">' +
  '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"></head><body>' +
  readFileSync(join(here, 'offline-signing-check.html'), 'utf8') +
  '</body></html>'

const readResults = () =>
  existsSync(resultsFile)
    ? readFileSync(resultsFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)).reverse()
    : []

const send = (res, status, type, body) => {
  res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store' })
  res.end(body)
}

const server = createServer(
  { key: readFileSync(join(here, '.cert/key.pem')), cert: readFileSync(join(here, '.cert/cert.pem')) },
  (req, res) => {
    const url = new URL(req.url, 'https://local')
    if (req.method === 'GET' && url.pathname === '/') return send(res, 200, 'text/html; charset=utf-8', page)
    if (url.pathname === '/api/v2-results') {
      if (req.method === 'GET') return send(res, 200, 'application/json', JSON.stringify(readResults()))
      if (req.method === 'POST') {
        let body = ''
        req.on('data', (c) => {
          body += c
          if (body.length > 16_384) req.destroy()
        })
        req.on('end', () => {
          try {
            const run = JSON.parse(body)
            if (typeof run !== 'object' || Array.isArray(run) || !run) throw new Error('not an object')
            appendFileSync(resultsFile, JSON.stringify({ ...run, receivedAt: Date.now() }) + '\n')
            console.log(`saved result from ${run.label ?? 'unnamed phone'}`)
            send(res, 201, 'application/json', '{"ok":true}')
          } catch {
            send(res, 400, 'application/json', '{"error":"invalid result"}')
          }
        })
        return
      }
    }
    send(res, 404, 'text/plain', 'not found')
  },
)

server.listen(PORT, '0.0.0.0', () => {
  console.log('V2 offline signing check is up. Open on a phone on the same Wi-Fi:')
  for (const nets of Object.values(networkInterfaces())) {
    for (const n of nets ?? []) if (n.family === 'IPv4' && !n.internal) console.log(`  https://${n.address}:${PORT}/`)
  }
})
