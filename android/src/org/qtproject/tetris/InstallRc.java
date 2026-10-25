// PackageInstaller 会话状态接收器：commit() 的回调必须是 broadcast 型 IntentSender。
// 旧实现把"启动应用的 Activity PI"当回调 → 系统在等待用户确认阶段就把它当普通页面启动
// （MIUI 上 getLaunchIntentForPackage 为 null → 裸 MAIN 被解析到优先级最高的
// com.android.phone 通话设置页），且真正的安装确认框从未拉起。
// 本接收器按官方协议处理：
//   PENDING_USER_ACTION → 启动 EXTRA_INTENT（系统安装确认框）
//   SUCCESS / FAILURE_* → 写入诊断日志（logcat tag TetrisDiag）
package org.qtproject.tetris;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.util.Log;

public class InstallRc extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent i) {
        int status = i.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
        switch (status) {
            case PackageInstaller.STATUS_PENDING_USER_ACTION: {
                Intent confirm = i.getParcelableExtra(Intent.EXTRA_INTENT);
                if (confirm != null) {
                    confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    try {
                        ctx.startActivity(confirm);
                    } catch (Exception e) {
                        Log.w("TetrisDiag", "[Upd] 拉起安装确认框失败: " + e);
                    }
                } else {
                    Log.w("TetrisDiag", "[Upd] 等待用户确认但系统未携带确认框 intent");
                }
                break;
            }
            case PackageInstaller.STATUS_SUCCESS:
                Log.i("TetrisDiag", "[Upd] 安装成功");
                break;
            default:
                Log.w("TetrisDiag", "[Upd] 安装失败 status=" + status
                        + " msg=" + i.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE));
                break;
        }
    }
}
