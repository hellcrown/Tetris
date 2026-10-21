# -*- coding: utf-8 -*-
"""逐张人工判定的裁剪：按每张图的关键元素定制横向裁剪窗口（竖向全保留），
最近邻放大到 720x1560 保持像素画锐利。坐标为各图宽度的比例。"""
import os
import sys

from PIL import Image

BASE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(BASE, u"原图")
TARGET_W, TARGET_H = 720, 1560

# 文件名 → (x1比例, x2比例)  裁剪窗口（竖向全高）
CROPS = {
    u"1.jpeg": (0.234, 0.696),   # 草原：小屋+石径
    u"2.gif": (0.44, 0.902),     # 海岸：灯塔+悬崖
    u"3.jpg": (0.143, 0.604),    # 营地：帐篷+篝火
    u"4.jpg": (0.269, 0.730),    # 樱花：居中透视
    u"5.jpg": (0.124, 0.498),    # 雪镇：左侧主屋
    u"6.jpg": (0.265, 0.770),    # 森林：蘑菇+鹿
    u"7.jpg": (0.293, 0.757),    # 海湾：光柱+小丑鱼
    u"8.jpg": (0.286, 0.771),    # 花园：城堡+瀑布
    u"9.jpg": (0.248, 0.689),    # 秋林：木屋+台阶
    u"10.jpg": (0.288, 0.741),   # 湖泊：垂钓者
    u"11.jpg": (0.178, 0.547),   # 观测站：圆顶
    u"12.jpg": (0.239, 0.757),   # 彼岸：树屋
}


def main():
    for i, fname in enumerate(sorted(CROPS, key=lambda n: int(os.path.splitext(n)[0])), 1):
        fx1, fx2 = CROPS[fname]
        src = os.path.join(RAW, fname)
        im = Image.open(src).convert(u"RGB")
        w, h = im.size
        cw = int(h * TARGET_W / float(TARGET_H))
        x1 = int(fx1 * w)
        x1 = max(0, min(x1, w - cw))
        x2 = x1 + cw
        im = im.crop((x1, 0, x2, h))
        im = im.resize((TARGET_W, TARGET_H), Image.NEAREST)
        out = os.path.join(BASE, u"bg%d.jpg" % i)
        im.save(out, u"JPEG", quality=82, optimize=True)
        print(u"bg%02d.jpg <- %s (%dx%d crop x=%d..%d, %dKB)" % (
            i, fname, cw, h, x1, x2, os.path.getsize(out) // 1024))
    return 0


if __name__ == u"__main__":
    sys.exit(main())
