"""Clawd: Claude Code's terracotta crab, as a Sidekick pet.

    python3 tools/petgen/petgen.py build clawd

A blocky homage drawn from scratch: a wide flat slab of a body (12 x 8 units), two tall
slot eyes in the upper third, a square nub arm on each side just below the middle, and
four stub legs in two pairs. It stays flat and boxy like the start-up mascot, so the
personality lives in the motion: the nubs pop up, the legs patter, the slab squashes.

Rig: the slab, resting nubs and legs are painted onto one layer and outlined once, so
the shape stays seamless like the original. Arms are small unions of rectangles (named
poses below), never rotated bitmaps, so every pose keeps the same square-cut look; the
waving forearm and the typing forearms sit in front of the slab with their own outline,
so they read as limbs without breaking the box silhouette. The face is painted onto the
slab before the outline. The laptop is the shared prop_laptop, recoloured dark (Clawd's
brief asks for a tiny dark laptop).
"""
from petgen import *

PET = {
    "id": "clawd",
    "displayName": "Clawd",
    "description": "Claude Code's crab, keeping an eye on your threads.",
}

# ---------------------------------------------------------------- palette
BODY = rgba("#D97757")
SHADE = rgba("#BE684D")
MID = mix(BODY, SHADE, 0.5)          # lower band between body and shade
TOP = rgba("#E39272")                # slightly lighter top band
GLINT = tint(BODY, 0.45)             # a small glint in the top-left corner
DEEP = rgba("#A5553F")               # underside of the legs, seams
OUTLINE = rgba("#4E1D14")            # deep warm brown, never black
EYE = rgba("#141413")
BLUSH = rgba("#EE8C7E")
TAP = mix(SCREEN, WHITE, 0.4)
GLOW = mix(tint(BODY, 0.3), SCREEN, 0.15)   # screen light on the slab above the lid
DUST_A, DUST_B, DUST_C = rgba("#B9A79C"), rgba("#E9DFD8"), rgba("#D4C6BD")

# ---------------------------------------------------------------- pose
REST = dict(
    dx=0, lift=0,          # whole-body offset; lift > 0 = up
    bw=32, bh=22,          # body fill box (width even, centred on CX)
    leg=5,                 # leg length at rest (fill rows under the body)
    legs=((0, 0),) * 4,    # (dx, lift) per leg, left to right
    eyes="open", look=0, blush=False,
    lean=0,                # px the slab above the eye line shifts into a run
    arm_l="rest", arm_r="rest",
    wave=None,             # (hand step-out, hand top rel. to body top) for the raised arm
    laptop=None, paws=(0, 0),
    fx=(),
)


def P(**kw):
    p = dict(REST)
    p.update(kw)
    return p


# ---------------------------------------------------------------- geometry
def geom(p):
    bw, bh = p["bw"], p["bh"]
    bottom = 46 - p["leg"] - p["lift"]          # last body fill row
    top = bottom - bh + 1
    bx0 = CX - bw // 2 + p["dx"]
    bx1 = bx0 + bw - 1
    return bx0, bx1, top, bottom


def leg_xs(p):
    bx0, bx1, _, _ = geom(p)
    return [bx0 + 2, bx0 + 8, bx1 - 10, bx1 - 4]


def arm_row(p):
    _, _, top, _ = geom(p)
    return top + round(p["bh"] * 0.55)


# Right-arm poses as rects (x, y, w, h). x is relative to the first column outside the
# body; y is relative to the resting arm row. The left arm is the mirror image.
ARMS = {
    "rest":   [(0, 0, 5, 5)],
    "hi":     [(0, -1, 5, 5)],              # run swing
    "lo":     [(0, 1, 5, 5)],
    "perk":   [(0, -4, 5, 5)],              # surprised: nub pops up the side
    "perk2":  [(0, -8, 5, 5)],              # cheering: nubs flung up high
    "droop":  [(0, 2, 4, 5)],
}


def rect_pts(x, y, w, h):
    return {(xx, yy) for yy in range(y, y + h) for xx in range(x, x + w)}


def arm_pixels(p, side, pose):
    bx0, bx1, top, bottom = geom(p)
    oy = arm_row(p)
    pts = set()
    for (x, y, w, h) in ARMS[pose]:
        pts |= rect_pts(bx1 + 1 + x, oy + y, w, h)
    if side < 0:
        pts = {(bx0 + bx1 - x, y) for x, y in pts}
    return pts


