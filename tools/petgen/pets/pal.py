"""Pal: Sidekick's own mascot as a soft, floating jelly spirit.

    python3 tools/petgen/petgen.py build pal

Rig: the logo's tab body (straight sides, wide rounded top whose corners follow the logo's
quadratic-Bezier curve) with a softly rounded bottom, drawn per pose so squash and stretch
re-render clean pixels. Pal never touches the ground: it hovers 2-3 px over a flat
two-tone shadow on y=46-47, which carries the ground contact. No mouth; the face is the
logo's two navy oval eyes with their highlight top-right, and expression lives in them.
Arms are tapered jelly pseudopods that grow out of the body only when a row needs them:
one outline around the union, plus an interior line where a hand crosses the body. The logo's speech bubble floats above-right and carries the state:
amber '!' (waiting), the logo's green/blue/amber dots (working), green check (review) and
red x (failed). Row notes:
  idle      blink, then a 1-px float up and back; nothing else moves
  runs      re-rendered per direction (light stays top-left): a gliding jelly bounce,
            top leaning into the drag, the base swept back like a spirit's tail
  waving    a pseudopod rises from the right side to an elbow clear of the head; the
            forearm arcs 30-85 degrees about it
  jumping   deep squash, stretched launch, happy peak with stubby arms up, jelly landing
  failed    x eyes and a shudder while the hover sags; then a deflated slump onto the
            shadow, sad eyes, sweat drop; the bubble shows the red x throughout
  waiting   the bubble pops in, then the big amber '!' with wide eyes; Pal sways
  running   hovering behind the laptop, eyes down, two arms reaching to the lid's edge,
            screen light on the body, the bubble's dots fill in green, blue, amber
  review    happy eyes, blush, arms out alternating, sparkles, green check bubble
"""
import math

from petgen import *

PET = {
    "id": "pal",
    "displayName": "Pal",
    "description": "Sidekick's own Pal, floating by, its speech bubble showing what's up.",
}

# ---------------------------------------------------------------- palette
HI = rgba("#FFFFFF")
BASE = rgba("#F4F4FF")
MID = rgba("#E1E3FE")
SH = rgba("#C9CCF6")
TONES = [SH, MID, BASE, HI]                    # dark -> light
OUTLINE = rgba("#2E2F8F")
EYE = rgba("#1E1F5C")
BLUSH = rgba("#FFAFCB")
SHADOW = [rgba("#B5B7E7"), rgba("#9093D3")]    # rim, core (opaque)
SPEED = rgba("#9EA1E2")
BUB_PAPER = WHITE
BUB_EDGE = rgba("#D7D9F8")
DOTS = [rgba("#34C759"), rgba("#0A84FF"), rgba("#FF9F0A")]   # the logo's status dots
GLOW = {t: mix(t, SCREEN, 0.32) for t in TONES}
DIM = {t: mix(t, "#B4B5D2", 0.28) for t in TONES}            # failed: the glow fades
TAP = mix(SCREEN, WHITE, 0.4)

# ---------------------------------------------------------------- knobs
BOTTOM = 42            # lowest body fill row at rest (outline on 43); shadow on 46-47
RT = 0.40              # top corner radius / width (logo: 170 / 424)
RB = 0.26              # bottom corner radius / width
SAG = 1.6              # px the bottom edge bulges down in the middle (a soft jelly base)
EYE_GAP = 0.175        # eye centre offset from the centre line / width (logo: 74 / 424)
EYE_Y = 0.35           # eye centre below the top / height

