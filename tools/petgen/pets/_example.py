"""Worked example: a small lilac blob, built with the rig approach.

    python3 tools/petgen/petgen.py build _example

The pattern every pet should follow:
  1. Palette at the top (ramps from one base colour per material, outline_of(base)).
  2. Parts drawn once as small functions (body, feet, arms, eyes, mouth).
  3. One draw(pose) that composes the parts back to front, each part outlined
     separately so overlaps get a clean interior line.
  4. frames() lists poses per row; only the numbers change between frames.

Underscore-prefixed pets are previews only: their pack goes to out/_example/pack/,
never into the app bundle.
"""
import math

from petgen import *

PET = {
    "id": "example",
    "displayName": "Example Blob",
    "description": "A lilac blob that shows how the petgen rig works.",
}

# ---------------------------------------------------------------- palette
BODY = "#A99BFF"
TONES = [shade(BODY, 0.34), shade(BODY, 0.17), rgba(BODY), tint(BODY, 0.42)]   # dark -> light
OUTLINE = outline_of(BODY)
FEET = [shade(BODY, 0.3), shade(BODY, 0.12)]
GLOSS = tint(BODY, 0.8)
BLUSH = mix("#FF8FB8", BODY, 0.25)
TONGUE = rgba("#FF7A9C")
TAP = mix(SCREEN, WHITE, 0.4)

# ---------------------------------------------------------------- pose
REST = dict(
    dx=0, lift=0,             # whole-body offset (lift > 0 = up, used by jumps)
    bw=30, bh=31,             # body ellipse box; squash = wider/shorter, stretch = narrower/taller
    lean=0,                   # px the top of the body leans (runs: +2 toward the travel direction)
    eyes="open", look=0,      # eye style; look turns the whole face left/right (px)
    mouth="smile", blush=True,
    arm_l=None, arm_r=None,   # None = resting nub, else angle in degrees (0 out, 90 up, -90 down)
    arm_len=7,
    feet=((0, 0), (0, 0)),    # (dx, lift) per foot, left then right
    laptop=None,              # frame index for the working prop
    paws=(0, 0),              # working: 1 = that paw is pressing a key this frame
    glow=0.0,                 # working: screen light on the face (0..1)
    fx=(),                    # [(sprite, x, y)] effect glyphs, drawn last
)


def P(**kw):
    p = dict(REST)
    p.update(kw)
    return p


# ---------------------------------------------------------------- parts
def body_box(p):
    """Body ellipse box (x, y, w, h) and the cut that flattens its base."""
    cut = 3
    bottom = 44 - p["lift"]                 # lowest filled body row
    x = CX - p["bw"] // 2 + p["dx"]
    y = bottom - (p["bh"] - cut) + 1
    return x, y, p["bw"], p["bh"], cut


def draw_feet(c, p, front):
    """Feet planted on the ground sit behind the body; a foot lifted 2+ px is stepping
    toward us, so it is drawn in front of the body (front=True pass)."""
    layer = Canvas()
    for side, (fdx, flift) in zip((-1, 1), p["feet"]):
        if (flift >= 2) != front:
            continue
        x = (CX - 11 if side < 0 else CX + 4) + p["dx"] + fdx
        y = min(43, 43 - p["lift"] - flift)          # a planted foot never sinks below the ground
        layer.sphere(x, y, 7, 4, FEET)
    c.paste(layer.outline(OUTLINE))


def draw_body(c, p):
    x, y, w, h, cut = body_box(p)
    layer = Canvas().sphere(x, y, w, h, TONES, cut_bottom=cut)
    # a two-pixel gloss in the light band sells the "soft and shiny" read
    gx, gy = x + w // 4 + 1, y + 3
    layer.set(gx, gy, GLOSS).set(gx + 1, gy, GLOSS).set(gx, gy + 1, GLOSS)
    if p["lean"]:
        layer = layer.sheared(p["lean"], y, y + h - cut)
    c.paste(layer.outline(OUTLINE))


