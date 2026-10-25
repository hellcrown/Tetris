#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QFile>
#include <QSettings>
#include <QSslConfiguration>
#include <QSslCertificate>
#include <QStandardPaths>
#include <QDir>
#include <QFileInfo>
#include <QClipboard>
#include <QDateTime>
#include <QTimer>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSysInfo>
#ifdef Q_OS_ANDROID
#include <QJniObject>   // 仅安卓 kit 提供此头文件；桌面构建不含它
#endif

// 震动桥：QML 里 NativeVibe.buzz(毫秒)；非 Android 平台为空操作
class NativeVibe : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;

    Q_INVOKABLE void buzz(int ms) const
    {
#ifdef Q_OS_ANDROID
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (!activity.isValid())
            return;
        const QJniObject vibrator = defaultVibrator(activity);
        if (!vibrator.isValid())
            return;
        if (QNativeInterface::QAndroidApplication::sdkVersion() >= 26) {
            // VibrationEffect.createOneShot(ms, DEFAULT_AMPLITUDE)；vibrate(long) 自 API 29 起弃用
            const QJniObject effect = QJniObject::callStaticObjectMethod(
                "android/os/VibrationEffect", "createOneShot",
                "(JI)Landroid/os/VibrationEffect;",
                static_cast<jlong>(ms), static_cast<jint>(-1));
            if (effect.isValid()) {
                vibrator.callMethod<void>("vibrate", "(Landroid/os/VibrationEffect;)V",
                                          effect.object());
                return;
            }
        }
        // minSdk 23：API 26 以下的老系统没有 VibrationEffect，走已弃用但可用的 vibrate(long)
        vibrator.callMethod<void>("vibrate", "(J)V", static_cast<jlong>(ms));
#else
        Q_UNUSED(ms);
#endif
    }

private:
#ifdef Q_OS_ANDROID
    // API 31+：vibrator 服务从 activity 迁入 VibratorManager；不可用或旧系统回退旧路径
    static QJniObject defaultVibrator(const QJniObject &activity)
    {
        if (QNativeInterface::QAndroidApplication::sdkVersion() >= 31) {
            const QJniObject manager = activity.callObjectMethod(
                "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;",
                QJniObject::fromString("vibrator_manager").object<jstring>());
            if (manager.isValid()) {
                const QJniObject vibrator = manager.callObjectMethod(
                    "getDefaultVibrator", "()Landroid/os/Vibrator;");
                if (vibrator.isValid())
                    return vibrator;
            }
        }
        return activity.callObjectMethod(
            "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;",
            QJniObject::fromString("vibrator").object<jstring>());
    }
#endif
};

// 安卓系统网络栈桥：绕开 Qt 缺少 OpenSSL TLS 后端的问题（浏览器能通=系统栈能通）。
// QML: nativeHttp.post(url, body) / nativeHttp.get(url) → done(response) 信号。
// 线程模型：HTTP 由 Http.java 的单线程池执行，完成后经 nativeResult() JNI 回调回到
// 本类（回调发生在 Java 线程上，跨线程信号自动排队回 GUI 线程）。本对象为进程级
// 单例：堆上创建且随进程销毁，退出时在途请求的回调不会命中悬垂指针。
class NativeHttp : public QObject {
    Q_OBJECT
public:
    explicit NativeHttp(QObject *parent = nullptr)
        : QObject(parent) { s_instance = this; }
    static NativeHttp *instance() { return s_instance; }

    Q_INVOKABLE void post(const QString &url, const QString &body)
    {
        run(QStringLiteral("POST"), url, body);
    }

    Q_INVOKABLE void get(const QString &url)
    {
        run(QStringLiteral("GET"), url, QString());
    }

signals:
    void done(const QString &response);

private:
    void run(const QString &method, const QString &url, const QString &body)
    {
#ifdef Q_OS_ANDROID
        QJniObject::callStaticMethod<void>(
            "org/qtproject/tetris/Http", "requestAsync",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V",
            QJniObject::fromString(method).object<jstring>(),
            QJniObject::fromString(url).object<jstring>(),
            QJniObject::fromString(body).object<jstring>());
#else
        Q_UNUSED(method);
        Q_UNUSED(url);
        Q_UNUSED(body);
        emit done(QStringLiteral("ERR NOSUPPORT"));
#endif
    }

