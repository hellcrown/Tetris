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

// 每日挑战：种子由日期决定（全服同一天同一序列）；成绩按日存 data-daily.json；
// 跨天时前一天第一名归档进 winners.json（冠军称号/成就数据源）
const DAILY_FILE = path.join(__dirname, 'data-daily.json')
const WINNERS_FILE = path.join(__dirname, 'winners.json')
let dailyStore = { day: '', entries: [] } // entries: [{uid,name,score,lines,time,ts}]
let winners = [] // [{date, uid, name, score}]

function todayStr() {
  const d = new Date()
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0')
}
function dailySeed() {
  // 与客户端回退公式一致：YYYYMMDD 取模（服务器在线时客户端以服务器值为准）
  return Number(todayStr().replace(/-/g, '')) % 2147483647
}
function loadDaily() {
  // 无条件采用文件内容（哪怕是昨天/更早的）：跨天归档由 rollDailyIfNeeded 统一处理，
  // 若此处按"等于今天"过滤，凌晨重启会把昨天的榜和冠军一起丢掉
  try {
    const d = JSON.parse(fs.readFileSync(DAILY_FILE, 'utf8'))
    if (d && Array.isArray(d.entries)) dailyStore = d
  } catch (e) { }
}
function saveDaily() {
  const tmp = DAILY_FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(dailyStore))
  fs.renameSync(tmp, DAILY_FILE)
}
function loadWinners() {
  try {
    const w = JSON.parse(fs.readFileSync(WINNERS_FILE, 'utf8'))
    if (Array.isArray(w)) winners = w
  } catch (e) { }
}
function saveWinners() {
  const tmp = WINNERS_FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(winners))
  fs.renameSync(tmp, WINNERS_FILE)
}
// 跨天归档：前一天第一名记入 winners（幂等：同日只归档一次），然后重置当日榜
function rollDailyIfNeeded() {
  const today = todayStr()
  if (dailyStore.day && dailyStore.day !== today && dailyStore.entries.length > 0) {
    const top = dailyStore.entries.slice().sort((a, b) => b.score - a.score || a.time - b.time)[0]
    if (top && !winners.some(w => w.date === dailyStore.day)) {
      winners.push({ date: dailyStore.day, uid: top.uid, name: top.name, score: top.score })
      saveWinners()
    }
  }
  if (dailyStore.day !== today) dailyStore = { day: today, entries: [] }
}

// ---- 日活统计：客户端每次启动的版本检查带 uid（天然活跃心跳），按日聚合 ----
const STATS_FILE = path.join(__dirname, 'stats.json')
let statsStore = { dau: {} } // dau: { 'YYYY-MM-DD': { uids: [], ips: [], launches: n } }

