// 极简 ContentProvider：向系统安装器提供 APK 文件的 content:// 读取通道。
// 不引入 androidx FileProvider 依赖（Qt 模板无该编译依赖），只实现安装器需要的最小接口。
package org.qtproject.tetris;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import java.io.File;
import java.io.FileNotFoundException;

public class ApkPrv extends ContentProvider {
    @Override
    public boolean onCreate() {
        return true;
    }

    private File fileFor(Uri uri) {
        // 路径形如 /update.apk → 应用私有目录下的相对文件
        String rel = uri.getPath().replaceFirst("^/", "");
        File f = new File(getContext().getFilesDir(), rel);
        if (!f.exists()) {
            File extDir = getContext().getExternalFilesDir(null);
            if (extDir != null)
                f = new File(extDir, rel);
        }
        return f;
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        File f = fileFor(uri);
        if (!f.exists())
            throw new FileNotFoundException(uri.toString());
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override
    public String getType(Uri uri) {
        return "application/vnd.android.package-archive";
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection,
                        String[] selectionArgs, String sortOrder) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        return 0;
    }
}