    static NativeHttp *s_instance;
};
NativeHttp *NativeHttp::s_instance = nullptr;

// 主窗口指针：锁屏恢复补帧 / 演示模式截图使用（objectCreated 时赋值）
static QQuickWindow *s_mainWin = nullptr;

// 在线更新：下载 APK + 调系统安装器。进度/完成经信号供 QML 显示下载百分比
class NativeUpdate : public QObject {
    Q_OBJECT
public:
    explicit NativeUpdate(QObject *parent = nullptr) { s_instance = this; }
    static NativeUpdate *instance() { return s_instance; }

    Q_INVOKABLE QString apkDownloadPath(const QString &fileName) const
    {
#ifdef Q_OS_ANDROID
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (activity.isValid()) {
            const QJniObject dir = activity.callObjectMethod(
                "getExternalFilesDir", "(Ljava/lang/String;)Ljava/io/File;",
                static_cast<jstring>(nullptr));
            if (dir.isValid()) {
                const QJniObject p = dir.callObjectMethod("getAbsolutePath", "()Ljava/lang/String;");
                if (p.isValid())
                    return p.toString() + QStringLiteral("/") + fileName;
            }
        }
#endif
        return fileName;
    }

    // 下载前清理其他版本的残留安装包（按版本命名，同名槽位保留）
    Q_INVOKABLE void cleanOldApks(const QString &keepName) const
    {
#ifdef Q_OS_ANDROID
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (!activity.isValid())
            return;
        const QJniObject dir = activity.callObjectMethod(
            "getExternalFilesDir", "(Ljava/lang/String;)Ljava/io/File;",
            static_cast<jstring>(nullptr));
        if (!dir.isValid())
            return;
        const QJniObject path = dir.callObjectMethod("getAbsolutePath", "()Ljava/lang/String;");
        QDir d(path.toString());
        if (!d.exists())
            return;
        const QStringList entries = d.entryList(QStringList() << QStringLiteral("update*.apk"), QDir::Files);
        for (const QString &e : entries)
            if (e != keepName)
                QFile::remove(path.toString() + "/" + e);
#endif
    }

    Q_INVOKABLE void downloadApk(const QString &url, const QString &dest)
    {
#ifdef Q_OS_ANDROID
        QJniObject::callStaticMethod<void>(
            "org/qtproject/tetris/Http", "downloadApkAsync",
            "(Ljava/lang/String;Ljava/lang/String;)V",
            QJniObject::fromString(url).object<jstring>(),
            QJniObject::fromString(dest).object<jstring>());
#else
        Q_UNUSED(url);
        Q_UNUSED(dest);
        emit downloadDone(QStringLiteral(""));
#endif
    }

    Q_INVOKABLE bool canInstallApk() const
    {
#ifdef Q_OS_ANDROID
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (!activity.isValid())
            return false;
        // 注意：canRequestPackageInstalls() 在 PackageManager 上，Activity 没有这个方法
        const QJniObject pm = activity.callObjectMethod(
            "getPackageManager", "()Landroid/content/pm/PackageManager;");
        if (!pm.isValid())
            return false;
        return pm.callMethod<jboolean>("canRequestPackageInstalls", "()Z");
#else
        return false;
#endif
    }

    Q_INVOKABLE qint64 fileSize(const QString &path) const
    {
        QFileInfo fi(path);
        return fi.exists() ? fi.size() : -1;
    }

    // QML 热更新补丁的存放路径（files/patch/Main.qml）
    Q_INVOKABLE QString patchPath() const
    {
#ifdef Q_OS_ANDROID
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (activity.isValid()) {
            const QJniObject dir = activity.callObjectMethod(
                "getExternalFilesDir", "(Ljava/lang/String;)Ljava/io/File;",
                static_cast<jstring>(nullptr));
            if (dir.isValid()) {
                const QJniObject p = dir.callObjectMethod("getAbsolutePath", "()Ljava/lang/String;");
                if (p.isValid())
                    return p.toString() + QStringLiteral("/patch/Main.qml");
            }
        }
#endif
        return QStringLiteral("patch/Main.qml");
    }

