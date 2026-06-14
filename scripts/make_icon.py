"""Generate a Transcribe.app icon: two overlapping speech bubbles."""
from PIL import Image, ImageDraw
import os, sys

SIZE = 1024
PAD = 80

# Colors
BG_TOP = (62, 138, 220)        # blue
BG_BOTTOM = (40, 96, 170)
BUBBLE_A = (255, 255, 255, 255)
BUBBLE_B = (255, 232, 124, 255)  # warm yellow for contrast
TEXT_DARK = (45, 60, 90, 255)

def rounded_rect(draw, box, r, fill):
    draw.rounded_rectangle(box, radius=r, fill=fill)

def speech_bubble(img, box, tail_xy, fill):
    """Draw a rounded-rectangle speech bubble with a small tail."""
    overlay = Image.new("RGBA", img.size, (0,0,0,0))
    d = ImageDraw.Draw(overlay)
    x1,y1,x2,y2 = box
    r = (y2 - y1) // 5
    d.rounded_rectangle(box, radius=r, fill=fill)
    # Tail: small triangle near tail_xy
    tx, ty = tail_xy
    tail_size = (y2 - y1) // 6
    if ty < y1:  # tail above
        d.polygon([(tx-tail_size, y1+r), (tx+tail_size, y1+r), (tx, ty)], fill=fill)
    else:
        d.polygon([(tx-tail_size, y2-r), (tx+tail_size, y2-r), (tx, ty)], fill=fill)
    img.alpha_composite(overlay)

def lines_in_bubble(draw, box, color, n=3):
    """Horizontal lines suggesting text inside the bubble."""
    x1,y1,x2,y2 = box
    w = x2 - x1
    h = y2 - y1
    margin_x = w // 6
    spacing = h // (n + 2)
    line_h = max(8, h // 18)
    for i in range(n):
        y = y1 + spacing * (i + 1) + line_h
        right_pad = (w - 2 * margin_x) * (0.4 if i == n-1 else 0.1)
        draw.rounded_rectangle(
            (x1 + margin_x, y, x2 - margin_x - right_pad, y + line_h),
            radius=line_h // 2, fill=color)

def build():
    img = Image.new("RGBA", (SIZE, SIZE), (0,0,0,0))

    # Rounded-square background (macOS-style "squircle"-ish)
    bg = Image.new("RGBA", (SIZE, SIZE), (0,0,0,0))
    bg_draw = ImageDraw.Draw(bg)
    # Vertical gradient via multiple rounded rects
    for y in range(SIZE):
        t = y / SIZE
        r = int(BG_TOP[0]*(1-t) + BG_BOTTOM[0]*t)
        g = int(BG_TOP[1]*(1-t) + BG_BOTTOM[1]*t)
        b = int(BG_TOP[2]*(1-t) + BG_BOTTOM[2]*t)
        bg_draw.line([(0, y), (SIZE, y)], fill=(r,g,b,255))
    # Mask to rounded square
    mask = Image.new("L", (SIZE, SIZE), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((PAD//2, PAD//2, SIZE-PAD//2, SIZE-PAD//2), radius=SIZE//5, fill=255)
    bg.putalpha(mask)
    img.alpha_composite(bg)

    # Bubble A (upper-left, white)
    a_box = (160, 220, 700, 580)
    speech_bubble(img, a_box, (300, 620), BUBBLE_A)
    d = ImageDraw.Draw(img)
    lines_in_bubble(d, a_box, TEXT_DARK, n=3)

    # Bubble B (lower-right, yellow)
    b_box = (340, 480, 880, 820)
    speech_bubble(img, b_box, (760, 440), BUBBLE_B)
    lines_in_bubble(d, b_box, TEXT_DARK, n=3)

    return img

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "icon_1024.png"
    img = build()
    img.save(out)
    print(f"wrote {out}")
