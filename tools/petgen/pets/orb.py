"""Orb: a glossy near-black ball whose two slanted white capsule eyes sit up and
to the right, angled like highlights. No mouth, no limbs.

    python3 tools/petgen/petgen.py build orb

Rig: one flat black ellipse (optionally rotated), re-rendered per pose so squash,
stretch and lean stay clean, with a 1-px glint inside its top-left edge. A
1-px outline in a dark-grey family keeps it visible on dark desktops: lighter on the
top-left (a rim light), darker on the bottom-right. The ball rests on a flat two-tone
contact shadow on y=46-47. Expression lives only in the eyes (hand-drawn grids placed at
normalised spots on the ball, so they ride along with squash, roll and tilt) and in the
body. A speech bubble above-right carries the state, as on Pal.
"""
import math

from petgen import *

PET = {
    "id": "orb",
    "displayName": "Orb",
    "description": "A glossy little ball that keeps an eye on your threads.",
}

# ---------------------------------------------------------------- palette
BASE = rgba("#0B0B0D")
LT = rgba("#1C1C23")           # a 1-px glint along the top-left inside edge
TONES = [BASE, LT]
RIM_LT = rgba("#4A4A52")       # outline, lit side (top-left)
RIM = rgba("#33333A")          # outline, mid
RIM_DK = rgba("#2A2A30")       # outline, shaded side (bottom-right)
EYE = WHITE
SHADOW = [rgba("#BDBDC6"), rgba("#9C9CA7")]    # rim, core (opaque)
SPEED = rgba("#A6A6B0")
BUB_PAPER = WHITE
BUB_EDGE = rgba("#DADAE2")
BUB_LINE = rgba("#2E2E36")
DOTS = [rgba("#34C759"), rgba("#0A84FF"), rgba("#FF9F0A")]
GLOW = {t: mix(t, SCREEN, 0.22) for t in TONES}
TAP = mix(SCREEN, WHITE, 0.4)

BOTTOM = 45            # lowest body fill row at rest (outline on 46); shadow on 46-47

# ---------------------------------------------------------------- pose
REST = dict(
    dx=0, lift=0,             # whole-body offset (lift > 0 = up)
    bw=32, bh=32,             # body fill box
    rot=0,                    # degrees the whole ball (shape and eyes) turns, + = clockwise
    face=1,                   # 1 = faces right (as in the reference), -1 = faces left
    eyes="open",
    tilt=0,                   # degrees the eyes roll round the ball (+ = clockwise)
    look=(0, 0),              # extra eye offset in px
    eye_at=None,              # override normalised eye spots ((uL, vL), (uR, vR))
    laptop=None, tap=0,
    bubble=None, bub_dy=0,
    shadow=True,
    fx=(),
)


def P(**kw):
    p = dict(REST)
    p.update(kw)
    return p


# ---------------------------------------------------------------- body
def geom(p):
    w, h = p["bw"], p["bh"]
    rx, ry = w / 2.0, h / 2.0
    th = math.radians(p["rot"])
    bot = BOTTOM - p["lift"]
    ext = math.sqrt((rx * math.sin(th)) ** 2 + (ry * math.cos(th)) ** 2)
    return dict(w=w, h=h, rx=rx, ry=ry, th=th, bot=bot,
                cx=CX + p["dx"] + 0.0, cy=bot + 1 - ext)


def body_mask(g):
    """Pixel centres inside the (possibly rotated) ellipse, nudged so the lowest row
    sits exactly on g['bot']."""
    cs, sn = math.cos(g["th"]), math.sin(g["th"])
    pts = set()
    for y in range(H):
        for x in range(W):
            dx, dy = x + 0.5 - g["cx"], y + 0.5 - g["cy"]
            u = (dx * cs + dy * sn) / g["rx"]
            v = (-dx * sn + dy * cs) / g["ry"]
            if u * u + v * v <= 1.0:
                pts.add((x, y))
    low = max(y for _, y in pts)
    if low != g["bot"]:
        d = g["bot"] - low
        pts = {(x, y + d) for x, y in pts}
        g["cy"] += d
    return pts


def body_layer(p, g):
    """Flat glossy black, as in the reference, plus a 1-px glint just inside the
    top-left edge so the ball still reads as round."""
    mask = body_mask(g)
    c = Canvas()
    for x, y in mask:
        edge = any((x + a, y + b) not in mask for a, b in ((1, 0), (-1, 0), (0, 1), (0, -1)))
        nx = (x + 0.5 - g["cx"]) / g["rx"]
        ny = (y + 0.5 - g["cy"]) / g["ry"]
        lit = edge and (-0.6 * nx - 0.8 * ny) / (math.hypot(nx, ny) or 1.0) > 0.5
        c.set(x, y, LT if lit else BASE)
    return c


