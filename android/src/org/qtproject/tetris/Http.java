package org.qtproject.tetris;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/**
 * 走安卓系统网络栈的 HTTP 桥（Qt 缺 OpenSSL TLS 后端时的替代通道）。
 * 返回格式："OK <code>\n<body>" 或 "ERR <异常简名>"；阻塞调用，须在非主线程使用。
 */
public class Http {
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
