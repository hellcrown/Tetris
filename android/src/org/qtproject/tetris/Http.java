package org.qtproject.tetris;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 走安卓系统网络栈的 HTTP 桥（Qt 缺 OpenSSL TLS 后端时的替代通道）。
 * request() 返回格式："OK <code>\n<body>" 或 "ERR <异常简名>"；阻塞调用，勿在主线程使用。
 */
public class Http {
    // 单线程池：请求天然按序执行、按序回调，C++/QML 侧按 FIFO 匹配响应即可
    private static final ExecutorService POOL = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "tetris-http");
        t.setDaemon(true);
        return t;
    });

    /**
     * 异步请求：在后台线程执行 request()，完成后经 nativeResult(String) 回调 C++ 侧
     * （回调即发生在本线程上，C++ 的跨线程信号会自动排队回 GUI 线程）。
     */
    public static void requestAsync(String method, String url, String body) {
        POOL.execute(() -> {
            String res = request(method, url, body);
            try {
                nativeResult(res);
            } catch (Throwable ignored) {
                // 进程退出、native 库已不可用等极端情况：丢弃结果即可
            }
        });
    }

    private static native void nativeResult(String response);

    /** APK 下载：专用线程（新下载会断开并中断卡死的旧下载），48MB 级文件流式落盘 */
    private static volatile Thread dlThread;
    private static volatile HttpURLConnection dlConn;
    // 下载代数：新下载顶替旧下载后，旧线程的进度/完成回调静默丢弃，
    // 避免被打断的旧线程迟到的失败回调把 QML 侧新下载的 UI 状态打回去
    private static volatile int dlGen = 0;

    /**
     * 异步下载 APK 到 destPath：先写 .tmp 临时文件，完成后原子改名；
     * 进度经 nativeDownloadProgress(done,total)、结果经 nativeDownloadDone(路径|"") 回调。
     */
    public static void downloadApkAsync(String urlStr, String destPath) {
        final int gen = ++dlGen;
        // 上一条下载若卡死（连接僵死/读阻塞），断开连接并中断，让新下载顶替
        HttpURLConnection staleConn = dlConn;
        if (staleConn != null)
            staleConn.disconnect();
        Thread stale = dlThread;
        if (stale != null)
            stale.interrupt();
        Thread t = new Thread(() -> {
            HttpURLConnection conn = null;
            try {
                URL u = new URL(urlStr);
                conn = (HttpURLConnection) u.openConnection();
                dlConn = conn;
                conn.setConnectTimeout(8000);
                conn.setReadTimeout(30000);
                long total = Math.max(conn.getContentLength(), 1);
                InputStream is = conn.getInputStream();
                java.io.File tmp = new java.io.File(destPath + ".tmp");
                java.io.FileOutputStream fos = new java.io.FileOutputStream(tmp);
                byte[] buf = new byte[64 * 1024];
                long done = 0;
                int n;
                while ((n = is.read(buf)) > 0) {
                    fos.write(buf, 0, n);
                    done += n;
                    if (gen == dlGen) {
                        try {
                            nativeDownloadProgress(done, total);
                        } catch (Throwable ignored) {
                        }
                    }
                }
                fos.close();
                is.close();
                java.io.File out = new java.io.File(destPath);
                if (!tmp.renameTo(out) && !out.exists()) {
                    if (gen == dlGen) {
                        try {
                            nativeDownloadDone("");
                        } catch (Throwable ignored) {
                        }
                    }
                    return;
                }
                if (gen == dlGen) {
                    try {
                        nativeDownloadDone(out.getAbsolutePath());
                    } catch (Throwable ignored) {
                    }
                }
            } catch (Exception e) {
                if (gen == dlGen) {
                    try {
                        nativeDownloadDone("");
                    } catch (Throwable ignored) {
                    }
                }
            } finally {
                if (conn != null) {
                    conn.disconnect();
                }
            }
        }, "tetris-apk");
        t.setDaemon(true);
        dlThread = t;
        t.start();
    }

    private static native void nativeDownloadProgress(long done, long total);
    private static native void nativeDownloadDone(String path);

    public static String request(String method, String url, String body) {
        HttpURLConnection conn = null;
        try {
            URL u = new URL(url);
            conn = (HttpURLConnection) u.openConnection();
            conn.setConnectTimeout(8000);
            conn.setReadTimeout(8000);
            conn.setRequestMethod(method);
            if (body != null && !body.isEmpty()) {
                conn.setDoOutput(true);
                conn.setRequestProperty("Content-Type", "application/json");
                OutputStream os = conn.getOutputStream();
                os.write(body.getBytes(StandardCharsets.UTF_8));
                os.close();
            }
            int code = conn.getResponseCode();
            InputStream is = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
            BufferedReader r = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) {
                sb.append(line);
            }
            r.close();
            return "OK " + code + "\n" + sb.toString();
        } catch (Exception e) {
            return "ERR " + e.getClass().getSimpleName();
        } finally {
            if (conn != null) {
                conn.disconnect();
            }
        }
    }
}