# ---------------------------------------------------------------- pose
REST = dict(
    dx=0, lift=0,             # whole-body offset (lift > 0 = up)
    bw=26, bh=30,             # body fill box
    lean=0, trail=0,          # px the top leans forward / the bottom trails back (runs)
    eyes="open", look=0, lookv=0, blush=False,
    arm_l=None, arm_r=None,   # pseudopods: None = none, else (angle deg, length)
    elbow=None,               # waving: (deg, px) upper segment of the right arm
    arm_at=0.55,              # arm root height down the body (0 top .. 1 bottom)
    laptop=None, paws=(0, 0),
    tone=None,                # None | "dim"
    bubble=None, bub_dy=0,    # bubble content and vertical offset
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
    bot = BOTTOM - p["lift"]
    top = bot - h + 1
    return dict(w=w, h=h, top=top, bot=bot, cx=CX + p["dx"],
                rt=min(w / 2.0, RT * w), rb=min(w / 2.0, RB * w))


def corner(r, s):
    """The logo's corner: a quadratic Bezier, i.e. sqrt(x) + sqrt(y) = sqrt(r). Returns
    how far the edge drops from the top (or rises from the bottom) at distance s in from
    the side."""
    if r <= 0 or s >= r:
        return 0.0
    return r * (1 - math.sqrt(max(0.0, s) / r)) ** 2


def column_span(g, x):
    """(top edge, bottom edge) of column x in edge coordinates, or None."""
    half = g["w"] / 2.0
    s = half - abs(x + 0.5 - g["cx"])
    if s <= 0:
        return None
    t = g["top"] + corner(g["rt"], s)
    b = g["bot"] + 1 - corner(g["rb"], s) - SAG * (1 - s / half) ** 2
    return t, b


def shift_at(p, g, y):
    """Row offset for lean (top forward) and trail (bottom back)."""
    if not p["lean"] and not p["trail"]:
        return 0
    t = min(1.0, max(0.0, (g["bot"] - y) / max(1, g["bot"] - g["top"])))
    return int(round(p["lean"] * t - p["trail"] * (1 - t) ** 3))


def body_mask(g):
    mask = set()
    for x in range(int(g["cx"] - g["w"] / 2) - 1, int(g["cx"] + g["w"] / 2) + 2):
        span = column_span(g, x)
        if not span:
            continue
        for y in range(int(span[0]) - 1, int(span[1]) + 2):
            if span[0] <= y + 0.5 <= span[1]:
                mask.add((x, y))
    return mask


def body_layer(p, g):
    ln = math.sqrt(sum(v * v for v in LIGHT))
    lx, ly, lz = (v / ln for v in LIGHT)
    mask = body_mask(g)
    cols, rows = {}, {}
    for x, y in mask:
        lo, hi = cols.get(x, (y, y))
        cols[x] = (min(lo, y), max(hi, y))
        lo, hi = rows.get(y, (x, x))
        rows[y] = (min(lo, x), max(hi, x))
    c = Canvas()
    for x, y in mask:
        lo, hi = rows[y]
        u = (x + 0.5 - (lo + hi + 1) / 2.0) / ((hi + 1 - lo) / 2.0)
        lo, hi = cols[x]
        v = (y + 0.5 - (lo + hi + 1) / 2.0) / ((hi + 1 - lo) / 2.0)
        nx = math.copysign(abs(u) ** 3, u)
        ny = math.copysign(abs(v) ** 3, v)
        nn = nx * nx + ny * ny
        if nn > 0.92:
            k = math.sqrt(0.92 / nn)
            nx, ny, nn = nx * k, ny * k, 0.92
        nz = math.sqrt(1 - nn)
        d = nx * lx + ny * ly + nz * lz
        idx = sum(1 for t in (0.22, 0.52, 0.84) if d > t)
        c.set(x + shift_at(p, g, y), y, TONES[idx])
    return c


def limb(path, r0=2.0, r1=1.3, rh=2.1):
    """A tapered jelly arm along a polyline: thick at the root (r0), thin at the wrist (r1),
    ending in a round mitt (rh). Unoutlined; lit from the top-left."""
    pts = []
    segs = list(zip(path, path[1:]))
    total = sum(math.hypot(x1 - x0, y1 - y0) for (x0, y0), (x1, y1) in segs) or 1.0
    run = 0.0
    for (x0, y0), (x1, y1) in segs:
        L = math.hypot(x1 - x0, y1 - y0)
        n = max(1, int(L * 3))
        for i in range(n + 1):
            t = i / n
            pts.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, r0 + (r1 - r0) * (run + L * t) / total))
        run += L
    ex, ey = path[-1]
    a = Canvas()
    for x, y, r in pts:
        a.disc(x, y, r, MID)
    a.disc(ex + 0.2, ey + 0.2, rh, MID)
    for x, y, r in pts:
        a.disc(x - 0.4, y - 0.5, r - 0.6, BASE)
    a.disc(ex - 0.4, ey - 0.5, rh - 0.6, BASE)
    a.set(int(ex - 1.2), int(ey - 1.2), HI)
    return a


