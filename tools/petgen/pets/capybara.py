"""Capybara: an unbothered, barrel-shaped capybara in 3/4 view.

    python3 tools/petgen/petgen.py build capybara

Rig notes
  * Body and head are "slabs": a silhouette (squircles) shaded from its own distance
    field, so the brick head and its cheek shade as one surface with the light top-left.
    Facing left re-renders the mirrored silhouette, so the light never flips.
  * The head rides on the body: it follows the body's top and front edge, so squash and
    stretch only need new body sizes.
  * Poses are dicts of numbers; every row is a list of overrides of REST.
"""
import math

from petgen import *

PET = {
    "id": "capybara",
    "displayName": "Capybara",
    "description": "Unbothered. Moisturized. Watching your threads.",
}

# ---------------------------------------------------------------- palette
FUR = rgba("#A8743F")
FUR_SH = rgba("#84572F")
FUR_DK = shade(FUR_SH, 0.1)        # light enough to hold on dark wallpaper
FUR_LT = tint(FUR, 0.2)
FUR4 = [FUR_DK, FUR_SH, FUR, FUR_LT]
MUZ = rgba("#C99B68")
MUZ_SH = mix(MUZ, FUR, 0.55)
MUZ_LT = tint(MUZ, 0.25)
MUZ4 = [FUR_SH, MUZ_SH, MUZ, MUZ_LT]
OUTLINE = rgba("#4A2E18")
NOSE = rgba("#3A2414")
LID = FUR_DK
BLUSH = mix("#FF8FA0", FUR, 0.3)
TONGUE = rgba("#FF7A9C")
TAP = mix(SCREEN, WHITE, 0.4)
YUZU = [shade(AMBER, 0.24), rgba(AMBER), tint(AMBER, 0.38)]
YUZU_GLOSS = tint(AMBER, 0.8)
LEAF = [shade(GREEN, 0.2), rgba(GREEN), tint(GREEN, 0.35)]
DUST = [rgba("#CDB9A0"), rgba("#E6D9C8")]


# ---------------------------------------------------------------- slab shading
def squircle(cx, cy, rx, ry, n=2.0):
    def f(x, y):
        return abs((x - cx) / rx) ** n + abs((y - cy) / ry) ** n <= 1.0
    return f


_SLAB = {}


def slab(key, inside, w, h, R, thresholds=(0.30, 0.62, 0.93), light=LIGHT, ss=3):
    """Toon band per pixel for a rounded slab with silhouette inside(x, y) (float coords in
    a local w x h box). A pixel's normal tilts outward the closer it is to the edge (a
    quarter-circle edge profile of radius R); N.L against the top-left light picks the band.
    Returns {(x, y): band}, cached by key."""
    if key in _SLAB:
        return _SLAB[key]
    lx, ly, lz = light
    ln = math.sqrt(lx * lx + ly * ly + lz * lz)
    lx, ly, lz = lx / ln, ly / ln, lz / ln
    pad = 2
    gw, gh = (w + 2 * pad) * ss, (h + 2 * pad) * ss
    ins = [[inside((i + 0.5) / ss - pad, (j + 0.5) / ss - pad) for i in range(gw)] for j in range(gh)]
    edge = []
    for j in range(gh):
        for i in range(gw):
            if ins[j][i]:
                continue
            for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                a, b = i + di, j + dj
                if 0 <= a < gw and 0 <= b < gh and ins[b][a]:
                    edge.append(((i + 0.5) / ss - pad, (j + 0.5) / ss - pad))
                    break
    out = {}
    for y in range(h):
        for x in range(w):
            px, py = x + 0.5, y + 0.5
            if not inside(px, py):
                continue
            best = min((ex - px) ** 2 + (ey - py) ** 2 for ex, ey in edge)
            d = math.sqrt(best)
            ox = oy = 0.0
            lim = (d + 0.6) ** 2
            for ex, ey in edge:
                d2 = (ex - px) ** 2 + (ey - py) ** 2
                if d2 <= lim:
                    k = 1.0 / (0.3 + math.sqrt(d2))
                    ox += (ex - px) * k
                    oy += (ey - py) * k
            on = math.hypot(ox, oy) or 1.0
            ox, oy = ox / on, oy / on
            tilt = 1.0 - min(1.0, max(0.0, (d - 0.3) / R))
            nz = math.sqrt(max(0.0, 1.0 - tilt * tilt))
            dot = (ox * lx + oy * ly) * tilt + nz * lz
            out[(x, y)] = sum(1 for th in thresholds if dot > th)
    _SLAB[key] = out
    return out