    // 补丁版本标记的存放路径（files/patch/ver）：保存补丁时一并写入版本号，
    // 启动加载端据此拒载无版本标记/过旧的补丁（历史 v1 补丁无此文件）
    Q_INVOKABLE QString patchVerPath() const
    {
#ifdef Q_OS_ANDROID
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (activity.isValid()) {
            const QJniObject dir = activity.callObjectMethod(
                "getExternalFilesDir", "(Ljava/lang/String;)Ljava/io/File;",
                static_cast<jstring>(nullptr));
            if (dir.isValid()) {
                const QJniObject p = dir.callObjectMethod("getAbsolutePath", "()Ljava/lang/String;");
                if (p.isValid())
                    return p.toString() + QStringLiteral("/patch/ver");
            }
        }
#endif
        return QStringLiteral("patch/ver");
    }

    Q_INVOKABLE bool saveText(const QString &path, const QString &content) const
    {
        QDir().mkpath(QFileInfo(path).path());
        QFile f(path);
        if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
            return false;
        f.write(content.toUtf8());
        f.close();
        return true;
    }

    Q_INVOKABLE void restartApp()
    {
#ifdef Q_OS_ANDROID
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (!activity.isValid())
            return;
        QJniObject::callStaticMethod<void>(
            "org/qtproject/tetris/Upd", "restartApp",
            "(Landroid/content/Context;)V",
            activity.object());
#endif
    }

    // 阶段验收演示：把主窗口当前画面存为 PNG（窗口在后台也可截取）
    Q_INVOKABLE bool saveShot(const QString &path) const
    {
        if (!s_mainWin) {
            qWarning() << "[Shot] 主窗口指针为空";
            return false;
        }
        QImage img = s_mainWin->grabWindow();
        QDir().mkpath(QFileInfo(path).path());   // 目录不存在时自动创建
        const bool ok = !img.isNull() && img.save(path);
        qInfo() << "[Shot]" << path << (ok ? "OK" : "FAILED") << img.width() << "x" << img.height();
        return ok;
    }

    Q_INVOKABLE void openInstallPermissionSettings() const
    {
#ifdef Q_OS_ANDROID
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (!activity.isValid())
            return;
        QJniObject intent("android/content/Intent", "(Ljava/lang/String;)V",
                          QJniObject::fromString(
                              QStringLiteral("android.settings.MANAGE_UNKNOWN_APP_SOURCES")).object());
        intent.callMethod<void>("setData", "(Landroid/net/Uri;)V",
            QJniObject::callStaticObjectMethod(
                "android/net/Uri", "parse", "(Ljava/lang/String;)Landroid/net/Uri;",
                QJniObject::fromString(
                    QStringLiteral("package:") + activity.callObjectMethod(
                        "getPackageName", "()Ljava/lang/String;").toString()).object()).object());
        intent.callMethod<void>("addFlags", "(I)V", 0x10000000);   // FLAG_ACTIVITY_NEW_TASK
        activity.callMethod<void>("startActivity", "(Landroid/content/Intent;)V",
                                  intent.object());
#endif
    }

    // 安装路由（Upd.java）：返回 1=已拉起安装器 2=已复制到公共下载（手动点装） 0=失败
    Q_INVOKABLE int installApk(const QString &path)
    {
#ifdef Q_OS_ANDROID
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (!activity.isValid())
            return 0;
        return QJniObject::callStaticMethod<jint>(
            "org/qtproject/tetris/Upd", "installOrRoute",
            "(Landroid/content/Context;Ljava/lang/String;)I",
            activity.object(),
            QJniObject::fromString(path).object<jstring>());
#else
        Q_UNUSED(path);
        return 0;
#endif
    }

signals:
    void downloadProgress(qint64 done, qint64 total);
    void downloadDone(const QString &path);

private:
    static NativeUpdate *s_instance;
};
NativeUpdate *NativeUpdate::s_instance = nullptr;