def rim_outline(layer, g):
    """1-px outline outside the silhouette, lit from the top-left."""
    ol = layer.outlined(RIM)
    for y in range(H):
        for x in range(W):
            if ol.opaque(x, y) and not layer.opaque(x, y):
                nx = (x + 0.5 - g["cx"]) / g["rx"]
                ny = (y + 0.5 - g["cy"]) / g["ry"]
                d = (-0.6 * nx - 0.8 * ny) / (math.hypot(nx, ny) or 1.0)
                ol.set(x, y, RIM_LT if d > 0.55 else (RIM_DK if d < -0.35 else RIM))
    return ol


# ---------------------------------------------------------------- eyes
# Grids are drawn for the right-facing pose (slant "\" like the reference) and flipped
# for left-facing. '#' white.
EYES = {
    "open": """
        ##..
        ###.
        ###.
        .###
        .###
        ..##
        """,
    "wide": """
        ##..
        ###.
        ####
        ####
        .###
        .###
        ..##
        """,
    "half": """
        .###
        .###
        ..##
        """,
    "closed": """
        ####
        """,
    "down": """
        ##.
        ###
        ###
        .##
        """,
    "happy": """
        .##.
        ####
        #..#
        """,
    "squint": """
        ##..
        ..##
        ##..
        """,
    "x": """
        #..#
        .##.
        .##.
        #..#
        """,
    "sad": """
        ..##
        .###
        ###.
        """,
}
# vertical anchor of each grid relative to the "open" grid's top (keeps blinks in place)
EYE_DY = {"open": 0, "wide": -1, "half": 3, "closed": 4, "down": 0, "happy": 1,
          "squint": 1, "x": 1, "sad": 2}
# which grids mirror on the right eye (so > < and sad droop face outward)
EYE_MIRROR_R = {"squint", "sad"}

SPOTS = ((0.21, -0.40), (0.62, -0.48))     # normalised (u, v) eye centres, from the reference


def rotate(x, y, th):
    return x * math.cos(th) - y * math.sin(th), x * math.sin(th) + y * math.cos(th)


def eye_spots(p, g):
    spots = p["eye_at"] or SPOTS
    out = []
    for u, v in spots:
        u, v = rotate(u * p["face"], v, math.radians(p["tilt"]))
        ox, oy = rotate(u * g["rx"], v * g["ry"], g["th"])
        out.append((g["cx"] + ox + p["look"][0], g["cy"] + oy + p["look"][1]))
    return out


def fits(body, x0, y0, pts):
    """Every eye pixel sits on the ball with at least 1 px of black around it."""
    return all(body.opaque(x0 + i + a, y0 + j + b)
               for i, j in pts for a in (-1, 0, 1) for b in (-1, 0, 1))


def draw_eyes(c, p, g, body):
    """Place both eyes; if one would touch the ball's edge, slide the pair inward
    together so the gap between them never closes."""
    name = p["eyes"]
    rows = [r.strip() for r in EYES[name].strip().splitlines()]
    gw = max(len(r) for r in rows)
    ref_h = len(EYES["open"].strip().splitlines())
    flip = p["face"] < 0
    placed = []
    for k, (ex, ey) in enumerate(eye_spots(p, g)):
        x0 = int(math.floor(ex - gw / 2.0 + 0.5))
        y0 = int(math.floor(ey - ref_h / 2.0 + 0.5)) + EYE_DY[name]
        f = flip != (k == 1 and name in EYE_MIRROR_R)
        pts = [((gw - 1 - i) if f else i, j) for j, r in enumerate(rows) for i, ch in enumerate(r) if ch == "#"]
        placed.append((x0, y0, f, pts))
    inward = -p["face"]
    shift = 0
    for step in range(4):
        if all(fits(body, x0 + inward * step, y0, pts) for x0, y0, _, pts in placed):
            shift = inward * step
            break
    for x0, y0, f, _ in placed:
        c.grid(x0 + shift, y0, EYES[name], {"#": EYE}, flip=f)