def arm_layer(side, p, angle):
    """One arm as a little capsule with a rounded mitten, shaded dark at its lower edge."""
    x, y, w, h, cut = body_box(p)
    sx = (x + 1.5) if side < 0 else (x + w - 1.5)          # shoulder just inside the body edge
    sy = y + h * 0.62
    if angle is None:                                    # resting nub hugging the body
        ex, ey = sx + side * 2.2, sy + 2.5
        r = 1.6
    else:
        a = math.radians(angle)
        L = p["arm_len"]
        ex, ey = sx + side * L * math.cos(a), sy - L * math.sin(a)
        r = 1.5
    layer = Canvas()
    layer.capsule(sx, sy, ex, ey, r, TONES[1])
    layer.disc(ex + 0.3, ey + 0.4, r + 0.4, TONES[1])
    layer.capsule(sx - 0.4, sy - 0.5, ex - 0.4, ey - 0.5, r - 0.5, TONES[2])
    layer.disc(ex - 0.2, ey - 0.2, r - 0.1, TONES[2])
    return layer.outline(OUTLINE)


EYE = {
    # left-eye patterns; '#' ink, 'w' highlight. (dx, dy) places the grid relative to the
    # eye's 2x3 slot. mirror=True flips the pattern for the right eye (shape-only patterns).
    "open":   ((0, 0), False, "w#\n##\n##"),
    "half":   ((0, 1), False, "##\n##"),
    "closed": ((0, 2), False, "##"),
    "down":   ((0, 1), False, "w#\n##\n##"),
    "happy":  ((-1, 1), True, ".##.\n#..#"),
    "squint": ((-1, 0), True, "##..\n..##\n##.."),
    "x":      ((-1, 0), True, "#.#\n.#.\n#.#"),
    "sad":    ((-1, 0), True, "#...\n.##.\n.##."),
}

MOUTH = {
    "smile": "#..#\n.##.",
    "open":  "####\n#tt#\n.##.",
    "o":     ".##.\n#..#\n.##.",
    "small": ".##.",
    "flat":  "####",
    "frown": ".##.\n#..#",
}


def draw_face(c, p):
    x, y, w, h, cut = body_box(p)
    ink = {"#": INK, "w": WHITE, "t": TONGUE}
    gap = max(3, round(w * 0.14))                     # half-distance between the eyes
    ey = y + round(h * 0.38)
    turn = p["dx"] + p["look"] + round(p["lean"] * 0.6)
    lx = CX - gap - 2 + turn                          # left eye slot's left column
    rx = CX + gap + turn                              # right eye slot (mirror of lx)
    (ox, oy), mirror, pat = EYE[p["eyes"]]
    pw = len(pat.split("\n")[0])
    c.grid(lx + ox, ey + oy, pat, ink)
    c.grid(rx + (1 - ox - (pw - 1) if mirror else ox), ey + oy, pat, ink, flip=mirror)
    if p["blush"]:
        for bx in (lx - 2, rx + 2):
            c.rect(bx, ey + 4, 2, 1, BLUSH)
    m = MOUTH[p["mouth"]]
    c.grid(CX - 2 + turn, ey + 4, m, ink)