def wave_pixels(p):
    """The raised right forearm: a 4-wide bar standing on the right nub (the elbow, out
    to the side like a "hi"), in front of the slab's right edge (2 px over it, 2 px proud
    of it) and up past the top. Above the slab the hand steps sideways by t px, the bar
    below leaning half as far, so the arm swings from the elbow and reads as a wave
    rather than an ear on the corner."""
    bx0, bx1, top, bottom = geom(p)
    t, ht = p["wave"]
    x0 = bx1 - 1
    elbow = arm_row(p) + ARMS[p["arm_r"]][0][1]
    mid = (top + elbow) // 2
    pts = rect_pts(x0, mid, 4, elbow - mid + 1)
    pts |= rect_pts(x0 + max(t, 0) // 2, top + 2, 4, mid - top - 2)
    pts |= rect_pts(x0 + t, top + ht, 4, 2 - ht)
    return pts


# ---------------------------------------------------------------- parts
def slab(p):
    """The body slab alone, painted in flat toon bands: lit top, base, a mid band low
    down, the underside in shade, a shaded right edge and a small top-left glint."""
    bx0, bx1, top, bottom = geom(p)
    c = Canvas()
    c.rect(bx0, top, bx1 - bx0 + 1, bottom - top + 1, BODY)
    c.rect(bx0, top, bx1 - bx0 + 1, 2, TOP)
    c.rect(bx0, bottom - 6, bx1 - bx0 + 1, 5, MID)           # lower half turns away
    c.rect(bx1, top + 2, 1, bottom - top - 3, SHADE)
    c.rect(bx0, bottom - 1, bx1 - bx0 + 1, 2, SHADE)
    c.rect(bx0 + 2, top + 1, 3, 1, GLINT).set(bx0 + 1, top + 1, GLINT)
    return c


def figure(p):
    """Legs + nubs + slab (with the face), painted, un-outlined. The slab leans on its
    own so the nubs and legs never get sliced by the lean step."""
    bx0, bx1, top, bottom = geom(p)
    c = Canvas()
    for x, (ldx, llift) in zip(leg_xs(p), p["legs"]):
        foot = min(46 - llift, bottom + p["leg"] + 1 - llift)
        foot = max(foot, bottom + 2)
        x += ldx
        c.rect(x, bottom + 1, 3, foot - bottom, SHADE)
        c.vline(x + 2, bottom + 1, foot, DEEP)
    for side, key in ((-1, "arm_l"), (1, "arm_r")):
        if p[key] is not None:
            c.paste(shaded(arm_pixels(p, side, p[key])))
    body = slab(p)
    draw_face(body, p)
    c.paste(leaned(body, p))
    return c


EYES = {
    # left-eye patterns: (dx, dy) from the 3x6 eye slot, then the grid; the right eye
    # is the mirror image
    "open":   (0, 0, "###\n###\n###\n###\n###\n###"),
    "wide":   (0, -1, "###\n###\n###\n###\n###\n###\n###"),
    "half":   (0, 3, "###\n###\n###"),
    "closed": (0, 4, "###\n###"),
    "down":   (0, 2, "###\n###\n###\n###"),
    "happy":  (-1, 3, "#####\n#...#"),
    "joy":    (-1, 2, ".###.\n#####\n#...#"),
    "squint": (-1, 1, "##...\n.###.\n...##\n.###.\n##..."),
    "x":      (-1, 1, "##.##\n.###.\n..#..\n.###.\n##.##"),
    "sad":    (-1, 0, "...##\n.##..\n.....\n..##.\n.###.\n.###."),   # worried brow, droop
}


def draw_face(c, p):
    bx0, bx1, top, bottom = geom(p)
    ey = top + round(p["bh"] * 0.27)
    ox, oy, pat = EYES[p["eyes"]]
    pw = len(pat.split("\n")[0])
    lx = bx0 + 5 + p["look"]
    rx = bx1 - 7 + p["look"]
    ink = {"#": EYE}
    c.grid(lx + ox, ey + oy, pat, ink)
    c.grid(rx + (3 - pw - ox), ey + oy, pat, ink, flip=True)
    if p["blush"]:
        c.rect(lx - 2, ey + 7, 3, 1, BLUSH)
        c.rect(rx + 2, ey + 7, 3, 1, BLUSH)


DUST = [
    sprite("""
        .aa..
        abbaa
        acbba
        .aaa.
        """, {"a": DUST_A, "b": DUST_B, "c": DUST_C}),
    sprite("""
        .a...
        aba.a
        .a...
        ...a.
        """, {"a": DUST_A, "b": DUST_B}),
]


def shaded(pts):
    """Paint a set of limb pixels: lit top row, shaded bottom row."""
    c = Canvas()
    for (x, y) in pts:
        if (x, y - 1) not in pts:
            c.set(x, y, TOP)
        elif (x, y + 1) not in pts:
            c.set(x, y, SHADE)
        else:
            c.set(x, y, BODY)
    return c


def front_limb(pts):
    """A limb held in front of the slab, outlined: lit top and left edges, shaded bottom
    and right edges, so it separates from the same-coloured body behind it."""
    c = Canvas()
    for (x, y) in pts:
        if (x, y - 1) not in pts or ((x - 1, y) not in pts and (x, y + 1) in pts):
            col = TOP
        elif (x, y + 1) not in pts or (x + 1, y) not in pts:
            col = SHADE
        else:
            col = BODY
        c.set(x, y, col)
    return c.outline(OUTLINE)


def leaned(layer, p):
    """Shift the slab above the eye line sideways by p['lean'] (a hard 1-px step that
    sits by the nubs), so a run leans into its direction without slicing the eyes."""
    if not p["lean"]:
        return layer
    out = Canvas()
    _, _, top, _ = geom(p)
    split = top + round(p["bh"] * 0.27) + 6     # just below the eyes
    for y in range(H):
        s = p["lean"] if y < split else 0
        for x in range(W):
            q = layer.get(x, y)
            if q[3]:
                out.set(x + s, y, q)
    return out


def draw(p):
    c = Canvas()
    c.paste(figure(p).outline(OUTLINE))
    if p["wave"] is not None:
        c.paste(front_limb(wave_pixels(p)))
    if p["laptop"] is not None:
        draw_laptop(c, p)
    for spr, x, y in p["fx"]:
        c.paste(spr, x, y)
    return c


DARK_LAPTOP = {  # prop_laptop's greys -> charcoal; the logo keeps its screen glow. The
    # lid's top edge, lit left edge and the outline stay light enough to hold on #1e1e1e.
    "#dce2ee": "#AEB4C2", "#b3bbcb": "#6C7181", "#9aa2b5": "#474B59", "#7d8599": "#343744",
    "#5a6072": "#2C2E39", "#a9b1c2": "#6A6E7C", "#8890a3": "#545866", "#6e7588": "#383B47",
    "#292a45": "#3A3946",
}


def draw_laptop(c, p):
    bx0, bx1, top, bottom = geom(p)
    lap = prop_laptop(p["laptop"], width=18).recolor(DARK_LAPTOP)
    lx0, ly0 = CX - lap.w // 2, GROUND - lap.h + 1
    # short forearms come off the front of the slab and go down behind the lid to the
    # keys, so the silhouette stays a box; the typing paw dips a pixel
    for side, down in zip((-1, 1), p["paws"]):
        pts = rect_pts(lx0 + 5, ly0 - 5 + down, 4, 8)
        if side > 0:
            pts = {(bx0 + bx1 - x, y) for x, y in pts}
        c.paste(front_limb(pts))
    # screen light spills on the slab and the forearms just above the lid
    for yy in range(ly0 - 2, ly0 + 1):
        for xx in range(lx0 + 2, lx0 + lap.w - 2):
            q = c.get(xx, yy)
            if q in (BODY, TOP, MID, SHADE):
                c.set(xx, yy, GLOW)
    c.paste(lap, lx0, ly0)
    # a key-tap flick pops off the lid's top corner on the typing side
    for side, down in zip((-1, 1), p["paws"]):
        if down:
            tx = lx0 + 1 if side < 0 else lx0 + lap.w - 2
            c.set(tx, ly0 - 1, TAP).set(tx + side, ly0 - 2, TAP)


# ---------------------------------------------------------------- rows
def idle():
    return [draw(P(**kw)) for kw in (
        {},
        {"eyes": "half"},
        {"eyes": "closed"},
        {"bh": 23},                    # inhale: the top rises 1 px, feet stay planted
        {"bh": 23},
        {},
    )]


A, B = (0, 2), (1, 3)                  # alternating leg pairs
LEAN = 1
RUN = [  # facing right: contact, down, passing, up, then the other pair
    dict(lift=0, bh=21, a=(1, 0), b=(-1, 1), arms=("lo", "hi"), dust=0),
    dict(lift=-1, bh=21, a=(0, 0), b=(-1, 2), arms=("lo", "hi"), dust=1),
    dict(lift=0, bh=22, a=(0, 0), b=(0, 2), arms=("rest", "rest")),
    dict(lift=1, bh=23, a=(-1, 0), b=(1, 1), arms=("hi", "lo")),
    dict(lift=0, bh=21, a=(-1, 1), b=(1, 0), arms=("hi", "lo"), dust=0),
    dict(lift=-1, bh=21, a=(-1, 2), b=(0, 0), arms=("hi", "lo"), dust=1),
    dict(lift=0, bh=22, a=(0, 2), b=(0, 0), arms=("rest", "rest")),
    dict(lift=1, bh=23, a=(1, 1), b=(-1, 0), arms=("lo", "hi")),
]


def run(direction):
    """Drawn natively per direction (legs, arms and look mirrored) so the light stays
    top-left."""
    sgn = 1 if direction == "right" else -1
    out = []
    for f in RUN:
        legs = [None] * 4
        for idx in A:
            legs[idx] = f["a"]
        for idx in B:
            legs[idx] = f["b"]
        al, ar = f["arms"]
        if sgn < 0:
            legs = [(-dx, lf) for dx, lf in reversed(legs)]
            al, ar = ar, al
        fx = []
        if "dust" in f:
            spr = DUST[f["dust"]]
            if sgn > 0:
                fx.append((spr, 4 - 2 * f["dust"], 42 - f["dust"]))
            else:
                fx.append((spr.flipped(), 40 + 2 * f["dust"], 42 - f["dust"]))
        out.append(draw(P(lift=f["lift"], bh=f["bh"], legs=tuple(legs), arm_l=al, arm_r=ar,
                          look=2 * sgn, lean=LEAN * sgn, fx=fx)))
    return out


WAVE = ((2, -5), (1, -6), (-1, -7), (1, -6))     # hand step-out and height: 35, 65, 95, 65 deg


def waving():
    return [draw(P(wave=w, arm_r="perk", eyes="joy", blush=True)) for w in WAVE]


def jumping():
    return [
        draw(P(bw=34, bh=18, leg=4, eyes="squint", arm_l="droop", arm_r="droop")),
        draw(P(bw=30, bh=24, lift=7, eyes="open", arm_l="perk", arm_r="perk")),
        draw(P(lift=11, eyes="joy", arm_l="perk2", arm_r="perk2")),
        draw(P(bw=30, bh=23, lift=5, eyes="open", arm_l="perk", arm_r="perk")),
        draw(P(bw=34, bh=19, leg=4, eyes="happy", arm_l="rest", arm_r="rest")),
    ]


def failed():
    cross = fx_cross()
    sweat = fx_sweat()
    out = []
    for i, (dx, sq) in enumerate(((-1, 0), (1, 1), (-1, 1), (0, 2))):
        out.append(draw(P(dx=dx, bh=22 - sq, bw=32 + (2 if sq > 1 else 0), eyes="x",
                          fx=[(cross, 38 + dx, 9 + (1 if i % 2 else 0) + sq)])))
    for i, sy in enumerate((0, 2, 4, 6)):
        out.append(draw(P(bw=34, bh=19, eyes="sad", arm_l="droop", arm_r="droop",
                          fx=[(sweat, 39, 18 + sy)])))
    return out


def waiting():
    big, small = fx_exclaim(), fx_exclaim(big=False)
    bx = CX - big.w // 2
    sx = CX - small.w // 2
    tap = ((0, 0), (0, 0), (0, 0), (0, 2))
    return [
        draw(P(eyes="wide", fx=[(small, sx, 10)])),
        draw(P(bh=23, eyes="wide", arm_l="perk", arm_r="perk", fx=[(big, bx, 4)])),
        draw(P(eyes="wide", legs=tap, fx=[(big, bx, 6)])),
        draw(P(eyes="wide", fx=[(big, bx, 7)])),
        draw(P(eyes="wide", legs=tap, fx=[(big, bx, 6)])),
        draw(P(eyes="wide", fx=[(big, bx, 7)])),
    ]


def working():
    out = []
    paws = ((1, 0), (0, 1), (1, 0), (0, 0), (0, 1), (1, 0))
    for i in range(6):
        dots = fx_dots(1 + (i // 2))
        out.append(draw(P(eyes="down", arm_l=None, arm_r=None, laptop=i, paws=paws[i],
                          fx=[(dots, 33, 4)])))
    return out


def review():
    # a 1-px hop on f1 and f4 with a 1-px landing squash on f2; the nubs pump 8 px,
    # alternating between rest and flung up high
    hop = (0, 1, 0, 0, 1, 0)
    bounce = (0, 0, -1, 0, 0, 0)
    arms = (("perk2", "rest"), ("rest", "perk2")) * 3
    sparkles = [  # (centre x, centre y, size per frame or None)
        (6, 11, (0, 1, 2, 1, 0, None)),
        (41, 9, (None, 0, 1, 2, 1, 0)),
        (17, 6, (2, 1, 0, None, 0, 1)),
    ]
    out = []
    for i in range(6):
        fx = []
        for sx, sy, sizes in sparkles:
            s = sizes[i]
            if s is not None:
                spr = fx_sparkle(s)
                fx.append((spr, sx - spr.w // 2, sy - spr.h // 2))
        al, ar = arms[i]
        out.append(draw(P(lift=hop[i], bh=22 + bounce[i], eyes="happy", blush=True,
                          arm_l=al, arm_r=ar, fx=fx)))
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