def attach_arms(body, arms):
    """Paste jelly arms onto the (unoutlined) body and return the outlined result. The
    union gets one silhouette outline; where an arm crosses the body it also gets its own
    interior line, except within `seam` px of its root, so it grows out of the body
    without a seam."""
    out = body.copy()
    for arm, _, _ in arms:
        out.under(arm)
    out.outline(OUTLINE)
    for arm, (rx, ry), seam in arms:
        ol = arm.outlined(OUTLINE)
        for y in range(H):
            for x in range(W):
                if arm.opaque(x, y):
                    out.set(x, y, arm.get(x, y))
                elif ol.opaque(x, y) and body.opaque(x, y) and math.hypot(x + 0.5 - rx, y + 0.5 - ry) > seam:
                    out.set(x, y, OUTLINE)
    return out


def arm_path(p, g, side, spec, elbow=None, at=0.55):
    """Root on the body's side at height `at`, then an optional upper segment (elbow),
    then the forearm at spec = (angle deg, length); 0 = straight out, 90 = up."""
    ay = g["top"] + g["h"] * at
    root = (g["cx"] + side * (g["w"] / 2.0 - 2.5) + shift_at(p, g, int(ay)), ay)
    path = [root]
    x0, y0 = root
    if elbow:
        ea, el = elbow
        a = math.radians(ea)
        x0, y0 = x0 + side * el * math.cos(a), y0 - el * math.sin(a)
        path.append((x0, y0))
    ang, ln = spec
    a = math.radians(ang)
    path.append((x0 + side * ln * math.cos(a), y0 - ln * math.sin(a)))
    return path


# ---------------------------------------------------------------- face
EYES = {
    # (dx, dy, mirror, grid) relative to a 4x6 eye slot; '#' navy, 'w' highlight.
    # The highlight sits top-right on both eyes, as in the logo.
    "open":   (0, 0, False, ".##.\n##w#\n####\n####\n####\n.##."),
    "wide":   (0, -1, False, ".##.\n#ww#\n#ww#\n####\n####\n####\n.##."),
    "half":   (0, 3, False, "####\n####\n.##."),
    "closed": (0, 4, False, "####"),
    "down":   (0, 2, False, "####\n####\n####\n.##."),
    "happy":  (0, 1, False, ".##.\n#..#\n#..#"),
    "squint": (0, 1, True, "##..\n..##\n##.."),
    "x":      (0, 1, True, "#..#\n.##.\n.##.\n#..#"),
    "sad":    (0, 3, True, "..##\n####\n.##."),
}


def eye_slots(p, g):
    gap = int(EYE_GAP * g["w"] + 0.5)
    ey = g["top"] + int(EYE_Y * g["h"] + 0.5) - 3 + p["lookv"]
    turn = p["look"] + shift_at(p, g, ey + 3)
    lx = int(round(g["cx"])) - gap - 2 + turn
    rx = int(round(g["cx"])) + gap - 2 + turn
    return lx, rx, ey


def draw_face(c, p, g):
    lx, rx, ey = eye_slots(p, g)
    dx, dy, mirror, pat = EYES[p["eyes"]]
    pal = {"#": EYE, "w": WHITE}
    c.grid(lx + dx, ey + dy, pat, pal)
    c.grid(rx + dx, ey + dy, pat, pal, flip=mirror)
    if p["blush"]:
        c.rect(lx - 2, ey + 6, 3, 1, BLUSH)
        c.rect(rx + 3, ey + 6, 3, 1, BLUSH)


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
    """A shared fx glyph without its outline, to sit on the bubble's white paper. Its pale
    highlight column would vanish on white, so it takes the base colour."""
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
    """The logo's speech bubble (15x7 paper + tail, 17x11 outlined). content: 'dots1'..
    'dots3', 'bang', 'check', 'cross' or 'empty'."""
    if content == "small":
        b = sprite(SMALL_BUBBLE, {"p": BUB_PAPER, "e": BUB_EDGE})
        b.rect(4, 1, 3, 2, AMBER)
        o = Canvas(b.w + 2, b.h + 2).paste(b, 1, 1).outline(OUTLINE)
        return o
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
    return Canvas(b.w + 2, b.h + 2).paste(b, 1, 1).outline(OUTLINE)


