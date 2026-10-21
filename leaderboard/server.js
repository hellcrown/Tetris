// Tetris 全服排行榜（零依赖 Node，pm2 常驻 127.0.0.1:8787，nginx /tetris/api/ 反代）
// 数据：同目录 data.json，每个 uid 保留最好成绩；每 IP 提交限频 10 次/分
const http = require('http')
const fs = require('fs')
const path = require('path')

const PORT = 8787
const DATA_FILE = path.join(__dirname, 'data.json')
const MAX_ENTRIES = 5000
const POST_MAX = 10
const POST_WINDOW_MS = 60000

let entries = [] // [{uid, name, score, lines, time, ts}]
const postHits = new Map() // ip -> [ts]

function validEntry(e) {
  return !!e && typeof e.uid === 'string' && typeof e.name === 'string' &&
    Number.isFinite(e.score) && Number.isFinite(e.lines) && Number.isFinite(e.time)
}

function load() {
  try {
    const raw = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'))
    entries = Array.isArray(raw) ? raw.filter(validEntry) : []
  } catch (e) {
    entries = []
  }
}

function save() {
  const tmp = DATA_FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(entries))
  fs.renameSync(tmp, DATA_FILE)
}

function jsonHeaders() {
  return { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*' }
}

function send(res, code, obj) {
  res.writeHead(code, jsonHeaders())
  res.end(JSON.stringify(obj))
}

function cleanName(s) {
  if (typeof s !== 'string') return ''
  return s.replace(/[\u0000-\u001f\u007f]/g, '').replace(/\s+/g, ' ').trim().slice(0, 12)
}

function sorted() {
  return entries.slice().sort((a, b) => b.score - a.score || a.time - b.time || a.ts - b.ts)
}

function rateLimited(ip) {
  const now = Date.now()
  const arr = (postHits.get(ip) || []).filter(t => now - t < POST_WINDOW_MS)
  const limited = arr.length >= POST_MAX
  arr.push(now)
  postHits.set(ip, arr)
  return limited
}

// 惰性清理限频表
setInterval(() => {
  const now = Date.now()
  for (const [ip, arr] of postHits) {
    const keep = arr.filter(t => now - t < POST_WINDOW_MS)
    if (keep.length === 0) postHits.delete(ip)
    else postHits.set(ip, keep)
  }
}, 120000).unref()

function readBody(req, cb) {
  let size = 0
  let done = false
  const chunks = []
  req.on('data', c => {
    if (done) return
    size += c.length
    if (size > 4096) {
      done = true
      req.destroy()
      cb(null)
      return
    }
    chunks.push(c)
  })
  req.on('end', () => {
    if (done) return
    done = true
    try {
      cb(JSON.parse(Buffer.concat(chunks).toString('utf8')))
    } catch (e) {
      cb(null)
    }
  })
  req.on('error', () => {
    if (!done) {
      done = true
      cb(null)
    }
  })
}

const server = http.createServer((req, res) => {
  const xff = String(req.headers['x-forwarded-for'] || '')
  const ip = (xff.split(',').pop().trim()) || req.socket.remoteAddress || '?'
  const url = req.url || ''

  if (req.method === 'GET' && url === '/tetris/api/health') {
    return send(res, 200, { ok: true, players: entries.length })
  }

  if (req.method === 'GET' && url.startsWith('/tetris/api/top')) {
    const m = /[?&]limit=(\d+)/.exec(url)
    const limit = Math.min(50, Math.max(1, m ? +m[1] : 10))
    const top = sorted().slice(0, limit).map((e, i) => ({
      rank: i + 1,
      uid: e.uid,
      name: e.name,
      score: e.score,
      lines: e.lines,
      time: e.time
    }))
    return send(res, 200, { ok: true, total: entries.length, top })
  }

  if (req.method === 'POST' && url === '/tetris/api/score') {
    if (rateLimited(ip)) return send(res, 429, { ok: false, error: 'TOO_FAST' })
    return readBody(req, body => {
      if (!body || typeof body !== 'object') return send(res, 400, { ok: false, error: 'BAD_JSON' })
      const name = cleanName(body.name)
      const uid = typeof body.uid === 'string' ? body.uid : ''
      if (!/^[A-Za-z0-9-]{8,64}$/.test(uid)) return send(res, 400, { ok: false, error: 'BAD_UID' })
      if (name.length < 1) return send(res, 400, { ok: false, error: 'BAD_NAME' })
      const score = Math.floor(Number(body.score))
      const lines = Math.floor(Number(body.lines))
      const time = Math.floor(Number(body.time))
      if (!(score >= 0 && score <= 5000000)) return send(res, 400, { ok: false, error: 'BAD_SCORE' })
      if (!(lines >= 0 && lines <= 99999)) return send(res, 400, { ok: false, error: 'BAD_LINES' })
      if (!(time >= 5 && time <= 864000)) return send(res, 400, { ok: false, error: 'BAD_TIME' })

      const existing = entries.find(e => e.uid === uid)
      if (existing) {
        // 更好才覆盖（同分比用时）
        if (score > existing.score || (score === existing.score && time < existing.time)) {
          existing.name = name
          existing.score = score
          existing.lines = lines
          existing.time = time
          existing.ts = Date.now()
        } else {
          existing.name = name // 允许改名
        }
      } else {
        entries.push({ uid, name, score, lines, time, ts: Date.now() })
        if (entries.length > MAX_ENTRIES) {
          entries = sorted().slice(0, MAX_ENTRIES)
        }
      }
      save()
      const rank = sorted().findIndex(e => e.uid === uid) + 1
      return send(res, 200, { ok: true, rank })
    })
  }

  send(res, 404, { ok: false, error: 'NOT_FOUND' })
})

load()
server.listen(PORT, '127.0.0.1', () => console.log('tetris-leaderboard on 127.0.0.1:' + PORT))