#ifdef Q_OS_ANDROID
// Http.java 的 requestAsync 完成后在其后台线程上回调到这里。
// JNIEXPORT 保证符号默认可见（Qt 的安卓库以 -fvisibility=hidden 构建，缺了会找不到符号）
extern "C" JNIEXPORT void JNICALL
Java_org_qtproject_tetris_Http_nativeResult(JNIEnv *env, jclass, jstring response)
{
    if (!response)
        return;
    const char *utf = env->GetStringUTFChars(response, nullptr);
    if (!utf)
        return;
    const QString out = QString::fromUtf8(utf);
    env->ReleaseStringUTFChars(response, utf);
    if (NativeHttp *self = NativeHttp::instance())
        emit self->done(out);
}

extern "C" JNIEXPORT void JNICALL
Java_org_qtproject_tetris_Http_nativeDownloadProgress(JNIEnv *, jclass, jlong done, jlong total)
{
    if (NativeUpdate *u = NativeUpdate::instance())
        emit u->downloadProgress(done, total);
}

extern "C" JNIEXPORT void JNICALL
Java_org_qtproject_tetris_Http_nativeDownloadDone(JNIEnv *env, jclass, jstring path)
{
    if (!path)
        return;
    const char *utf = env->GetStringUTFChars(path, nullptr);
    if (!utf)
        return;
    const QString out = QString::fromUtf8(utf);
    env->ReleaseStringUTFChars(path, utf);
    if (NativeUpdate *u = NativeUpdate::instance())
        emit u->downloadDone(out);
}
#endif

// --- 黑屏诊断：全部 Qt 日志落盘（AppData/tetris-debug.log），重启后可在应用内查看 ---
static QFile *s_diagLog = nullptr;
static QFile *s_diagExport = nullptr;   // 应用外部目录镜像（文件管理器可读，卓易通容器内无法 adb，靠用户发文件回传）

static void diagMessageHandler(QtMsgType type, const QMessageLogContext &ctx, const QString &msg)
{
    static const char *levels[] = { "DEBUG", "WARN ", "CRIT ", "FATAL", "INFO " };
    const int idx = type == QtInfoMsg ? 4 : int(type);
    const QByteArray line = QDateTime::currentDateTime().toString("MM-dd HH:mm:ss.zzz").toUtf8()
        + ' ' + levels[idx] + ' '
        + (ctx.category ? ctx.category : "default") + ": "
        + msg.toUtf8() + '\n';
    if (s_diagLog) {
        s_diagLog->write(line);
        s_diagLog->flush();
    }
    if (s_diagExport) {
        s_diagExport->write(line);
        s_diagExport->flush();
    }
#ifdef Q_OS_ANDROID
    // 镜像到 android.util.Log → logcat：release 包无法 run-as 读私有文件，
    // stderr 在部分 ROM（MIUI）上也不通，直接调系统 Log 最可靠
    QJniObject::callStaticMethod<jint>(
        "android/util/Log", "println", "(ILjava/lang/String;Ljava/lang/String;)I",
        static_cast<jint>(type == QtWarningMsg || type == QtCriticalMsg ? 5 : 3),
        QJniObject::fromString("TetrisDiag").object<jstring>(),
        QJniObject::fromString(line).object<jstring>());
#endif
}

