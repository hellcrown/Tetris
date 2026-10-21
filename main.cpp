#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QFile>
#include <QSslConfiguration>
#include <QSslCertificate>
#include <QJniObject>
#include <thread>

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
        const QJniObject vibrator = activity.callObjectMethod(
            "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;",
            QJniObject::fromString("vibrator").object<jstring>());
        if (vibrator.isValid())
            vibrator.callMethod<void>("vibrate", "(J)V", static_cast<jlong>(ms));
#else
        Q_UNUSED(ms);
#endif
    }
};

// 安卓系统网络栈桥：绕开 Qt 缺少 OpenSSL TLS 后端的问题（浏览器能通=系统栈能通）。
// QML: nativeHttp.post(url, body) / nativeHttp.get(url) → done(response) 信号（异步回 GUI 线程）
class NativeHttp : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;

    Q_INVOKABLE void post(const QString &url, const QString &body) const
    {
        run(url, body);
    }

    Q_INVOKABLE void get(const QString &url) const
    {
        run(url, QString());
    }

signals:
    void done(const QString &response) const;

private:
    void run(const QString &url, const QString &body) const
    {
#ifdef Q_OS_ANDROID
        const QString u = url;
        const QString b = body;
        std::thread([this, u, b]() {
            const QJniObject jMethod = QJniObject::fromString(b.isEmpty() ? QStringLiteral("GET") : QStringLiteral("POST"));
            const QJniObject jUrl = QJniObject::fromString(u);
            const QJniObject jBody = QJniObject::fromString(b);
            const QJniObject res = QJniObject::callStaticObjectMethod(
                "org/qtproject/tetris/Http", "request",
                "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
                jMethod.object<jstring>(), jUrl.object<jstring>(), jBody.object<jstring>());
            const QString out = res.isValid() ? res.toString() : QStringLiteral("ERR JNI");
            emit done(out);
        }).detach();
#else
        Q_UNUSED(url);
        Q_UNUSED(body);
        emit done(QStringLiteral("ERR NOSUPPORT"));
#endif
    }
};

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);

    // 安卓上 Qt 的系统 CA 读取可能为空，导致 Let's Encrypt 证书验证失败（所有 HTTPS status 0）。
    // 把 ISRG Root X1 打进资源并注册为默认信任根。
    QFile caFile(QStringLiteral(":/certs/isrgrootx1.pem"));
    if (caFile.open(QIODevice::ReadOnly)) {
        const auto certs = QSslCertificate::fromDevice(&caFile, QSsl::Pem);
        if (!certs.isEmpty()) {
            QSslConfiguration config = QSslConfiguration::defaultConfiguration();
            config.addCaCertificates(certs);
            QSslConfiguration::setDefaultConfiguration(config);
        }
    }

    QQmlApplicationEngine engine;
    NativeVibe vibe;
    engine.rootContext()->setContextProperty("NativeVibe", &vibe);
    NativeHttp nativeHttp;
    engine.rootContext()->setContextProperty("nativeHttp", &nativeHttp);
    const QUrl url(QStringLiteral("qrc:/Tetris/Main.qml"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [url](QObject *obj, const QUrl &objUrl) {
                         if (!obj && url == objUrl)
                             QCoreApplication::exit(-1);
                     }, Qt::QueuedConnection);
    engine.load(url);

    return app.exec();
}
#include "main.moc"