# ---------------------------------------------------------------- speech bubble
BUBBLE = """
    ..ppppppppppp..
    .ppppppppppppp.
    ppppppppppppppp
    ppppppppppppppp
    ppppppppppppppp
    .pppppppppppppe
    ..eeeeeeeeeeee.
    ...pe..........
    ..e............
    """
SMALL_BUBBLE = """
    ..ppppppp..
    .ppppppppp.
    ppppppppppp
    .pppppppppe
    ..eeeeeeee.
    ...pe......
    ..e........
    """


def bare(spr, color, hi):
    """A shared fx glyph without its outline, to sit on white paper."""
    g = spr.crop(1, 1, spr.w - 2, spr.h - 2)
    return g.replace(outline_of(color, 0.6), CLEAR).replace(tint(color, hi), color)


CHECK = bare(fx_check(), GREEN, 0.35)
CROSS = bare(fx_cross(), RED, 0.35)
BANG = sprite("""
    bb
    bb
    bb
    bc
    ..
    bc
    """, {"b": AMBER, "c": shade(AMBER, 0.22)})


def bubble(content):
    if content == "small":
        b = sprite(SMALL_BUBBLE, {"p": BUB_PAPER, "e": BUB_EDGE})
        b.rect(4, 1, 3, 2, AMBER)
        return Canvas(b.w + 2, b.h + 2).paste(b, 1, 1).outline(BUB_LINE)
    b = sprite(BUBBLE, {"p": BUB_PAPER, "e": BUB_EDGE})
    if content.startswith("dots"):
        for i in range(int(content[-1])):
            b.rect(2 + 4 * i, 2, 3, 3, DOTS[i])
    elif content == "bang":
        b.paste(BANG, 7, 0)
    elif content == "check":
        b.paste(CHECK, 4, 1)
    elif content == "cross":
        b.paste(CROSS, 5, 1)
    return Canvas(b.w + 2, b.h + 2).paste(b, 1, 1).outline(BUB_LINE)


BUB_X, BUB_Y = 30, 1


# ---------------------------------------------------------------- shadow, speed lines
def draw_shadow(c, p, g):
    if not p["shadow"]:
        return
    lift = max(0, p["lift"])
    w = int(g["w"] * 0.72) // 2 * 2 - 2 * int(round(lift / 3.0))
    w = max(8, w)
    x0 = int(round(g["cx"])) - w // 2
    c.hline(x0 + 1, x0 + w - 2, 46, SHADOW[0])
    c.hline(x0, x0 + w - 1, 47, SHADOW[0])
    c.hline(x0 + 3, x0 + w - 4, 46, SHADOW[1])
    c.hline(x0 + 2, x0 + w - 3, 47, SHADOW[1])


def speed_lines(i, sgn):
    def fn(c):
        for k, (yy, ln) in enumerate(((22, 4), (29, 5), (36, 3))):
            if (i + k) % 3 == 2:
                continue
            xs = [x for x in range(W) if c.opaque(x, yy)]
            if not xs:
                continue
            if sgn > 0:
                x1 = xs[0] - 2 - (i % 2)
                c.hline(max(1, x1 - ln + 1), x1, yy, SPEED)
            else:
                x0 = xs[-1] + 2 + (i % 2)
                c.hline(x0, min(W - 2, x0 + ln - 1), yy, SPEED)
    return fn


# ---------------------------------------------------------------- laptop
def draw_laptop(c, p, g):
    lap = prop_laptop(p["laptop"], width=16)
    lx0, ly0 = CX - lap.w // 2, GROUND - lap.h + 1
    for yy in range(ly0 - 5, ly0 + 1):
        for xx in range(lx0, lx0 + lap.w):
            d = ((xx + 0.5 - CX) / 9.0) ** 2 + ((yy + 0.5 - ly0 - 1) / 5.0) ** 2
            q = c.get(xx, yy)
            if d <= 1 and q in GLOW:
                c.set(xx, yy, GLOW[q])
    c.paste(lap, lx0, ly0)
    if p["tap"]:
        side = p["tap"]
        tx = CX + side * 11 - (1 if side < 0 else 0)
        c.set(tx, ly0 - 1, TAP).set(tx + side, ly0 - 2, TAP)