// QML: Diagnostics.tail(行数) → 最近日志文本（含上一次会话，供黑屏复现后回看）
//      Diagnostics.copyToClipboard(文本) → 写系统剪贴板（卓易通与鸿蒙剪贴板互通）
class Diagnostics : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;

    Q_INVOKABLE QString tail(int lines) const
    {
        const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QStringList all;
        const QStringList names = { QStringLiteral("tetris-debug.log.old"),
                                    QStringLiteral("tetris-debug.log") };
        for (const QString &name : names) {
            QFile f(dir + QLatin1Char('/') + name);
            if (f.open(QIODevice::ReadOnly | QIODevice::Text)) {
                const auto ls = QString::fromUtf8(f.read(400 * 1024))
                                    .split(QLatin1Char('\n'));
                for (const QString &l : ls)
                    if (!l.isEmpty())
                        all.append(l);
            }
        }
        if (all.isEmpty())
            return QStringLiteral("(暂无日志)");
        while (all.size() > lines)
            all.removeFirst();
        return all.join(QLatin1Char('\n'));
    }

    Q_INVOKABLE void copyToClipboard(const QString &text) const
    {
#ifdef Q_OS_ANDROID
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (!activity.isValid())
            return;
        const QJniObject clip = QJniObject::callStaticObjectMethod(
            "android/content/ClipData", "newPlainText",
            "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;",
            QJniObject::fromString(QStringLiteral("tetris-log")).object<jstring>(),
            QJniObject::fromString(text).object<jstring>());
        if (!clip.isValid())
            return;
        const QJniObject cm = activity.callObjectMethod(
            "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;",
            QJniObject::fromString(QStringLiteral("clipboard")).object<jstring>());
        if (cm.isValid())
            cm.callMethod<void>("setPrimaryClip", "(Landroid/content/ClipData;)V",
                                clip.object());
#else
        QGuiApplication::clipboard()->setText(text);
#endif
    }
};

#ifdef Q_OS_ANDROID
static bool s_everRendered = false;   // 已有渲染帧（解锁恢复梯只对"玩过之后锁屏"武装）
static qint64 s_lastNoteMs = 0;       // noteFrame 节流
#endif

int main(int argc, char *argv[])
{
#ifdef Q_OS_ANDROID
    // 全设备统一默认 GLES 渲染：实测各机型 GPU 路径都能正常打开与游玩；
    // 软件渲染在小米（QBackingStoreRhiSupport EGL 探测死循环）与华为鸿蒙 NEXT
    // 卓易通容器内均启动白屏，不再作为任何默认值。
    // 华为（鸿蒙 NEXT + 卓易通）锁屏恢复黑屏由看门狗自动 recreate 兜底。
    qputenv("QSG_INFO", "1");   // scenegraph 初始化信息进诊断日志
#endif
    QGuiApplication app(argc, argv);

    // 阶段验收演示模式：--demo <场景> --shots <目录> --preset <zen|arcade|rm>
    // 仅开发验收使用；正式运行不带参数，完全无感
    QString demoScene, shotDir, demoPreset;
    for (int i = 1; i < argc; ++i) {
        const QString a = QString::fromLocal8Bit(argv[i]);
        if (a == QLatin1String("--demo") && i + 1 < argc)
            demoScene = QString::fromLocal8Bit(argv[++i]);
        else if (a == QLatin1String("--shots") && i + 1 < argc)
            shotDir = QString::fromLocal8Bit(argv[++i]);
        else if (a == QLatin1String("--preset") && i + 1 < argc)
            demoPreset = QString::fromLocal8Bit(argv[++i]);
    }
    // 环境变量形式等价（计划契约 TETRIS_DEMO/TETRIS_SHOT/TETRIS_PRESET），命令行参数优先
    if (demoScene.isEmpty())
        demoScene = qEnvironmentVariable("TETRIS_DEMO");
    if (shotDir.isEmpty())
        shotDir = qEnvironmentVariable("TETRIS_SHOT");
    if (demoPreset.isEmpty())
        demoPreset = qEnvironmentVariable("TETRIS_PRESET");

    // 诊断日志：>400KB 轮转为 .old；消息经 diagMessageHandler 逐行落盘
    {
        const QString logDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QDir().mkpath(logDir);
        const QString logPath = logDir + QStringLiteral("/tetris-debug.log");
        QFile prev(logPath);
        if (prev.exists() && prev.size() > 400 * 1024) {
            QFile::remove(logPath + QStringLiteral(".old"));
            QFile::rename(logPath, logPath + QStringLiteral(".old"));
        }
        s_diagLog = new QFile(logPath);
        s_diagLog->open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text);
        qInstallMessageHandler(&diagMessageHandler);
    }