function loadStats() {
  try {
    const s = JSON.parse(fs.readFileSync(STATS_FILE, 'utf8'))
    if (s && s.dau) statsStore = s
  } catch (e) { }
}
function saveStats() {
  const tmp = STATS_FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(statsStore))
  fs.renameSync(tmp, STATS_FILE)
}
// uid 可识别用户按 uid 去重；匿名设备按 IP 近似。DAU = max(两者)（识别用户是 IP 的子集）
function recordActivity(ip, uid) {
  const day = todayStr()
  if (!statsStore.dau[day]) statsStore.dau[day] = { uids: [], ips: [], launches: 0 }
  const d = statsStore.dau[day]
  if (typeof uid === 'string' && /^[A-Za-z0-9-]{8,64}$/.test(uid) && !d.uids.includes(uid))
    d.uids.push(uid)
  if (ip && !d.ips.includes(ip)) d.ips.push(ip)
  d.launches++
  const keys = Object.keys(statsStore.dau).sort()   // 只留 30 天
  while (keys.length > 30) delete statsStore.dau[keys.shift()]
  saveStats()
}
function dauNumber(day) {
  const d = statsStore.dau[day]
  return d ? Math.max(d.uids.length, d.ips.length) : 0
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
      // 日活心跳：每次启动的版本检查（uid 可选参数）
      const uq = /[?&]uid=([A-Za-z0-9-]{8,64})/.exec(url)
      recordActivity(ip, uq ? uq[1] : '')
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

  // 每日挑战：种子 / 成绩提交 / 今日榜 / 冠军档案
  if (req.method === 'GET' && url.split('?')[0] === '/tetris/api/daily') {
    rollDailyIfNeeded()
    const y = new Date(Date.now() - 86400000)
    const yesterday = y.getFullYear() + '-' + String(y.getMonth() + 1).padStart(2, '0') + '-' + String(y.getDate()).padStart(2, '0')
    const winner = winners.find(w => w.date === yesterday) || null
    return send(res, 200, { ok: true, date: todayStr(), seed: dailySeed(), players: dailyStore.entries.length, winner: winner })
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
      rollDailyIfNeeded()
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
    rollDailyIfNeeded()
    const top = dailyStore.entries.slice()
      .sort((a, b) => b.score - a.score || a.time - b.time)
      .slice(0, 10)
      .map((e, i) => ({ rank: i + 1, uid: e.uid, name: e.name, score: e.score, lines: e.lines, time: e.time }))
    return send(res, 200, { ok: true, date: todayStr(), total: dailyStore.entries.length, top })
  }
  if (req.method === 'GET' && url.split('?')[0] === '/tetris/api/winners') {
    return send(res, 200, { ok: true, winners: winners })
  }

  // ---- 数据仪表盘：JSON 数据 + 交互页（30s 自动刷新）----
  function statsPayload() {
    rollDailyIfNeeded()
    const dau = []
    for (let i = 6; i >= 0; i--) {
      const d = new Date(Date.now() - i * 86400000)
      const ds = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0')
      const rec = statsStore.dau[ds] || { uids: [], ips: [], launches: 0 }
      dau.push({ date: ds.slice(5), dau: Math.max(rec.uids.length, rec.ips.length), launches: rec.launches })
    }
    const top = entries.slice().sort((a, b) => b.score - a.score || a.time - b.time).slice(0, 10)
      .map((e, i) => ({ rank: i + 1, name: e.name, score: e.score, lines: e.lines, time: e.time }))
    const daily = dailyStore.entries.slice().sort((a, b) => b.score - a.score || a.time - b.time).slice(0, 10)
      .map((e, i) => ({ rank: i + 1, name: e.name, score: e.score, lines: e.lines, time: e.time }))
    let ver = ''
    try { ver = JSON.parse(fs.readFileSync(path.join(APK_DIR, 'version.json'), 'utf8')).name || '' } catch (e) { }
    return {
      ok: true, today: todayStr(), version: ver, dau,
      todayDetail: {
        dau: dauNumber(todayStr()),
        launches: (statsStore.dau[todayStr()] || {}).launches || 0,
        players: entries.length, dailyPlayers: dailyStore.entries.length
      },
      top, daily,
      winners: winners.slice(-10).reverse(),
      now: Date.now()
    }
  }
  if (req.method === 'GET' && url.split('?')[0] === '/tetris/api/stats') {
    return send(res, 200, statsPayload())
  }
  if (req.method === 'GET' && (url.split('?')[0] === '/tetris/stats' || url.split('?')[0] === '/tetris/api/dashboard')) {
    const html = `<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>俄罗斯方块 · 数据面板</title>
<style>
body{margin:0;background:#12151a;color:#e8e6e0;font-family:system-ui,sans-serif}
.wrap{max-width:900px;margin:0 auto;padding:22px 16px 60px}
h1{font-size:20px;margin:0 0 4px}.sub{color:#777;font-size:12px;margin-bottom:18px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:10px;margin-bottom:22px}
.card{background:#1c2128;border-radius:10px;padding:12px 14px}
.card b{display:block;font-size:26px;color:#ffd95a}
.card span{color:#888;font-size:12px}
h2{font-size:15px;color:#ffd95a;margin:20px 0 8px}
.bars{display:flex;align-items:flex-end;gap:8px;height:110px;background:#1c2128;border-radius:10px;padding:12px}
.bar{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:flex-end;height:100%}
.bar i{width:70%;background:linear-gradient(180deg,#7fd6a4,#2e7d5b);border-radius:4px 4px 0 0;min-height:2px;font-style:normal;position:relative}
.bar i b{position:absolute;top:-20px;left:50%;transform:translateX(-50%);color:#ffd95a;font-size:12px}
.bar span{color:#777;font-size:10px;margin-top:6px}
table{width:100%;border-collapse:collapse;background:#1c2128;border-radius:10px;overflow:hidden;font-size:13px}
th,td{padding:8px 10px;text-align:left;border-bottom:1px solid #262c34}
th{color:#888;font-weight:normal;font-size:12px}
tr:last-child td{border-bottom:none}
td.r{color:#ffd95a;width:36px}
.me{color:#7fd6a4}
.cols{display:grid;grid-template-columns:1fr 1fr;gap:14px}
@media(max-width:640px){.cols{grid-template-columns:1fr}}
.dl{display:block;text-align:center;background:#2e7d5b;color:#fff;text-decoration:none;font-size:16px;font-weight:bold;padding:14px;border-radius:12px;margin-top:8px}
.empty{color:#666;padding:14px;font-size:13px}
#tick{color:#555;font-size:11px;float:right}
</style></head><body><div class="wrap">
<h1>📊 俄罗斯方块 · 数据面板</h1><div class="sub">blood-table.top · 自动刷新 30s <span id="tick"></span></div>
<div class="cards">
<div class="card"><b id="dau">–</b><span>今日日活</span></div>
<div class="card"><b id="launches">–</b><span>今日启动</span></div>
<div class="card"><b id="players">–</b><span>总榜玩家</span></div>
<div class="card"><b id="dailyPlayers">–</b><span>今日挑战</span></div>
<div class="card"><b id="ver">–</b><span>当前版本</span></div>
</div>
<h2>近 7 日日活</h2><div class="bars" id="bars"></div>
<div class="cols">
<div><h2>🏆 总榜 TOP10</h2><table id="top"><tr><td class="empty">加载中…</td></tr></table></div>
<div><h2>⚡ 今日挑战</h2><table id="daily"><tr><td class="empty">加载中…</td></tr></table></div>
</div>
<h2>👑 冠军档案（近 10 天）</h2><table id="winners"><tr><td class="empty">加载中…</td></tr></table>
<h2>📥 安装包</h2>
<a class="dl" href="/tetris/api/apk/tetris-latest.apk">⬇ 下载 Android 版（v<span id="ver2"></span>）</a>
</div>
<script>
function fmtT(s){if(!s)return'—';const m=Math.floor(s/60),ss=s%60;return m+':'+String(ss).padStart(2,'0')}
function board(el,rows,name){
if(!rows||!rows.length){el.innerHTML='<tr><td class="empty">暂无记录</td></tr>';return}
el.innerHTML='<tr><th>#</th><th>'+name+'</th><th>分数</th><th>行</th><th>用时</th></tr>'+
rows.map(r=>'<tr><td class="r">'+r.rank+'</td><td>'+r.name+'</td><td>'+r.score+'</td><td>'+r.lines+'</td><td>'+fmtT(r.time)+'</td></tr>').join('')
}
async function refresh(){
try{
const d=await fetch('/tetris/api/stats').then(r=>r.json())
dau.textContent=d.todayDetail.dau
launches.textContent=d.todayDetail.launches
players.textContent=d.todayDetail.players
dailyPlayers.textContent=d.todayDetail.dailyPlayers
ver.textContent=d.version;ver2.textContent=d.version
const mx=Math.max(1,...d.dau.map(x=>x.dau))
bars.innerHTML=d.dau.map(x=>'<div class="bar"><i style="height:'+(x.dau/mx*100)+'%"></i><span>'+x.date+'<br>'+x.dau+'人</span></div>').join('')
board(top,d.top,'玩家')
board(daily,d.daily,'玩家')
winners.innerHTML=(d.winners&&d.winners.length)?'<tr><th>日期</th><th>冠军</th><th>分数</th></tr>'+
d.winners.map(w=>'<tr><td class="r">'+w.date.slice(5)+'</td><td>'+w.name+' 👑</td><td>'+w.score+'</td></tr>').join('')
:'<tr><td class="empty">还没有冠军档案，今天的第一名就是第一位</td></tr>'
tick.textContent='· 更新于 '+new Date().toLocaleTimeString('zh-CN')
}catch(e){tick.textContent='· 刷新失败，稍后重试'}
}
refresh();setInterval(refresh,30000)
</script></body></html>`
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
    return res.end(html)
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
loadWinners()
loadStats()
server.listen(PORT, '127.0.0.1', () => console.log('tetris-leaderboard on 127.0.0.1:' + PORT))