def mirrored(f, w):
    return lambda x, y: f(w - x, y)


# ---------------------------------------------------------------- head (local box HW x HH)
HW, HH = 27, 19


def _head_shape(x, y):
    # one rounded brick whose top slopes gently down to a blunt snout, plus a deep cheek
    yy = y - 1.3 * (x - HW / 2) / (HW / 2)
    return _BRICK(x, yy) or _CHEEK(x, y)


_BRICK = squircle(HW / 2, HH * 0.47, HW / 2, HH * 0.46, 3.2)
_CHEEK = squircle(HW * 0.33, HH * 0.56, HW * 0.31, HH * 0.44, 2.2)
_MUZZLE = squircle(HW * 0.80, HH * 0.67, HW * 0.27, HH * 0.39, 1.9)


# ---------------------------------------------------------------- pose
REST = dict(
    face=1,                 # +1 faces right, -1 faces left (pose mirrored, light stays top-left)
    dx=0, lift=0,           # whole-body offset (lift > 0 = up)
    bw=30, bh=22,           # body barrel box (squash = wider + shorter)
    tilt=0,                 # body pitch in degrees (+ = chest up, rump stays down)
    hx=0, hy=0,             # head offset on top of where the body puts it
    hrot=0,                 # head tilt in degrees about the neck (+ = clockwise when facing right)
    eyes="calm", mouth="smile", nose=True, blush=False,
    ears=(0, 0),            # ear perk (px up) near, far; -1 flattens
    legs=((0, 0), (0, 0), (0, 0), (0, 0)),   # (dx, lift) back-far, back-near, front-far, front-near
    lie=False,              # loaf pose: legs folded under, front paws peeking out
    plant=False,            # runs: feet measure from the ground even when the body bobs up 2
    paw=None,               # waving: angle (deg) of the raised near front paw
    paw_sx=0, paw_sy=0, paw_len=8.0,   # waving: shoulder offset (px forward, px up), forearm
    cast=True,              # head casts a 2-px shadow onto the shoulder below the jaw
    laptop=None, typing=(0, 0), glow=0.0,
    yuzu=None,              # review: (dx, dy) of the yuzu relative to its seat on the head
    fx=(),                  # [(sprite, x, y)] drawn last, already in screen coords
    under=(),               # [(sprite, x, y)] drawn first (dust behind the feet)
)


def P(**kw):
    p = dict(REST)
    p.update(kw)
    return p


def mx(s, x, w=1):
    """Screen column of a thing w wide whose left column is x in facing-right coords."""
    return x if s > 0 else W - x - w


def mf(s, x):
    """Mirror a float x (pixel-edge coords)."""
    return x if s > 0 else W - x


# ---------------------------------------------------------------- geometry
def body_box(p):
    bottom = 42 - p["lift"]
    x = 4 + (30 - p["bw"]) // 2 + p["dx"]
    y = bottom - p["bh"] + 1
    return x, y, p["bw"], p["bh"]


def grounded(p):
    return (p["lift"] <= 1 or p["plant"]) and not p["lie"]


def head_origin(p):
    """Top-left of the head box in facing-right coords."""
    x, y, w, h = body_box(p)
    return x + w - 17 + p["hx"], y - 8 + p["hy"]


def head_screen(p):
    """(left, top, right) of the head box in screen coords."""
    hx, hy = head_origin(p)
    left = mx(p["face"], hx, HW)
    return left, hy, left + HW - 1


# ---------------------------------------------------------------- parts
def body_shape(w, h, tilt):
    """Barrel silhouette in a (w, h + 2*ext) box; tilt pitches it about its centre."""
    ext = int(math.ceil(w / 2 * math.sin(math.radians(abs(tilt))))) if tilt else 0
    f = squircle(0, 0, w / 2, h / 2, 2.4)
    th = math.radians(tilt)
    ct, st = math.cos(th), math.sin(th)
    cx, cy = w / 2, h / 2 + ext

    def inside(x, y):
        dx, dy = x - cx, y - cy
        return f(dx * ct - dy * st, dx * st + dy * ct)
    return inside, ext


