# -*- coding: utf-8 -*-
"""生成「电视」应用的拟物化电视图标。

输出：
  android/app/src/main/res/mipmap-*/ic_launcher.png              （传统方形图标）
  android/app/src/main/res/mipmap-*/ic_launcher_foreground.png   （自适应图标前景）
  android/app/src/main/res/drawable/tv_banner.png                （电视端 banner）
  build/icon_preview.png                                         （1024 预览）
"""

import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
PREVIEW = os.path.join(ROOT, "build", "icon_preview.png")

S = 1024  # 绘制基准尺寸

# ---------------- 调色板（复古木壳 + 米白面板 + 青玻璃屏） ----------------
WOOD_TOP = (126, 78, 45)
WOOD_BOT = (74, 43, 24)
WOOD_EDGE = (48, 27, 14)
CREAM_TOP = (247, 239, 222)
CREAM_BOT = (206, 191, 164)
SCREEN_TOP = (26, 62, 64)
SCREEN_BOT = (8, 26, 30)
CHROME_HI = (244, 247, 248)
CHROME_LO = (118, 126, 130)
BG_TOP = (32, 26, 22)
BG_BOT = (14, 11, 10)


def vgrad(size, c1, c2):
    """垂直渐变（先画 1×h 再拉伸，边缘平滑）。"""
    w, h = size
    strip = Image.new("RGB", (1, max(h, 2)))
    px = strip.load()
    for y in range(max(h, 2)):
        t = y / (max(h, 2) - 1)
        px[0, y] = tuple(round(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
    return strip.resize((w, h), Image.BICUBIC)


def diag_grad(size, c1, c2, angle=45):
    """斜向渐变：画足够大的竖直渐变再旋转裁切。"""
    w, h = size
    big = int(math.hypot(w, h)) + 8
    g = vgrad((big, big), c1, c2).rotate(angle, resample=Image.BICUBIC, expand=False)
    left = (big - w) // 2
    top = (big - h) // 2
    return g.crop((left, top, left + w, top + h))


def round_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def paste_shape(base, color_img, mask, alpha=255):
    """把 color_img 按 mask 贴到 base 上（mask 灰度可做透明度）。"""
    if alpha != 255:
        mask = mask.point(lambda v: int(v * alpha / 255))
    base.paste(color_img, (0, 0), mask)


def draw_tv(size=1024):
    """画一台拟物化老电视，返回 RGBA 图（画布内留少量边距）。"""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = size / 1024.0

    def box(v):
        return [int(round(x * k)) for x in v]

    # 机身与面板的几何：天线在顶部，机身箱体，底部两只脚
    body = box((118, 300, 906, 852))
    face = box((150, 334, 874, 812))
    screen = box((182, 372, 648, 782))
    rad_body = int(58 * k)
    rad_face = int(40 * k)
    rad_screen = int(30 * k)

    # ---- 1. 投影 ----
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ds = ImageDraw.Draw(shadow)
    ds.ellipse(
        box((150, 826, 880, 918)),
        fill=(10, 6, 4, 165),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(18 * k)))
    img.alpha_composite(shadow)

    # ---- 2. 天线（两根镀铬伸缩杆 + 球形端头）----
    ant = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    da = ImageDraw.Draw(ant)
    for sx, dx in ((-1, 300), (1, 724)):
        base_x = 512 + sx * 26
        tip_x = base_x + sx * 250
        tip_y = 96
        da.line(
            [(base_x * k, 322 * k), (tip_x * k, tip_y * k)],
            fill=(196, 202, 205, 255),
            width=int(11 * k),
            joint="curve",
        )
        # 杆身高光
        da.line(
            [(base_x * k, 322 * k), (tip_x * k, tip_y * k)],
            fill=(238, 242, 244, 190),
            width=int(4 * k),
        )
        r = int(15 * k)
        da.ellipse(
            [(tip_x - 15) * k, (tip_y - 15) * k, (tip_x + 15) * k, (tip_y + 15) * k],
            fill=(222, 228, 231, 255),
        )
        da.ellipse(
            [(tip_x - 5) * k, (tip_y - 8) * k, (tip_x + 7) * k, (tip_y + 3) * k],
            fill=(255, 255, 255, 220),
        )
        _ = r
    # 天线底座
    da.rounded_rectangle(
        box((470, 300, 554, 340)), radius=int(14 * k), fill=(58, 60, 62, 255)
    )
    img.alpha_composite(ant)

    # ---- 3. 木质箱体 ----
    body_mask = round_mask((size, size), body, rad_body)
    paste_shape(img, vgrad((size, size), WOOD_TOP, WOOD_BOT), body_mask)

    # 木纹：稀疏的深浅竖条，低对比
    grain = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dg = ImageDraw.Draw(grain)
    for i in range(46):
        x = body[0] + int((body[2] - body[0]) * (i + 0.5) / 46)
        shade = (20, 12, 6, 26) if i % 2 == 0 else (255, 240, 220, 12)
        dg.line([(x, body[1] + 8), (x, body[3] - 8)], fill=shade, width=max(1, int(3 * k)))
    grain = grain.filter(ImageFilter.GaussianBlur(int(1.6 * k)))
    img.alpha_composite(Image.composite(grain, Image.new("RGBA", (size, size), (0, 0, 0, 0)), body_mask))

    # 箱体倒角：左上亮边、右下暗边
    hi = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(hi).rounded_rectangle(
        [body[0] + 3, body[1] + 3, body[2] - 3, body[3] - 3],
        radius=rad_body,
        outline=(255, 232, 200, 70),
        width=max(2, int(4 * k)),
    )
    img.alpha_composite(Image.composite(hi, Image.new("RGBA", (size, size), (0, 0, 0, 0)), body_mask))
    lo = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(lo).rounded_rectangle(body, radius=rad_body, outline=(22, 12, 6, 110), width=max(2, int(5 * k)))
    img.alpha_composite(Image.composite(lo, Image.new("RGBA", (size, size), (0, 0, 0, 0)), body_mask))

    # ---- 4. 米白前面板 ----
    face_mask = round_mask((size, size), face, rad_face)
    paste_shape(img, vgrad((size, size), CREAM_TOP, CREAM_BOT), face_mask)
    # 面板内阴影（顶部压暗）
    inner = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(inner).rounded_rectangle(
        [face[0], face[1], face[2], face[1] + int(34 * k)],
        radius=rad_face,
        fill=(120, 100, 74, 90),
    )
    inner = inner.filter(ImageFilter.GaussianBlur(int(11 * k)))
    img.alpha_composite(Image.composite(inner, Image.new("RGBA", (size, size), (0, 0, 0, 0)), face_mask))
    # 面板描边
    edge = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(face, radius=rad_face, outline=(122, 100, 72, 120), width=max(2, int(3 * k)))
    img.alpha_composite(Image.composite(edge, Image.new("RGBA", (size, size), (0, 0, 0, 0)), face_mask))

    # ---- 5. 屏幕（凹进面板的玻璃）----
    # 屏幕外框（深色胶圈）
    bez = round_mask((size, size), [screen[0] - 10, screen[1] - 10, screen[2] + 10, screen[3] + 10], rad_screen + 8)
    paste_shape(img, Image.new("RGB", (size, size), (44, 36, 28)), bez)
    # 屏内底色（中心略亮的径向感，用斜向渐变近似）
    screen_mask = round_mask((size, size), screen, rad_screen)
    paste_shape(img, diag_grad((size, size), (34, 78, 80), (6, 20, 24), angle=35), screen_mask)

    # 屏幕中心微光
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gw = screen[2] - screen[0]
    gh = screen[3] - screen[1]
    ImageDraw.Draw(glow).ellipse(
        [
            screen[0] + gw * 0.16,
            screen[1] + gh * 0.12,
            screen[0] + gw * 0.84,
            screen[1] + gh * 0.82,
        ],
        fill=(60, 150, 150, 78),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(int(46 * k)))
    img.alpha_composite(Image.composite(glow, Image.new("RGBA", (size, size), (0, 0, 0, 0)), screen_mask))

    # 扫描线
    scan = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dsl = ImageDraw.Draw(scan)
    step = max(3, int(7 * k))
    for y in range(screen[1], screen[3], step):
        dsl.line([(screen[0], y), (screen[2], y)], fill=(0, 0, 0, 30), width=max(1, int(1.4 * k)))
    img.alpha_composite(Image.composite(scan, Image.new("RGBA", (size, size), (0, 0, 0, 0)), screen_mask))

    # 玻璃反光：左上斜切亮带
    refl = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dr = ImageDraw.Draw(refl)
    dr.polygon(
        [
            (screen[0] + gw * 0.02, screen[1] + gh * 0.10),
            (screen[0] + gw * 0.46, screen[1] + gh * 0.02),
            (screen[0] + gw * 0.20, screen[1] + gh * 0.62),
            (screen[0] - gw * 0.06, screen[1] + gh * 0.70),
        ],
        fill=(255, 255, 255, 34),
    )
    dr.polygon(
        [
            (screen[0] + gw * 0.52, screen[1] + gh * 0.02),
            (screen[0] + gw * 0.62, screen[1] + gh * 0.02),
            (screen[0] + gw * 0.30, screen[1] + gh * 0.80),
            (screen[0] + gw * 0.22, screen[1] + gh * 0.80),
        ],
        fill=(255, 255, 255, 16),
    )
    refl = refl.filter(ImageFilter.GaussianBlur(int(6 * k)))
    img.alpha_composite(Image.composite(refl, Image.new("RGBA", (size, size), (0, 0, 0, 0)), screen_mask))

    # 屏幕内阴影 + 玻璃高光边
    sh = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(screen, radius=rad_screen, outline=(0, 0, 0, 130), width=max(3, int(9 * k)))
    sh = sh.filter(ImageFilter.GaussianBlur(int(7 * k)))
    img.alpha_composite(Image.composite(sh, Image.new("RGBA", (size, size), (0, 0, 0, 0)), screen_mask))
    gl = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(gl).rounded_rectangle(
        screen, radius=rad_screen, outline=(190, 225, 226, 70), width=max(1, int(2 * k))
    )
    img.alpha_composite(Image.composite(gl, Image.new("RGBA", (size, size), (0, 0, 0, 0)), screen_mask))

    # ---- 6. 右侧控制区：两只镀铬旋钮 + 喇叭格栅 ----
    def knob(cx, cy, r):
        cx, cy, r = cx * k, cy * k, r * k
        layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        dl = ImageDraw.Draw(layer)
        # 外圈阴影
        dl.ellipse([cx - r - 3, cy - r - 1, cx + r + 3, cy + r + 5], fill=(96, 76, 54, 120))
        # 镀铬环
        dl.ellipse([cx - r, cy - r, cx + r, cy + r], fill=CHROME_LO)
        dl.ellipse([cx - r + 2, cy - r + 2, cx + r - 2, cy + r - 2], fill=CHROME_HI)
        # 环内斜面
        dl.ellipse([cx - r + 7, cy - r + 7, cx + r - 7, cy + r - 7], fill=(150, 158, 162, 255))
        # 旋钮芯（深色）
        inner_r = r - 13
        dl.ellipse([cx - inner_r, cy - inner_r, cx + inner_r, cy + inner_r], fill=(46, 44, 42, 255))
        dl.ellipse(
            [cx - inner_r + 3, cy - inner_r + 3, cx + inner_r - 3, cy + inner_r - 3],
            fill=(64, 62, 58, 255),
        )
        # 旋钮上的白色指示
        dl.rounded_rectangle(
            [cx - 2.2 * k, cy - inner_r * 0.72, cx + 2.2 * k, cy - inner_r * 0.18],
            radius=int(2 * k),
            fill=(238, 238, 232, 235),
        )
        # 高光（小弧面，别糊成一团）
        dl.ellipse(
            [cx - r * 0.52, cy - r * 0.78, cx - r * 0.02, cy - r * 0.46],
            fill=(255, 255, 255, 42),
        )
        img.alpha_composite(layer)

    knob(742, 452, 46)
    knob(742, 566, 46)

    # 喇叭格栅
    grill = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dgr = ImageDraw.Draw(grill)
    gx0, gx1 = 690, 800
    gy0, gy1 = 640, 780
    for i in range(7):
        y = gy0 + (gy1 - gy0) * i / 6
        dgr.rounded_rectangle(
            [gx0 * k, y * k, gx1 * k, (y + 2.6) * k],
            radius=int(1.6 * k),
            fill=(84, 68, 48, 150),
        )
    img.alpha_composite(grill)

    # 屏幕下方的小品牌铭牌（纯色块，不放文字，避免放大后糊）
    d.rounded_rectangle(box((196, 796, 300, 802)), radius=int(2 * k), fill=(120, 100, 74, 90))

    # ---- 7. 两只脚 ----
    feet = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    df = ImageDraw.Draw(feet)
    for x0, x1 in ((236, 320), (704, 788)):
        df.polygon(
            [
                (x0 * k, 846 * k),
                (x1 * k, 846 * k),
                ((x1 - 12) * k, 892 * k),
                ((x0 + 12) * k, 892 * k),
            ],
            fill=(46, 32, 20, 255),
        )
    img.alpha_composite(feet)

    return img


def rounded_tile(size, radius_ratio=0.22):
    """深色圆角底板（传统图标用），带一点暖色渐变。"""
    tile = vgrad((size, size), BG_TOP, BG_BOT).convert("RGBA")
    # 中心暖光
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        [size * 0.1, size * 0.05, size * 0.9, size * 0.85],
        fill=(96, 68, 40, 120),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(size // 10))
    tile.alpha_composite(glow)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=int(size * radius_ratio), fill=255
    )
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(tile, (0, 0), mask)
    return out


def art_canvas(art, canvas_size, scale):
    """把电视画作缩放到 canvas_size 的画布中央。"""
    w = max(1, int(round(canvas_size * scale)))
    a = art.resize((w, w), Image.LANCZOS)
    c = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    c.alpha_composite(a, ((canvas_size - w) // 2, (canvas_size - w) // 2))
    return c


def main():
    art = draw_tv(S)

    # ---- 预览 ----
    preview = rounded_tile(S)
    preview.alpha_composite(art_canvas(art, S, 0.97))
    os.makedirs(os.path.dirname(PREVIEW), exist_ok=True)
    preview.save(PREVIEW)
    print("preview ->", PREVIEW)

    # ---- 传统图标：mdpi 48 → xxxhdpi 192 ----
    legacy = {48: "mdpi", 72: "hdpi", 96: "xhdpi", 144: "xxhdpi", 192: "xxxhdpi"}
    for px, dpi in legacy.items():
        tile = rounded_tile(px)
        tile.alpha_composite(art_canvas(art, px, 0.97))
        out = os.path.join(RES, "mipmap-" + dpi, "ic_launcher.png")
        tile.save(out)
        print("icon ->", out)

    # ---- 自适应图标前景：108dp 画布，内容收在中间 72dp 安全区 ----
    fg = {108: "mdpi", 162: "hdpi", 216: "xhdpi", 324: "xxhdpi", 432: "xxxhdpi"}
    for px, dpi in fg.items():
        c = art_canvas(art, px, 0.64)
        out = os.path.join(RES, "mipmap-" + dpi, "ic_launcher_foreground.png")
        c.save(out)
        print("fg ->", out)

    # ---- 电视端 banner 320x180（xhdpi 640x360）----
    def banner(w, h):
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        bg = vgrad((w, h), (34, 27, 22), (12, 10, 9)).convert("RGBA")
        img.alpha_composite(bg)
        # 左侧暖光
        glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        ImageDraw.Draw(glow).ellipse(
            [-w * 0.2, -h * 0.5, w * 0.7, h * 1.4], fill=(104, 70, 40, 150)
        )
        img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(h // 8)))
        tv = art.resize((int(h * 0.80), int(h * 0.80)), Image.LANCZOS)
        img.alpha_composite(tv, (int(w * 0.04), int(h * 0.10)))
        # 文字（按可用宽度自动缩字号，避免被裁）
        from PIL import ImageFont

        try:
            f1 = ImageFont.truetype("C:/Windows/Fonts/msyhbd.ttc", int(h * 0.30))
            f2 = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", int(h * 0.085))
        except Exception:
            return img
        d2 = ImageDraw.Draw(img)
        x0 = w * 0.42
        maxw = w - x0 - w * 0.05

        def fit(text, font, start):
            size = start
            while size > 6:
                f = font.font_variant(size=size)
                if d2.textlength(text, font=f) <= maxw:
                    return f
                size -= 1
            return font.font_variant(size=6)

        f1f = fit("电视", f1, int(h * 0.30))
        f2f = fit("LIVE TV PLAYER", f2, int(h * 0.085))
        d2.text((x0, h * 0.30), "电视", font=f1f, fill=(248, 244, 236, 255))
        d2.text((x0 + 2, h * 0.72), "LIVE TV PLAYER", font=f2f, fill=(198, 212, 210, 255))
        return img

    b = banner(320, 180)
    b.save(os.path.join(RES, "drawable", "tv_banner.png"))
    print("banner -> drawable/tv_banner.png")
    xh = os.path.join(RES, "drawable-xhdpi")
    os.makedirs(xh, exist_ok=True)
    banner(640, 360).save(os.path.join(xh, "tv_banner.png"))
    print("banner -> drawable-xhdpi/tv_banner.png")


if __name__ == "__main__":
    main()
