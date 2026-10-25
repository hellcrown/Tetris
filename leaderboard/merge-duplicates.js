// 排行榜数据一次性清理：
//   1. 同名条目合并成一条（保留最高分；同分保留用时更短、行数更多的）
//   2. 报告 lines=0 的可疑条目（旧版补录假数据所致；同名合并常能顺带找回真实行数）
// 用法（务必先停服务再跑，跑完再启动，防止内存里的旧数据写回覆盖）：
//   pm2 stop tetris-leaderboard
//   node merge-duplicates.js
//   pm2 restart tetris-leaderboard
const fs = require('fs')
const path = require('path')

const DATA_FILE = path.join(__dirname, 'data.json')
const entries = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'))
const valid = e => e && typeof e.uid === 'string' && typeof e.name === 'string' &&
  Number.isFinite(e.score) && Number.isFinite(e.lines) && Number.isFinite(e.time)

const byName = new Map()
const kept = []
let mergedCount = 0
const zeroLineSuspects = []

for (const e of entries.filter(valid)) {
  if (e.lines === 0 && e.score > 0) zeroLineSuspects.push(e)
  const prev = byName.get(e.name)
  if (!prev) {
    byName.set(e.name, e)
    kept.push(e)
  } else {
    mergedCount++
    // 更高分者胜；同分比更快，再同行数多者（找回真实行数）
    const better = e.score > prev.score ||
      (e.score === prev.score && (e.time < prev.time || (e.time === prev.time && e.lines > prev.lines)))
    if (better) Object.assign(prev, { uid: e.uid, score: e.score, lines: e.lines, time: e.time, ts: e.ts })
    else if (prev.lines === 0 && e.lines > 0) prev.lines = e.lines
  }
}

kept.sort((a, b) => b.score - a.score || a.time - b.time || a.ts - b.ts)
fs.writeFileSync(DATA_FILE + '.bak-' + Date.now(), JSON.stringify(entries))
fs.writeFileSync(DATA_FILE, JSON.stringify(kept))
console.log(`原始 ${entries.length} 条 → 合并后 ${kept.length} 条（消除 ${mergedCount} 条同名重复）`)
console.log(`备份：${path.basename(DATA_FILE)}.bak-*`)
if (zeroLineSuspects.length) {
  console.log('\nlines=0 的可疑条目（若同名合并未找回行数，只能等玩家下次破纪录自动修正）：')
  for (const e of zeroLineSuspects) console.log(`  ${e.name} score=${e.score} uid=${e.uid}`)
}