#ifdef Q_OS_ANDROID
    // 外部镜像：卓易通/HarmonyOS NEXT 上 adb 够不着容器，把日志写到应用外部目录
    // （Android/data/org.qtproject.tetris/files/），用户可用文件管理器发回来排查
    {
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (activity.isValid()) {
            const QJniObject dir = activity.callObjectMethod(
                "getExternalFilesDir", "(Ljava/lang/String;)Ljava/io/File;",
                static_cast<jstring>(nullptr));
            if (dir.isValid()) {
                const QJniObject path = dir.callObjectMethod(
                    "getAbsolutePath", "()Ljava/lang/String;");
                if (path.isValid()) {
                    const QString exportPath = path.toString()
                        + QStringLiteral("/tetris-debug.log");
                    if (QFile::exists(exportPath) && QFileInfo(exportPath).size() > 200 * 1024)
                        QFile::remove(exportPath);
                    s_diagExport = new QFile(exportPath);
                    if (!s_diagExport->open(QIODevice::WriteOnly | QIODevice::Append
                                            | QIODevice::Text)) {
                        delete s_diagExport;
                        s_diagExport = nullptr;
                    }
                }
            }
        }
    }
#endif

    // 渲染后端（QML「黑屏诊断」面板可切换，重启应用生效）：
    // gles=默认 RHI OpenGL / vulkan=绕开 GLES 驱动 / software=纯 CPU 渲染绕开整个 GPU 栈。
    // 渲染后端：按设备自适应默认（华为/荣耀→软件，其他→GPU），面板选择优先。
    QString gfxLabel = QStringLiteral("GLES");
    QString gfxNote;
    QString defaultBackend;
    {
        QSettings boot;
        boot.beginGroup(QStringLiteral("Tetris"));
        const QString choice = boot.value(QStringLiteral("gfxBackendValue")).toString();
        boot.endGroup();
#if defined(Q_OS_ANDROID)
        // 安卓一律 GLES，不读历史存档（诊断期存过不适配的值 → 打开异常）。
        // 诊断面板已移除，不再产生新写入。
        Q_UNUSED(choice);
        QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGLRhi);
        defaultBackend = QStringLiteral("gles");
#else
        defaultBackend = choice.isEmpty() ? QStringLiteral("gles") : choice;
        if (defaultBackend == QLatin1String("software")) {
            QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
            gfxLabel = QStringLiteral("软件");
        } else if (defaultBackend == QLatin1String("vulkan")) {
            QQuickWindow::setGraphicsApi(QSGRendererInterface::VulkanRhi);
            gfxLabel = QStringLiteral("Vulkan");
        } else {
            QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGLRhi);
        }
#endif
    }
    const QString loopName = qEnvironmentVariable("QSG_RENDER_LOOP", QStringLiteral("threaded"));
    qInfo() << "=== 会话启动 ===" << "Qt" << QT_VERSION_STR << QSysInfo::prettyProductName()
            << "| gfx:" << gfxLabel << "| loop:" << loopName;
#ifdef Q_OS_ANDROID
    {
        const QJniObject model = QJniObject::getStaticObjectField(
            "android/os/Build", "MODEL", "Ljava/lang/String;");
        if (model.isValid())
            qInfo() << "[Diag] 设备:" << model.toString();
    }
