import QtQuick
// import QtQuick.Controls
import QtQuick.Controls.Basic // 明确使用通用 Basic 样式，避免平台警告
import QtQuick.Layouts
import QtQuick.Particles
import QtCore

ApplicationWindow {
    id: root
    visible: true
    width: 360  // 手机竖屏典型宽度
    height: 780 // 桌面预览用；真机上以实际窗口大小为准
    title: qsTr("俄罗斯方块")
    color: "#2b2b2b"

    // --- 游戏常量配置 ---
    readonly property int cols: 12       // 游戏区域列数
    readonly property int rows: 21       // 游戏区域行数
    readonly property int blockSize: 26  // 每个方块的像素大小
    readonly property int margin: 30
    readonly property int baseDropInterval: 800
    readonly property int minDropInterval: 30   // 仅作定时器安全下限（防病态），实际不构成速度上限
    readonly property int dropAccelerationPerLine: 7
    property int settleAccelMs: 60      // 落块物理基准：1 格自由落体耗时，t = k·√h（h 单位：格）

    // 内容整体等比缩放：矮屏（如 16:9 手机的 640 逻辑高）和窄屏也能看到底部全部按钮
    readonly property real contentScale: Math.min(
        1,
        root.width / Math.max(1, mainColumn.width + 8),
        (root.height - 16) / Math.max(1, mainColumn.height)
    )

    // 7种方块形状定义 (I, O, T, L, J, S, Z)
    readonly property var shapes: [
        [[1,1,1,1]],                    // I
        [[1,1],[1,1]],                  // O
        [[0,1,0],[1,1,1]],              // T
        [[0,0,1],[1,1,1]],              // L
        [[1,0,0],[1,1,1]],              // J
        [[0,1,1],[1,1,0]],              // S
        [[1,1,0],[0,1,1]]               // Z
    ]

    // 对应颜色（治愈系高辨识配色：I/O/T/L/J/S/Z）
    readonly property var colors: [
        "#54D6E8", "#F5D76E", "#B69CFF",
        "#FFB46E", "#7FAEFF", "#8BDB9A", "#FF8B94"
    ]

    // --- 游戏状态变量 ---
    property var grid: []               // 游戏网格数据
    property int currentShapeIndex: 0   // 当前方块索引
    property var currentShape: []       // 当前方块形状
    property string currentColor: ""    // 当前方块颜色
    property int nextShapeIndex: 0      // 下一个方块索引
    property var nextShape: []          // 下一个方块形状
    property string nextColor: ""       // 下一个方块颜色
    property int posX: 0                // 当前方块X位置
    property int posY: 0                // 当前方块Y位置
    property int score: 0               // 当前显示分数
    property int scoreTarget: 0         // 目标分数（动画用）
    property int bestScore: 0           // 历史最高分
    property int comboStreak: 0         // 连续消行次数（用于COMBO）
    property int totalClearedLines: 0   // 累计消行数（用于加速）
    property bool isGameOver: false     // 游戏结束标志
    property bool isPaused: false       // 暂停标志
    property int shakeOffsetX: 0        // 清行时的轻微震屏偏移
    property var settleFallers: []      // 消行后受重力下落的方块 {col, fromRow, toRow, color}
    property var settleHiddenMap: ({})  // 下落动画期间临时隐藏的落点格
    property string opMode: "buttons"   // 操作方式：buttons=按钮 / gestures=手势
    property string vibeLevel: "std"    // 震动：off=关 / std=标准 / strong=加强
    property string playerName: ""      // 全服排行榜昵称
    property string playerUid: ""       // 本机标识（服务端按它保留最好成绩）
    property int bestLines: 0           // 最高分那一局的消行（上传排行用真实数据）
    property int bestTime: 0            // 最高分那一局的用时（秒）
    property string pendingAdopt: ""    // 旧随机 uid：下次提交时让服务端并入新 uid，成功后清空
    property bool showLeaderboard: false
    property bool lbLoading: false
    property bool lbError: false
    property var lbRows: []
    property int lbTotal: 0
    property bool submitPending: false
    property string myRankText: ""
    readonly property string apiBase: "https://blood-table.top/tetris/api/"
    readonly property int settingsVersion: 3    // 设置结构版本：升级时清旧版历史记录（最高分归零）
    property int savedSettingsVersion: 0
    property string bgChoice: "t01"             // 当前背景主题
    property bool bgFallback: false             // 背景文件缺失时回退到内置图
    onBgChoiceChanged: bgFallback = false
    property real bgPhase: 0                    // 背景漂移/呼吸的相位（低频 Timer 驱动）
    property bool showBgPicker: false
    property bool showStats: false
    property bool showDiag: false          // 隐藏诊断日志页（连点"已暂停"标题 5 次打开）
    property bool forceFrames: false       // 回前台后强推帧 3 秒：卓易通锁屏会吞 Surface，
                                           // 解锁后必须持续冲刷帧才能把新画面顶上去（用户实测
                                           // 锁屏前开过菜单=帧泵在跑→解锁不黑屏，据此推广）
    Timer {
        id: forceFramesStop
        interval: 8000
        onTriggered: root.forceFrames = false
    }

    // ---- 特效预设（v3.6 阶段1）：治愈(默认)/街机 只调表现层参数，不改规则 ----
    property string fxPreset: "zen"        // zen=治愈 / arcade=街机
    property bool reduceMotion: false      // 减少动态：无震屏/无闪光/慢呼吸，保留必要提示
    readonly property bool zenFx: fxPreset === "zen"
    // 参数表（全部走缩放系数，随时可调）
    readonly property real fxShakeScale: reduceMotion ? 0 : (zenFx ? 0.4 : 1.0)      // 震屏幅度
    readonly property int  fxFlashMs: reduceMotion ? 0 : (zenFx ? 300 : 180)         // 全屏白闪时长
    readonly property real fxFlashPeak: reduceMotion ? 0 : (zenFx ? 0.35 : 0.85)     // 白闪峰值（治愈=柔和渐变）
    readonly property real fxParticleScale: reduceMotion ? 0.5 : (zenFx ? 0.65 : 1.0)// 粒子数量
    readonly property real fxBreathScale: reduceMotion ? 2.2 : (zenFx ? 1.6 : 1.0)   // 呼吸/闪烁周期倍率
    property bool fxSurge: false           // P1 大事件进行中：背景/氛围层让位（压暗+减速）
    property double bigFxUntil: 0          // Tetris 大演出占用期（解锁演出让位，避免同帧撞车）
    property string pendingUnlock: ""      // 暂缓的背景解锁主题名
    property bool tetrisB2b: false
    property int tetrisEarned: 0
    property bool permAttempted: false   // 安装权限引导只跳一次设置，之后直接尝试
    property int patchVer: 0             // 已应用的 QML 热更补丁版本（0=无）

    Timer {
        id: fxSurgeTimer
        interval: 800
        onTriggered: root.fxSurge = false
    }

    Timer {
        id: unlockDelayTimer
        interval: 1000
        onTriggered: if (pendingUnlock !== "") showUnlockCelebrate(pendingUnlock)
    }

    // ---- 阶段5/6：危险预警 · 徽章 · 里程碑 · 结算回忆 ----
    property int tetrisCount: 0           // 本局四行消除次数（结果徽章）
    property int b2bCount: 0              // 本局 B2B 次数（结果徽章）
    property var gameBadges: []           // 本局已获过程徽章 id
    property int cleanClearStreak: 0      // 连续未入危险区（顶部4行）的消行次数
    property int newUnlocks: 0            // 本局新解锁背景数（结算统计格）
    property bool recapCompact: false     // 结算页折叠态（点头部切换）
    property int dangerLv: 0              // 危险三段：1=顶部6行有块 2=顶部4行 3=顶部2行（命令式更新）

    // 连击能量槽（连击保鲜）：消行回满 100，落锁不消行随时间衰减（满槽 5 秒），
    // 归零连击结束。衰减用 100ms 游戏时钟累计，暂停即停（单调游戏时钟）。
    property real comboEnergy: 0
    Timer {
        id: energyTick
        interval: 100
        running: !isPaused && !isGameOver && comboEnergy > 0
        onTriggered: {
            comboEnergy = Math.max(0, comboEnergy - 2)
            if (comboEnergy === 0) {
                comboStreak = 0
                comboDisplayText = ""
            }
        }
    }
    property string diagText: ""           // 诊断日志内容（打开面板时拉取）
    property string diagCopyHint: ""       // 复制成功的提示
    // 个人战绩（永久累计，settingsVersion 清档时不重置）
    property int totalGames: 0
    property int totalLinesAll: 0
    property int totalSecondsAll: 0
    property int maxComboAll: 0
    // 主题环境粒子：随主题切换颜色与运动方向
    readonly property color ambientColor: ["#ffe9a8","#eaf6ff","#ffd98a","#ffb7d5","#eaf6ff","#d8ff9a","#eaf6ff","#ffffff","#ffb46e","#c8b8ff","#9fc8ff","#ffc8dc"][bgThemeIndex(bgChoice)]
    readonly property bool ambientRise: [false,false,true,false,false,true,false,false,false,false,false,true][bgThemeIndex(bgChoice)]
    readonly property int ambientSpeed: [26,22,34,40,70,30,26,20,46,20,32,18][bgThemeIndex(bgChoice)]
    property string unlockCelebrateName: ""     // 解锁成就演出主题名
    // 背景主题表：need = 单局分数门槛（过线即永久收藏）；文件 = qrc:/bgN.jpg（N=序号，缺文件的卡片自动隐藏）
    readonly property var bgThemes: [
        { id: "t01", name: "晴日草原", need: 0 },
        { id: "t02", name: "落日海岸", need: 100 },
        { id: "t03", name: "星夜营地", need: 300 },
        { id: "t04", name: "樱花庭院", need: 600 },
        { id: "t05", name: "初雪小镇", need: 1000 },
        { id: "t06", name: "萤火森林", need: 1600 },
        { id: "t07", name: "蓝湾渔村", need: 2400 },
        { id: "t08", name: "云端花园", need: 3400 },
        { id: "t09", name: "枫糖秋林", need: 4600 },
        { id: "t10", name: "月光湖泊", need: 6000 },
        { id: "t11", name: "银河观测站", need: 7800 },
        { id: "t12", name: "梦境彼岸", need: 10000 }
    ]
    property var savedUnlocks: ["t01"]          // 永久收藏（过线即存，重开/退出不丢）
    onScoreTargetChanged: checkBgUnlocks()
    function bgThemeIndex(id) {
        for (var i = 0; i < bgThemes.length; i++)
            if (bgThemes[i].id === id) return i
        return 0
    }
    function bgUrl(id) {
        return "qrc:/bg" + (bgThemeIndex(id) + 1) + ".jpg"
    }
    function checkBgUnlocks() {
        var latest = ""
        for (var i = 0; i < bgThemes.length; i++) {
            var t = bgThemes[i]
            if (savedUnlocks.indexOf(t.id) === -1 && scoreTarget >= t.need) {
                savedUnlocks.push(t.id)
                latest = t.name
            }
        }
        if (latest !== "") {
            savedUnlocks = savedUnlocks.slice()  // 重新赋值触发 Settings 持久化
            newUnlocks++                         // 结算页"新收藏"统计格
            if (Date.now() < bigFxUntil)
                pendingUnlock = latest           // 四消大演出中：解锁演出延迟让位
            else
                showUnlockCelebrate(latest)
        }
    }
    function showUnlockCelebrate(latest) {
        // 成就演出：背景渐变 + 星星扩散 + 主题名弹出
        unlockCelebrateName = "解锁背景 · " + latest
        unlockCelebrate.visible = true
        unlockCelebrateAnim.restart()
        sparkBurst.burst(Math.round(10 * fxParticleScale),
                         gameBoard.width / 2, gameBoard.height * 0.3)
        dimBurst.burst(Math.round(14 * fxParticleScale),
                       gameBoard.width / 2, gameBoard.height * 0.3)
    }
    property var bagQueue: []           // 7-bag 随机袋余量
    property int holdShapeIndex: -1     // Hold 区方块索引（-1 为空）
    property bool canHold: true         // 每个方块落地前只能 Hold 一次
    property bool b2bActive: false      // Back-to-Back：上次是消 4 行时保持
    property int maxCombo: 0            // 本局最大连击
    readonly property bool turboMode: gameLoop.interval <= minDropInterval  // 下落已到安全下限=极速状态
    property int playSeconds: 0         // 本局用时（秒）
    property int lockResets: 0          // 锁定延迟已被移动/旋转刷新的次数（有上限）
    property int lowestRow: 0           // 当前方块到达过的最低行（下到新低行时重置 lockResets）
    readonly property int ghostRow: {   // 落点投影行
        if (currentShape.length === 0 || grid.length === 0) return 0
        var gy = posY
        while (!checkCollision(posX, gy + 1, currentShape)) gy++
        return gy
    }
    property int shakeOffsetY: 0        // 到底纵向冲击偏移
    property real shakeYAmplitude: 8    // 纵向冲击幅度（消行按行数加码，到底固定）
    property real boardPunch: 1.0       // 消行打击 zoom（棋盘整体脉冲放大）
    property var rowFlashes: []         // 消行白光爆闪的行号
    property var lockFlashes: []        // 落锁闪光 {col,row}
    property var afterimages: []        // 移动/旋转残影 {cells:[{c,r}],color,ts}
    property var dropStreaks: []        // 到底速度线 {x,y0,y1,color}
    property var scoreFloats: []        // 分数栏飘字 {dx,text,born}
    property real lastFloatAt: 0        // 软降飘字限速
    property var lineClearFragments: [] // 消行碎片 {col,row,color}
    readonly property bool dangerActive: dangerLv > 0   // 兼容旧引用（红框等已改用 dangerLv 分层）

    // 立体质感方块：顶部高光 + 底部阴影
    component GameBlock: Rectangle {
        property color baseColor: "#f00000"
        color: baseColor
        radius: 2
        border.width: 1
        border.color: Qt.lighter(baseColor, 1.4)

        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: parent.height * 0.3
            radius: parent.radius
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.42) }
                GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.04) }
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: parent.height * 0.2
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.32) }
            }
        }
    }
    property string scoreBurstText: ""  // 清行加分爆字文本
    property color scoreBurstColor: "#ffffff"
    property color scoreBurstOutlineColor: "transparent"
    property bool scoreBurstGlowEnabled: false
    property string comboCenterText: ""
    property string comboDisplayText: ""
    property var lineClearEffects: []
    property var lineClearWave2: []     // 双消第二道波纹（错位 80ms，冰蓝）
    property var wave2Pending: []
    property color lineClearEffectColor: "#ffffff"

    Settings {
        id: gameSettings
        category: "Tetris"
        property alias bestScoreValue: root.bestScore
        property alias opModeValue: root.opMode
        property alias vibeLevelValue: root.vibeLevel
        property alias playerNameValue: root.playerName
        property alias playerUidValue: root.playerUid
        property alias savedSettingsVersionValue: root.savedSettingsVersion
        property alias bgChoiceValue: root.bgChoice
        property alias savedUnlocksValue: root.savedUnlocks
        property alias totalGamesValue: root.totalGames
        property alias totalLinesAllValue: root.totalLinesAll
        property alias totalSecondsAllValue: root.totalSecondsAll
        property alias maxComboAllValue: root.maxComboAll
        property alias fxPresetValue: root.fxPreset
        property alias reduceMotionValue: root.reduceMotion
        property alias patchVerValue: root.patchVer
        property alias bestLinesValue: root.bestLines
        property alias bestTimeValue: root.bestTime
        property alias pendingAdoptValue: root.pendingAdopt
    }

    // 游戏主定时器
    Timer {
        id: gameLoop
        interval: baseDropInterval // 下落速度 (毫秒)
        repeat: true
        onTriggered: {
            moveDown()
        }
    }

    Timer {
        id: clearEffectTimer
        interval: 1200
        repeat: false
        onTriggered: {
            lineClearEffects = []
            lineClearFragments = []
        }
    }
    Timer {
        id: wave2Timer
        interval: 80
        repeat: false
        onTriggered: lineClearWave2 = wave2Pending
    }

    Timer { id: lockFlashTimer; interval: 320; onTriggered: lockFlashes = [] }

    Timer { id: rowFlashTimer; interval: 260; onTriggered: rowFlashes = [] }

    Timer {
        id: afterimageTimer
        interval: 220
        onTriggered: {
            var now = Date.now()
            var kept = []
            for (var i = 0; i < afterimages.length; i++)
                if (now - afterimages[i].ts < 200) kept.push(afterimages[i])
            afterimages = kept
        }
    }

    Timer { id: streakTimer; interval: 200; onTriggered: dropStreaks = [] }

    Timer {
        id: scoreFloatTimer
        interval: 700
        repeat: true
        running: scoreFloats.length > 0
        onTriggered: {
            var now = Date.now()
            var kept = []
            for (var i = 0; i < scoreFloats.length; i++)
                if (now - scoreFloats[i].born < 620) kept.push(scoreFloats[i])
            scoreFloats = kept
        }
    }

    function spawnScoreFloat(text) {
        var now = Date.now()
        if (now - lastFloatAt < 110) return   // 连续软降时限速，避免刷屏
        lastFloatAt = now
        // var 属性必须整体重赋值才发变更通知（原地 push 不触发 Repeater/绑定刷新）；
        // 飘字固定显示在分数栏旁（不跟随方块），随机横向偏移错开连续 +1
        var next = scoreFloats.concat([{ dx: Math.round(Math.random() * 18 - 9), text: text, born: now }])
        scoreFloats = next.length > 6 ? next.slice(next.length - 6) : next
    }

    // 落块动画结束：撤下落层、恢复落点格显示
    Timer {
        id: settleTimer
        repeat: false
        onTriggered: {
            settleFallers = []
            settleHiddenMap = ({})
        }
    }

    // 分数逐一递增动画计时器
    Timer {
        id: scoreTimer
        interval: 20
        repeat: true
        onTriggered: {
            if (score < scoreTarget) {
                score++
                bumpBest(score)
            } else {
                stop()
            }
        }
    }

    // 锁定延迟：触底后给 0.5 秒挪动/旋转的余地
    Timer {
        id: lockDelayTimer
        interval: 500
        repeat: false
        onTriggered: lockPiece()
    }

    // 本局用时
    Timer {
        id: playTimeTimer
        interval: 1000
        repeat: true
        running: false
        onTriggered: playSeconds++
    }

    // 安卓返回键 = 暂停（不退出）；桌面端保持正常关窗
    onClosing: (close) => {
        if (Qt.platform.os !== "android") return
        close.accepted = false
        pauseGame()
    }

    // 切到后台自动暂停
    Connections {
        target: Qt.application
        function onStateChanged() {
            if (Qt.application.state !== Qt.ApplicationActive) {
                pauseGame()
                } else {
                    // 恢复前台时强制全场景重绘，规避安卓锁屏恢复后黑屏
                    resumeRepaintTimer.restart()
                    // 卓易通等容器：解锁后 Surface 被换，必须持续冲刷帧才能恢复显示。
                    // 强推 3 秒帧（帧泵期间每帧 noteFrame 会解除 Java 侧恢复梯）
                    forceFrames = true
                    forceFramesStop.restart()
                    updateBanner.checkStart()   // 回前台顺带刷新更新检查
                }
        }
    }

    Timer {
        id: resumeRepaintTimer
        interval: 80
        onTriggered: bgHost.opacity = bgHost.opacity === 1 ? 0.999 : 1
    }

    SequentialAnimation {
        id: shakeAnimation
        running: false

        NumberAnimation {
            id: shakeForward
            target: root
            property: "shakeOffsetX"
            duration: 35
            easing.type: Easing.OutQuad
        }
        NumberAnimation {
            id: shakeBack
            target: root
            property: "shakeOffsetX"
            to: 0
            duration: 70
            easing.type: Easing.OutQuad
        }
    }

    ParallelAnimation {
        id: scoreBurstAnimation
        running: false

        NumberAnimation {
            target: scoreBurstLabel
            property: "opacity"
            from: 1
            to: 0
            duration: 1000
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: scoreBurstLabel
            property: "scale"
            from: 0.82
            to: 1.18
            duration: 1000
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: scoreBurstLabel
            property: "y"
            from: 4
            to: -10
            duration: 1000
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            target: scoreBurstGlow
            property: "opacity"
            from: 0.62
            to: 0
            duration: 1000
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: scoreBurstGlow
            property: "scale"
            from: 0.9
            to: 1.26
            duration: 1000
            easing.type: Easing.OutCubic
        }

        onStopped: {
            scoreBurstLabel.visible = false
            scoreBurstGlow.visible = false
        }
    }

    ParallelAnimation {
        id: comboCenterBurstAnimation
        running: false

        NumberAnimation {
            target: comboBurstBackdrop
            property: "opacity"
            from: 0.55
            to: 0
            duration: 1000
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: comboBurstCore
            property: "scale"
            from: 0.55
            to: 1.65
            duration: 1000
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: comboBurstCore
            property: "opacity"
            from: 0.95
            to: 0
            duration: 1000
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: comboCenterLabel
            property: "opacity"
            from: 1
            to: 0
            duration: 1000
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: comboCenterLabel
            property: "scale"
            from: 0.8
            to: 1.24
            duration: 1000
            easing.type: Easing.OutCubic
        }

        onStopped: {
            comboBurstOverlay.visible = false
        }
    }

    // 到底/消行纵向砸击（幅度由 shakeYAmplitude 控制）
    SequentialAnimation {
        id: thumpAnimation
        NumberAnimation { target: root; property: "shakeOffsetY"; to: root.shakeYAmplitude; duration: 40; easing.type: Easing.InQuad }
        NumberAnimation { target: root; property: "shakeOffsetY"; to: 0; duration: 220; easing.type: Easing.OutBounce }
    }

    // 消行打击 zoom：棋盘整体脉冲放大再弹回
    SequentialAnimation {
        id: punchAnimation
        NumberAnimation { target: root; property: "boardPunch"; to: 1.035; duration: 50; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "boardPunch"; to: 1.0; duration: 170; easing.type: Easing.OutBack }
    }

    // Tetris 全屏白闪（治愈=柔和渐变 300ms / 街机=180ms / 减少动态=不闪）
    SequentialAnimation {
        id: flashAnimation
        NumberAnimation { target: flashOverlay; property: "opacity"; from: root.fxFlashPeak; to: 0; duration: Math.max(root.fxFlashMs, 1); easing.type: Easing.OutQuad }
        onStopped: flashOverlay.visible = false
    }

    // Tetris 三段式·蓄力：棋盘微压缩 70ms 后触发释放（闪光/环/火花/文字集中入场）
    Timer {
        id: tetrisReleaseTimer
        interval: 70
        repeat: false
        onTriggered: tetrisRelease()
    }

    // Tetris 背景灼烧
    SequentialAnimation {
        id: burnAnimation
        NumberAnimation { target: bgBurnOverlay; property: "opacity"; from: 0.38; to: 0; duration: 950; easing.type: Easing.OutCubic }
        onStopped: bgBurnOverlay.visible = false
    }

    // 普通消行背景泛光
    SequentialAnimation {
        id: bgTintAnimation
        NumberAnimation { target: bgTintOverlay; property: "opacity"; from: 0.13; to: 0; duration: 550; easing.type: Easing.OutCubic }
        onStopped: bgTintOverlay.visible = false
    }

    // Tetris 双重冲击波
    SequentialAnimation {
        id: tetrisRingsAnimation
        ParallelAnimation {
            NumberAnimation { target: tetrisRing1; property: "scale"; from: 0.25; to: 2.6; duration: 800; easing.type: Easing.OutCubic }
            NumberAnimation { target: tetrisRing1; property: "opacity"; from: 0.85; to: 0; duration: 800 }
            NumberAnimation { target: tetrisRing2; property: "scale"; from: 0.15; to: 1.7; duration: 1050; easing.type: Easing.OutCubic }
            NumberAnimation { target: tetrisRing2; property: "opacity"; from: 0.7; to: 0; duration: 1050 }
        }
        onStopped: {
            tetrisRing1.visible = false
            tetrisRing2.visible = false
        }
    }

    // --- 初始化 ---
    Component.onCompleted: {
        // 设置结构升级：清旧版历史记录（最高分），保留名字/操作/震动偏好
        if (savedSettingsVersion < settingsVersion) {
            bestScore = 0
            savedSettingsVersion = settingsVersion
        }
        // uid 稳定化：安卓用 ANDROID_ID（卸载重装不变），杜绝同名字分家；
        // 旧的随机 uid 交由服务端在下次提交时并入（adopt），成绩不丢
        var deviceId = typeof nativeDeviceId !== "undefined" ? String(nativeDeviceId) : ""
        if (deviceId !== "") {
            var want = "a" + deviceId
            if (playerUid !== want) {
                if (playerUid !== "") pendingAdopt = playerUid
                playerUid = want
            }
        } else if (playerUid === "") {
            playerUid = "t" + Date.now().toString(36) + Math.random().toString(36).slice(2, 10)
        }
        startGame()
        updateBanner.checkStart()   // 启动时静默检查在线更新

        // 阶段验收演示模式（--demo 场景 --shots 目录 --preset 预设）：仅开发用
        if (demoPreset === "rm") {
            fxPreset = "zen"
            reduceMotion = true
        } else if (demoPreset === "zen" || demoPreset === "arcade") {
            fxPreset = demoPreset
            reduceMotion = false
        }
        if (demoScene !== "" && shotDir !== "")
            demoTimer.restart()
    }

    // ---- 阶段验收演示（仅 --demo 启动时生效，正式运行零影响）----
    function demoFillRow(y, str) {
        for (var c = 0; c < cols && c < str.length; c++)
            grid[y][c] = str[c] === "1" ? colors[c % colors.length] : 0
    }
    function demoSetupTetris() {
        // 底部 4 行（17-20）留出最右 1 列 → 竖 I 直落补齐即四消（棋盘 12 列 × 21 行）
        for (var r = 17; r <= 20; r++) demoFillRow(r, "11111111111")
        demoSetI(11, true)
        comboStreak = 3
        comboEnergy = 100
        b2bActive = true
        refreshGrid()
        refreshDanger()
    }
    function demoSetI(x, vertical) {
        currentShapeIndex = 0
        currentShape = cloneShape(vertical ? [[1], [1], [1], [1]] : shapes[0])
        currentColor = colors[0]
        posX = x
        posY = 12
    }
    function demoSetupLines(n) {
        // n 消演示：底部 n 行留最右 1 列空缺，竖 I 从天而降补齐 → 严格 n 消
        var gap11 = ""
        for (var g = 0; g < cols - 1; g++) gap11 += "1"
        for (var r = 21 - n; r <= 20; r++) demoFillRow(r, gap11)
        demoSetI(cols - 1, true)
        comboStreak = 1
        refreshGrid()
        refreshDanger()
    }
    function shoot(tag) {
        if (shotDir === "")
            return
        NativeUpdate.saveShot(shotDir + "/" + tag + ".png")
    }
    property int demoStep: 0
    Timer {
        id: demoTimer
        interval: 400
        repeat: true
        running: false
        onTriggered: {
            if (demoScene === "tetris" || demoScene === "clear1" || demoScene === "clear2" || demoScene === "clear3") {
                if (demoStep === 0) {
                    if (demoScene === "tetris")
                        demoSetupTetris()
                    else
                        demoSetupLines(parseInt(demoScene.charAt(5)))
                    shoot("0-before")
                } else if (demoStep === 1) {
                    if (demoScene === "tetris")
                        demoFireTetris()      // 旋转 + 硬降 → 四消演出
                    else
                        hardDrop()            // 直接落下补齐
                    demoTimer.interval = 150  // 紧拍释放阶段
                } else if (demoStep === 3) {
                    shoot("1-after-2")        // +300ms：回落开始
                    demoTimer.interval = 400  // 恢复常规节奏
                } else if (demoStep === 2) {
                    shoot("1-after-1")        // +150ms：释放阶段
                } else if (demoStep <= 7) {
                    shoot("1-after-" + (demoStep - 1))   // 0.7s/1.1s/1.5s/1.9s
                } else {
                    demoTimer.stop()
                    if (shotDir !== "")
                        Qt.quit()             // 拍完自动退出
                }
            } else if (demoScene === "fire") {
                // 火焰边框验收：3 消残局 + 连击 4 + B2B → 猩红金焰
                // 后台启动会被自动暂停挡住 → 每步强制恢复
                isPaused = false
                if (demoStep === 0) {
                    demoSetupLines(3)
                    comboStreak = 4
                    b2bActive = true
                    refreshGrid()
                    shoot("fire-0")
                } else if (demoStep <= 4) {
                    shoot("fire-" + demoStep)
                } else {
                    demoTimer.stop()
                    Qt.quit()
                }
            } else if (demoScene === "energy") {
                // 能量槽验收：高能量 / 低能量（<25% 转暖红）两态
                if (demoStep === 0) {
                    comboStreak = 4
                    comboEnergy = 68
                    shoot("energy")
                } else if (demoStep === 1) {
                    comboEnergy = 12
                    shoot("energy-low")
                } else {
                    demoTimer.stop()
                    Qt.quit()
                }
            } else if (demoScene === "settings") {
                if (demoStep === 0) {
                    isPaused = true           // 打开暂停菜单展示新特效设置行
                    shoot("settings")
                } else {
                    demoTimer.stop()
                    Qt.quit()
                }
            } else if (demoScene === "danger6" || demoScene === "danger4" || demoScene === "danger2") {
                // 危险三段验收：一段=最高块在第5行 / 二段=第3行 / 三段=第1行
                isPaused = false
                if (demoStep === 0) {
                    var top = demoScene === "danger6" ? 5 : demoScene === "danger4" ? 3 : 1
                    for (var dr = top; dr < rows; dr++) {
                        var rowStr = ""
                        for (var dc = 0; dc < cols; dc++) rowStr += "1"
                        demoFillRow(dr, rowStr)
                    }
                    refreshGrid()
                    refreshDanger()
                    shoot("danger-top" + top)
                } else {
                    demoTimer.stop()
                    Qt.quit()
                }
            } else if (demoScene === "recap") {
                // 结算页验收：预置战绩与徽章 → 展开态 / 折叠态
                if (demoStep === 0) {
                    score = 4136
                    scoreTarget = 4820
                    totalClearedLines = 38
                    maxCombo = 6
                    tetrisCount = 2
                    b2bCount = 1
                    newUnlocks = 1
                    gameBadges = ["clutch", "precise"]
                    isGameOver = true
                    shoot("recap")
                } else if (demoStep === 1) {
                    recapCompact = true
                    shoot("recap-compact")
                } else {
                    demoTimer.stop()
                    Qt.quit()
                }
            } else if (demoScene === "badge") {
                isPaused = false
                if (demoStep === 0) {
                    showToast("🛡️", "极限救场")
                } else if (demoStep === 1) {
                    shoot("badge")
                } else {
                    demoTimer.stop()
                    Qt.quit()
                }
            } else {
                demoTimer.stop()
            }
            demoStep++
        }
    }
    function demoFireTetris() {
        // 竖 I 已对准 col11 缺口：直接硬落补齐 → 四消三段式演出（勿 rotate，会落到堆顶）
        hardDrop()
        // 演示诊断：验证四消是否真的发生
        var filled = 0
        for (var r = 0; r < rows; r++)
            for (var c = 0; c < cols; c++)
                if (grid[r][c] !== 0) filled++
        var counts = []
        for (var r2 = 12; r2 < rows; r2++) {
            var n = 0
            for (var c2 = 0; c2 < cols; c2++)
                if (grid[r2][c2] !== 0) n++
            counts.push(r2 + ":" + n)
        }
        console.warn("[Demo] score=" + score + " cleared=" + totalClearedLines
                     + " combo=" + comboStreak + " 总数=" + filled
                     + " 行填充[12-19]: " + counts.join(" "))
    }

    // 最高分连同该局的行数/用时一起记录，排行上传用真实数据
    function bumpBest(s) {
        if (s > bestScore) {
            bestScore = s
            bestLines = totalClearedLines
            bestTime = playSeconds
        }
    }

    function cloneShape(shape) {
        var cloned = []
        for (var r = 0; r < shape.length; r++) {
            cloned.push(shape[r].slice(0))
        }
        return cloned
    }

    function createEmptyGrid() {
        var newGrid = []
        for (var r = 0; r < rows; r++) {
            var row = []
            for (var c = 0; c < cols; c++) {
                row.push(0)
            }
            newGrid.push(row)
        }
        return newGrid
    }

    function refreshGrid() {
        var refreshedGrid = []
        for (var r = 0; r < grid.length; r++) {
            refreshedGrid.push(grid[r].slice(0))
        }
        grid = refreshedGrid
    }

    // 7-bag：7 种方块洗牌成袋发放，保证分布
    function nextFromBag() {
        if (bagQueue.length === 0) {
            bagQueue = [0, 1, 2, 3, 4, 5, 6]
            for (var i = bagQueue.length - 1; i > 0; i--) {
                var j = Math.floor(Math.random() * (i + 1))
                var t = bagQueue[i]
                bagQueue[i] = bagQueue[j]
                bagQueue[j] = t
            }
        }
        return bagQueue.pop()
    }

    function prepareNextPiece() {
        nextShapeIndex = nextFromBag()
        nextShape = cloneShape(shapes[nextShapeIndex])
        nextColor = colors[nextShapeIndex]
    }

    function isRowFull(rowData) {
        for (var c = 0; c < rowData.length; c++) {
            if (rowData[c] === 0) {
                return false
            }
        }
        return true
    }

    function scoreForClearedLines(linesCleared) {
        // 经典倍率制（缩放版）: 单消10, 双消30, 三消50, 四消80
        if (linesCleared === 1) return 10
        if (linesCleared === 2) return 30
        if (linesCleared === 3) return 50
        if (linesCleared >= 4) return 80
        return 0
    }

    function scoreColorForLines(linesCleared) {
        if (linesCleared === 1) return "#ffffff"
        if (linesCleared === 2) return "#9ed8ff"
        if (linesCleared === 3) return "#ff9e3d"
        return "#ff2a2a"
    }

    function triggerScoreBurst(points, combo, linesCleared, b2bBonus) {
        scoreBurstText = "+" + points + (b2bBonus ? "  B2B" : "") + (combo > 1 ? "  COMBO x" + combo : "")
        scoreBurstOutlineColor = "transparent"
        scoreBurstGlowEnabled = false
        scoreBurstColor = scoreColorForLines(linesCleared)
        if (linesCleared === 3) {
            scoreBurstColor = "#ff9e3d"
            scoreBurstOutlineColor = "#ffd95a"
        } else if (linesCleared >= 4) {
            scoreBurstOutlineColor = "#ffd1a8"
            scoreBurstGlowEnabled = true
        }
        scoreBurstLabel.opacity = 1
        scoreBurstLabel.scale = 0.82
        scoreBurstLabel.y = 4
        scoreBurstLabel.visible = true
        scoreBurstGlow.opacity = scoreBurstGlowEnabled ? 0.62 : 0
        scoreBurstGlow.scale = 0.9
        scoreBurstGlow.visible = scoreBurstGlowEnabled
        scoreBurstAnimation.restart()
    }

    function triggerComboCenterBurst(combo) {
        if (combo < 2) return
        comboCenterText = combo + "x"
        comboBurstOverlay.visible = true
        comboBurstBackdrop.opacity = 0.55
        comboBurstCore.scale = 0.6
        comboCenterLabel.opacity = 1
        comboCenterLabel.scale = 0.8
        comboCenterBurstAnimation.restart()
    }

    // ---- 阶段5：过程徽章 + 小徽章 toast（局内里程碑复用同一 toast）----
    readonly property var badgeDefs: ({
        "clutch":  { icon: "🛡️", name: "极限救场" },
        "flow":    { icon: "🌊", name: "流畅操作" },
        "precise": { icon: "🎯", name: "精准落位" }
    })
    function earnBadge(id) {
        for (var i = 0; i < gameBadges.length; i++)
            if (gameBadges[i] === id) return
        gameBadges.push(id)
        showToast(badgeDefs[id].icon, badgeDefs[id].name)
    }
    property string toastIcon: ""
    property string toastText: ""
    Timer { id: toastTimer; interval: 2200; onTriggered: toastText = "" }
    function showToast(icon, text) {
        toastIcon = icon
        toastText = text
        toastTimer.restart()
    }
    // 结算页「本局亮点」：取徽章之最（clutch > flow > precise），无徽章回退战绩句
    function recapHighlight() {
        if (gameBadges.indexOf("clutch") !== -1) return "🛡️ 危险时刻极限救场"
        if (gameBadges.indexOf("flow") !== -1) return "🌊 行云流水未涉险境"
        if (gameBadges.indexOf("precise") !== -1) return "🎯 落位分毫不差"
        if (tetrisCount > 0) return "🧱 打出 " + tetrisCount + " 次四行消除"
        if (maxCombo >= 3) return "🔥 最高连击 x" + maxCombo
        return "稳扎稳打的一局"
    }

    // 震动三档：off 静音 / std 标准 / strong 加强（时长 1.8 倍）
    function vibe(ms) {
        if (vibeLevel === "off") return
        if (typeof NativeVibe === "undefined") return
        NativeVibe.buzz(vibeLevel === "strong" ? Math.round(ms * 1.8) : ms)
    }

    property var pendingApiQ: []        // 安卓 nativeHttp 的请求队列（Java 侧单线程池按序返回，FIFO 匹配）

    function nativeHttpSend(item) {
        if (item.method === "POST") nativeHttp.post(apiBase + item.path, item.body)
        else nativeHttp.get(apiBase + item.path)
    }

    function nativeDispatch(response) {
        var nl = response.indexOf("\n")
        var head = nl >= 0 ? response.slice(0, nl) : response
        var body = nl >= 0 ? response.slice(nl + 1) : ""
        var status = parseInt(head.slice(3), 10)
        var data = null
        try { data = JSON.parse(body) } catch (e) {}
        var ok = head.indexOf("OK") === 0 && status >= 200 && status < 300 && !!data && data.ok === true
        var detail = ok ? "" : (head.indexOf("ERR") === 0 ? "NET(" + head.slice(4) + ")" : "HTTP" + status + (data && data.error ? " " + data.error : ""))
        var done = pendingApiQ.shift()   // 队首 = 最早发起的请求（Java 单线程池保证响应顺序）
        if (done) done.cb(ok, data, detail)
        if (pendingApiQ.length > 0) nativeHttpSend(pendingApiQ[0])   // 串行发下一个
    }

    Connections {
        target: typeof nativeHttp !== "undefined" ? nativeHttp : null
        function onDone(response) {
            nativeDispatch(response)
        }
    }

    function apiRequest(method, apiPath, rawBody, cb) {
        if (Qt.platform.os === "android") {
            // 安卓：走系统网络栈（Qt 缺 OpenSSL TLS 后端，XHR https 全挂）。
            // 请求串行排队（FIFO），不再因"忙"直接拒绝——排行/提交/补录可同屏并发
            pendingApiQ.push({ method: method, path: apiPath, body: rawBody, cb: cb })
            if (pendingApiQ.length === 1) nativeHttpSend(pendingApiQ[0])
        } else {
            xhrRequest(method, apiBase + apiPath, rawBody, cb)
        }
    }

    function xhrRequest(method, url, rawBody, cb) {
        var xhr = new XMLHttpRequest()
        xhr.open(method, url)
        if (method === "POST") xhr.setRequestHeader("Content-Type", "application/json")
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var data = null
            try { data = JSON.parse(xhr.responseText) } catch (e) {}
            var ok = xhr.status >= 200 && xhr.status < 300 && !!data && data.ok === true
            var detail = ok ? "" : (xhr.status === 0 ? "NET" : ("HTTP" + xhr.status + (data && data.error ? " " + data.error : "")))
            cb(ok, data, detail)
        }
        xhr.send(rawBody === "" ? null : rawBody)
    }

    function apiPost(apiPath, body, cb) {
        apiRequest("POST", apiPath, JSON.stringify(body), cb)
    }

    function apiGet(apiPath, cb) {
        apiRequest("GET", apiPath, "", cb)
    }

    // 设置名字后补录本地最高分。必须带真实行数/用时：服务端“同分比用时”会用
    // 新数据覆盖旧数据，假数据(0行/5秒)会把真实战绩洗成 0
    function uploadBest() {
        if (submitPending || bestScore <= 0 || playerName === "") return
        submitPending = true
        apiPost("score", { uid: playerUid, name: playerName, score: bestScore,
                           lines: bestLines, time: bestTime >= 5 ? bestTime : 5,
                           adopt: pendingAdopt }, function (ok, data, detail) {
            submitPending = false
            if (ok && data) {
                pendingAdopt = ""
                myRankText = "已上榜 · 全服第 " + data.rank + " 名"
            } else {
                myRankText = "补录失败(" + detail + ")"
            }
        })
    }

    function submitScore() {
        if (submitPending) return
        var name = playerName.trim()
        if (name === "") {
            myRankText = "先在上方输入名字"
            return
        }
        submitPending = true
        myRankText = "提交中……"
        apiPost("score", { uid: playerUid, name: name, score: scoreTarget, lines: totalClearedLines, time: playSeconds, adopt: pendingAdopt }, function (ok, data, detail) {
            submitPending = false
            if (ok && data) {
                pendingAdopt = ""
                myRankText = "已上榜 · 全服第 " + data.rank + " 名"
            } else if (detail === "NET") {
                myRankText = "提交失败：网络未连通"
            } else {
                myRankText = "提交失败(" + detail + ")"
            }
        })
    }

    function fetchTop() {
        lbLoading = true
        lbRows = []
        lbTotal = 0
        lbError = false
        apiGet("top?limit=10", function (ok, data, detail) {
            lbLoading = false
            if (ok && data) {
                lbRows = data.top
                lbTotal = data.total
            } else {
                lbError = true
            }
        })
    }

    function triggerScreenShake(linesCleared) {
        var amplitude = Math.round(Math.min(14, 6 + linesCleared * 2) * fxShakeScale)
        var yAmp = Math.round(Math.min(10, 2 + linesCleared * 2) * fxShakeScale)
        if (amplitude <= 0 && yAmp <= 0)
            return   // 减少动态/治愈低档：无震屏
        shakeAnimation.stop()
        root.shakeOffsetX = amplitude
        shakeForward.to = -amplitude
        root.shakeYAmplitude = yAmp
        thumpAnimation.restart()
        shakeAnimation.restart()
    }

    function triggerLineClearEffects(clearedRows, linesCleared) {
        lineClearEffectColor = scoreColorForLines(linesCleared)
        lineClearEffects = clearedRows
        clearEffectTimer.restart()
        // 每种消行自己的运动语言（颜色已按行数分级）：
        //   双消：第二道冰蓝波纹错位 80ms；三消：橙色碎片自行中心斜上迸发
        if (linesCleared === 2) {
            wave2Pending = clearedRows
            wave2Timer.restart()
        } else {
            lineClearWave2 = []
        }
        if (linesCleared === 3) {
            for (var i = 0; i < clearedRows.length; i++)
                debrisBurst.burst(7, gameBoard.width / 2,
                                  clearedRows[i] * blockSize + blockSize / 2)
        }
    }

    // 危险三段（基于真实堆叠最高点）：顶部2行→3 / 顶部4行→2 / 顶部6行→1 / 其余 0。
    // grid 为原地变更，绑定时序不可靠 → 由 lockPiece/startGame/演示场景命令式刷新 dangerLv
    function dangerLevel() {
        if (grid.length === 0) return 0
        for (var r = 0; r < rows; r++)
            for (var c = 0; c < cols; c++)
                if (grid[r][c] !== 0) {
                    if (r < 2) return 3
                    if (r < 4) return 2
                    if (r < 6) return 1
                    return 0
                }
        return 0
    }
    function refreshDanger() { dangerLv = dangerLevel() }

    // 移动/旋转前的当前形态快照（残影）
    function spawnAfterimage() {
        if (currentShape.length === 0) return
        var cells = []
        for (var r = 0; r < currentShape.length; r++)
            for (var c = 0; c < currentShape[r].length; c++)
                if (currentShape[r][c]) cells.push({ c: posX + c, r: posY + r })
        // 同 spawnScoreFloat：整体重赋值触发 Repeater 刷新（cells 本身是新数组，push 无妨）
        var next = afterimages.concat([{ cells: cells, color: currentColor, ts: Date.now() }])
        afterimages = next.length > 2 ? next.slice(next.length - 2) : next   // 残影只留 1-2 个关键位置
        afterimageTimer.restart()
    }

    function triggerDropShockwave(cx, cy) {
        dropShockwave.x = cx - dropShockwave.width / 2
        dropShockwave.y = cy - dropShockwave.height / 2
        dropShockwave.visible = true
        shockwaveAnimation.restart()
    }

    // Tetris 三段式演出：蓄力(0-70ms 压缩+行增亮) → 释放(70-180ms 闪光/环/火花/震屏/文字) → 回落(自然衰减)
    // 减少动态：跳过压缩阶段与闪光/环，仅保留文字与灼烧色反馈
    function triggerTetrisCelebration(b2b, earned) {
        bigFxUntil = Date.now() + 900           // 里程碑/解锁演出让位（避免同帧撞车）
        tetrisB2b = b2b
        tetrisEarned = earned
        if (reduceMotion) {
            tetrisRelease()
            return
        }
        boardPunch = 0.99                       // 蓄力：棋盘微压缩
        tetrisReleaseTimer.restart()            // 70ms 后释放（回弹+全部大特效）
    }
    function tetrisRelease() {
        console.warn("[Release] zen=" + zenFx + " rm=" + reduceMotion + " flashMs=" + fxFlashMs)
        if (!reduceMotion) {
            if (fxFlashMs > 0) {
                flashOverlay.visible = true
                flashAnimation.restart()
            }
            if (!zenFx) {
                bgBurnOverlay.visible = true
                burnAnimation.restart()
            }
            var cy = mainColumn.y + gameBoard.y + gameBoard.height / 2
            var oy = mainColumn.y + mainColumn.height / 2
            cy = oy + root.contentScale * (cy - oy)
            tetrisRing1.y = cy - tetrisRing1.height / 2
            tetrisRing2.y = cy - tetrisRing2.height / 2
            tetrisRing1.visible = true
            tetrisRing2.visible = true
            tetrisRingsAnimation.restart()
            sparkBurst.burst(Math.round(12 * fxParticleScale),
                             gameBoard.width / 2, gameBoard.height / 2)
            dimBurst.burst(Math.round(16 * fxParticleScale),
                           gameBoard.width / 2, gameBoard.height / 2)
            triggerScreenShake(4)
            punchAnimation.restart()            // 0.99 回弹到 1.035 再回落 = 释放冲击
        }
        triggerScoreBurst(tetrisEarned, comboStreak, 4, tetrisB2b)
        triggerComboCenterBurst(comboStreak)
    }

    function pauseGame() {
        if (isPaused) return
        isPaused = true
        gameLoop.stop()
        scoreTimer.stop()
        playTimeTimer.stop()
        lockDelayTimer.stop()
    }

    function resumeGame() {
        if (isGameOver || !isPaused) return
        isPaused = false
        gameLoop.start()
        playTimeTimer.start()
        if (score < scoreTarget) scoreTimer.start()
        if (checkCollision(posX, posY + 1, currentShape)) lockDelayTimer.start()
    }

    function updateDropSpeed() {
        var nextInterval = baseDropInterval - totalClearedLines * dropAccelerationPerLine
        gameLoop.interval = Math.max(minDropInterval, nextInterval)
    }

    function startGame() {
        grid = createEmptyGrid()
        score = 0
        scoreTarget = 0
        comboStreak = 0
        comboDisplayText = ""
        comboEnergy = 0
        totalClearedLines = 0
        isPaused = false
        lineClearEffects = []
        settleFallers = []
        settleHiddenMap = ({})
        settleTimer.stop()
        bagQueue = []
        holdShapeIndex = -1
        canHold = true
        b2bActive = false
        maxCombo = 0
        tetrisCount = 0
        b2bCount = 0
        gameBadges = []
        cleanClearStreak = 0
        newUnlocks = 0
        recapCompact = false
        dangerLv = 0
        playSeconds = 0
        myRankText = ""
        submitPending = false
        playTimeTimer.restart()
        lockDelayTimer.stop()
        updateDropSpeed()
        isGameOver = false
        prepareNextPiece()
        spawnPiece()
        gameLoop.start()
    }

    function formatPlayTime(s) {
        var m = Math.floor(s / 60)
        var ss = s % 60
        return (m < 10 ? "0" : "") + m + ":" + (ss < 10 ? "0" : "") + ss
    }

    // 生成新方块
    function spawnPiece() {
        currentShapeIndex = nextShapeIndex
        currentShape = cloneShape(nextShape)
        currentColor = nextColor
        prepareNextPiece()
        posX = Math.floor(cols / 2) - Math.floor(currentShape[0].length / 2)
        posY = 0
        lowestRow = 0
        lockResets = 0
        lockDelayTimer.stop()
        canHold = true

        // 检查生成即碰撞（游戏结束）
        if (checkCollision(posX, posY, currentShape)) {
            gameOver()
        }
    }

    // Hold：暂存当前方块换出暂存区的（每个方块限一次）
    function holdPiece() {
        if (isGameOver || isPaused || !canHold) return
        lockDelayTimer.stop()
        var cur = currentShapeIndex
        if (holdShapeIndex < 0) {
            holdShapeIndex = cur
            spawnPiece()
        } else {
            var swap = holdShapeIndex
            holdShapeIndex = cur
            currentShapeIndex = swap
            currentShape = cloneShape(shapes[swap])
            currentColor = colors[swap]
            posX = Math.floor(cols / 2) - Math.floor(currentShape[0].length / 2)
            posY = 0
            lowestRow = 0
            lockResets = 0
            if (checkCollision(posX, posY, currentShape)) {
                gameOver()
                return
            }
        }
        canHold = false
    }

    // 碰撞检测
    function checkCollision(x, y, shape) {
        for (var r = 0; r < shape.length; r++) {
            for (var c = 0; c < shape[r].length; c++) {
                if (shape[r][c]) {
                    var newX = x + c
                    var newY = y + r
                    // 边界检查
                    if (newX < 0 || newX >= cols || newY >= rows) return true
                    // 堆叠检查 (忽略负的Y，允许在屏幕上方)
                    if (newY >= 0 && grid[newY][newX]) return true
                }
            }
        }
        return false
    }

    // 锁定方块到网格。fast=true（硬降）：落点闪光提速至 140ms，强调"落在哪"
    function lockPiece(fast) {
        lockDelayTimer.stop()
        vibe(15)
        var flashCells = []
        for (var r = 0; r < currentShape.length; r++) {
            for (var c = 0; c < currentShape[r].length; c++) {
                if (currentShape[r][c]) {
                    if (posY + r >= 0) { // 防止在顶部溢出
                        grid[posY + r][posX + c] = currentColor
                        flashCells.push({ col: posX + c, row: posY + r })
                    }
                }
            }
        }
        lockFlashes = flashCells
        lockFlashTimer.interval = fast ? 140 : 320
        lockFlashTimer.restart()
        clearLines()
        refreshGrid()
        refreshDanger()
        spawnPiece()
    }

    // 消除行
    function clearLines() {
        // 先按原始行号收集满行再统一删除，保证特效行号准确
        var clearedRows = []
        for (var r = 0; r < rows; r++) {
            if (isRowFull(grid[r])) {
                clearedRows.push(r)
            }
        }
        var linesCleared = clearedRows.length
        if (linesCleared === 0) {
            // 连击不清零：交由能量槽随时间衰减，能量归零才结束连击
            return
        }
        // 阶段5 过程徽章（判定取消行前的危险态，严格可复现）
        if (dangerLv >= 2) {
            earnBadge("clutch")                  // 极限救场：危险态完成消行
        } else if (dangerLv < 2) {
            cleanClearStreak++
            if (cleanClearStreak >= 6) earnBadge("flow")   // 流畅操作：连续 6 次消行未入危险区
        }
        // 碎片：按删行前的布局记录被消方块的原始位置与颜色
        var frags = []
        for (var fi = 0; fi < clearedRows.length; fi++)
            for (var fc = 0; fc < cols; fc++)
                if (grid[clearedRows[fi]][fc] !== 0)
                    frags.push({ col: fc, row: clearedRows[fi], color: grid[clearedRows[fi]][fc] })
        // 重力结算：按删行前的布局算每个悬空方块的落点（下方被清几行就掉几格）
        var clearedSet = {}
        for (var c1 = 0; c1 < clearedRows.length; c1++) {
            clearedSet[clearedRows[c1]] = true
        }
        var fallers = []
        var hidden = {}
        for (var fr = 0; fr < rows; fr++) {
            if (clearedSet[fr] === true) continue
            var drop = 0
            for (var fc = 0; fc < clearedRows.length; fc++) {
                if (clearedRows[fc] > fr) drop++
            }
            if (drop === 0) continue
            for (var c2 = 0; c2 < cols; c2++) {
                var cell = grid[fr][c2]
                if (cell !== 0) {
                    fallers.push({ col: c2, fromRow: fr, toRow: fr + drop, color: cell })
                    hidden[(fr + drop) + "_" + c2] = true
                }
            }
        }
        // 从下往上删，删除行不影响下方已记录的行号
        for (var i = linesCleared - 1; i >= 0; i--) {
            grid.splice(clearedRows[i], 1)
        }
        for (var k = 0; k < linesCleared; k++) {
            grid.unshift(Array(cols).fill(0))
        }
        applySettle(fallers, hidden)
        lineClearFragments = frags
        rowFlashes = clearedRows
        rowFlashTimer.restart()
        if (!reduceMotion && linesCleared < 4)
            punchAnimation.restart()          // 四消走三段式演出（蓄力压缩），普通消行才用脉冲
        // P1 大事件（3/4 消）让位：背景压暗、氛围粒子减速 800ms
        if (linesCleared >= 3) {
            fxSurge = true
            fxSurgeTimer.restart()
        }
        bgTintOverlay.color = scoreColorForLines(linesCleared)
        bgTintOverlay.visible = true
        bgTintAnimation.restart()
        triggerLineClearEffects(clearedRows, linesCleared)
        if (comboStreak > maxCombo) maxCombo = comboStreak
        var isDifficult = linesCleared >= 4
        var b2bBonus = isDifficult && b2bActive
        b2bActive = isDifficult
        comboStreak++
        comboDisplayText = comboStreak > 1 ? (comboStreak + "x") : ""
        // 阶段5 结果徽章计数 + 局内里程碑（新背景解锁复用现有演出，不加 toast）
        if (isDifficult) {
            tetrisCount++
            if (tetrisCount === 1) showToast("🎉", "本局首次四消！")
        }
        if (b2bBonus) b2bCount++
        if (comboStreak === 5) showToast("🔥", "连击 x5")
        else if (comboStreak === 7) showToast("🔥", "连击 x7")
        // 精准落位：本块锁定格子全部属于被消的行
        if (lockFlashes.length > 0) {
            var allInCleared = true
            for (var lc = 0; lc < lockFlashes.length; lc++)
                if (clearedSet[lockFlashes[lc].row] !== true) { allInCleared = false; break }
            if (allInCleared) earnBadge("precise")
        }
        comboEnergy = 100                    // 连击保鲜：消行瞬间回满
        totalClearedLines += linesCleared
        updateDropSpeed()
        var basePoints = scoreForClearedLines(linesCleared)
        var earnedPoints = basePoints * comboStreak
        if (b2bBonus) earnedPoints = Math.floor(earnedPoints * 1.5)
        if (linesCleared >= 3)
            bigFxUntil = Date.now() + 900   // 必须先于 scoreTarget 变更：解锁检查据此让位
        scoreTarget += earnedPoints
        if (linesCleared >= 4) {
            // 四消三段式：蓄力(0-70ms 压缩+行增亮) → 释放(闪光/环/火花/震屏/文字) → 回落
            triggerTetrisCelebration(b2bBonus, earnedPoints)
        } else {
            triggerScoreBurst(earnedPoints, comboStreak, linesCleared, b2bBonus)
            triggerScreenShake(linesCleared)
            triggerComboCenterBurst(comboStreak)
        }
        vibe(linesCleared >= 4 ? 70 : 35)
        scoreTimer.start()
    }

    // 自由落体 t∝√h（InQuad 缓动=恒定重力加速度），反弹高度按恢复系数逐次衰减
    function settleDuration(dropRows) {
        var tFall = settleAccelMs * Math.sqrt(dropRows)
        var tBounce = settleAccelMs * Math.sqrt(Math.min(dropRows * 0.32, 1.6))
        return tFall + 3.1 * tBounce
    }

    // 播放下落反弹动画；动画期间落点格先隐藏，结束后由 settleTimer 恢复
    function applySettle(fallers, hidden) {
        settleFallers = fallers
        settleHiddenMap = hidden
        var maxDur = 0
        for (var i = 0; i < fallers.length; i++) {
            maxDur = Math.max(maxDur, settleDuration(fallers[i].toRow - fallers[i].fromRow))
        }
        if (maxDur === 0) return
        settleTimer.interval = maxDur + 40
        settleTimer.restart()
    }

    // --- 移动控制 ---
    function moveLeft() {
        if (isGameOver || isPaused) return
        if (!checkCollision(posX - 1, posY, currentShape)) {
            spawnAfterimage()
            posX--
            onPieceMoved()
        }
    }
    function moveRight() {
        if (isGameOver || isPaused) return
        if (!checkCollision(posX + 1, posY, currentShape)) {
            spawnAfterimage()
            posX++
            onPieceMoved()
        }
    }
    // 重力 tick：能下则下（离地取消锁定延迟），触底则启动锁定延迟
    function moveDown() {
        if (isGameOver || isPaused) return
        if (!checkCollision(posX, posY + 1, currentShape)) {
            posY++
            if (posY > lowestRow) {
                lowestRow = posY
                lockResets = 0
            }
            lockDelayTimer.stop()
        } else if (!lockDelayTimer.running) {
            lockDelayTimer.restart()
        }
    }
    // 手动软降：+1 分/格（直接进显示分，立即可见），伴随 +1 小飘字
    function softDropStep() {
        if (isGameOver || isPaused) return
        if (!checkCollision(posX, posY + 1, currentShape)) {
            posY++
            scoreTarget++
            score++
            bumpBest(score)
            if (posY > lowestRow) {
                lowestRow = posY
                lockResets = 0
            }
            spawnScoreFloat("+1")
            lockDelayTimer.stop()
        }
    }
    // 手动到底：+2 分/格，立即锁定；带速度线/冲击波/纵向砸击
    function hardDrop() {
        if (isGameOver || isPaused) return
        var streaks = []
        for (var c = 0; c < currentShape[0].length; c++) {
            for (var r = 0; r < currentShape.length; r++) {
                if (currentShape[r][c]) {
                    streaks.push({ x: (posX + c) * blockSize + 3, y0: (posY + r) * blockSize, y1: 0, color: currentColor })
                    break
                }
            }
        }
        var rows = 0
        while (!checkCollision(posX, posY + 1, currentShape)) {
            posY++
            rows++
        }
        scoreTarget += rows * 2
        score += rows * 2
        bumpBest(score)
        var bottomY = (posY + currentShape.length) * blockSize
        if (rows > 0) spawnScoreFloat("+" + rows * 2)
        for (var s = 0; s < streaks.length; s++)
            streaks[s].y1 = bottomY
        dropStreaks = streaks
        streakTimer.restart()
        triggerDropShockwave((posX + currentShape[0].length / 2) * blockSize, bottomY)
        dustBurst.burst(Math.round(10 * fxParticleScale),
                        (posX + currentShape[0].length / 2) * blockSize, bottomY - blockSize * 0.5)
        // 震屏随下落距离递增（封顶 8px），减少动态时归零
        root.shakeYAmplitude = Math.round(Math.min(8, 2 + rows * 0.7) * fxShakeScale)
        thumpAnimation.restart()
        lockPiece(true)
    }
    // 移动/旋转成功后调用：触底则刷新锁定延迟（有次数上限，防止无限拖延）
    // 移动/旋转成功后调用：触底则刷新锁定延迟（有次数上限），离地则取消待锁定（防止半空锁定）
    function onPieceMoved() {
        if (isGameOver || isPaused) return
        if (checkCollision(posX, posY + 1, currentShape)) {
            if (lockResets < 10) {
                lockDelayTimer.restart()
                lockResets++
            } else if (!lockDelayTimer.running) {
                lockDelayTimer.start()
            }
        } else {
            lockDelayTimer.stop()
        }
    }
    // 旋转
    function rotate() {
        if (isGameOver || isPaused) return
        // 矩阵转置后反转实现旋转
        var newShape = []
        for (var c = 0; c < currentShape[0].length; c++) {
            var newRow = []
            for (var r = currentShape.length - 1; r >= 0; r--) {
                newRow.push(currentShape[r][c])
            }
            newShape.push(newRow)
        }
        // I 型：绕自身近侧边缘旋转——靠右缘近 → 转完右缘对齐原右缘（向左伸展）；
        // 靠左缘近 → 左缘对齐原左缘（向右伸展）。不再锚定棋盘墙。
        // 落点被堆叠挡住时从锚点向原位置逐格回退取最近空位，全堵则退回普通踢墙（含上踢）。
        if (currentShapeIndex === 0) {
            var oldW = currentShape[0].length
            var oldRight = posX + oldW - 1
            var nearRight = (cols - 1 - oldRight) < posX
            var newW = newShape[0].length
            var anchorX = nearRight ? oldRight - (newW - 1) : posX
            var step = anchorX <= posX ? 1 : -1
            for (var xx = anchorX; step > 0 ? xx <= posX : xx >= posX; xx += step) {
                if (!checkCollision(xx, posY, newShape)) {
                    spawnAfterimage()
                    posX = xx
                    currentShape = newShape
                    onPieceMoved()
                    return
                }
            }
            // 贴墙侧全被占（贴地旋转等）：退回普通踢墙（含上踢）
            var kicksI = [[0, 0], [-1, 0], [1, 0], [-2, 0], [2, 0], [-3, 0], [3, 0], [0, -1]]
            for (var i = 0; i < kicksI.length; i++) {
                if (!checkCollision(posX + kicksI[i][0], posY + kicksI[i][1], newShape)) {
                    spawnAfterimage()
                    posX += kicksI[i][0]
                    posY += kicksI[i][1]
                    currentShape = newShape
                    onPieceMoved()
                    return
                }
            }
            return
        }
        // 其他方块：简易踢墙（贴墙/贴地转不动时平移后再转）
        var kicks = [[0, 0], [-1, 0], [1, 0], [0, -1]]
        for (var j = 0; j < kicks.length; j++) {
            if (!checkCollision(posX + kicks[j][0], posY + kicks[j][1], newShape)) {
                spawnAfterimage()
                posX += kicks[j][0]
                posY += kicks[j][1]
                currentShape = newShape
                onPieceMoved()
                return
            }
        }
    }

    function gameOver() {
        isGameOver = true
        isPaused = false
        gameLoop.stop()
        scoreTimer.stop()
        playTimeTimer.stop()
        lockDelayTimer.stop()
        score = scoreTarget
        bumpBest(score)
        // 永久累计战绩（settingsVersion 清档机制不清这四项之外的本局数据）
        totalGames++
        totalLinesAll += totalClearedLines
        totalSecondsAll += playSeconds
        maxComboAll = Math.max(maxComboAll, maxCombo)
        // 已有名字则本局成绩自动上榜（真实行数/用时），失败仍可手动点按钮重提
        if (playerName !== "" && scoreTarget > 0)
            submitScore()
        vibe(220)
    }

    // --- UI 绘制部分 ---

    // 背景（动态漂移 + 呼吸明暗 + 主题切换；Image 不参与锚定，避免与动画冲突）
    Item {
        id: bgHost
        anchors.fill: parent
        clip: true

        Image {
            id: bgImage
            x: -26
            y: -18
            width: bgHost.width + 92
            height: bgHost.height + 92
            source: bgFallback ? "qrc:/Tetris/image.jpg" : bgUrl(bgChoice)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true   // 大图解码放后台线程，主题切换不卡 GUI 帧
            opacity: 0.18
            onStatusChanged: if (status === Image.Error && !bgFallback) bgFallback = true
        }

        // 背景漂移/呼吸低频驱动：200ms 步进（x 全周期 34s），降低渲染压力
        Timer {
            id: bgAnimTimer
            interval: 200
            repeat: true
            running: !isPaused && !showBgPicker && Qt.application.state === Qt.ApplicationActive
            onTriggered: {
                // P1 大事件让位：背景压暗 ~25%
                bgImage.opacity = (0.19 + Math.sin(bgPhase * 0.42) * 0.05) * (fxSurge ? 0.75 : 1.0)
                bgPhase += 0.037
                bgImage.x = -26 + Math.sin(bgPhase) * 26
                bgImage.y = -18 + Math.sin(bgPhase * 0.74) * 18
            }
        }

        // 主题环境粒子（随主题换色/换向；低密度漂浮）：背景层，永远盖不到棋盘/控件
        ParticleSystem { id: ambientSys }

        ItemParticle {
            system: ambientSys
            fade: true
            delegate: Rectangle {
                width: 6; height: 6; radius: 3
                color: ambientColor
                opacity: 0.55
            }
        }

        Emitter {
            id: ambientEmitter
            system: ambientSys
            width: parent.width
            height: 8
            x: 0
            y: ambientRise ? parent.height - 8 : 0
            enabled: !isPaused && Qt.application.state === Qt.ApplicationActive
            // P1 大事件让位（fxSurge）：环境粒子降到 40%；预设/减少动态缩放数量
            emitRate: 4 * fxParticleScale * (fxSurge ? 0.4 : 1.0)
            lifeSpan: 9000
            size: 6; endSize: 3
            velocity: AngleDirection {
                angle: ambientRise ? 270 : 90
                angleVariation: 12
                magnitude: ambientSpeed
                magnitudeVariation: 8
            }
        }

        // 消行背景泛光 / Tetris 背景灼烧（盖背景图、内容之下）
        Rectangle {
            id: bgTintOverlay
            anchors.fill: parent
            color: lineClearEffectColor
            opacity: 0
            visible: false
        }

        Rectangle {
            id: bgBurnOverlay
            anchors.fill: parent
            color: "#ff7a18"
            opacity: 0
            visible: false
        }
    }

    // 帧泵：软件渲染下若暂停/结束后无任何动画驱动，面板可能永远不被绘制上屏；
    // 用角落 2x2 微件的透明度振荡持续制造微小脏区冲刷帧。
    // 仅在需要时运行：游戏中本来就有下落/特效在驱动渲染，常开会让整窗全程满帧重绘耗电
    Rectangle {
        width: 2
        height: 2
        color: "#111111"
        opacity: 0.5
        SequentialAnimation on opacity {
            running: isPaused || isGameOver || root.forceFrames
            loops: Animation.Infinite
            NumberAnimation { to: 0.1; duration: 500 }
            NumberAnimation { to: 0.5; duration: 500 }
        }
    }

    // 解锁成就演出（轻遮罩 + 渐变 + 主题名弹出；星星由 fxSystem 火花承担）
    Rectangle {
        id: unlockCelebrate
        anchors.fill: parent
        visible: unlockCelebrateName !== ""
        color: "#48000000"
        z: 55

        Rectangle {
            id: unlockGradient
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#66ffd95a" }
                GradientStop { position: 1.0; color: "#10ffd95a" }
            }
            opacity: 0.7
        }

        Text {
            id: unlockCelebrateLabel
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.16
            text: unlockCelebrateName === "" ? "" : "解锁背景\n" + unlockCelebrateName
            color: "#ffd95a"
            font.pixelSize: 26
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            style: Text.Outline
            styleColor: "#000000"
            transformOrigin: Item.Center
            scale: 0.7
            opacity: 0
        }
    }

    SequentialAnimation {
        id: unlockCelebrateAnim
        running: false

        ParallelAnimation {
            NumberAnimation { target: unlockCelebrateLabel; property: "scale"; from: 0.6; to: 1.15; duration: 420; easing.type: Easing.OutBack }
            NumberAnimation { target: unlockCelebrateLabel; property: "opacity"; from: 0; to: 1; duration: 250 }
            NumberAnimation { target: unlockGradient; property: "opacity"; from: 0.7; to: 0.15; duration: 1500 }
        }
        PauseAnimation { duration: 1100 }
        ParallelAnimation {
            NumberAnimation { target: unlockCelebrateLabel; property: "opacity"; to: 0; duration: 450; easing.type: Easing.InQuad }
            NumberAnimation { target: unlockGradient; property: "opacity"; to: 0; duration: 450 }
        }
        ScriptAction { script: unlockCelebrate.visible = false }
    }

    Item {
        id: comboBurstOverlay
        anchors.fill: parent
        visible: false
        z: 20

        Rectangle {
            id: comboBurstBackdrop
            anchors.fill: parent
            color: "#7a1f00"
            opacity: 0
        }

        Item {
            id: comboBurstCore
            width: 340
            height: 340
            anchors.centerIn: parent
            opacity: 0.95

            Rectangle {
                width: 300
                height: 300
                radius: 150
                anchors.centerIn: parent
                color: "transparent"
                border.width: 12
                border.color: "#ff7a18"
                opacity: 0.75
            }

            Rectangle {
                width: 210
                height: 210
                radius: 105
                anchors.centerIn: parent
                color: "transparent"
                border.width: 8
                border.color: "#ffd15e"
                opacity: 0.85
            }

            Rectangle {
                width: 120
                height: 120
                radius: 60
                anchors.centerIn: parent
                color: "#ffb03a"
                opacity: 0.38
            }
        }

        Text {
            id: comboCenterLabel
            anchors.centerIn: parent
            text: comboCenterText
            color: "#ffd37a"
            font.pixelSize: 56
            font.bold: true
            style: Text.Outline
            styleColor: "#ff4f00"
            opacity: 0
        }
    }

    // 棋盘下移量：按键模式少量腾出能量条空间；手势模式底部无按钮，下移更多
    readonly property int boardTopOffset: opMode === "gestures" ? 20 : 8

    Column {
        id: mainColumn
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: boardTopOffset
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 8

        transform: Scale {
            xScale: root.contentScale
            yScale: root.contentScale
            origin.x: mainColumn.width / 2
            origin.y: mainColumn.height / 2
        }

        Row {
            width: gameBoard.width
            spacing: 12
            anchors.horizontalCenter: parent.horizontalCenter

            // 左侧：当前分数 + 历史最高分
            Column {
                id: scoreColumn
                spacing: 6
                width: 112
                anchors.verticalCenter: parent.verticalCenter

                Item {
                    width: parent.width
                    height: 34

                    Text {
                        id: scoreText
                        text: "分数: " + score
                        color: "#F5F1E8"
                        font.pixelSize: 21
                        font.bold: false
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        id: scoreBurstGlow
                        text: scoreBurstText
                        visible: false
                        color: "#ff5a5a"
                        font.pixelSize: 22
                        font.bold: true
                        x: scoreText.width + 8
                        y: 4
                        z: 1
                    }

                    Text {
                        id: scoreBurstLabel
                        text: scoreBurstText
                        visible: false
                        color: scoreBurstColor
                        font.pixelSize: 20
                        font.bold: true
                        style: Text.Outline
                        styleColor: scoreBurstOutlineColor
                        x: scoreText.width + 8
                        y: 4
                        z: 2
                    }

                    // 软降/到底加分飘字：分数旁上飘淡出（寿命 620ms 与 scoreFloatTimer 对齐）
                    Repeater {
                        model: scoreFloats
                        delegate: Text {
                            x: scoreText.width + 6 + modelData.dx
                            y: 22
                            text: modelData.text
                            color: "#ffe9a8"
                            font.pixelSize: 14
                            font.bold: true
                            style: Text.Outline
                            styleColor: "#000000"
                            z: 1

                            NumberAnimation on y {
                                from: 22
                                to: -10
                                duration: 620
                                easing.type: Easing.OutQuad
                                running: true
                            }
                            NumberAnimation on opacity {
                                from: 1
                                to: 0
                                duration: 620
                                easing.type: Easing.InQuad
                                running: true
                            }
                        }
                    }
                }

                Text {
                    text: "最高: " + bestScore
                    color: "#B9C4C8"
                    font.pixelSize: 15
                    font.bold: false
                }

            }

            Column {
                id: topCenterColumn
                width: parent.width - scoreColumn.width - nextPreviewColumn.width - parent.spacing * 2
                spacing: 4
                anchors.verticalCenter: parent.verticalCenter

                Text {
                    text: comboDisplayText
                    color: "#ffd37a"
                    font.pixelSize: 28
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    width: parent.width
                    style: Text.Outline
                    styleColor: "#ff4f00"
                    opacity: comboDisplayText.length > 0 ? 1 : 0
                }

                Rectangle {
                    width: 72
                    height: 32
                    radius: 8
                    color: "#2f2f2fb0"
                    border.width: 1
                    border.color: "#8a8a8a"
                    anchors.left: parent.left
                    anchors.leftMargin: 0

                    Button {
                        anchors.fill: parent
                        text: "菜单"
                        onClicked: pauseGame()

                        background: Rectangle {
                            radius: 8
                            color: parent.down ? "#4d4d4d" : "transparent"
                            border.width: 0
                        }

                        contentItem: Text {
                            text: parent.text
                            color: "white"
                            font.pixelSize: 15
                            font.bold: false
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }

            // 右侧：下一个方块预览（标签在框外上方）
            Column {
                id: nextPreviewColumn
                spacing: 2
                width: 84
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                    id: nextPreview
                    width: 4 * 18
                    height: 4 * 18
                    anchors.horizontalCenter: parent.horizontalCenter
                    radius: 8
                    color: "#202020"
                    border.color: "#707070"
                    border.width: 1

                    Item {
                        anchors.centerIn: parent
                        width: nextShape.length > 0 ? nextShape[0].length * 16 : 0
                        height: nextShape.length * 16

                        Repeater {
                            model: nextShape.length
                            delegate: Repeater {
                                property int previewRow: index
                                model: nextShape[previewRow]
                                Rectangle {
                                    visible: modelData === 1
                                    x: index * 16
                                    y: previewRow * 16
                                    width: 16
                                    height: 16
                                    radius: 2
                                    color: nextColor
                                    border.color: "white"
                                    border.width: 1
                                }
                            }
                        }
                    }
                }

                // 暂存指示（手势模式下可见：上滑暂存/调出，用过置灰）
                Rectangle {
                    visible: opMode === "gestures"
                    width: 4 * 13
                    height: 4 * 13
                    anchors.horizontalCenter: parent.horizontalCenter
                    radius: 8
                    color: "#202020"
                    border.color: canHold ? "#707070" : "#3a3a3a"
                    border.width: 1
                    opacity: canHold ? 1.0 : 0.35

                    Item {
                        anchors.centerIn: parent
                        visible: holdShapeIndex >= 0
                        width: holdShapeIndex >= 0 ? shapes[holdShapeIndex][0].length * 9 : 0
                        height: holdShapeIndex >= 0 ? shapes[holdShapeIndex].length * 9 : 0

                        Repeater {
                            model: holdShapeIndex >= 0 ? shapes[holdShapeIndex].length : 0
                            delegate: Repeater {
                                property int hr: index
                                model: holdShapeIndex >= 0 ? shapes[holdShapeIndex][hr] : 0
                                Rectangle {
                                    visible: modelData === 1
                                    x: index * 9
                                    y: hr * 9
                                    width: 8
                                    height: 8
                                    radius: 2
                                    color: colors[holdShapeIndex]
                                    border.color: "white"
                                    border.width: 1
                                }
                            }
                        }
                    }
                }
            }
        }

        Item {
            width: 1
            height: 13
        }

        // 游戏画布区域

        // 连击能量槽卡片：横铺棋盘上方（连击 ≥2 显示），消行回满 / 随时间衰减
        Rectangle {
            id: energyCard
            visible: true                          // 常驻：无连击时槽为空
            width: gameBoard.width
            height: 68
            radius: 10
            color: "#F0141414"
            border.color: comboEnergy > 25 ? "#ff7a18" : "#ff4444"
            border.width: 1

            Column {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 4

                Item {
                    width: parent.width
                    height: 18

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "COMBO × " + comboStreak
                        color: "#f5f1e8"
                        font.pixelSize: 15
                        font.bold: true
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "连击状态"
                        color: "#ff9e3d"
                        font.pixelSize: 12
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 10
                    radius: 5
                    color: "#333333"
                    Rectangle {
                        width: parent.width * comboEnergy / 100
                        height: parent.height
                        radius: 5
                        color: comboEnergy > 25 ? "#ff7a18" : "#ff4444"
                    }
                }

                Item {
                    width: parent.width
                    height: 16

                    Rectangle {
                        width: 16
                        height: 16
                        radius: 4
                        anchors.left: parent.left
                        color: "#ff7a18"
                        Text {
                            anchors.centerIn: parent
                            text: "🔥"
                            font.pixelSize: 10
                        }
                    }
                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 22
                        anchors.verticalCenter: parent.verticalCenter
                        text: "连击能量： " + Math.round(comboEnergy) + "%"
                        color: "#f5f1e8"
                        font.pixelSize: 12
                    }
                }
            }
        }

        Rectangle {
            id: gameBoard
            width: cols * blockSize
            height: rows * blockSize
            anchors.horizontalCenter: parent.horizontalCenter
            clip: true
            color: "#18232B" // 游戏区域深蓝灰（治愈系配色规范）
            border.color: turboMode ? "#ff4444" : "transparent"   // 白边框太扎眼，仅极速模式显示警示红框
            border.width: 2
            transform: [
                Translate { x: root.shakeOffsetX; y: root.shakeOffsetY },
                Scale {
                    origin.x: gameBoard.width / 2
                    origin.y: gameBoard.height / 2
                    xScale: root.boardPunch
                    yScale: root.boardPunch
                }
            ]

            // 极速状态徽标（下落间隔到达安全下限时出现）
            Text {
                visible: turboMode && !isGameOver
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 6
                text: "⚡极速"
                color: "#ff6666"
                font.pixelSize: 13
                font.bold: true
                style: Text.Outline
                styleColor: "#000000"
            }

            // 1. 静态棋盘网格（不参与消行回弹）
            Repeater {
                model: rows
                delegate: Repeater {
                    property int rowIndex: index
                    model: cols
                    Rectangle {
                        x: index * blockSize
                        y: rowIndex * blockSize
                        width: blockSize
                        height: blockSize
                        border.color: "#35434B"
                        color: "#18232B"
                    }
                }
            }

            // 2. 已锁定方块
            Repeater {
                model: rows
                delegate: Repeater {
                    property int rowIndex: index
                    model: cols
                    GameBlock {
                        visible: grid[rowIndex][index] !== 0 && settleHiddenMap[rowIndex + "_" + index] !== true
                        x: index * blockSize
                        y: rowIndex * blockSize
                        width: blockSize
                        height: blockSize
                        baseColor: grid[rowIndex][index]
                    }
                }
            }

            // 3. 消行后的重力下落+反弹（物理：InQuad 匀加速下落，反弹高度按恢复系数衰减）
            Repeater {
                model: settleFallers
                delegate: GameBlock {
                    id: faller
                    property real dropDist: (modelData.toRow - modelData.fromRow) * blockSize
                    property real bounceH: Math.min(dropDist * 0.32, blockSize * 1.6)
                    property real tFallMs: settleAccelMs * Math.sqrt(dropDist / blockSize)
                    property real tBounceMs: settleAccelMs * Math.sqrt(bounceH / blockSize)

                    x: modelData.col * blockSize
                    y: modelData.fromRow * blockSize
                    width: blockSize
                    height: blockSize
                    baseColor: modelData.color

                    SequentialAnimation {
                        running: true
                        NumberAnimation { target: faller; property: "y"; from: modelData.fromRow * blockSize; to: modelData.toRow * blockSize; duration: faller.tFallMs; easing.type: Easing.InQuad }
                        NumberAnimation { target: faller; property: "y"; from: modelData.toRow * blockSize; to: modelData.toRow * blockSize - faller.bounceH; duration: faller.tBounceMs; easing.type: Easing.OutQuad }
                        NumberAnimation { target: faller; property: "y"; from: modelData.toRow * blockSize - faller.bounceH; to: modelData.toRow * blockSize; duration: faller.tBounceMs; easing.type: Easing.InQuad }
                        NumberAnimation { target: faller; property: "y"; from: modelData.toRow * blockSize; to: modelData.toRow * blockSize - faller.bounceH * 0.3; duration: faller.tBounceMs * 0.55; easing.type: Easing.OutQuad }
                        NumberAnimation { target: faller; property: "y"; from: modelData.toRow * blockSize - faller.bounceH * 0.3; to: modelData.toRow * blockSize; duration: faller.tBounceMs * 0.55; easing.type: Easing.InQuad }
                    }
                }
            }

            // 4. 落点投影（虚影）
            Repeater {
                model: currentShape.length
                delegate: Repeater {
                    property int gr: index
                    model: currentShape[gr]
                    Rectangle {
                        visible: modelData === 1 && ghostRow > posY
                        x: (posX + index) * blockSize
                        y: (ghostRow + gr) * blockSize
                        width: blockSize
                        height: blockSize
                        radius: 3
                        color: "transparent"
                        border.color: currentColor
                        border.width: 2
                        opacity: 0.35
                    }
                }
            }

            // 5. 绘制当前活动方块
            Repeater {
                model: currentShape.length
                delegate: Repeater {
                    property int r: index
                    model: currentShape[r]
                    GameBlock {
                        visible: modelData === 1
                        x: (posX + index) * blockSize
                        y: (posY + r) * blockSize
                        width: blockSize
                        height: blockSize
                        baseColor: currentColor
                    }
                }
            }

            Repeater {
                model: lineClearEffects
                delegate: Item {
                    property real rowTop: modelData * blockSize
                    x: 0
                    y: 0
                    width: gameBoard.width
                    height: gameBoard.height

                    // 光束扫描：亮光扫过被消的行
                    Rectangle {
                        x: -blockSize * 3
                        y: rowTop
                        width: blockSize * 3
                        height: blockSize
                        opacity: 0.95
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0) }
                            GradientStop { position: 0.55; color: lineClearEffectColor }
                            GradientStop { position: 0.82; color: "#ffffff" }
                            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0) }
                        }

                        NumberAnimation on x {
                            from: -blockSize * 3
                            to: gameBoard.width
                            duration: 240
                            easing.type: Easing.InQuad
                            running: true
                        }
                        NumberAnimation on opacity {
                            from: 0.95
                            to: 0
                            duration: 400
                            easing.type: Easing.InQuad
                            running: true
                        }
                    }
                }
            }

            // 双消第二道波纹：错位 80ms，冰蓝、更慢更透（两层错位扩散）
            Repeater {
                model: lineClearWave2
                delegate: Item {
                    property real rowTop: modelData * blockSize
                    x: 0
                    y: 0
                    width: gameBoard.width
                    height: gameBoard.height

                    Rectangle {
                        x: gameBoard.width
                        y: rowTop
                        width: blockSize * 3
                        height: blockSize
                        opacity: 0.7
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0) }
                            GradientStop { position: 0.6; color: "#9ed8ff" }
                            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0) }
                        }

                        NumberAnimation on x {
                            from: gameBoard.width
                            to: -blockSize * 3
                            duration: 280
                            easing.type: Easing.OutQuad
                            running: true
                        }
                        NumberAnimation on opacity {
                            from: 0.7
                            to: 0
                            duration: 320
                            easing.type: Easing.InQuad
                            running: true
                        }
                    }
                }
            }

            // 6. 消行碎片：方块裂成小块抛散
            Repeater {
                model: lineClearFragments
                delegate: GameBlock {
                    property real fragX: modelData.col * blockSize + blockSize * 0.225
                    property real fragY: modelData.row * blockSize + blockSize * 0.225
                    property real spreadX: (Math.random() - 0.5) * blockSize * 4.5
                    property real riseY: -Math.random() * blockSize * 2.2
                    property real fallY: blockSize * (1.0 + Math.random() * 1.8)
                    property real spin: (Math.random() - 0.5) * 540
                    width: blockSize * 0.55
                    height: blockSize * 0.55
                    x: fragX
                    y: fragY
                    baseColor: modelData.color

                    SequentialAnimation on y {
                        NumberAnimation { from: fragY; to: fragY + riseY; duration: 300; easing.type: Easing.OutQuad }
                        NumberAnimation { from: fragY + riseY; to: fragY + fallY; duration: 650; easing.type: Easing.InQuad }
                    }
                    NumberAnimation on x {
                        from: fragX
                        to: fragX + spreadX
                        duration: 950
                        easing.type: Easing.OutQuad
                        running: true
                    }
                    NumberAnimation on rotation {
                        from: 0
                        to: spin
                        duration: 950
                        running: true
                    }
                    NumberAnimation on opacity {
                        from: 0.95
                        to: 0
                        duration: 900
                        easing.type: Easing.InQuad
                        running: true
                    }
                }
            }

            // 7. 消行白光爆闪：被消的行整行亮一帧再碎裂
            Repeater {
                model: rowFlashes
                delegate: Rectangle {
                    y: modelData * blockSize
                    x: 0
                    width: gameBoard.width
                    height: blockSize
                    color: "#ffffff"
                    opacity: 0.85

                    NumberAnimation on opacity {
                        from: 0.85
                        to: 0
                        duration: 200
                        easing.type: Easing.InQuad
                        running: true
                    }
                }
            }

            // 8. 落锁闪光（白光 + 底部挤压）
            Repeater {
                model: lockFlashes
                delegate: Rectangle {
                    property real fx: modelData.col * blockSize
                    property real fy: modelData.row * blockSize
                    x: fx
                    y: fy
                    width: blockSize
                    height: blockSize
                    radius: 2
                    color: "#ffffff"
                    opacity: 0.9
                    transformOrigin: Item.Bottom

                    NumberAnimation on scale {
                        from: 1.18
                        to: 1.0
                        duration: 200
                        easing.type: Easing.OutQuad
                        running: true
                    }
                    NumberAnimation on opacity {
                        from: 0.9
                        to: 0
                        duration: 270
                        easing.type: Easing.InQuad
                        running: true
                    }
                }
            }

            // 9. 移动/旋转残影
            Repeater {
                model: afterimages
                delegate: Item {
                    property var aCells: modelData.cells
                    property color aColor: modelData.color
                    opacity: 0.28

                    NumberAnimation on opacity {
                        from: 0.28
                        to: 0
                        duration: 170
                        running: true
                    }

                    Repeater {
                        model: aCells.length
                        delegate: Rectangle {
                            x: aCells[index].c * blockSize + 2
                            y: aCells[index].r * blockSize + 2
                            width: blockSize - 4
                            height: blockSize - 4
                            radius: 2
                            color: aColor
                        }
                    }
                }
            }

            // 10. 到底速度线
            Repeater {
                model: dropStreaks
                delegate: Rectangle {
                    x: modelData.x
                    y: modelData.y0
                    width: blockSize - 6
                    height: modelData.y1 - modelData.y0
                    radius: 3
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0) }
                        GradientStop { position: 1.0; color: modelData.color }
                    }
                    opacity: 0.4

                    NumberAnimation on opacity {
                        from: 0.4
                        to: 0
                        duration: 140          // 速度线：只强调"从哪来"，短促
                        running: true
                    }
                }
            }

            // 11. 到底冲击波
            Rectangle {
                id: dropShockwave
                visible: false
                width: blockSize * 3
                height: blockSize * 3
                radius: width / 2
                color: "transparent"
                border.width: 4
                border.color: "#ffffff"
                opacity: 0
                transformOrigin: Item.Center

                SequentialAnimation {
                    id: shockwaveAnimation
                    ParallelAnimation {
                        NumberAnimation { target: dropShockwave; property: "scale"; from: 0.4; to: 1.9; duration: 380; easing.type: Easing.OutCubic }
                        NumberAnimation { target: dropShockwave; property: "opacity"; from: 0.8; to: 0; duration: 380; easing.type: Easing.OutQuad }
                    }
                    onStopped: dropShockwave.visible = false
                }
            }

            // 12. 粒子系统：Tetris 火花（亮星/暗屑两档）+ 到底灰尘 + 三消橙色碎片
            // 亮星：大而快、寿命短——负责冲击感；暗屑：小而慢、寿命长——负责余韵拖尾
            ParticleSystem { id: starSystem }

            ItemParticle {
                system: starSystem
                delegate: Rectangle {
                    width: 8
                    height: 8
                    radius: 4
                    color: "#fff3b0"
                }
            }

            Gravity {
                system: starSystem
                angle: 90
                magnitude: 300
            }

            Emitter {
                id: sparkBurst
                system: starSystem
                enabled: false
                emitRate: 0
                lifeSpan: 700
                size: 8
                endSize: 2
                velocity: AngleDirection { angle: 90; angleVariation: 180; magnitude: 300; magnitudeVariation: 160 }
            }

            ParticleSystem { id: dimSystem }

            ItemParticle {
                system: dimSystem
                delegate: Rectangle {
                    width: 4
                    height: 4
                    radius: 2
                    color: "#a8863f"
                    opacity: 0.8
                }
            }

            Gravity {
                system: dimSystem
                angle: 90
                magnitude: 200
            }

            Emitter {
                id: dimBurst
                system: dimSystem
                enabled: false
                emitRate: 0
                lifeSpan: 950
                size: 4
                endSize: 1
                velocity: AngleDirection { angle: 90; angleVariation: 180; magnitude: 150; magnitudeVariation: 80 }
            }

            ParticleSystem { id: fxSystem }

            ItemParticle {
                system: fxSystem
                delegate: Rectangle {
                    width: 4
                    height: 4
                    radius: 2
                    color: "#ffd95a"
                }
            }

            Gravity {
                system: fxSystem
                angle: 90
                magnitude: 260
            }

            Emitter {
                id: dustBurst
                system: fxSystem
                enabled: false
                emitRate: 0
                lifeSpan: 480
                size: 6
                endSize: 2
                velocity: AngleDirection { angle: 270; angleVariation: 65; magnitude: 95; magnitudeVariation: 60 }
            }

            // 三消橙色碎片（独立粒子系统：颜色与火花/灰尘区分）
            ParticleSystem { id: debrisSystem }
            ItemParticle {
                system: debrisSystem
                delegate: Rectangle {
                    width: 7
                    height: 7
                    radius: 2
                    color: "#ff9e3d"
                    opacity: 0.9
                }
            }

            Emitter {
                id: debrisBurst
                system: debrisSystem
                enabled: false
                emitRate: 0
                lifeSpan: 340
                size: 7
                endSize: 2
                velocity: AngleDirection { angle: 270; angleVariation: 48; magnitude: 190; magnitudeVariation: 90 }
            }

            // 13. 连击燃烧边框（分级：2-3 橙 / 4-6 红橙 / 7+ 烈焰红；B2B 时金色优先）
            Rectangle {
                anchors.fill: parent
                color: "transparent"
                radius: 2
                border.width: comboStreak >= 7 ? 8 : comboStreak >= 4 ? 6 : 4
                border.color: {
                    if (b2bActive) return "#ffd95a"
                    if (comboStreak >= 7) return "#ff2a2a"
                    if (comboStreak >= 4) return "#ff5a2a"
                    return "#ff7a18"
                }
                visible: comboStreak >= 2 || b2bActive
                opacity: 0.6

                SequentialAnimation on opacity {
                    running: (comboStreak >= 2 || b2bActive) && !isPaused && !reduceMotion
                    loops: Animation.Infinite
                    NumberAnimation {
                        to: 0.95
                        duration: Math.round((comboStreak >= 7 ? 160 : comboStreak >= 4 ? 260 : 420) * fxBreathScale)
                        easing.type: Easing.OutQuad
                    }
                    NumberAnimation {
                        to: 0.35
                        duration: Math.round((comboStreak >= 7 ? 160 : comboStreak >= 4 ? 260 : 420) * fxBreathScale)
                        easing.type: Easing.InQuad
                    }
                }
            }

            // 14. 危险三段预警（全部基于真实堆叠最高点，refreshDanger 命令式刷新）
            // 一段：顶部暖色光带（第 6 行有块）——柔和预告，不催促
            Rectangle {
                anchors.top: parent.top
                width: parent.width
                height: blockSize * 2.6
                visible: dangerLv >= 1 && !isGameOver
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.rgba(1.0, 0.62, 0.30, dangerLv >= 2 ? 0.24 : 0.30) }
                    GradientStop { position: 1.0; color: Qt.rgba(1.0, 0.62, 0.30, 0) }
                }
            }

            // 二段：红色呼吸边框（进入顶部 4 行），治愈模式慢呼吸
            Rectangle {
                anchors.fill: parent
                color: "transparent"
                radius: 2
                border.width: 4
                border.color: "#ff2a2a"
                visible: dangerLv >= 2 && !isGameOver
                opacity: reduceMotion ? 0.55 : 0.6

                SequentialAnimation on opacity {
                    running: dangerLv >= 2 && !isGameOver && !isPaused && !reduceMotion
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.9; duration: Math.round(300 * fxBreathScale); easing.type: Easing.OutQuad }
                    NumberAnimation { to: 0.3; duration: Math.round(300 * fxBreathScale); easing.type: Easing.InQuad }
                }
            }

            // 三段：每 2 秒短脉冲（170ms 亮 + 1830ms 熄）+ 小字提示（进入顶部 2 行）
            Rectangle {
                anchors.fill: parent
                color: "transparent"
                radius: 2
                border.width: 6
                border.color: "#ff2020"
                visible: dangerLv >= 3 && !isGameOver
                opacity: reduceMotion ? 0.6 : 0.15

                SequentialAnimation on opacity {
                    running: dangerLv >= 3 && !isGameOver && !isPaused && !reduceMotion
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.9; duration: 170; easing.type: Easing.OutQuad }
                    NumberAnimation { to: 0.15; duration: 1830; easing.type: Easing.InQuad }
                }
            }

            Text {
                visible: dangerLv >= 3 && !isGameOver
                anchors.horizontalCenter: parent.horizontalCenter
                y: 6
                text: "即将失败"
                color: "#ff5a4a"
                font.pixelSize: 13
                font.bold: true
                opacity: 0.95
            }

            // 14b. 小徽章 / 里程碑 toast（棋盘顶部居中，2.2s 自动淡出）
            Rectangle {
                id: badgeToast
                visible: toastText !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                y: 10
                width: toastRow.implicitWidth + 30
                height: 38
                radius: 19
                color: "#F0222222"
                border.color: "#ffd95a"
                border.width: 1
                z: 40
                opacity: toastText !== "" ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 220 } }

                Row {
                    id: toastRow
                    anchors.centerIn: parent
                    spacing: 8
                    Text { text: toastIcon; font.pixelSize: 17; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: toastText; color: "#ffe9a8"; font.pixelSize: 15; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
                }
            }

            // 手势操作区（手势模式启用）：横滑移动 / 点按旋转 / 下滑加速 / 快甩到底 / 上滑暂存
            // 支持斜滑：横移与加速两轴同时结算，不锁单轴
            MouseArea {
                id: gestureArea
                anchors.fill: parent
                enabled: opMode === "gestures" && !isGameOver && !isPaused
                property real startX: 0
                property real startY: 0
                property real pressX: 0
                property real pressY: 0
                property real lastX: 0
                property real lastY: 0
                property real lastT: 0
                property real vyPrev: 0
                property real axisAx: 0   // 近段横/竖位移的指数衰减累计（约5个事件窗口）
                property real axisAy: 0
                property real pressTime: 0
                property bool flicked: false
                property bool held: false
                property real flickVelocity: 1.1   // 快甩判定：滑动速度 px/ms

                onPressed: function (mouse) {
                    startX = mouse.x
                    startY = mouse.y
                    pressX = mouse.x
                    pressY = mouse.y
                    lastX = mouse.x
                    lastY = mouse.y
                    lastT = Date.now()
                    pressTime = lastT
                    flicked = false
                    held = false
                    vyPrev = 0
                    axisAx = 0
                    axisAy = 0
                }

                onPositionChanged: function (mouse) {
                    if (flicked || held) return
                    var dx = mouse.x - startX
                    var dy = mouse.y - startY
                    // 近段运动方向：竖向主导时抬高横移门槛。快甩下滑时手指几乎必然
                    // 带横向漂移（无死区时累计一格宽就误移，落点偏左/右）；判为横滑或
                    // 斜滑时门槛回落，横移/斜滑同划不受影响。
                    var edx = mouse.x - lastX
                    var edy = mouse.y - lastY   // lastY 此刻仍是上一事件的 y
                    lastX = mouse.x
                    axisAx = axisAx * 0.75 + Math.abs(edx)
                    axisAy = axisAy * 0.75 + Math.abs(edy)
                    var dominance = axisAy > axisAx
                                  ? Math.min(1, (axisAy - axisAx) / (blockSize * 1.5)) : 0
                    var need = blockSize + Math.max(4, blockSize * 0.2) + dominance * blockSize
                    // 横轴：整格移动（带死区与竖向抑制）
                    while (dx >= need) { moveRight(); startX += blockSize; dx -= blockSize }
                    while (dx <= -need) { moveLeft(); startX -= blockSize; dx += blockSize }
                    // 竖轴：软降整格 + 快甩/上滑判定
                    var now = Date.now()
                    var vy = (mouse.y - lastY) / Math.max(1, now - lastT)
                    var totalDown = mouse.y - pressY
                    lastY = mouse.y
                    lastT = now
                    while (dy >= blockSize) { softDropStep(); startY += blockSize; dy -= blockSize }
                    if (dy <= -blockSize) {
                        held = true
                        holdPiece()
                    } else if (totalDown > blockSize * 2 && vy > flickVelocity && vyPrev > flickVelocity * 0.6) {
                        flicked = true
                        hardDrop()
                    }
                    vyPrev = vy
                }

                onReleased: function (mouse) {
                    var totalDx = Math.abs(mouse.x - pressX)
                    var totalDy = Math.abs(mouse.y - pressY)
                    if (totalDx < 12 && totalDy < 12 && !flicked && !held && (Date.now() - pressTime) < 260) {
                        rotate()
                    }
                }
            }

            Rectangle {
                anchors.fill: parent
                color: "#B3000000"
                visible: isGameOver
                z: 10

                Column {
                    anchors.centerIn: parent
                    spacing: 12

                    // 阶段6 本局回忆：大分数 + 2×2 统计格 + 本局亮点，点头部折叠为紧凑模式
                    Rectangle {
                        id: recapHead
                        visible: !recapCompact
                        width: 268
                        height: recapHeadCol.implicitHeight + 22
                        radius: 12
                        color: "#22222220"
                        border.color: "#55333333"
                        border.width: 1

                        Column {
                            id: recapHeadCol
                            anchors.centerIn: parent
                            spacing: 9

                            Text {
                                text: "本局结束"
                                color: "#ffd95a"
                                font.pixelSize: 15
                                font.bold: true
                                anchors.horizontalCenter: parent.horizontalCenter
                            }

                            Text {
                                text: "" + scoreTarget
                                color: "#ffffff"
                                font.pixelSize: 36
                                font.bold: true
                                anchors.horizontalCenter: parent.horizontalCenter
                            }

                            Grid {
                                columns: 2
                                spacing: 7
                                anchors.horizontalCenter: parent.horizontalCenter

                                Repeater {
                                    model: [
                                        { label: "累计消行", value: "" + totalClearedLines },
                                        { label: "最高连击", value: maxCombo > 1 ? "x" + maxCombo : "—" },
                                        { label: "四行消除", value: "" + tetrisCount },
                                        { label: "新收藏", value: "" + newUnlocks }
                                    ]
                                    delegate: Rectangle {
                                        width: 122
                                        height: 46
                                        radius: 9
                                        color: "#33222222"

                                        Column {
                                            anchors.centerIn: parent
                                            spacing: 1

                                            Text {
                                                text: modelData.value
                                                color: "#ffffff"
                                                font.pixelSize: 17
                                                font.bold: true
                                                anchors.horizontalCenter: parent.horizontalCenter
                                            }
                                            Text {
                                                text: modelData.label
                                                color: "#999999"
                                                font.pixelSize: 11
                                                anchors.horizontalCenter: parent.horizontalCenter
                                            }
                                        }
                                    }
                                }
                            }

                            Text {
                                text: "本局亮点：" + recapHighlight()
                                color: "#ffe9a8"
                                font.pixelSize: 12
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: recapCompact = true
                        }
                    }

                    Rectangle {
                        visible: recapCompact
                        width: 268
                        height: 42
                        radius: 10
                        color: "#22222220"
                        border.color: "#55333333"
                        border.width: 1

                        Row {
                            anchors.centerIn: parent
                            spacing: 10
                            Text { text: "" + scoreTarget + " 分"; color: "#ffffff"; font.pixelSize: 16; font.bold: true }
                            Text { text: "点按展开"; color: "#888888"; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: recapCompact = false
                        }
                    }

                    TextField {
                        visible: playerName === ""
                        width: 220
                        anchors.horizontalCenter: parent.horizontalCenter
                        placeholderText: "输入上榜名字（最多12字）"
                        placeholderTextColor: "#777777"
                        maximumLength: 12
                        font.pixelSize: 14
                        color: "white"
                        background: Rectangle {
                            radius: 6
                            color: "#1e1e1e"
                            border.width: 1
                            border.color: "#666666"
                        }
                        onEditingFinished: {
                            var t = text.replace(/[\u0000-\u001f\u007f]/g, "").trim()
                            if (t !== "") {
                                playerName = t
                                // 输名字即自动上榜本局成绩（真实 lines/time，
                                // 比暂停面板 uploadBest 的 0行/5秒补录更准；重复提交服务端幂等）
                                if (scoreTarget > 0) submitScore()
                            }
                        }
                    }

                    Button {
                        visible: playerName !== ""
                        text: submitPending ? "提交中……" : "提交全服排名"
                        enabled: !submitPending && scoreTarget > 0
                        anchors.horizontalCenter: parent.horizontalCenter
                        onClicked: submitScore()
                    }

                    Text {
                        text: myRankText
                        color: "#ffd95a"
                        font.pixelSize: 13
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: myRankText !== ""
                    }

                    Button {
                        text: "重新开始"
                        anchors.horizontalCenter: parent.horizontalCenter
                        onClicked: startGame()
                    }
                }
            }
        }

        Item {
            width: 1
            height: 14
        }

        // --- 触摸控制按钮（手势模式下隐藏）---
        Column {
            visible: opMode === "buttons"
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8

            Row {
                spacing: 10

                Button {
                    id: leftButton
                    text: "←"
                    width: 92
                    height: 48
                    autoRepeat: true
                    autoRepeatDelay: 120
                    autoRepeatInterval: 70
                    onClicked: moveLeft()

                    background: Rectangle {
                        radius: 12
                        border.width: 1
                        color: parent.down ? "#3a8be0" : "#5ea6f2"
                        border.color: parent.down ? "#94c6ff" : "#c9e2ff"
                        opacity: parent.down ? 0.95 : 0.9
                    }

                    contentItem: Text {
                        text: parent.text
                        color: "white"
                        font.pixelSize: 22
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: downButton
                    text: "↓"
                    width: 92
                    height: 48
                    autoRepeat: true
                    autoRepeatDelay: 80
                    autoRepeatInterval: 45
                    onClicked: softDropStep()

                    background: Rectangle {
                        radius: 12
                        border.width: 1
                        color: parent.down ? "#2cab65" : "#38d07c"
                        border.color: parent.down ? "#82efb0" : "#c7f8dc"
                        opacity: parent.down ? 0.95 : 0.9
                    }

                    contentItem: Text {
                        text: parent.text
                        color: "white"
                        font.pixelSize: 24
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: rightButton
                    text: "→"
                    width: 92
                    height: 48
                    autoRepeat: true
                    autoRepeatDelay: 120
                    autoRepeatInterval: 70
                    onClicked: moveRight()

                    background: Rectangle {
                        radius: 12
                        border.width: 1
                        color: parent.down ? "#3a8be0" : "#5ea6f2"
                        border.color: parent.down ? "#94c6ff" : "#c9e2ff"
                        opacity: parent.down ? 0.95 : 0.9
                    }

                    contentItem: Text {
                        text: parent.text
                        color: "white"
                        font.pixelSize: 22
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            Row {
                spacing: 10

                // 暂存按钮：有暂存方块时在按钮里显示小图
                Button {
                    id: holdButton
                    width: 92
                    height: 48
                    onClicked: holdPiece()
                    opacity: canHold ? 1.0 : 0.45

                    background: Rectangle {
                        radius: 12
                        border.width: 1
                        color: parent.down ? "#8a4de0" : "#a06af0"
                        border.color: parent.down ? "#c9a8ff" : "#e0ccff"
                        opacity: parent.down ? 0.95 : 0.9
                    }

                    contentItem: Item {
                        Text {
                            anchors.centerIn: parent
                            visible: holdShapeIndex < 0
                            text: "暂存"
                            color: "white"
                            font.pixelSize: 18
                        }

                        Item {
                            anchors.centerIn: parent
                            visible: holdShapeIndex >= 0
                            width: holdShapeIndex >= 0 ? shapes[holdShapeIndex][0].length * 12 : 0
                            height: holdShapeIndex >= 0 ? shapes[holdShapeIndex].length * 12 : 0

                            Repeater {
                                model: holdShapeIndex >= 0 ? shapes[holdShapeIndex].length : 0
                                delegate: Repeater {
                                    property int hr: index
                                    model: holdShapeIndex >= 0 ? shapes[holdShapeIndex][hr] : 0
                                    Rectangle {
                                        visible: modelData === 1
                                        x: index * 12
                                        y: hr * 12
                                        width: 11
                                        height: 11
                                        radius: 2
                                        color: colors[holdShapeIndex]
                                        border.color: "white"
                                        border.width: 1
                                    }
                                }
                            }
                        }
                    }
                }

                Button {
                    id: rotateButton
                    width: 92
                    height: 48
                    autoRepeat: true
                    autoRepeatDelay: 120
                    autoRepeatInterval: 70
                    onClicked: rotate()

                    background: Rectangle {
                        radius: 12
                        border.width: 1
                        color: parent.down ? "#ff9f1a" : "#f3b44a"
                        border.color: parent.down ? "#ffd28a" : "#ffe3b4"
                        opacity: parent.down ? 0.95 : 0.9
                    }

                    contentItem: Text {
                        text: "旋转"
                        color: "white"
                        font.pixelSize: 18
                        font.bold: false
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        opacity: rotateButton.down ? 0.82 : 1.0
                    }
                }

                Button {
                    id: dropButton
                    width: 92
                    height: 48
                    onClicked: hardDrop()

                    background: Rectangle {
                        radius: 12
                        border.width: 1
                        color: parent.down ? "#d04040" : "#e05a5a"
                        border.color: parent.down ? "#ff9a9a" : "#ffc9c9"
                        opacity: parent.down ? 0.95 : 0.9
                    }

                    contentItem: Text {
                        text: "到底"
                        color: "white"
                        font.pixelSize: 18
                        font.bold: false
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        opacity: dropButton.down ? 0.82 : 1.0
                    }
                }
            }
        }

    }

    // 全服排行榜面板
    Rectangle {
        anchors.fill: parent
        visible: showLeaderboard
        color: "#B0000000"
        z: 45

        // 点暗区关闭；没有它点击会穿透到下层暂停菜单的按钮（误触重开/战绩）
        MouseArea { anchors.fill: parent; onClicked: showLeaderboard = false }

        Rectangle {
            width: 308
            height: 460
            radius: 14
            color: "#2a2a2a"
            border.color: "#666666"
            border.width: 1
            anchors.centerIn: parent

            Column {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 8

                Text {
                    text: "🏆 全服排行榜"
                    color: "#ffd95a"
                    font.pixelSize: 20
                    font.bold: true
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    text: lbLoading ? "加载中……"
                        : lbError ? "加载失败，请检查网络"
                        : (lbRows.length === 0 ? "暂无记录，快来抢占第一名！" : "共 " + lbTotal + " 人上榜 · 展示前 " + lbRows.length)
                    color: lbError ? "#ff8a8a" : "#999999"
                    font.pixelSize: 13
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Column {
                    width: parent.width
                    spacing: 5

                    Repeater {
                        model: lbRows
                        delegate: Row {
                            width: parent.width
                            spacing: 6

                            Text {
                                text: "#" + modelData.rank
                                color: modelData.rank <= 3 ? "#ffd95a" : "#cccccc"
                                font.pixelSize: 13
                                font.bold: modelData.rank <= 3
                                width: 32
                            }

                            Text {
                                text: modelData.name
                                color: modelData.uid === playerUid ? "#7fd6a4" : "white"
                                font.pixelSize: 13
                                elide: Text.ElideRight
                                width: 108
                            }

                            Text {
                                text: String(modelData.score)
                                color: "white"
                                font.pixelSize: 13
                                font.bold: true
                                width: 68
                                horizontalAlignment: Text.AlignRight
                            }

                            Text {
                                text: modelData.lines + "行"
                                color: "#888888"
                                font.pixelSize: 12
                            }
                        }
                    }
                }

                Button {
                    text: "关闭"
                    anchors.horizontalCenter: parent.horizontalCenter
                    onClicked: showLeaderboard = false
                }
            }
        }
    }

    // 背景选择面板（按最高分解锁）
    Rectangle {
        anchors.fill: parent
        visible: showBgPicker
        color: "#B0000000"
        z: 46

        // 同排行榜：吃掉暗区点击，防止穿透下层菜单
        MouseArea { anchors.fill: parent; onClicked: showBgPicker = false }

        Rectangle {
            width: 312
            height: 620
            radius: 14
            color: "#2a2a2a"
            border.color: "#666666"
            border.width: 1
            anchors.centerIn: parent

            Column {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 10

                Text {
                    text: "🖼️ 背景"
                    color: "#ffd95a"
                    font.pixelSize: 21
                    font.bold: false
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    text: "单局分数达到门槛即永久解锁"
                    color: "#999999"
                    font.pixelSize: 13
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    text: "加分：消行 10/30/50/80 ×连击\n四消连续 ×1.5 · 到底+2/格 · ↓+1/格"
                    color: "#B9C4C8"
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Grid {
                    columns: 3
                    spacing: 8
                    anchors.horizontalCenter: parent.horizontalCenter

                    Repeater {
                        model: bgThemes
                        delegate: Item {
                            id: bgCell
                            width: 88
                            height: 92

                            property bool unlocked: savedUnlocks.indexOf(modelData.id) !== -1
                            property bool selected: bgChoice === modelData.id

                            Rectangle {
                                anchors.fill: parent
                                radius: 8
                                color: "#1e1e1e"
                                border.width: 2
                                border.color: bgCell.selected ? "#7fd6a4" : (bgCell.unlocked ? "#888888" : "#444444")
                            }

                            Image {
                                anchors.fill: parent
                                anchors.margins: 2
                                source: "qrc:/bg" + (bgThemeIndex(modelData.id) + 1) + ".jpg"
                                fillMode: Image.PreserveAspectCrop
                                opacity: bgCell.unlocked ? 1 : 0.25
                                asynchronous: true
                                onStatusChanged: if (status === Image.Error) bgCell.visible = false
                            }

                            Text {
                                anchors.bottom: parent.bottom
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottomMargin: 2
                                text: modelData.name
                                color: bgCell.unlocked ? "#F5F1E8" : "#888888"
                                font.pixelSize: 11
                                style: Text.Outline
                                styleColor: "#000000"
                            }

                            Text {
                                visible: !bgCell.unlocked
                                anchors.centerIn: parent
                                text: "🔒\n" + modelData.need + "分"
                                color: "#dddddd"
                                font.pixelSize: 12
                                horizontalAlignment: Text.AlignHCenter
                                style: Text.Outline
                                styleColor: "#000000"
                            }

                            Text {
                                visible: bgCell.selected
                                anchors.top: parent.top
                                anchors.right: parent.right
                                anchors.margins: 4
                                text: "✓"
                                color: "#7fd6a4"
                                font.pixelSize: 14
                                font.bold: true
                                style: Text.Outline
                                styleColor: "#000000"
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled: bgCell.unlocked
                                onClicked: bgChoice = modelData.id
                            }
                        }
                    }
                }

                Button {
                    text: "关闭"
                    anchors.horizontalCenter: parent.horizontalCenter
                    onClicked: showBgPicker = false
                }
            }
        }
    }

    // Tetris 全屏白闪
    // 个人战绩页（菜单内「战绩」打开；点外部关闭）
    Rectangle {
        anchors.fill: parent
        visible: showStats
        color: "#B0000000"
        z: 47

        MouseArea { anchors.fill: parent; onClicked: showStats = false }

        Rectangle {
            width: 312
            height: 380
            radius: 14
            color: "#2a2a2a"
            border.color: "#666666"
            border.width: 1
            anchors.centerIn: parent

            Column {
                anchors.centerIn: parent
                spacing: 12
                width: 260

                Text {
                    text: "📊 个人战绩"
                    color: "#ffd95a"
                    font.pixelSize: 19
                    font.bold: true
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Repeater {
                    model: [
                        ["历史最高", bestScore + " 分"],
                        ["累计局数", totalGames],
                        ["累计消行", totalLinesAll],
                        ["最大连击", maxComboAll > 0 ? "x" + maxComboAll : "—"],
                        ["累计时长", formatPlayTime(totalSecondsAll)]
                    ]
                    delegate: Row {
                        width: parent.width

                        Text {
                            text: modelData[0]
                            color: "#B9C4C8"
                            font.pixelSize: 14
                            width: 140
                        }

                        Text {
                            text: modelData[1]
                            color: "#F5F1E8"
                            font.pixelSize: 14
                            font.bold: true
                            horizontalAlignment: Text.AlignRight
                            width: 110
                        }
                    }
                }

                Button {
                    text: "关闭"
                    width: 120
                    anchors.horizontalCenter: parent.horizontalCenter
                    onClicked: showStats = false
                }
            }
        }
    }

    // 诊断日志页（隐藏入口：连点"已暂停"标题 5 次）：渲染异常时查看最近日志
    Rectangle {
        anchors.fill: parent
        visible: showDiag
        color: "#B0000000"
        z: 48

        MouseArea { anchors.fill: parent; onClicked: showDiag = false }

        Rectangle {
            width: 312
            height: 520
            radius: 14
            color: "#1e1e1e"
            border.color: "#666666"
            border.width: 1
            anchors.centerIn: parent

            Column {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                Text {
                    text: "🔧 诊断日志（点空白处关闭）"
                    color: "#ffd95a"
                    font.pixelSize: 15
                    font.bold: true
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    text: "运行后端: " + (typeof gfxActiveLabel !== "undefined" ? gfxActiveLabel : "?")
                    color: "#8DE0B2"
                    font.pixelSize: 11
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Flickable {
                    width: parent.width
                    height: parent.height - 250
                    clip: true
                    contentHeight: diagLogText.height

                    Text {
                        id: diagLogText
                        width: parent.width
                        text: diagText === "" ? "(暂无日志)" : diagText
                        color: "#9fd8a8"
                        font.pixelSize: 10
                        font.family: "monospace"
                        wrapMode: Text.WrapAnywhere
                    }
                }

                Button {
                    width: 250
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "📋 复制日志到剪贴板"
                    onClicked: {
                        if (typeof Diagnostics !== "undefined") {
                            Diagnostics.copyToClipboard(Diagnostics.tail(300))
                            diagCopyHint = "已复制最近300行日志，去能发字的地方粘贴发送即可"
                        }
                    }

                    background: Rectangle {
                        radius: 8
                        color: "#3a3a3a"
                        border.width: 1
                        border.color: "#666666"
                    }

                    contentItem: Text {
                        text: "📋 复制日志到剪贴板"
                        color: "white"
                        font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Text {
                    text: diagCopyHint
                    visible: diagCopyHint !== ""
                    color: "#8DE0B2"
                    font.pixelSize: 11
                    horizontalAlignment: Text.AlignHCenter
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Button {
                    width: 200
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "刷新日志"
                    onClicked: if (typeof Diagnostics !== "undefined") diagText = Diagnostics.tail(150)

                    background: Rectangle {
                        radius: 8
                        color: "#3a3a3a"
                        border.width: 1
                        border.color: "#666666"
                    }

                    contentItem: Text {
                        text: "刷新日志"
                        color: "white"
                        font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }


    Rectangle {
        id: flashOverlay
        anchors.fill: parent
        color: "#ffffff"
        opacity: 0
        visible: false
        z: 60
    }

    // Tetris 双重冲击波（以棋盘中心为原点）
    Item {
        anchors.fill: parent
        z: 15

        Rectangle {
            id: tetrisRing1
            visible: false
            width: 240
            height: 240
            radius: 120
            color: "transparent"
            border.width: 6
            border.color: "#ffd95a"
            opacity: 0
            x: root.width / 2 - width / 2
            transformOrigin: Item.Center
        }

        Rectangle {
            id: tetrisRing2
            visible: false
            width: 420
            height: 420
            radius: 210
            color: "transparent"
            border.width: 4
            border.color: "#ff9e3d"
            opacity: 0
            x: root.width / 2 - width / 2
            transformOrigin: Item.Center
        }
    }

    Rectangle {
        anchors.fill: parent
        visible: isPaused
        color: "#90000000"
        z: 40

        // 点暗区（菜单框以外）关闭菜单回到游戏
        MouseArea {
            anchors.fill: parent
            onClicked: {
                if (showLeaderboard || showBgPicker || showStats) return
                if (isGameOver) isPaused = false
                else resumeGame()
            }
        }

        Rectangle {
            width: 290
            height: 600
            radius: 14
            color: "#2a2a2a"
            border.width: 1
            border.color: "#666666"
            anchors.centerIn: parent

            // 吞掉面板内部的空白点击，防止误触关闭
            MouseArea {
                anchors.fill: parent
            }

            Column {
                anchors.centerIn: parent
                spacing: 13

                Text {
                    text: "已暂停"
                    color: "white"
                    font.pixelSize: 24
                    font.bold: false
                    anchors.horizontalCenter: parent.horizontalCenter

                    // 隐藏诊断入口：连点 5 次标题打开日志页（平时不可见，避免误触）
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -14
                        property int taps: 0
                        onClicked: {
                            if (++taps < 5) return
                            taps = 0
                            showDiag = true
                            if (typeof Diagnostics !== "undefined") diagText = Diagnostics.tail(150)
                        }
                    }
                }

                Row {
                    spacing: 12
                    anchors.horizontalCenter: parent.horizontalCenter

                    Button {
                        text: "战绩"
                        width: 84
                        onClicked: showStats = true
                    }

                    Button {
                        text: "排行"
                        width: 84
                        onClicked: {
                            fetchTop()
                            showLeaderboard = true
                        }
                    }

                    Button {
                        text: "重开"
                        width: 84
                        onClicked: startGame()
                    }
                }

                Text {
                    text: "排行榜名字"
                    color: "#999999"
                    font.pixelSize: 14
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                TextField {
                    width: 250
                    anchors.horizontalCenter: parent.horizontalCenter
                    placeholderText: playerName === "" ? "点击输入（最多12字），自动上传最高分" : ""
                    placeholderTextColor: "#777777"
                    maximumLength: 12
                    font.pixelSize: 14
                    color: "white"
                    text: playerName
                    background: Rectangle {
                        radius: 6
                        color: "#1e1e1e"
                        border.width: 1
                        border.color: playerName === "" ? "#666666" : "#7fd6a4"
                    }
                    onEditingFinished: {
                        var t = text.replace(/[\u0000-\u001f\u007f]/g, "").trim()
                        if (t === playerName) return   // 无改动不提交（编辑完成事件失焦也会触发）
                        playerName = t
                        text = t
                        if (t !== "") uploadBest()
                    }
                }

                Text {
                    text: myRankText
                    visible: myRankText !== ""
                    color: "#8DE0B2"
                    font.pixelSize: 12
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    text: "操作方式"
                    color: "#999999"
                    font.pixelSize: 14
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Row {
                    spacing: 10
                    anchors.horizontalCenter: parent.horizontalCenter

                    Button {
                        id: modeButtonMode
                        width: 110
                        onClicked: opMode = "buttons"

                        background: Rectangle {
                            radius: 8
                            color: opMode === "buttons" ? "#5ea6f2" : "#3a3a3a"
                            border.width: 1
                            border.color: opMode === "buttons" ? "#c9e2ff" : "#666666"
                        }

                        contentItem: Text {
                            text: "按钮操作"
                            color: "white"
                            font.pixelSize: 15
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Button {
                        id: modeGesture
                        width: 110
                        onClicked: opMode = "gestures"

                        background: Rectangle {
                            radius: 8
                            color: opMode === "gestures" ? "#38d07c" : "#3a3a3a"
                            border.width: 1
                            border.color: opMode === "gestures" ? "#c7f8dc" : "#666666"
                        }

                        contentItem: Text {
                            text: "手势操作"
                            color: "white"
                            font.pixelSize: 15
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                Text {
                    text: "震动"
                    color: "#999999"
                    font.pixelSize: 14
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Row {
                    spacing: 8
                    anchors.horizontalCenter: parent.horizontalCenter

                    Button {
                        width: 74
                        onClicked: vibeLevel = "off"

                        background: Rectangle {
                            radius: 8
                            color: vibeLevel === "off" ? "#5ea6f2" : "#3a3a3a"
                            border.width: 1
                            border.color: vibeLevel === "off" ? "#c9e2ff" : "#666666"
                        }

                        contentItem: Text {
                            text: "关"
                            color: "white"
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Button {
                        width: 74
                        onClicked: vibeLevel = "std"

                        background: Rectangle {
                            radius: 8
                            color: vibeLevel === "std" ? "#5ea6f2" : "#3a3a3a"
                            border.width: 1
                            border.color: vibeLevel === "std" ? "#c9e2ff" : "#666666"
                        }

                        contentItem: Text {
                            text: "标准"
                            color: "white"
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Button {
                        width: 74
                        onClicked: vibeLevel = "strong"

                        background: Rectangle {
                            radius: 8
                            color: vibeLevel === "strong" ? "#38d07c" : "#3a3a3a"
                            border.width: 1
                            border.color: vibeLevel === "strong" ? "#c7f8dc" : "#666666"
                        }

                        contentItem: Text {
                            text: "加强"
                            color: "white"
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                Text {
                    text: "特效"
                    color: "#999999"
                    font.pixelSize: 14
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Row {
                    spacing: 8
                    anchors.horizontalCenter: parent.horizontalCenter

                    Button {
                        width: 74
                        onClicked: fxPreset = "zen"

                        background: Rectangle {
                            radius: 8
                            color: zenFx ? "#5ea6f2" : "#3a3a3a"
                            border.width: 1
                            border.color: zenFx ? "#c9e2ff" : "#666666"
                        }

                        contentItem: Text {
                            text: "治愈"
                            color: "white"
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Button {
                        width: 74
                        onClicked: fxPreset = "arcade"

                        background: Rectangle {
                            radius: 8
                            color: !zenFx ? "#5ea6f2" : "#3a3a3a"
                            border.width: 1
                            border.color: !zenFx ? "#c9e2ff" : "#666666"
                        }

                        contentItem: Text {
                            text: "街机"
                            color: "white"
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                Button {
                    width: 250
                    anchors.horizontalCenter: parent.horizontalCenter
                    onClicked: reduceMotion = !reduceMotion

                    background: Rectangle {
                        radius: 8
                        color: reduceMotion ? "#38d07c" : "#3a3a3a"
                        border.width: 1
                        border.color: reduceMotion ? "#c7f8dc" : "#666666"
                    }

                    contentItem: Text {
                        text: reduceMotion ? "减少动态： 开" : "减少动态： 关"
                        color: "white"
                        font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    width: 250
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "🖼️ 背景选择"
                    onClicked: showBgPicker = true

                    background: Rectangle {
                        radius: 8
                        color: "#3a3a3a"
                        border.width: 1
                        border.color: "#666666"
                    }

                    contentItem: Text {
                        text: "🖼️ 背景选择"
                        color: "white"
                        font.pixelSize: 15
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Text {
                    text: "手势: 点按旋转 移动+加速可斜滑同划\n快甩到底 上滑暂存"
                    color: "#888888"
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    // 在线更新横幅（服务器 version.json 比对出新版时出现，顶部不挡棋盘）
    Rectangle {
        id: updateBanner
        property string state: ""        // ""=无 / offer=有新版 / downloading / done / perm / manual / fail / patch-offer / patch-ready
        property string file: ""
        property string newName: ""
        property int percent: 0
        property string apkPath: ""
        property int expectedSize: 0
        property string code: ""          // 服务器版本号（本地安装包按它命名）
        property int qmlServerVer: 0      // 服务器 QML 补丁版本
        visible: state !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 6
        width: 300
        height: 60
        radius: 12
        color: "#F01E1E1E"
        border.color: "#7fd6a4"
        border.width: 1
        z: 70

        function destPath() {
            return NativeUpdate.apkDownloadPath("update-" + code + ".apk")
        }
        function checkStart() {
            if (Qt.platform.os !== "android") return
            apiGet("version?cur=" + clientVersionCode, function (ok, data) {
                if (ok && data && data.file && data.code > clientVersionCode) {
                    updateBanner.file = data.file
                    updateBanner.newName = data.name
                    code = data.code
                    expectedSize = data.size || 0
                    apkPath = destPath()
                    // 本地已有该版本的完整安装包 → 直接可安装（不重复下载）
                    if (expectedSize > 0 && NativeUpdate.fileSize(apkPath) === expectedSize) {
                        updateBanner.state = "done"
                        return
                    }
                    updateBanner.state = "offer"
                    return
                }
                // 无 APK 更新：检查 QML 热更补丁（免安装，重启生效）
                if (ok && data && data.qmlVer > patchVer && (!data.qmlMinApk || clientVersionCode >= data.qmlMinApk)) {
                    qmlServerVer = data.qmlVer
                    updateBanner.state = "patch-offer"
                }
            })
        }

        function startDownload() {
            state = "downloading"
            percent = 0
            dlStallGuard.restart()
            NativeUpdate.cleanOldApks(apkPath)   // 清理其他版本的残留安装包
            NativeUpdate.downloadApk(apiBase + "apk/" + file, apkPath)
        }

        // 下载卡死保镖：20 秒无进度自动回到可重试状态
        Timer {
            id: dlStallGuard
            interval: 20000
            onTriggered: if (updateBanner.state === "downloading") updateBanner.state = "offer"
        }

        // 吞掉横幅区域的点击，防止透传到棋盘
        MouseArea { anchors.fill: parent }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 14
            width: parent.width - 100
            text: updateBanner.state === "offer" ? "🚀 新版本 v" + updateBanner.newName + " 可更新"
                : updateBanner.state === "downloading" ? "下载中 " + updateBanner.percent + "%"
                : updateBanner.state === "done" ? "下载完成"
                : updateBanner.state === "perm" ? "请打开「允许安装未知应用」后返回，再点重试"
                : updateBanner.state === "manual" ? "已复制到 下载/tetris/，请在文件管理器点击 tetris-update.apk 安装"
                : updateBanner.state === "fail" ? "未能拉起安装器，请重试或重新下载"
                : updateBanner.state === "patch-offer" ? "📦 界面补丁 v" + updateBanner.qmlServerVer + " 可更新（免安装，重启生效）"
                : updateBanner.state === "patch-ready" ? "📦 补丁已就绪，点重启立即生效"
                : ""
            color: "#f5f1e8"
            font.pixelSize: 13
            wrapMode: Text.WrapAnywhere
        }

        Rectangle {
            id: actionBtn
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 10
            width: 78
            height: 34
            radius: 8
            color: updateBanner.state === "downloading" ? "#3a3a3a" : "#2e7d5b"

            Text {
                anchors.centerIn: parent
                text: updateBanner.state === "offer" ? "下载"
                    : updateBanner.state === "downloading" ? "后台"
                    : updateBanner.state === "done" ? "安装"
                    : updateBanner.state === "perm" ? "重试"
                    : updateBanner.state === "manual" ? "知道了"
                    : updateBanner.state === "fail" ? "重试"
                    : updateBanner.state === "patch-offer" ? "下载"
                    : updateBanner.state === "patch-ready" ? "重启"
                    : ""
                color: "white"
                font.pixelSize: 13
                font.bold: true
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (updateBanner.state === "offer") updateBanner.startDownload()
                    else if (updateBanner.state === "downloading") return   // 已在后台下载
                    else if (updateBanner.state === "done" || updateBanner.state === "fail") {
                        // 无权限 → 直达本应用的「允许安装未知应用」开关（一次授权永久有效）；
                        // 有权限 → 直接拉起安装器。返回 1=安装器已拉起 2=已复制到公共下载 0=全部失败
                        if (NativeUpdate.canInstallApk()) {
                            var res = NativeUpdate.installApk(updateBanner.apkPath)
                            if (res === 2) {
                                updateBanner.state = "manual"
                                updateBanner.height = 78
                            } else if (res === 0) {
                                updateBanner.state = "fail"
                            }
                        } else {
                            updateBanner.state = "perm"
                            NativeUpdate.openInstallPermissionSettings()
                        }
                    } else if (updateBanner.state === "perm") {
                        if (NativeUpdate.canInstallApk()) {
                            var res2 = NativeUpdate.installApk(updateBanner.apkPath)
                            if (res2 === 2) {
                                updateBanner.state = "manual"
                                updateBanner.height = 78
                            } else if (res2 === 0) {
                                updateBanner.state = "fail"
                            }
                        } else {
                            NativeUpdate.openInstallPermissionSettings()
                        }
                    } else if (updateBanner.state === "manual") {
                        updateBanner.state = ""
                        updateBanner.height = 60
                    } else if (updateBanner.state === "patch-offer") {
                        // QML 补丁下载（几 KB~150KB，走 JSON 通道，内容在 data.qml）
                        updateBanner.state = "downloading"
                        apiGet("patch/info", function (ok, data) {
                            if (ok && data && data.qml) {
                                NativeUpdate.saveText(NativeUpdate.patchPath(), data.qml)
                                // 版本标记与补丁同存：启动加载端据此拒载历史无标记/过旧的补丁
                                NativeUpdate.saveText(NativeUpdate.patchVerPath(), String(updateBanner.qmlServerVer))
                                patchVer = updateBanner.qmlServerVer
                                updateBanner.state = "patch-ready"
                            } else {
                                updateBanner.state = ""
                            }
                        })
                    } else if (updateBanner.state === "patch-ready") {
                        NativeUpdate.restartApp()
                    }
                }
            }
        }

        Rectangle {
            // 关闭角标
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            width: 22
            height: 34
            color: "transparent"
            visible: updateBanner.state !== "downloading"
            Text {
                anchors.centerIn: parent
                text: "×"
                color: "#888888"
                font.pixelSize: 16
            }
            MouseArea {
                anchors.fill: parent
                onClicked: updateBanner.state = ""
            }
        }
    }


    Connections {
        target: NativeUpdate
        function onDownloadProgress(done, total) {
            updateBanner.percent = total > 0 ? Math.round(done * 100 / total) : 0
            dlStallGuard.restart()
        }
        function onDownloadDone(path) {
            dlStallGuard.stop()
            if (path !== "") {
                updateBanner.apkPath = path
                updateBanner.state = "done"
            } else {
                updateBanner.state = "offer"
            }
        }
    }
}