# ---------------------------------------------------------------- compose
def draw(p):
    c = Canvas()
    g = geom(p)
    draw_shadow(c, p, g)
    body = body_layer(p, g)
    c.paste(rim_outline(body, g))
    draw_eyes(c, p, g, body)
    if p["laptop"] is not None:
        draw_laptop(c, p, g)
    for item in p["fx"]:
        if callable(item):
            item(c)
        else:
            spr, fx_x, fx_y = item
            c.paste(spr, fx_x, fx_y)
    if p["bubble"]:
        spr = bubble(p["bubble"])
        c.paste(spr, BUB_X, BUB_Y + p["bub_dy"] + 11 - spr.h)
    return c


# ---------------------------------------------------------------- rows
def idle():
    return [draw(P(**kw)) for kw in (
        {},
        {"eyes": "half"},
        {"eyes": "closed"},
        {"bh": 33},
        {"bh": 33},
        {},
    )]


RUN = [  # a bouncing roll: squash on contact, stretch on the up
    dict(lift=0, bw=34, bh=30),
    dict(lift=-1, bw=34, bh=30),
    dict(lift=1),
    dict(lift=3, bw=30, bh=34),
    dict(lift=0, bw=34, bh=30),
    dict(lift=-1, bw=34, bh=30),
    dict(lift=1),
    dict(lift=3, bw=30, bh=34),
]


def run(direction):
    sgn = 1 if direction == "right" else -1
    return [draw(P(face=sgn, rot=r * sgn, look=(sgn, 0), fx=[speed_lines(i, sgn)], **f))
            for i, (f, r) in enumerate(zip(RUN, (8, 10, 8, 12, 8, 10, 8, 12)))]


def waving():
    # a cheerful side-to-side wiggle: the ball rocks right, stretches up as it passes
    # upright, rocks left (held), then settles; the eyes roll round with it
    return [draw(P(eyes="happy", **kw)) for kw in (
        dict(),                                   # same footprint as idle
        dict(rot=18, tilt=10, bw=34, bh=30),
        dict(bw=30, bh=34),
        dict(rot=-18, tilt=-10, bw=34, bh=30),
    )]


def jumping():
    return [
        draw(P(bw=36, bh=27, eyes="squint")),
        draw(P(bw=28, bh=36, lift=7)),
        draw(P(lift=11, eyes="happy")),
        draw(P(bw=30, bh=34, lift=5)),
        draw(P(bw=36, bh=28, eyes="happy")),
    ]


def failed():
    sweat = fx_sweat()
    out = []
    for i, (dx, bw, bh) in enumerate(((-1, 32, 32), (1, 32, 31), (-1, 34, 31), (0, 34, 30))):
        out.append(draw(P(dx=dx, bw=bw, bh=bh, eyes="x", bubble="cross", bub_dy=i % 2)))
    for i in range(4):
        out.append(draw(P(bw=36, bh=29, eyes="sad", look=(0, 2), bubble="cross", bub_dy=1,
                          fx=[(sweat.flipped(), 7, 19 + 2 * i)])))
    return out


def waiting():
    e = dict(eyes="wide")
    return [
        draw(P(bubble="small", bub_dy=1, **e)),
        draw(P(bh=33, bubble="bang", bub_dy=0, **e)),
        draw(P(rot=-6, bubble="bang", bub_dy=1, **e)),
        draw(P(bubble="bang", bub_dy=0, **e)),
        draw(P(rot=6, bubble="bang", bub_dy=1, **e)),
        draw(P(bubble="bang", bub_dy=0, **e)),
    ]


def working():
    reads = (-1, 0, 1, 1, 0, -1)
    taps = (-1, 0, 1, 0, -1, 1)
    spots = ((-0.16, -0.06), (0.24, -0.10))
    return [draw(P(eyes="down", eye_at=spots, look=(reads[i], 0), laptop=i, tap=taps[i],
                   bh=32 - (1 if taps[i] else 0), bubble=f"dots{1 + i // 2}"))
            for i in range(6)]


def review():
    bounce = (0, 1, 0, -1, 0, 0)
    tilt = (0, 8, 0, -8, 0, 0)
    sparkles = [
        (6, 17, (0, 1, 2, 1, 0, None)),
        (43, 38, (None, 0, 1, 1, 1, 0)),
        (6, 34, (2, 1, 0, None, 0, 1)),
    ]
    out = []
    for i in range(6):
        fx = []
        for sx, sy, sizes in sparkles:
            s = sizes[i]
            if s is not None:
                spr = fx_sparkle(s)
                fx.append((spr, sx - spr.w // 2, sy - spr.h // 2))
        out.append(draw(P(bh=32 + bounce[i], tilt=tilt[i], eyes="happy", bubble="check", fx=fx)))
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