def draw(p):
    c = Canvas()
    draw_feet(c, p, front=False)
    draw_body(c, p)
    draw_face(c, p)
    draw_feet(c, p, front=True)
    if p["laptop"] is not None:
        # arms reach down to the keyboard behind the lid; the paw that types dips 1 px
        # and a tiny key-tap flick appears beside it
        x, y, w, h, cut = body_box(p)
        lap = prop_laptop(p["laptop"], width=16)
        lx0, ly0 = CX - lap.w // 2, GROUND - lap.h + 1
        if p["glow"]:   # screen light spills onto the body just above the lid
            for yy in range(ly0 - 5, ly0 + 1):
                for xx in range(lx0 + 1, lx0 + lap.w - 1):
                    d = ((xx + 0.5 - CX) / 9.5) ** 2 + ((yy + 0.5 - ly0) / 5.0) ** 2
                    q = c.get(xx, yy)
                    if d <= 1 and q[3] and q not in (OUTLINE, INK, WHITE):
                        c.set(xx, yy, mix(q, SCREEN, 0.38 * p["glow"]))
        for side, down in zip((-1, 1), p["paws"]):
            sx = (x + 3.0) if side < 0 else (x + w - 3.0)
            sy = y + h * 0.6
            hx, hy = CX + side * (9.0 - down), 38.5 + down
            arm = Canvas()
            arm.capsule(sx, sy, hx, hy, 1.6, TONES[1])
            arm.disc(hx, hy, 2.0, TONES[1])
            arm.capsule(sx - 0.4, sy - 0.6, hx - 0.4, hy - 0.6, 1.0, TONES[2])
            arm.disc(hx - 0.4, hy - 0.4, 1.5, TONES[2])
            c.paste(arm.outline(OUTLINE))
        c.paste(lap, lx0, ly0)
        for side, down in zip((-1, 1), p["paws"]):
            if down:
                tx = CX + side * 12 - (1 if side < 0 else 0)
                c.set(tx, 35, TAP).set(tx + side, 34, TAP)
    else:
        for side, key in ((-1, "arm_l"), (1, "arm_r")):
            c.paste(arm_layer(side, p, p[key]))
    for spr, fx_x, fx_y in p["fx"]:
        c.paste(spr, fx_x, fx_y)
    return c


# ---------------------------------------------------------------- rows
def idle():
    return [draw(P(**kw)) for kw in (
        {},
        {"eyes": "half"},
        {"eyes": "closed"},
        {"bh": 32},                    # inhale: the top rises 1 px, feet stay planted
        {"bh": 32},
        {},
    )]


RUN = [  # 8-frame cycle (facing right): contact, down, passing, up, then the other foot
    # feet = ((dx, lift) left, (dx, lift) right); lift/bw/bh give the 2-px bob + squash
    dict(feet=((-3, 1), (3, 0)), lift=0, bw=31, bh=30, arm_l=-35, arm_r=-80, dust=0),
    dict(feet=((-3, 3), (1, 0)), lift=-1, bw=31, bh=30, arm_l=-45, arm_r=-70, dust=1),
    dict(feet=((0, 3), (-1, 0)), lift=0, arm_l=-60, arm_r=-55),
    dict(feet=((3, 2), (-3, 1)), lift=1, bw=29, bh=32, arm_l=-75, arm_r=-40),
    dict(feet=((3, 0), (-3, 1)), lift=0, bw=31, bh=30, arm_l=-80, arm_r=-35, dust=0),
    dict(feet=((1, 0), (-3, 3)), lift=-1, bw=31, bh=30, arm_l=-70, arm_r=-45, dust=1),
    dict(feet=((-1, 0), (0, 3)), lift=0, arm_l=-55, arm_r=-60),
    dict(feet=((-3, 1), (3, 2)), lift=1, bw=29, bh=32, arm_l=-40, arm_r=-75),
]
DUST = [sprite("""
    .aa.
    abba
    .aa.
    """, {"a": "#B4ABCF", "b": "#E2DDF0"}), sprite("""
    .a..a
    a....
    .a...
    """, {"a": "#C3BBDB"})]


def run(direction):
    """Drawn natively for each direction (look/lean/feet mirrored) so the light stays
    top-left. mirror_row(run_right) is the quick alternative if a rig can't do this."""
    sgn = 1 if direction == "right" else -1
    out = []
    for f in RUN:
        f = dict(f)
        dust = f.pop("dust", None)
        fl, fr = f.pop("feet")
        al, ar = f.pop("arm_l"), f.pop("arm_r")
        if sgn < 0:   # mirror the pose, not the pixels
            fl, fr = (-fr[0], fr[1]), (-fl[0], fl[1])
            al, ar = ar, al
        fx = []
        if dust is not None:
            spr = DUST[dust]
            fx.append((spr if sgn > 0 else spr.flipped(), (6 - 3 * dust) if sgn > 0 else (38 + 3 * dust), 42))
        out.append(draw(P(feet=(fl, fr), arm_l=al, arm_r=ar, look=2 * sgn, lean=2 * sgn,
                          mouth="small", arm_len=4, fx=fx, **f)))
    return out


def waving():
    return [draw(P(arm_r=a, arm_len=8, eyes="happy", mouth="open", look=-1))
            for a in (35, 65, 95, 65)]