def draw_body(c, p, s):
    x, y, w, h = body_box(p)
    inside, ext = body_shape(w, h, p["tilt"])
    hh = h + 2 * ext
    inside_s = inside if s > 0 else mirrored(inside, w)
    bands = slab(("body", w, h, p["tilt"], s), inside_s, w, hh, R=7.0, thresholds=(0.32, 0.6, 0.94))
    lowest = max(j for (_, j) in bands)
    y0 = y + h - 1 - lowest            # the lowest body row stays on the belly line
    lay = Canvas()
    x0 = mx(s, x, w)
    for (i, j), b in bands.items():
        lay.set(x0 + i, y0 + j, FUR4[b])
    c.paste(lay.outline(OUTLINE))


EAR = sprite("""
    .rr.
    rddr
    rddr
    """, {"r": FUR, "d": FUR_DK})
EAR_FAR = EAR.copy().recolor({FUR: FUR_SH})
EAR_FLAT = sprite("""
    .rrr.
    rdddr
    """, {"r": FUR, "d": FUR_DK})
EAR_FLAT_FAR = EAR_FLAT.copy().recolor({FUR: FUR_SH})


HPAD = 3            # a tilted head is shaded in a box this much bigger on every side


def _rot(x, y, deg, cx=HW * 0.4, cy=HH * 0.9):
    """Rotate a head-local point (facing right) about the neck; deg > 0 is clockwise."""
    t = math.radians(deg)
    dx, dy = x - cx, y - cy
    return cx + dx * math.cos(t) - dy * math.sin(t), cy + dx * math.sin(t) + dy * math.cos(t)


def hoff(p, x, y):
    """Whole-pixel shift of the head-local point (x, y) (facing right) under the head tilt."""
    if not p["hrot"]:
        return 0, 0
    rx, ry = _rot(x, y, p["hrot"])
    return int(round(rx - x)), int(round(ry - y))


def head_shapes(p, s):
    """(silhouette, muzzle, pad): the head's shape functions in its (padded) local box."""
    r = p["hrot"]
    if not r:
        shape, muz, pad = _head_shape, _MUZZLE, 0
    else:
        pad = HPAD

        def unrot(x, y):
            u, v = _rot(x - pad, y - pad, -r)
            return (u, v) if 0 <= u <= HW and 0 <= v <= HH else (-99, -99)

        def shape(x, y):
            return _head_shape(*unrot(x, y))

        def muz(x, y):
            return _MUZZLE(*unrot(x, y))
    if s < 0:
        shape, muz = mirrored(shape, HW + 2 * pad), mirrored(muz, HW + 2 * pad)
    return shape, muz, pad


def draw_head(c, p, s):
    hx, hy = head_origin(p)
    for k, ((ex, ey), up) in enumerate(zip(((3, -2), (10, -2)), p["ears"])):
        ox, oy = hoff(p, ex + 2, ey + 1.5)
        ears = Canvas()
        if up < 0:
            spr = EAR_FLAT if k == 0 else EAR_FLAT_FAR
            ears.paste(spr, mx(s, hx + ex - 1 + ox, 5), hy + ey + 1 + oy)
        else:
            spr = EAR if k == 0 else EAR_FAR
            ears.paste(spr, mx(s, hx + ex + ox, 4), hy + ey - up + oy)
        c.paste(ears.outline(OUTLINE))
    shape, muz, pad = head_shapes(p, s)
    ox, oy = mx(s, hx, HW) - pad, hy - pad
    bands = slab(("head", s, p["hrot"]), shape, HW + 2 * pad, HH + 2 * pad, R=4.5)
    if p["cast"]:
        # the head casts a soft 2-px shadow down onto the shoulder/chest below the jaw
        down = {FUR_LT: FUR, FUR: FUR_SH, FUR_SH: FUR_DK}
        bottoms = {}
        for (i, j) in bands:
            bottoms[i] = max(bottoms.get(i, -1), j)
        for i, j in bottoms.items():
            for k in (2, 3):
                xx, yy = ox + i, oy + j + k
                q = c.get(xx, yy)
                if q in down:
                    c.set(xx, yy, down[q])
    lay = Canvas()
    for (i, j), b in bands.items():
        tones = MUZ4 if muz(i + 0.5, j + 0.5) else FUR4
        lay.set(ox + i, oy + j, tones[b])
    c.paste(lay.outline(OUTLINE))


