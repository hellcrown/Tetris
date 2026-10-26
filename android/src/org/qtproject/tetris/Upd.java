// APK 安装三级链（按可靠度排序）：
//   1. content:// + ACTION_VIEW：各 ROM 安装器（含 MIUI InstallStart）都注册了这一路，
//      直接弹安装器确认框——文件管理器装 APK 的同款通道，实测最稳
//   2. 框架 PackageInstaller 会话：官方通道，回调走 InstallRc 广播（MUTABLE！）
//      ——但 MIUI 上会话卡在安全扫描、回调永不送达，只作 VIEW 探测失败时的备选
//   3. 兜底：复制到公共 Download/tetris/，用户从文件管理手动点装（卓易通最稳的一路）
// 每级失败自动降下一级；返回 false 表示三级全不可用（极少见）。
package org.qtproject.tetris;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

public class Upd {
    private static final String AUTH = "org.qtproject.tetris.apk";
    private static final String TAG = "TetrisDiag";   // 与 Recovery.java 共用同一 logcat 标签

    // 华为/荣耀（鸿蒙 NEXT + 卓易通）：容器内安装器/会话通道均不可靠
    // （会话"成功"但实际没装、ACTION_VIEW 弹空的打开方式）→ 直接复制到公共下载，
    // 用户在文件管理点 APK，由卓易通接管安装（与手动装 APK 同路径，实测必然可用）
    private static boolean isHuaweiLike() {
        String brand = android.os.Build.BRAND == null ? "" : android.os.Build.BRAND.toLowerCase();
        return brand.contains("huawei") || brand.contains("honor");
    }

    /** 返回 1=已拉起安装器 2=已复制到公共下载（用户手动点装） 0=全部失败 */
    public static int installOrRoute(Context ctx, String path) {
        if (isHuaweiLike())
            return copyToDownloads(ctx, path) ? 2 : 0;
        if (viewInstall(ctx, path))
            return 1;
        if (sessionInstall(ctx, path))
            return 1;
        return copyToDownloads(ctx, path) ? 2 : 0;
    }

    // 1) 框架 PackageInstaller 会话：写入会话流后 commit，系统弹官方安装确认框
    private static boolean sessionInstall(Context ctx, String path) {
        PackageInstaller.Session session = null;
        try {
            File f = new File(path);
            if (!f.exists())
                return false;
            PackageInstaller pi = ctx.getPackageManager().getPackageInstaller();
            PackageInstaller.SessionParams p =
                    new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
            int sessionId = pi.createSession(p);
            session = pi.openSession(sessionId);
            InputStream in = new FileInputStream(f);
            OutputStream out = session.openWrite("base", 0, f.length());
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = in.read(buf)) > 0)
                out.write(buf, 0, n);
            session.fsync(out);
            out.close();
            in.close();
            // 回调必须是 broadcast 型：activity 型会被系统在"等待用户确认"阶段直接启动，
            // 且确认框（EXTRA_INTENT）永远无人拉起（MIUI 上表现为跳到通话设置页）。
            // 且必须 MUTABLE：系统要往回调里填充状态 extras（EXTRA_STATUS 等），
            // IMMUTABLE 会让回调永远无法送达（Android 12+ 经典坑，会话无限卡在扫描）
            Intent st = new Intent("org.qtproject.tetris.INSTALL_STATUS")
                    .setPackage(ctx.getPackageName());
            int piFlags = PendingIntent.FLAG_UPDATE_CURRENT
                    | (Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0);
            PendingIntent callback = PendingIntent.getBroadcast(ctx, sessionId, st, piFlags);
            session.commit(callback.getIntentSender());
            session.close();
            return true;
        } catch (Exception e) {
            if (session != null) {
                try {
                    session.abandon();
                } catch (Exception ignored) {
                }
            }
            return false;
        }
    }

    // 2) ACTION_VIEW + content://（配合 manifest 的 <queries> 用 resolveActivity 探测）
    private static boolean viewInstall(Context ctx, String path) {
        try {
            File f = new File(path);
            if (!f.exists())
                return false;
            Uri uri = Uri.parse("content://" + AUTH + "/" + f.getName());
            Intent i = new Intent(Intent.ACTION_VIEW);
            i.setDataAndType(uri, "application/vnd.android.package-archive");
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
            if (i.resolveActivity(ctx.getPackageManager()) == null)
                return false;
            ctx.startActivity(i);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /** 重启应用（QML 补丁生效用）：400ms 后闹钟重新拉起，当前进程立即退出 */
    public static void restartApp(Context ctx) {
        try {
            Intent i = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
            if (i == null)
                return;
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            PendingIntent pi = PendingIntent.getActivity(ctx, 300, i,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
            if (am != null)
                am.set(AlarmManager.RTC, System.currentTimeMillis() + 400, pi);
            android.os.Process.killProcess(android.os.Process.myPid());
        } catch (Exception e) {
            Log.w(TAG, "[Upd] 重启失败: " + e);
        }
    }

    // 3) 兜底：复制到公共 Download/tetris/（Android 10+ 走 MediaStore，无需存储权限）。
    //    复制前先删除上一份副本：同一槽位覆盖，不累积占用空间
    private static boolean copyToDownloads(Context ctx, String path) {
        try {
            if (Build.VERSION.SDK_INT < 29)
                return false;
            File f = new File(path);
            if (!f.exists())
                return false;
            try {
                ctx.getContentResolver().delete(
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                        MediaStore.MediaColumns.RELATIVE_PATH + "=? AND "
                                + MediaStore.MediaColumns.DISPLAY_NAME + "=?",
                        new String[]{Environment.DIRECTORY_DOWNLOADS + "/tetris/",
                                     "tetris-update.apk"});
            } catch (Exception ignored) {
            }
            ContentValues v = new ContentValues();
            v.put(MediaStore.MediaColumns.DISPLAY_NAME, "tetris-update.apk");
            v.put(MediaStore.MediaColumns.MIME_TYPE, "application/vnd.android.package-archive");
            v.put(MediaStore.MediaColumns.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/tetris");
            Uri uri = ctx.getContentResolver().insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
            if (uri == null)
                return false;
            OutputStream os = ctx.getContentResolver().openOutputStream(uri);
            InputStream in = new FileInputStream(f);
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = in.read(buf)) > 0)
                os.write(buf, 0, n);
            os.close();
            in.close();
            return true;
        } catch (Exception e) {
            return false;
        }
    }
}
