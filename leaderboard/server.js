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

// APK 在线更新：apk/ 目录下放 tetris-latest.apk + version.json（code/name/file）
const APK_DIR = path.join(__dirname, 'apk')

// 每日挑战：种子由日期决定（全服同一天同一序列）；成绩按日存 data-daily.json
const DAILY_FILE = path.join(__dirname, 'data-daily.json')
let dailyStore = { day: '', entries: [] } // entries: [{uid,name,score,lines,time,ts}]

function todayStr() {
  const d = new Date()
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0')
}
function dailySeed() {
  // 与客户端回退公式一致：YYYYMMDD 取模（服务器在线时客户端以服务器值为准）
  return Number(todayStr().replace(/-/g, '')) % 2147483647
}
function loadDaily() {
  try {
    const d = JSON.parse(fs.readFileSync(DAILY_FILE, 'utf8'))
    if (d.day === todayStr()) dailyStore = d
  } catch (e) { }
}
function saveDaily() {
  const tmp = DAILY_FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(dailyStore))
  fs.renameSync(tmp, DAILY_FILE)
}

const server = http.createServer((req, res) => {
  const xff = String(req.headers['x-forwarded-for'] || '')
  const ip = (xff.split(',').pop().trim()) || req.socket.remoteAddress || '?'
  const url = req.url || ''

  // QML 热更补丁：元数据单一真源是 apk/patch/patch.json（ver/minApk）。
  // /version 响应自动注入 qmlVer/qmlMinApk（客户端只查 /version，避免每次拉 QML 全文）；
  // /patch/info 按需返回 QML 全文，客户端 saveText 写入 files/patch/Main.qml 重启生效
  const patchMeta = (() => {
    try {
      const p = JSON.parse(fs.readFileSync(path.join(APK_DIR, 'patch', 'patch.json'), 'utf8'))
      return { qmlVer: p.ver || 0, qmlMinApk: p.minApk || 0 }
    } catch (e) {
      return { qmlVer: 0, qmlMinApk: 0 }
    }
  })()
  if (req.method === 'GET' && url.split('?')[0] === '/tetris/api/patch/info') {
    try {
      const qml = fs.readFileSync(path.join(APK_DIR, 'patch', 'Main.qml'), 'utf8')
      return send(res, 200, { ok: true, ...patchMeta, qml: qml })
    } catch (e) {
      return send(res, 200, { ok: true, qmlVer: 0, qmlMinApk: 0 })
    }
  }
  if (req.method === 'GET' && url.split('?')[0] === '/tetris/api/version') {
    try {
      const meta = JSON.parse(fs.readFileSync(path.join(APK_DIR, 'version.json'), 'utf8'))
      if (!meta.size && meta.file) {
        // size 缺失/为 0 时按 APK 实际体积补：客户端用它免重复下载已缓存的安装包
        try { meta.size = fs.statSync(path.join(APK_DIR, meta.file)).size } catch (e) { }
      }
      return send(res, 200, { ...meta, ...patchMeta })
    } catch (e) {
      return send(res, 200, { ok: true, code: 0, name: '', file: '', ...patchMeta })
    }
  }

  if (req.method === 'GET' && url.startsWith('/tetris/api/apk/')) {
    const name = url.slice('/tetris/api/apk/'.length).replace(/[\/\\]/g, '')
    const f = path.join(APK_DIR, name)
    if (!fs.existsSync(f)) return send(res, 404, { ok: false, error: 'NO_APK' })
    res.writeHead(200, {
      'Content-Type': 'application/vnd.android.package-archive',
      'Content-Length': fs.statSync(f).size,
      'Content-Disposition': 'attachment; filename="' + name + '"',
      'X-Accel-Buffering': 'no'
    })
    fs.createReadStream(f).pipe(res)
    return
  }

  if (req.method === 'GET' && url === '/tetris/api/health') {
    return send(res, 200, { ok: true, players: entries.length })
  }

  // 每日挑战：种子 / 成绩提交 / 今日榜
  if (req.method === 'GET' && url.split('?')[0] === '/tetris/api/daily') {
    if (dailyStore.day !== todayStr()) loadDaily()
    if (dailyStore.day !== todayStr()) dailyStore = { day: todayStr(), entries: [] }
    return send(res, 200, { ok: true, date: todayStr(), seed: dailySeed(), players: dailyStore.entries.length })
  }
  if (req.method === 'POST' && url === '/tetris/api/daily/score') {
    if (rateLimited(ip)) return send(res, 429, { ok: false, error: 'TOO_FAST' })
    return readBody(req, body => {
      if (!body || typeof body !== 'object') return send(res, 400, { ok: false, error: 'BAD_JSON' })
      const uid = typeof body.uid === 'string' && /^[A-Za-z0-9-]{8,64}$/.test(body.uid) ? body.uid : ''
      const name = cleanName(body.name)
      const score = Math.floor(Number(body.score))
      const lines = Math.floor(Number(body.lines))
      const time = Math.floor(Number(body.time))
      if (!uid || name.length < 1) return send(res, 400, { ok: false, error: 'BAD_INPUT' })
      if (!(score >= 0 && score <= 5000000)) return send(res, 400, { ok: false, error: 'BAD_SCORE' })
      if (dailyStore.day !== todayStr()) dailyStore = { day: todayStr(), entries: [] }
      const ex = dailyStore.entries.find(e => e.uid === uid)
      if (ex) {
        if (score > ex.score) {
          ex.score = score; ex.lines = lines; ex.time = time; ex.ts = Date.now()
        } else if (name !== ex.name) {
          ex.name = name
        }
      } else {
        dailyStore.entries.push({ uid, name, score, lines, time, ts: Date.now() })
      }
      saveDaily()
      const rank = dailyStore.entries.slice().sort((a, b) => b.score - a.score || a.time - b.time).findIndex(e => e.uid === uid) + 1
      return send(res, 200, { ok: true, rank })
    })
  }
  if (req.method === 'GET' && url.split('?')[0] === '/tetris/api/daily/top') {
    if (dailyStore.day !== todayStr()) loadDaily()
    if (dailyStore.day !== todayStr()) dailyStore = { day: todayStr(), entries: [] }
    const top = dailyStore.entries.slice()
      .sort((a, b) => b.score - a.score || a.time - b.time)
      .slice(0, 10)
      .map((e, i) => ({ rank: i + 1, name: e.name, score: e.score, lines: e.lines, time: e.time }))
    return send(res, 200, { ok: true, date: todayStr(), total: dailyStore.entries.length, top })
  }

  // 下载页（推广落地页：下载按钮 + 玩法亮点 + 毒舌示例）
  if (req.method === 'GET' && (url.split('?')[0] === '/tetris/api/download' || url.split('?')[0] === '/tetris/download')) {
    let ver = ''
    try { ver = JSON.parse(fs.readFileSync(path.join(APK_DIR, 'version.json'), 'utf8')).name || '' } catch (e) { }
    const html = `<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>俄罗斯方块 · 下载</title>
<style>
body{margin:0;background:#16181c;color:#f5f1e8;font-family:system-ui,sans-serif;display:flex;justify-content:center}
.card{max-width:420px;width:100%;padding:36px 22px;box-sizing:border-box}
h1{font-size:26px;margin:0 0 6px}.sub{color:#8a8a8a;font-size:13px;margin-bottom:26px}
.dl{display:block;text-align:center;background:#2e7d5b;color:#fff;text-decoration:none;font-size:18px;font-weight:bold;
padding:16px;border-radius:14px;margin:18px 0 8px}
.tip{color:#666;font-size:12px;text-align:center;margin-bottom:26px}
.f{background:#1f2429;border-radius:12px;padding:14px 16px;margin:10px 0;font-size:14px;line-height:1.7}
.f b{color:#ffd95a}
.roast{background:#241f1a;border-left:3px solid #ff9e3d;border-radius:8px;padding:12px 14px;margin:10px 0;font-size:13px;color:#ffd0a0;line-height:1.6}
.v{color:#555;font-size:12px;text-align:center;margin-top:24px}
</style></head><body><div class="card">
<h1>俄罗斯方块</h1>
<div class="sub">经典落块 · 毒舌评分 · 每日挑战 · 全服排行</div>
<a class="dl" href="/tetris/api/apk/tetris-latest.apk">⬇ 下载 Android 版（约 50MB）</a>
<div class="tip">安装时允许「未知来源应用」即可；更新直接在游戏里点</div>
<div class="f"><b>🎮 每日挑战</b><br>全服每天同一串方块，看谁稳——今天你排第几？</div>
<div class="f"><b>🏅 24 枚成就 + 成长链</b><br>极限救场、大满贯、万分俱乐部……永久收藏</div>
<div class="f"><b>👁 护眼模式</b><br>低饱和配色 · 平滑下落 · 20 分钟休息提醒，玩久不流泪</div>
<div class="roast">结算示例 · F 档：『F——Fine，仅指你退场的手速』<br>本局亮点：『0 行。棋盘表示它今天没被用过』</div>
<div class="roast">结算示例 · A+ 档：『满分？这是台机器在打吧？』</div>
<div class="v">v${ver} · 服务端数据仅存最高分与当日挑战成绩</div>
</div></body></html>`
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
    return res.end(html)
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

      // uid 过户（旧随机 uid → 设备稳定 uid）：新 uid 不存在时把旧条目并入，
      // 老玩家升级后成绩不丢、不产生同名分家
      const adopt = typeof body.adopt === 'string' && /^[A-Za-z0-9-]{8,64}$/.test(body.adopt)
        ? body.adopt : ''
      if (adopt && adopt !== uid && !entries.some(e => e.uid === uid)) {
        const old = entries.find(e => e.uid === adopt)
        if (old) {
          old.uid = uid
          save()
        }
      }

      const existing = entries.find(e => e.uid === uid)
      if (existing) {
        // 更好才覆盖（同分比用时）。行数不得倒退：旧客户端补录发过 0行/5秒 的假数据，
        // 没这道防线时“同分+更短时间”会把真实行数洗成 0
        if (score > existing.score ||
            (score === existing.score && time < existing.time && lines >= existing.lines)) {
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
loadDaily()
server.listen(PORT, '127.0.0.1', () => console.log('tetris-leaderboard on 127.0.0.1:' + PORT))
