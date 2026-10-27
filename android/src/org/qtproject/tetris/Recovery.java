// 锁屏恢复兜底（卓易通容器专用）：解锁后 Surface 不回传导致黑屏时，
// 由 Java 侧 Handler 计时逐级恢复。Qt 侧每帧调用 noteFrame() 取消计时；
// 帧没恢复则 1.5s 重开 Activity（等效手动重开，实测有效）→ 5s 杀进程+闹钟拉起。
// 不用 Qt 定时器：Surface 丢失后 Qt 定时器/帧回调在容器内不可靠。
package org.qtproject.tetris;

import android.app.Activity;
import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.util.Log;

public class Recovery {
    private static final String TAG = "TetrisDiag";
    private static final Handler h = new Handler(Looper.getMainLooper());
    private static Activity act;
    private static long lastFrameAt = 0;

    // 把恢复梯动作追加到 Qt 侧同一份日志文件（外部目录，用户可导出回传）
    private static void appendLog(String line) {
        try {
            Activity a = act;
            Context c = a != null ? a.getApplicationContext() : null;
            if (c == null)
                return;
            java.io.File dir = c.getExternalFilesDir(null);
            if (dir == null)
                return;
            java.io.FileWriter w = new java.io.FileWriter(
                    new java.io.File(dir, "tetris-debug.log"), true);
            String ts = new java.text.SimpleDateFormat("MM-dd HH:mm:ss.SSS", java.util.Locale.US)
                    .format(new java.util.Date());
            w.write(ts + " INFO  Recovery(java): " + line + "\n");
            w.close();
        } catch (Exception e) { }
        Log.i(TAG, "[Recovery] " + line);
    }

    public static void arm(Context c) {
        try {
            act = (Activity) c;
            lastFrameAt = System.currentTimeMillis();
            h.removeCallbacksAndMessages(null);
            h.postDelayed(new Runnable() { public void run() { step(false); } }, 3000);
            h.postDelayed(new Runnable() { public void run() { step(true); } }, 8000);
            appendLog("[Recovery] 已武装（3s 重开 Activity / 8s 杀进程+闹钟拉起，按帧新近度判定）");
        } catch (Exception e) {
            appendLog("[Recovery] arm 失败: " + e);
        }
    }

    // 只记录最后出帧时间，不再立即撤防——卓易通上首帧可能成功渲染而 Surface 随后坏死，
    // 老逻辑首帧即解除会让这类黑屏永远触发不了兜底（偶发黑屏的根因）
    public static void noteFrame() {
        if (act == null)
            return;   // 未武装时的高频调用直接跳过
        lastFrameAt = System.currentTimeMillis();
    }

    public static void cancel() {
        act = null;
        h.removeCallbacksAndMessages(null);
    }

    // 卓易通定向：解锁回前台时前台重建一次 Activity——效果等同用户手动点图标重开
    //（实测手动重开必拿健康 Surface），用于「帧在跳、屏是黑」这种看门狗检测不到的表现
    public static void recreate(Context c) {
        Activity a = (Activity) c;
        if (a == null || a.isFinishing())
            return;
        appendLog("[Recovery] 卓易通解锁重建 Activity（前台重建拿新 Surface）");
        try {
            Intent i = new Intent(a, a.getClass());
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
            a.startActivity(i);
            a.finish();
        } catch (Exception e) {
            appendLog("[Recovery] 重建失败: " + e);
        }
    }

    // 检查点（3s 非致命=重开 Activity / 8s 致命=杀进程+闹钟拉起）：
    // 近 1.5 秒内仍在出帧 = 渲染健康，解除兜底；否则按级别恢复
    private static void step(boolean fatal) {
        Activity a = act;
        if (a == null)
            return;
        long since = System.currentTimeMillis() - lastFrameAt;
        if (since < 1500) {
            appendLog("[Recovery] 帧流畅（距上帧 " + since + "ms），解除兜底");
            cancel();
            return;
        }
        if (!fatal) {
            appendLog("[Recovery] " + (since / 1000) + "s 无帧，重开 Activity 重获 Surface");
            try {
                Intent i = new Intent(a, a.getClass());
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
                a.startActivity(i);
                a.finish();
            } catch (Exception e) {
                appendLog("[Recovery] 重开失败: " + e);
            }
            return;
        }
        appendLog("[Recovery] 重开后仍无帧，杀进程并用闹钟自动拉起");
        try {
            Context c = a.getApplicationContext();
            Intent i = c.getPackageManager().getLaunchIntentForPackage(c.getPackageName());
            if (i != null) {
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                PendingIntent pi = PendingIntent.getActivity(c, 0, i,
                        PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
                AlarmManager am = (AlarmManager) c.getSystemService(Context.ALARM_SERVICE);
                if (am != null)
                    am.set(AlarmManager.RTC, System.currentTimeMillis() + 800, pi);
            }
            a.finishAffinity();
        } catch (Exception e) {
            appendLog("[Recovery] 闹钟拉起失败，需手动重开: " + e);
        }
        Process.killProcess(Process.myPid());
    }

    private static void step1() {
        Activity a = act;
        if (a == null || a.isFinishing())
            return;
        appendLog("[Recovery] 解锁后无帧，重开 Activity 重获 Surface");
        try {
            Intent i = new Intent(a, a.getClass());
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
            a.startActivity(i);
            a.finish();
        } catch (Exception e) {
            appendLog("[Recovery] 重开失败: " + e);
        }
    }

    private static void step2() {
        appendLog("[Recovery] 重开 Activity 仍无帧，杀进程并用闹钟自动拉起");
        try {
            Activity a = act;
            Context c = a != null ? a.getApplicationContext() : null;
            if (c != null) {
                Intent i = c.getPackageManager().getLaunchIntentForPackage(c.getPackageName());
                if (i != null) {
                    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    PendingIntent pi = PendingIntent.getActivity(c, 0, i,
                            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
                    AlarmManager am = (AlarmManager) c.getSystemService(Context.ALARM_SERVICE);
                    if (am != null)
                        am.set(AlarmManager.RTC, System.currentTimeMillis() + 800, pi);
                }
                a.finishAffinity();
            }
        } catch (Exception e) {
            appendLog("[Recovery] 闹钟拉起失败，需手动重开: " + e);
        }
        Process.killProcess(Process.myPid());
    }
}