#endif
    QObject::connect(&app, &QGuiApplication::applicationStateChanged, &app, [](Qt::ApplicationState s) {
        qInfo() << "[App] 状态 →" << s;
#ifdef Q_OS_ANDROID
        // 已有渲染帧才武装（冷启动首帧未出前不误杀）
        if (s == Qt::ApplicationActive) {
            const QJniObject activity = QNativeInterface::QAndroidApplication::context();
            if (activity.isValid() && s_everRendered)
                QJniObject::callStaticMethod<void>(
                    "org/qtproject/tetris/Recovery", "arm",
                    "(Landroid/content/Context;)V", activity.object());
            if (s_mainWin) {
                for (int delayMs : {150, 600, 1500, 3000})
                    QTimer::singleShot(delayMs, s_mainWin, [] { s_mainWin->requestUpdate(); });
            }
        } else {
            QJniObject::callStaticMethod<void>(
                "org/qtproject/tetris/Recovery", "cancel", "()V");
        }
#endif
    });

    // 安卓上 Qt 的系统 CA 读取可能为空，导致 Let's Encrypt 证书验证失败（所有 HTTPS status 0）。
    // 把 ISRG Root X1 打进资源并注册为默认信任根。
    // 注意路径前缀：qt_add_qml_module 把 RESOURCES 放在模块目录 /Tetris/ 下
    QFile caFile(QStringLiteral(":/Tetris/certs/isrgrootx1.pem"));
    if (caFile.open(QIODevice::ReadOnly)) {
        const auto certs = QSslCertificate::fromDevice(&caFile, QSsl::Pem);
        if (!certs.isEmpty()) {
            QSslConfiguration config = QSslConfiguration::defaultConfiguration();
            config.addCaCertificates(certs);
            QSslConfiguration::setDefaultConfiguration(config);
        }
    } else {
        qWarning("ISRG Root X1 CA resource not found, using system trust store only");
    }

    QQmlApplicationEngine engine;
    NativeVibe vibe;
    engine.rootContext()->setContextProperty("NativeVibe", &vibe);
    // 进程级单例（有意不销毁）：退出时若仍有在途请求，Java 回调也不会命中悬垂对象
    auto *nativeHttp = new NativeHttp();
    engine.rootContext()->setContextProperty("nativeHttp", nativeHttp);
    Diagnostics diag;
    engine.rootContext()->setContextProperty("Diagnostics", &diag);
    engine.rootContext()->setContextProperty("gfxActiveLabel", gfxLabel + " · " + loopName);
    engine.rootContext()->setContextProperty("gfxDefaultBackend", defaultBackend);
    engine.rootContext()->setContextProperty("gfxBackendNote", gfxNote);
    // 在线更新：下载器 + 本机版本号（QML 与服务器 version.json 比对决定是否提示）
    NativeUpdate updater;
    engine.rootContext()->setContextProperty("NativeUpdate", &updater);
    int clientVersionCode = 0;
#ifdef Q_OS_ANDROID
    {
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (activity.isValid()) {
            const QJniObject pkgInfo = activity.callObjectMethod("getPackageManager",
                "()Landroid/content/pm/PackageManager;")
                .callObjectMethod("getPackageInfo",
                    "(Ljava/lang/String;I)Landroid/content/pm/PackageInfo;",
                    activity.callObjectMethod("getPackageName",
                        "()Ljava/lang/String;").object<jstring>(), 0);
            if (pkgInfo.isValid())
                clientVersionCode = pkgInfo.getField<jint>("versionCode");
        }
    }
#endif
    engine.rootContext()->setContextProperty("clientVersionCode", clientVersionCode);
    engine.rootContext()->setContextProperty("demoScene", demoScene);
    engine.rootContext()->setContextProperty("shotDir", shotDir);
    engine.rootContext()->setContextProperty("demoPreset", demoPreset);

    // 排行榜 uid 用 ANDROID_ID（卸载重装不变），避免重装后同名玩家在榜上分家；
    // 拿不到（桌面/受限系统）时 QML 回退随机 uid
    QString deviceId;
#ifdef Q_OS_ANDROID
    {
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (activity.isValid()) {
            const QJniObject resolver = activity.callObjectMethod(
                "getContentResolver", "()Landroid/content/ContentResolver;");
            const QJniObject id = QJniObject::callStaticObjectMethod(
                "android/provider/Settings$Secure", "getString",
                "(Landroid/content/ContentResolver;Ljava/lang/String;)Ljava/lang/String;",
                resolver.object<jobject>(),
                QJniObject::fromString("android_id").object<jstring>());
            if (id.isValid())
                deviceId = id.toString();
        }
    }
#endif
    engine.rootContext()->setContextProperty("nativeDeviceId", deviceId);
    // 入口 QML：外部 QML 热更补丁（files/patch/Main.qml，updateBanner 经 saveText 写入）
    // 存在且版本达标时优先加载，重启生效；否则回退内置版，防一次坏/旧补丁影响应用。
    // 补丁带版本标记文件 files/patch/ver（正整数）；无标记视为历史旧补丁，一律拒载并删除。
    QUrl mainUrl(QStringLiteral("qrc:/Tetris/Main.qml"));
    QString patchFile;