BUB_X, BUB_Y = 30, 1


# ---------------------------------------------------------------- shadow, speed lines
def draw_shadow(c, p):
    if not p["shadow"]:
        return
    lift = p["lift"]
    w = 20 - 2 * int(round(max(0, lift) / 3.0)) + (2 if lift < 0 else 0)
    x0 = CX - w // 2
    c.hline(x0 + 1, x0 + w - 2, 46, SHADOW[0])
    c.hline(x0, x0 + w - 1, 47, SHADOW[0])
    c.hline(x0 + 4, x0 + w - 5, 46, SHADOW[1])
    c.hline(x0 + 3, x0 + w - 4, 47, SHADOW[1])


# ---------------------------------------------------------------- laptop
def draw_laptop(c, p, g):
    lap = prop_laptop(p["laptop"], width=16)
    lx0, ly0 = CX - lap.w // 2, GROUND - lap.h + 1
    # screen light spills onto the body just above the lid
    for yy in range(ly0 - 5, ly0 + 1):
        for xx in range(lx0, lx0 + lap.w):
            d = ((xx + 0.5 - CX) / 10.5) ** 2 + ((yy + 0.5 - ly0) / 5.0) ** 2
            q = c.get(xx, yy)
            if d <= 1 and q in GLOW:
                c.set(xx, yy, GLOW[q])
    c.paste(lap, lx0, ly0)
    # two jelly arms reach from the body's sides down to the lid's top edge; a typing
    # mitt hops 2 px up and a key-tap flick shows beside the lid
    arms = []
    for side, up in zip((-1, 1), p["paws"]):
        root = (g["cx"] + side * (g["w"] / 2.0 - 2.5), g["top"] + g["h"] * 0.55)
        hand = (CX + side * 6.5, ly0 - 1.5 - (2 if up else 0))
        arms.append((limb([root, hand], r0=1.8, r1=1.3, rh=2.0), root, 3.2))
    for arm, root, seam in arms:
        ol = arm.outlined(OUTLINE)
        for y in range(H):
            for x in range(W):
                if arm.opaque(x, y):
                    c.set(x, y, arm.get(x, y))
                elif ol.opaque(x, y) and math.hypot(x + 0.5 - root[0], y + 0.5 - root[1]) > seam:
                    c.set(x, y, OUTLINE)
    for side, up in zip((-1, 1), p["paws"]):
        if up:
            tx = CX + side * 11 - (1 if side < 0 else 0)
            c.set(tx, ly0 - 1, TAP).set(tx + side, ly0 - 2, TAP)


# ---------------------------------------------------------------- compose
def draw(p):
    c = Canvas()
    draw_shadow(c, p)
    g = geom(p)
    body = body_layer(p, g)
    arms = []
    for side, key in ((-1, "arm_l"), (1, "arm_r")):
        spec = p[key]
        if spec:
            path = arm_path(p, g, side, spec, p["elbow"] if side > 0 else None, p["arm_at"])
            arms.append((limb(path), path[0], 3.2))
    if p["tone"] == "dim":
        body.recolor(DIM)
        arms = [(a.recolor(DIM), r, sm) for a, r, sm in arms]
    c.paste(attach_arms(body, arms))
    draw_face(c, p, g)
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
        # anchored by the tail tip, so the small pop-in bubble grows from the same point
        c.paste(spr, BUB_X, BUB_Y + p["bub_dy"] + 11 - spr.h)
    return c


