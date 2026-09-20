#!/usr/bin/env python3
"""DMG 창 배경 그림을 만든다 — macos/dmg/background.png(600×400)와 @2x(1200×800)를 한 TIFF로 묶는다.

    python3 scripts/make_dmg_background.py

아이콘 자리(왼쪽 Madang, 오른쪽 응용 프로그램)는 release.py의 DMG_ICON_LEFT/RIGHT와 맞춘다.
"""
import os
import subprocess
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(HERE, "macos/dmg")
BG, INK, SOFT = (247, 243, 238), (58, 40, 52), (190, 170, 160)


def font(size):
    for path in ("/System/Library/Fonts/AppleSDGothicNeo.ttc", "/System/Library/Fonts/Supplemental/AppleGothic.ttf"):
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size, index=6 if path.endswith(".ttc") else 0)
            except Exception:
                return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def draw(scale):
    w, h = 600 * scale, 400 * scale
    im = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(im)
    # 픽셀 화살표 — 두 아이콘(가운데 y=190) 사이. 네모 칸으로 찍어 앱 그림체와 맞춘다.
    px = 6 * scale
    y = 190 * scale
    for x in range(250 * scale, 338 * scale, px * 2):
        d.rectangle([x, y - px // 2, x + px - 1, y + px // 2 - 1], fill=SOFT)
    tip = 350 * scale
    for i in range(4):
        d.rectangle([tip - px * (i + 1), y - px // 2 - px * i, tip - px * i - 1, y + px // 2 + px * i - 1], fill=SOFT)
    title = "Madang을 응용 프로그램 폴더로 끌어 놓으세요"
    f = font(17 * scale)
    tw = d.textlength(title, font=f)
    d.text(((w - tw) / 2, 312 * scale), title, font=f, fill=INK)
    sub = "Claude Code 세션들이 사는 작은 사무실"
    f2 = font(12 * scale)
    sw = d.textlength(sub, font=f2)
    d.text(((w - sw) / 2, 342 * scale), sub, font=f2, fill=SOFT)
    return im


def main():
    os.makedirs(OUT, exist_ok=True)
    one, two = os.path.join(OUT, "background.png"), os.path.join(OUT, "background@2x.png")
    draw(1).save(one)
    draw(2).save(two)
    # Finder는 한 TIFF 안의 두 해상도를 골라 쓴다 — 레티나에서 흐려지지 않게.
    subprocess.run(["tiffutil", "-cathidpicheck", one, two, "-out", os.path.join(OUT, "background.tiff")], check=True)
    print("✓", os.path.join(OUT, "background.tiff"))


if __name__ == "__main__":
    main()