def jumping():
    return [
        draw(P(bw=34, bh=26, eyes="squint", mouth="flat", arm_l=-65, arm_r=-65, arm_len=5)),      # anticipation
        draw(P(bw=27, bh=34, lift=7, eyes="open", mouth="o", arm_l=60, arm_r=60, feet=((2, -1), (-2, -1)))),  # rise
        draw(P(lift=11, eyes="happy", mouth="open", arm_l=80, arm_r=80, arm_len=8, feet=((1, 1), (-1, 1)))),  # peak
        draw(P(bw=28, bh=33, lift=5, eyes="open", mouth="o", arm_l=30, arm_r=30, feet=((1, -1), (-1, -1)))),   # fall
        draw(P(bw=34, bh=27, eyes="happy", mouth="smile", arm_l=-55, arm_r=-55, arm_len=5)),       # land
    ]


def failed():
    cross = fx_cross()
    sweat = fx_sweat()
    out = []
    for i, (dx, sq) in enumerate(((-1, 0), (1, 1), (-1, 2), (0, 2))):
        out.append(draw(P(dx=dx, bw=30 + sq, bh=31 - sq, eyes="x", mouth="frown", blush=False,
                          arm_l=-75, arm_r=-75, arm_len=5,
                          fx=[(cross, 32 + dx, 8 + (1 if i % 2 else 0))])))
    for i, sy in enumerate((0, 2, 4, 6)):
        out.append(draw(P(bw=33, bh=28, eyes="sad", mouth="frown", blush=False,
                          arm_l=-80, arm_r=-80, arm_len=5,
                          fx=[(sweat, 34, 15 + sy)])))
    return out


def waiting():
    big, small = fx_exclaim(), fx_exclaim(big=False)
    bx = CX - big.w // 2
    sx = CX - small.w // 2
    return [
        draw(P(eyes="open", mouth="o", fx=[(small, sx, 8)])),
        draw(P(bh=33, eyes="open", mouth="o", arm_l=20, arm_r=20, fx=[(big, bx, 1)])),
        draw(P(bw=31, bh=30, eyes="open", mouth="o", feet=((0, 0), (1, 2)), fx=[(big, bx, 2)])),
        draw(P(eyes="open", mouth="o", fx=[(big, bx, 3)])),
        draw(P(bw=31, bh=30, eyes="open", mouth="o", feet=((0, 0), (1, 2)), fx=[(big, bx, 2)])),
        draw(P(eyes="open", mouth="o", fx=[(big, bx, 2)])),
    ]


def working():
    out = []
    paws = ((1, 0), (0, 1), (1, 0), (0, 0), (0, 1), (1, 0))
    for i in range(6):
        dots = fx_dots(1 + (i // 2))
        out.append(draw(P(eyes="down", mouth="small", laptop=i, paws=paws[i],
                          glow=(0.8 if i % 3 else 1.0), fx=[(dots, 33, 4)])))
    return out


def review():
    bounce = (0, 1, 0, -1, 0, 0)                   # body height +/- (1 px stretch / squash)
    sparkles = [  # (x, y, size per frame or None)
        (6, 14, (0, 1, 2, 1, 0, None)),
        (37, 8, (None, 0, 1, 2, 1, 0)),
        (39, 26, (2, 1, 0, None, 0, 1)),
    ]
    out = []
    for i in range(6):
        fx = []
        for sx, sy, sizes in sparkles:
            s = sizes[i]
            if s is not None:
                spr = fx_sparkle(s)
                fx.append((spr, sx - spr.w // 2, sy - spr.h // 2))
        out.append(draw(P(bh=31 + bounce[i], eyes="happy", mouth="open",
                          arm_l=20 + 10 * (i % 2), arm_r=20 + 10 * ((i + 1) % 2), fx=fx)))
    return out


def frames():
    return {
        "idle": idle(),
        "running-right": run("right"),
        "running-left": run("left"),
        "waving": waving(),
        "jumping": jumping(),
        "failed": failed(),
        "waiting": waiting(),
        "running": working(),
        "review": review(),
    }