# ---------------------------------------------------------------- rows
def idle():
    return [draw(P(**kw)) for kw in (
        {},
        {"eyes": "half"},
        {"eyes": "closed"},
        {"lift": 1},
        {"lift": 1},
        {},
    )]


RUN = [  # facing right: a gliding jelly bounce (squash on contact, stretch on the up)
    dict(lift=0, bw=30, bh=27),
    dict(lift=-1, bw=30, bh=27),
    dict(lift=0),
    dict(lift=1, bw=24, bh=32),
    dict(lift=0, bw=30, bh=27),
    dict(lift=-1, bw=30, bh=27),
    dict(lift=0),
    dict(lift=1, bw=24, bh=32),
]


def speed_lines(i, sgn):
    def fn(c):
        for k, (yy, ln) in enumerate(((24, 4), (31, 5), (37, 3))):
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


def run(direction):
    sgn = 1 if direction == "right" else -1
    return [draw(P(lean=2 * sgn, trail=(4 + (i % 2)) * sgn, look=2 * sgn,
                   fx=[speed_lines(i, sgn)], **f))
            for i, f in enumerate(RUN)]


def waving():
    # the upper arm rises out to an elbow clear of the head; the forearm arcs about it
    return [draw(P(arm_r=(a, 4.5), elbow=(40, 5.0), arm_at=0.42, eyes="happy", blush=True))
            for a in (30, 55, 85, 55)]


def jumping():
    return [
        draw(P(bw=34, bh=24, lift=-1, eyes="squint")),                          # anticipation
        draw(P(bw=24, bh=34, lift=6, eyes="open")),                             # rise
        draw(P(lift=10, eyes="happy", arm_l=(40, 7), arm_r=(40, 7), arm_at=0.5)),   # peak
        draw(P(bw=26, bh=32, lift=5, eyes="open")),                             # fall
        draw(P(bw=34, bh=25, eyes="happy")),                                    # land
    ]


def failed():
    sweat = fx_sweat()
    out = []
    for i, (dx, lift) in enumerate(((-1, 0), (1, -1), (-1, -1), (0, -2))):
        out.append(draw(P(dx=dx, lift=lift, eyes="x", bubble="cross", bub_dy=(i % 2))))
    for i in range(4):
        out.append(draw(P(lift=-2, bw=30, bh=27, eyes="sad", tone="dim",
                          bubble="cross", bub_dy=1,
                          fx=[(sweat.flipped(), 8, 17 + 2 * i)])))
    return out


def waiting():
    e = dict(eyes="wide")
    return [
        draw(P(bubble="small", bub_dy=1, **e)),
        draw(P(bh=31, bubble="bang", bub_dy=0, **e)),
        draw(P(lean=-1, bubble="bang", bub_dy=1, **e)),
        draw(P(bubble="bang", bub_dy=0, **e)),
        draw(P(lean=1, bubble="bang", bub_dy=1, **e)),
        draw(P(bubble="bang", bub_dy=0, **e)),
    ]


def working():
    paws = ((1, 0), (0, 1), (1, 0), (0, 0), (0, 1), (1, 0))
    return [draw(P(eyes="down", laptop=i, paws=paws[i], shadow=False,
                   bubble=f"dots{1 + i // 2}")) for i in range(6)]


def review():
    bounce = (0, 1, 0, -1, 0, 0)
    sparkles = [
        (6, 18, (0, 1, 2, 1, 0, None)),
        (42, 33, (None, 0, 1, 2, 1, 0)),
        (5, 34, (2, 1, 0, None, 0, 1)),
    ]
    out = []
    for i in range(6):
        fx = []
        for sx, sy, sizes in sparkles:
            s = sizes[i]
            if s is not None:
                spr = fx_sparkle(s)
                fx.append((spr, sx - spr.w // 2, sy - spr.h // 2))
        out.append(draw(P(bh=30 + bounce[i], eyes="happy", blush=True,
                          arm_l=(25 + 25 * (i % 2), 6), arm_r=(25 + 25 * ((i + 1) % 2), 6),
                          bubble="check", fx=fx)))
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