#ifdef Q_OS_ANDROID
    {
        const QJniObject activity = QNativeInterface::QAndroidApplication::context();
        if (activity.isValid()) {
            const QJniObject dir = activity.callObjectMethod(
                "getExternalFilesDir", "(Ljava/lang/String;)Ljava/io/File;",
                static_cast<jstring>(nullptr));
            if (dir.isValid()) {
                const QJniObject p = dir.callObjectMethod("getAbsolutePath", "()Ljava/lang/String;");
                if (p.isValid()) {
                    const QString patchDir = p.toString() + QStringLiteral("/patch");
                    patchFile = patchDir + QStringLiteral("/Main.qml");
                    // 版本门：kPatchMinVer 是本 APK 信任的补丁最低代数。
                    // 历史 v1 补丁无版本标记且是半成品（横幅无文案、按钮无事件）→ 拒载并删除
                    static constexpr int kPatchMinVer = 2;
                    int savedPatchVer = -1;
                    QFile vf(patchDir + QStringLiteral("/ver"));
                    if (vf.open(QIODevice::ReadOnly))
                        savedPatchVer = QString::fromUtf8(vf.readAll()).trimmed().toInt();
                    if (QFile::exists(patchFile) && savedPatchVer < kPatchMinVer) {
                        qInfo() << "[Update] 补丁无版本标记或过旧(" << savedPatchVer
                                << ")，拒载并删除:" << patchFile;
                        QFile::remove(patchFile);
                        QFile::remove(patchDir + QStringLiteral("/ver"));
                    }
                }
            }
        }
        if (!patchFile.isEmpty() && QFile::exists(patchFile)) {
            qInfo() << "[Update] 检测到 QML 补丁，本次加载外部版:" << patchFile;
            mainUrl = QUrl::fromLocalFile(patchFile);
        }
    }
#endif
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [&engine, &mainUrl, &patchFile](QObject *obj, const QUrl &objUrl) {
                         if (obj || objUrl != mainUrl)
                             return;
#ifdef Q_OS_ANDROID
                         if (objUrl.scheme() == QLatin1String("file")) {
                             qWarning() << "[Update] QML 补丁加载失败，删除补丁回退内置版:" << patchFile;
                             QFile::remove(patchFile);
                             mainUrl = QUrl(QStringLiteral("qrc:/Tetris/Main.qml"));
                             engine.load(mainUrl);
                             return;
                         }
#endif
                         QCoreApplication::exit(-1);
                     }, Qt::QueuedConnection);
#ifdef Q_OS_ANDROID
    // 帧恢复标记：每帧渲染通知 Java 侧恢复梯解除（多帧才通知一次，节流 JNI 调用）。
    // 锁屏恢复梯完全由 Recovery.java 驱动，不使用 Qt 定时器看门狗
    // （Surface 丢失后容器内 Qt 定时器/帧回调不可靠，实测看门狗从未触发）。
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated, &app, [](QObject *obj) {
        if (auto *win = qobject_cast<QQuickWindow *>(obj)) {
            s_mainWin = win;
            QObject::connect(win, &QQuickWindow::afterRendering, [] {
                s_everRendered = true;
                const qint64 now = QDateTime::currentMSecsSinceEpoch();
                if (now - s_lastNoteMs > 200) {
                    s_lastNoteMs = now;
                    QJniObject::callStaticMethod<void>(
                        "org/qtproject/tetris/Recovery", "noteFrame", "()V");
                }
            });
        }
    });
#else
    // 桌面/演示模式：仅记录主窗口指针（演示模式截图用）
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated, &app, [](QObject *obj) {
        if (auto *win = qobject_cast<QQuickWindow *>(obj))
            s_mainWin = win;
    });
#endif
    engine.load(mainUrl);

    return app.exec();
}
#include "main.moc"