# eye patterns (left eye); '#' ink, 'w' highlight, 'L' lid. (dx, dy) offsets the grid in
# the eye's 2x3 slot; mirror=True flips the pattern for the right eye.
EYE = {
    "calm":   ((0, 0), False, "LL\nw#\n##"),
    "open":   ((0, -1), False, "w#\n##\n##"),
    "half":   ((0, 1), False, "LL\n##"),
    "closed": ((0, 2), False, "##"),
    "down":   ((0, 1), False, "LL\ns#"),
    "happy":  ((-1, 1), True, ".##.\n#..#"),
    "squint": ((-1, 0), True, "##..\n..##\n##.."),
    "x":      ((-1, 0), True, "#.#\n.#.\n#.#"),
    "sad":    ((-1, 0), True, "#...\n.##.\n.##."),
}

MOUTH = {
    "smile": "#..#\n.##.",
    "line":  ".##.",
    "open":  "#..#\n.##.\n.tt.",
    "o":     ".##.\n#..#\n.##.",
    "frown": ".##.\n#..#",
}

NOSE_SPR = sprite("""
    .nn.
    nnnn
    n..n
    """, {"n": NOSE})


def draw_face(c, p, s):
    hx, hy = head_origin(p)
    ink = {"#": INK, "w": WHITE, "t": TONGUE, "L": LID, "s": SCREEN}
    (ox, oy), mirror, pat = EYE[p["eyes"]]
    pw = len(pat.split("\n")[0])
    ey = hy + 4
    (lox, loy), (rox, roy) = hoff(p, 8, 5.5), hoff(p, 18, 5.5)
    lx, rx = hx + 7 + lox, hx + 17 + rox      # eye slots (facing right)
    ly, ry = ey + loy, ey + roy
    if s < 0:
        lx, rx, ly, ry = W - rx - 2, W - lx - 2, ry, ly
    c.grid(lx + ox, ly + oy, pat, ink)
    c.grid(rx + (1 - ox - (pw - 1) if mirror else ox), ry + oy, pat, ink, flip=mirror)
    if p["blush"]:
        for bx, by in ((lx - 1, ly), (rx + 1, ry)):
            c.rect(bx, by + 4, 2, 1, BLUSH)
    if p["nose"]:
        nx, ny = hoff(p, 22, 8.5)
        c.paste(NOSE_SPR, mx(s, hx + 20 + nx, 4), hy + 7 + ny)
    m = MOUTH[p["mouth"]]
    mw = len(m.split("\n")[0])
    mox, moy = hoff(p, 22, 13)
    c.grid(mx(s, hx + 22 + mox - mw // 2, mw), hy + 12 + moy, m, {"#": NOSE, "t": TONGUE}, flip=s < 0)


def leg_layer(s, x, top, bottom, far):
    """A stubby leg, 4 px wide, from top (hidden under the body) to its foot row."""
    a, b, d = (FUR_SH, FUR_DK, FUR_DK) if far else (FUR, FUR_SH, FUR_DK)
    lay = Canvas()
    for yy in range(top, bottom + 1):
        row = (a, a, b, d) if yy < bottom else (d, d, d, d)
        if yy == bottom - 1 and not far:
            row = (a, b, b, d)
        for i, col in enumerate(row):
            lay.set(mx(s, x + i), yy, col)
    return lay.outline(OUTLINE)


def leg_x(p, k):
    """Left column of leg k (back-far, back-near, front-far, front-near), facing right."""
    bx, by, bw, bh = body_box(p)
    return (bx + 7, bx + 3, bx + bw - 5, bx + bw - 9)[k] + p["legs"][k][0]


def stepping(p, k):
    """A near leg lifted 2+ px mid-stride is drawn in front of the belly, so the step reads."""
    return p["plant"] and k in (1, 3) and p["legs"][k][1] >= 2


def draw_legs(c, p, s, front=False):
    if p["lie"]:
        return
    bx, by, bw, bh = body_box(p)
    for k in (0, 2, 1, 3):
        if (k == 3 and p["paw"] is not None) or stepping(p, k) != front:
            continue
        llift = p["legs"][k][1]
        bottom = 46 - llift if grounded(p) else 46 - p["lift"] - llift
        top = by + bh - 3 if front else by + 8
        c.paste(leg_layer(s, leg_x(p, k), top, min(46, bottom), far=k in (0, 2)))


PAW_REST = sprite("""
    aaab
    dddd
    """, {"a": FUR, "b": FUR_SH, "d": FUR_DK})


def draw_lying_paws(c, p, s):
    """Front paws folded forward on the ground in the loaf pose."""
    bx, by, bw, bh = body_box(p)
    lay = Canvas()
    for k, (px, col) in enumerate(((bx + bw - 7, FUR_SH), (bx + bw - 3, None))):
        spr = PAW_REST if col is None else PAW_REST.copy().recolor({FUR: FUR_SH, FUR_SH: FUR_DK})
        lay.paste(spr, mx(s, px, 4), 45)
    c.paste(lay.outline(OUTLINE))


PAW_PALM = sprite("""
    .l.a.b
    llaaab
    aPPPMb
    aPPPMb
    aMMMSb
    .bbbb.
    """, {"l": FUR_LT, "a": FUR, "b": FUR_SH, "P": tint(MUZ_LT, 0.3), "M": MUZ_LT, "S": MUZ})


def draw_paw(c, p, s):
    """Raised near front paw (waving): a forearm out from the chest and a palm-out paw with a
    light pad, outlined on its own so it reads over the body."""
    bx, by, bw, bh = body_box(p)
    sx, sy = bx + bw - 4.0 + p["paw_sx"], by + bh - 7.0 - p["paw_sy"]     # shoulder
    a = math.radians(p["paw"])
    L = p["paw_len"]
    ex, ey = sx + L * math.cos(a), sy - L * math.sin(a)                     # wrist
    lay = Canvas()
    lay.capsule(mf(s, sx), sy, mf(s, ex), ey, 1.6, FUR_SH)
    lay.capsule(mf(s, sx - 0.4), sy - 0.6, mf(s, ex - 0.4), ey - 0.6, 1.0, FUR)
    # the paw sits on the wrist, toes up and palm to the viewer, unflipped so its light stays
    # top-left when facing left
    pw, ph = PAW_PALM.w, PAW_PALM.h
    lay.paste(PAW_PALM, int(round(mf(s, ex) - pw / 2)), int(round(ey - ph + 1.5)))
    c.paste(lay.outline(OUTLINE))


def draw_yuzu(c, p, s):
    hx, hy = head_origin(p)
    dx, dy = p["yuzu"]
    x0 = mx(s, hx + 12 + dx, 8)
    y0 = hy - 7 + dy
    lay = Canvas()
    lay.sphere(x0, y0 + 1, 8, 7, YUZU)
    lay.set(x0 + 2, y0 + 2, YUZU_GLOSS).set(x0 + 3, y0 + 2, YUZU_GLOSS)
    lay.outline(outline_of(AMBER, 0.6))
    leaf = sprite("""
        .ab
        ab.
        """, {"a": LEAF[2], "b": LEAF[1]})
    stem = Canvas().paste(leaf, x0 + 4, y0 - 1).outline(outline_of(GREEN, 0.55))
    c.paste(lay)
    c.paste(stem)


def glow(c, cx, cy, rx, ry, amt):
    """Screen light spilling onto the fur just above the lid: one tinted tone, elliptical."""
    for yy in range(int(cy - ry), int(cy) + 1):
        for xx in range(int(cx - rx), int(cx + rx) + 1):
            if ((xx + 0.5 - cx) / rx) ** 2 + ((yy + 0.5 - cy) / ry) ** 2 > 1:
                continue
            q = c.get(xx, yy)
            if q[3] and q in _GLOWABLE:
                c.set(xx, yy, mix(tint(q, 0.25, 0), SCREEN, amt))


_GLOWABLE = set(FUR4 + MUZ4)

TYPE_PAW = sprite("""
    .lla
    llab
    dddd
    """, {"l": FUR_LT, "a": FUR, "b": FUR_SH, "d": FUR_DK})
TYPE_PAW_FAR = TYPE_PAW.copy().recolor({FUR_LT: FUR, FUR: FUR_SH, FUR_SH: FUR_DK})
LAP_X = 22          # laptop's left column (facing right): under the snout


def draw_laptop(c, p, s):
    lap = prop_laptop(p["laptop"], width=16)
    lx0 = mx(s, LAP_X, lap.w)
    ly0 = GROUND - lap.h + 1
    # paws reach round both sides of the lid onto the keys; the pressing paw dips 1 px
    paws = Canvas()
    for side, down in zip((-1, 1), p["typing"]):
        spr = TYPE_PAW if side < 0 else TYPE_PAW_FAR
        px = lx0 - 3 if side < 0 else lx0 + lap.w - 1
        paws.paste(spr, px, ly0 + 4 + down, flip=side > 0)
    c.paste(paws.outline(OUTLINE))
    if p["glow"]:
        glow(c, lx0 + lap.w / 2, ly0 + 1, lap.w / 2 - 2.5, 1.6, 0.4 * p["glow"])
    c.paste(lap, lx0, ly0)
    for side, down in zip((-1, 1), p["typing"]):
        if down:
            tx = lx0 - 3 if side < 0 else lx0 + lap.w + 2
            c.set(tx, ly0 + 1, TAP).set(tx + side, ly0, TAP)


def draw(p):
    s = p["face"]
    c = Canvas()
    for spr, x, y in p["under"]:
        c.paste(spr, x, y)
    draw_legs(c, p, s)
    draw_body(c, p, s)
    draw_legs(c, p, s, front=True)
    if p["lie"] and p["laptop"] is None:
        draw_lying_paws(c, p, s)
    draw_head(c, p, s)
    draw_face(c, p, s)
    if p["paw"] is not None:
        draw_paw(c, p, s)
    if p["yuzu"] is not None:
        draw_yuzu(c, p, s)
    if p["laptop"] is not None:
        draw_laptop(c, p, s)
    for spr, x, y in p["fx"]:
        c.paste(spr, x, y)
    return c


# ---------------------------------------------------------------- rows
def idle():
    return [draw(P(**kw)) for kw in (
        {},
        {"eyes": "half"},
        {"eyes": "closed"},
        {"bh": 23},                              # inhale: the back rises 1 px
        {"bh": 23, "ears": (1, 0)},              # hold, with an ear twitch
        {},
    )]


TROT = [  # (A dx, A lift, B dx, B lift, body lift); A = front-near + back-far, B = the others
    (3, 0, -3, 1, 0),      # contact
    (1, 0, -2, 2, -1),     # down
    (-1, 0, 0, 3, 1),      # passing
    (-2, 0, 2, 2, 2),      # up
    (-3, 1, 3, 0, 0),
    (-2, 2, 1, 0, -1),
    (0, 3, -1, 0, 1),
    (2, 2, -2, 0, 2),
]
PUFF = [sprite("""
    .aa.
    abba
    .aa.
    """, {"a": DUST[0], "b": DUST[1]}), sprite("""
    .a..a
    a....
    .a...
    """, {"a": DUST[0]})]


def run(direction):
    s = 1 if direction == "right" else -1
    out = []
    for i, (adx, al, bdx, bl, lift) in enumerate(TROT):
        legs = ((adx, al), (bdx, bl), (bdx, bl), (adx, al))
        under = []
        if i in (0, 1, 4, 5):
            spr = PUFF[0 if i in (0, 4) else 1]
            x = 2 if i in (0, 4) else 1
            under.append((spr if s > 0 else spr.flipped(), mx(s, x, spr.w), 43))
        out.append(draw(P(face=s, legs=legs, lift=lift, plant=True, hx=1, mouth="line",
                          under=under)))
    return out


def waving():
    # rears up (chest up, head up and tilted toward the paw) and waves the near front paw,
    # palm out, in the clear space in front of the chest
    return [draw(P(tilt=12, hy=-7, hx=-4, hrot=6, paw=a, paw_sx=4, paw_sy=-3, paw_len=9,
                   eyes="happy", mouth="open", blush=True, ears=(1, 1))) for a in (25, 45, 62, 45)]


def jumping():
    dangle = ((0, -1), (0, -1), (0, -1), (0, -1))
    return [
        draw(P(bw=33, bh=18, eyes="squint", mouth="line", ears=(-1, -1))),            # anticipation
        draw(P(bw=29, bh=23, lift=5, eyes="open", mouth="o", ears=(1, 1), legs=dangle)),  # rise
        draw(P(lift=7, eyes="open", mouth="o", ears=(1, 1),
               legs=((1, 0), (-1, 0), (-1, 0), (1, 0)))),                              # peak
        draw(P(bw=29, bh=23, lift=3, eyes="open", mouth="o", legs=dangle)),             # fall
        draw(P(bw=33, bh=19, eyes="happy", mouth="smile", ears=(-1, -1))),             # land
    ]


SIGH = sprite("""
    .aa..
    abbaa
    .aabb
    ...aa
    """, {"a": rgba("#D8D2E6"), "b": rgba("#F2EFF8")})
SIGH_SMALL = sprite("""
    .a.a
    a...
    """, {"a": rgba("#D8D2E6")})


def failed():
    """Loops while the thread stays failed, so the whole loop stays flopped (no getting up and
    falling again every 1.2 s): a small inhale, a long sigh under the red x, then weary eyes
    while the sweat drop slides down."""
    cross = fx_cross()
    sweat = fx_sweat()
    flop = dict(lie=True, lift=-4, bw=31, dx=-1, hx=0, mouth="frown", ears=(-1, -1))
    #        bh  hy  eyes    cross-bob  sigh puff
    beats = [(19, 4, "x", 0, None),       # inhale: head up a touch
             (18, 5, "x", 1, 0),          # sigh...
             (18, 5, "x", 0, 1),
             (18, 5, "x", 1, None),
             (18, 5, "half", None, None),  # ...and just lie there
             (18, 5, "half", None, None),
             (18, 5, "half", None, None),
             (18, 5, "half", None, None)]
    out = []
    for i, (bh, hy, eyes, bob, puff) in enumerate(beats):
        p = P(bh=bh, hy=hy, eyes=eyes, **flop)
        l, t, r = head_screen(p)
        fx = []
        if bob is not None:
            fx.append((cross, r - 7, t - 9 + bob))
        else:
            fx.append((sweat, r - 6, t - 4 + 2 * (i - 4)))
        if puff is not None:
            fx.append((SIGH if puff == 0 else SIGH_SMALL, r - 1 + puff, t + 12 - puff))
        out.append(draw(P(**{**p, "fx": fx})))
    return out


def waiting():
    big, small = fx_exclaim(), fx_exclaim(big=False)
    base = P(eyes="open", mouth="o", ears=(1, 1))
    l, t, r = head_screen(base)
    bx = r - 6                       # above the snout, where the head top slopes away
    tap = ((0, 0), (0, 0), (0, 0), (1, 2))
    return [
        draw(P(**{**base, "ears": (0, 0), "fx": [(small, bx, 5)]})),
        draw(P(**{**base, "bh": 23, "hy": -1, "fx": [(big, bx, 1)]})),
        draw(P(**{**base, "legs": tap, "fx": [(big, bx, 3)]})),
        draw(P(**{**base, "fx": [(big, bx, 2)]})),
        draw(P(**{**base, "legs": tap, "fx": [(big, bx, 3)]})),
        draw(P(**{**base, "fx": [(big, bx, 2)]})),
    ]


def working():
    out = []
    typing = ((1, 0), (0, 1), (1, 0), (0, 0), (0, 1), (1, 0))
    for i in range(6):
        dots = fx_dots(1 + (i // 2))
        out.append(draw(P(lie=True, lift=-4, bw=31, bh=19, dx=-1, hy=0, eyes="down",
                          mouth="line", laptop=i, typing=typing[i],
                          glow=(0.8 if i % 3 else 1.0), fx=[(dots, 33, 4)])))
    return out


def review():
    bounce = (0, 1, 0, -1, 0, 0)
    lag = (0, 0, -1, 0, 1, 0)            # the yuzu trails the bounce by a frame
    sparkles = [  # (x, y, size per frame or None)
        (6, 17, (0, 1, 2, 1, 0, None)),
        (15, 8, (None, 0, 1, 2, 1, 0)),
        (41, 8, (2, 1, 0, None, 0, 1)),
    ]
    out = []
    for i in range(6):
        fx = []
        for sx, sy, sizes in sparkles:
            sz = sizes[i]
            if sz is not None:
                spr = fx_sparkle(sz)
                fx.append((spr, sx - spr.w // 2, sy - spr.h // 2))
        out.append(draw(P(bh=22 + bounce[i], eyes="happy", mouth="open", blush=True,
                          yuzu=(0, lag[i]), fx=fx)))
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
