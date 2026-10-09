"""Hamster: a chubby golden hamster that stuffs its cheeks while the agents work.

    python3 tools/petgen/petgen.py build hamster

Three rigs share one palette and one face:
  * the sitting rig (front view): one pear-shaped ball of fur with tiny round ears, a
    cream muzzle and belly, short arms and pink paws. Idle, waving, jumping, waiting,
    working and review all use it; cheek pouches puff out on top of it (`puff`).
  * the scurry rig (side view) for running-right / running-left, drawn natively for each
    direction (geometry mirrored, shading computed afterwards so the light stays top-left).
  * the flop rig for failed: head on the floor, face to us, the body belly up behind it
    with all four feet in the air, and a couple of seeds spilled by its chin.
Every part is a shape drawn in code, shaded, and outlined separately, back to front.
"""
import math

from petgen import *

PET = {
    "id": "hamster",
    "displayName": "Hamster",
    "description": "Stuffs its cheeks with your finished tasks.",
}

# ---------------------------------------------------------------- palette
FUR = rgba("#F2B36B")
FUR_SH = rgba("#D98A45")
FUR_DK = shade("#D98A45", 0.14)
FUR_LT = tint("#F2B36B", 0.38)
FUR_T = [FUR_DK, FUR_SH, FUR, FUR_LT]
FUR_TH = [0.1, 0.48, 0.965]
CREAM = rgba("#FFE9CF")
CREAM_SH = mix("#FFE9CF", "#D98A45", 0.3)
CREAM_LT = tint("#FFE9CF", 0.6)
CREAM_T = [CREAM_SH, CREAM, CREAM_LT]
PINK = rgba("#F6A3AA")
PINK_SH = shade("#F6A3AA", 0.18)
PINK_LT = tint("#F6A3AA", 0.4)
NOSE = shade("#F6A3AA", 0.14)
BLUSH = mix("#F6A3AA", "#FF8FA0", 0.4)
OUT = rgba("#5A3317")
TONGUE = rgba("#FF7A9C")
WHISK = mix("#D98A45", "#5A3317", 0.35)
SEED = rgba("#77707F")
SEED_DK = rgba("#544D5C")
SEED_ST = rgba("#F4EFE6")
SEED_OUT = outline_of("#5E5866", 0.5)
TAP = mix(SCREEN, WHITE, 0.4)
SPEED = mix("#D98A45", "#F2B36B", 0.3)
SWISH = mix("#F6A3AA", "#D98A45", 0.45)
GLOWABLE = {FUR, FUR_SH, FUR_DK, FUR_LT, CREAM, CREAM_SH}

BW, BH = 32, 32          # sitting body box
BOTTOM = 45              # lowest body fill row at rest (the feet carry it to the ground)


# ---------------------------------------------------------------- helpers
def rim(layer, dark, mid, light, dw=1, lw=1):
    """Flat-part shading: bottom/right rim dark, top/left rim light, the rest mid."""
    out = Canvas(layer.w, layer.h)
    for y in range(layer.h):
        for x in range(layer.w):
            if not layer.opaque(x, y):
                continue
            d = any(not layer.opaque(x + k, y) or not layer.opaque(x, y + k) for k in range(1, dw + 1))
            l = light is not None and any(not layer.opaque(x - k, y) or not layer.opaque(x, y - k)
                                          for k in range(1, lw + 1))
            out.set(x, y, dark if d else (light if l else mid))
    return out


def _light():
    lx, ly, lz = LIGHT
    n = math.sqrt(lx * lx + ly * ly + lz * lz)
    return lx / n, ly / n, lz / n


LX, LY, LZ = _light()


def egg(c, cx, cy, a, b, k=0.0, axis="v", tones=FUR_T, th=FUR_TH):
    """Toon-shaded egg. axis 'v': half width a, half height b, the widest part pushed toward
    +y by k. axis 'h': half length a, half height b, the tall end toward -x when k < 0 and
    toward +x when k > 0. Centre (cx, cy) in pixel-edge coordinates. Shading uses the
    sphere normal of the un-warped egg, so the light stays top-left whichever way it
    faces."""
    for py in range(int(cy - b) - 1, int(cy + b) + 2):
        for px in range(int(cx - a) - 2, int(cx + a) + 3):
            if axis == "v":
                t = (py + 0.5 - cy) / b
                if abs(t) >= 1:
                    continue
                hw = a * math.sqrt(1 - t * t) * (1 + k * t)
                s = (px + 0.5 - cx) / hw
                if abs(s) > 1:
                    continue
                nx, ny = s * math.sqrt(1 - t * t), t
            else:
                t = (px + 0.5 - cx) / a
                if abs(t) >= 1:
                    continue
                hh = b * math.sqrt(1 - t * t) * (1 + k * t)
                s = (py + 0.5 - cy) / hh
                if abs(s) > 1:
                    continue
                nx, ny = t, s * math.sqrt(1 - t * t)
            nz = math.sqrt(max(0.0, 1 - nx * nx - ny * ny))
            d = nx * LX + ny * LY + nz * LZ
            idx = sum(1 for v in th if d > v)
            c.set(px, py, tones[idx])
    return c


def mirror_box(x, w, side):
    """A box laid out for the left side, mirrored about CX for the right side."""
    return x if side < 0 else 48 - x - w


# ---------------------------------------------------------------- pose
REST = dict(
    dx=0, lift=0,             # whole-body offset (lift > 0 = up)
    sq=0,                     # squash rows (> 0 shorter + wider, < 0 taller + narrower)
    stand=0,                  # standing up on the hind legs: taller, narrower
    lean=0,                   # px the top shears sideways (popcorn twist)
    look=0,                   # face turn (px)
    eyes="open", mouth="smile", blush=True, whisk=0,
    whiskers=True,            # off for the closed-eye faces, where they read as lashes
    ears="up",                # up, perk, flat
    puff=0,                   # cheek pouches: 0 flat .. 6 stuffed
    arm_l="tuck", arm_r="tuck",   # an ARM_POS name, or (paw_x, paw_y[, shoulder_h, inset]) left side
    seed=None,                # held seed: y of its top row (between the paws)
    feet=((0, 0), (0, 0)),    # (dx outward, lift) per foot, left then right
    hang=0,                   # feet dangle below the body (airborne)
    laptop=None, paws=(0, 0), glow=0.0,
    fx=(),
)


def P(**kw):
    p = dict(REST)
    p.update(kw)
    return p


# ---------------------------------------------------------------- sitting rig
def body_geo(p):
    """(cx, top, bottom, a, b) of the sitting body in pixel-edge coordinates."""
    sq, st = p["sq"], p["stand"]
    h = BH - sq + st
    w = BW + sq - st
    bottom = BOTTOM - p["lift"]
    top = bottom - h + 1
    return CX + p["dx"], top, bottom, w / 2.0, h / 2.0


def half_width(p, y):
    cx, top, bottom, a, b = body_geo(p)
    cy = (top + bottom + 1) / 2.0
    t = (y + 0.5 - cy) / b
    if abs(t) >= 1:
        return 0
    return a * math.sqrt(1 - t * t) * (1 + 0.16 * t)


def face_y(p):
    cx, top, bottom, a, b = body_geo(p)
    return top + int(round(2 * b * 0.31))


def ears_layer(p):
    cx, top, bottom, a, b = body_geo(p)
    L = Canvas()
    for side in (-1, 1):
        if p["ears"] == "perk":
            ox, oy, r = 8.0, 1.2, 3.6
        elif p["ears"] == "flat":
            ox, oy, r = 12.5, 4.8, 3.2
        else:
            ox, oy, r = 9.5, 2.4, 3.4
        ex, ey = cx + side * ox, top + oy
        e = Canvas()
        egg(e, ex, ey, r, r, tones=FUR_T, th=FUR_TH)
        # pink inner ear, toward the head centre and down
        egg(e, ex - side * 0.2, ey + 0.4, r * 0.5, r * 0.55, tones=[PINK_SH, PINK, PINK],
            th=[0.3, 0.95])
        L.paste(e)
    return L.outline(OUT)


def cheek_geo(p, side):
    """(ccx, ccy, a, b) of one cheek pouch, or None when the cheeks are flat. puff 1..6
    grows the pouch out past the silhouette, about 1.1 px a step, and down a little."""
    n = p["puff"]
    if n <= 0:
        return None
    cx, top, bottom, a, b = body_geo(p)
    ey = face_y(p)
    hcx = cx + p["look"]
    ccy = ey + 7.0 + n * 0.12
    edge = half_width(p, int(ccy))
    outer = edge - 1.5 + n * 1.12
    inner = 3.5
    ca = (outer - inner) / 2.0
    cb = 3.8 + n * 0.45
    return hcx + side * (inner + ca), ccy, ca, cb


def body_layer(p):
    cx, top, bottom, a, b = body_geo(p)
    cy = (top + bottom + 1) / 2.0
    L = Canvas()
    egg(L, cx, cy, a, b, k=0.16)
    ey = face_y(p)
    hcx = cx + p["look"]
    # cream: muzzle + cheeks across the lower face, and the belly below
    m = Canvas()
    egg(m, hcx, ey + 7.5, 11.5, 6.5, tones=CREAM_T, th=[0.2, 2.0])
    egg(m, cx, bottom - 6.5, 9.5, 9.0, tones=CREAM_T, th=[0.2, 2.0])
    L.paste(m, inside=True)
    # stuffed cheek pouches: part of the silhouette, so one outline wraps the fat face
    for side in (-1, 1):
        g = cheek_geo(p, side)
        if g:
            ccx, ccy, ca, cb = g
            ch = Canvas()
            egg(ch, ccx, ccy, ca, cb, tones=CREAM_T, th=[0.12, 0.9])
            # clip the pouch top so it never covers the eyes
            for yy in range(0, ey + 3):
                for xx in range(48):
                    ch.set(xx, yy, CLEAR)
            L.paste(ch)
    if p["lean"]:
        L = L.sheared(p["lean"], top, bottom)
    return L.outline(OUT)


EYE = {
    # left-eye patterns; '#' ink, 'w' highlight. (dx, dy) offset in the 2x3 slot.
    "open":   ((0, 0), False, "w#\n##\n##"),
    "half":   ((0, 1), False, "##\n##"),
    "closed": ((0, 2), False, "##"),
    "down":   ((0, 1), False, "w#\n##\n##"),
    "happy":  ((-1, 1), True, ".##.\n#..#"),
    "squint": ((-1, 0), True, "##..\n..##\n##.."),
    "x":      ((-1, 0), True, "#.#\n.#.\n#.#"),
    "sad":    ((0, 0), True, "..#\n##.\n##."),
}

MOUTH = {   # 6 wide, centred; 'n' is the pink nose on the top row
    "smile":  "..nn..\n..##..\n.#..#.",
    "teeth":  "..nn..\n..##..\n.#ww#.\n..ww..",
    "open":   "..nn..\n.####.\n.#tt#.\n..##..",
    "o":      "..nn..\n..##..\n.#..#.\n..##..",
    "small":  "..nn..\n..##..",
    "flat":   "..nn..\n......\n.####.",
    "frown":  "..nn..\n......\n..##..\n.#..#.",
}


def draw_face(c, hcx, ey, p):
    ink = {"#": INK, "w": WHITE, "t": TONGUE, "n": NOSE}
    lx, rx = hcx - 7, hcx + 5
    (ox, oy), mirror, pat = EYE[p["eyes"]]
    pw = len(pat.split("\n")[0])
    c.grid(lx + ox, ey + oy, pat, ink)
    c.grid(rx + (1 - ox - (pw - 1) if mirror else ox), ey + oy, pat, ink, flip=mirror)
    if p["blush"]:
        k = 0 if p["puff"] <= 0 else min(3, (p["puff"] + 1) // 2)
        for side, bx in ((-1, lx - 2), (1, rx + 2)):
            c.rect(bx + side * k, ey + 4 + (1 if k else 0), 2, 1, BLUSH)
    c.grid(hcx - 3, ey + 3, MOUTH[p["mouth"]], ink)
    if p["whiskers"] and p["puff"] <= 1:   # one whisker a side; the twitch lifts the tips 1 px
        w = p["whisk"]
        for side in (-1, 1):
            x0 = hcx + (-5 if side < 0 else 4)
            c.line(x0, ey + 5, x0 + side * 3, ey + 4 - w, WHISK)


def paw(c, x, y, w=3, h=3):
    pw = Canvas().ellipse(x, y, w, h, PINK)
    pw = rim(pw, PINK_SH, PINK, PINK_LT)
    c.paste(pw)
    return c


ARM_POS = {   # left paw centre (edge coordinates) for elbows-in poses; mirrored for the right
    "tuck": (20.5, 36.5),     # paws resting on the chest
    "hold": (20.5, 36.0),     # gripping the seed
    "nibble": (20.5, 33.5),   # seed raised to the teeth
    "beg": (20.5, 31.5),      # standing: paws curled up at the chest
}

# waving: the paw arcs about 35, 65, 85, 65 degrees around a shoulder at the body's edge
WAVE = [(11.0 - 7.0 * math.cos(math.radians(d)), 31.6 - 7.0 * math.sin(math.radians(d)),
         0.55, 3.0) for d in (35, 65, 85, 65)]


def arm_layer(p, side):
    """A short fur forearm ending in a pink paw. "tuck"/"hold": elbows in, paws on the
    chest. (x, y): the left paw's centre (edge coordinates), mirrored for the right side;
    the arm then reaches from the shoulder."""
    cx, top, bottom, a, b = body_geo(p)
    spec = p["arm_l" if side < 0 else "arm_r"]
    if spec is None:
        return None
    if isinstance(spec, str):
        hx, hy = ARM_POS[spec]
        hy -= p["lift"]
        sx, sy, r = cx - 7.5, hy - 1.0, 1.6
    else:
        hx, hy = spec[:2]
        hy -= p["lift"]
        sh = spec[2] if len(spec) > 2 else 0.6          # shoulder height (fraction of body)
        inset = spec[3] if len(spec) > 3 else 4.5       # shoulder distance in from the edge
        sx, sy, r = cx - (a - inset), top + 2 * b * sh, 1.9
    hx += p["dx"]
    if side > 0:
        sx, hx = 2 * cx - sx, 2 * (CX + p["dx"]) - hx
    L = Canvas()
    seg = Canvas().capsule(sx, sy, hx, hy, r, FUR)
    L.paste(rim(seg, FUR_SH, FUR, FUR_LT))
    lx = int(math.floor((hx if side < 0 else 2 * (CX + p["dx"]) - hx) - 1.5))
    px = lx if side < 0 else 2 * (CX + p["dx"]) - lx - 3
    paw(L, px, int(math.floor(hy - 1.5)), 3, 3)
    return L.outline(OUT)


SEED_V = """
    .kw.
    kwkw
    kwkd
    kwkd
    .wd.
    .k..
    """
SEED_H = """
    ..kkk.
    kwwwkk
    kkkkdd
    .ddd..
    """
SEED_D = """
    ..kk
    .kwk
    kwkd
    kkd.
    """
SEED_S = """
    .kkk.
    wwwkd
    .kdd.
    """


def seed_sprite(kind=False, flip=False):
    """kind: False upright (held), True lying, "diag" tipped over, "small" a little one."""
    g = {"diag": SEED_D, "small": SEED_S}[kind] if isinstance(kind, str) else (SEED_H if kind else SEED_V)
    s = sprite(g, {"k": SEED, "w": SEED_ST, "d": SEED_DK})
    if flip:
        s = s.flipped()
    return Canvas(s.w + 2, s.h + 2).paste(s, 1, 1).outline(SEED_OUT)


def feet_layer(p):
    cx, top, bottom, a, b = body_geo(p)
    L = Canvas()
    for side, (fdx, flift) in zip((-1, 1), p["feet"]):
        x = mirror_box(15 - fdx, 5, side) + p["dx"]
        y = min(44, 44 - p["lift"] + p["hang"]) - flift
        f = Canvas().ellipse(x, y, 5, 3, PINK)
        f = rim(f, PINK_SH, PINK, PINK_LT)
        L.paste(f)
    return L.outline(OUT)


def draw_sit(p):
    cx, top, bottom, a, b = body_geo(p)
    c = Canvas()
    c.paste(ears_layer(p))
    c.paste(body_layer(p))
    c.paste(feet_layer(p))
    ey = face_y(p)
    hcx = cx + p["look"] + int(round(p["lean"] * 0.6))
    draw_face(c, hcx, ey, p)
    if p["laptop"] is not None:
        draw_laptop(c, p)
    else:
        if p["seed"] is not None:
            c.paste(seed_sprite(), CX - 3 + p["dx"], p["seed"] - p["lift"])
        for side in (-1, 1):
            arm = arm_layer(p, side)
            if arm is not None:
                c.paste(arm)
    for spr, fx_x, fx_y in p["fx"]:
        c.paste(spr, fx_x, fx_y)
    return c


def draw_laptop(c, p):
    lap = prop_laptop(p["laptop"], width=16)
    lx0, ly0 = CX - lap.w // 2, GROUND - lap.h + 1
    if p["glow"]:
        for yy in range(ly0 - 3, ly0 + 1):
            for xx in range(lx0 + 1, lx0 + lap.w - 1):
                d = ((xx + 0.5 - CX) / 9.0) ** 2 + ((yy + 0.5 - ly0) / 3.5) ** 2
                q = c.get(xx, yy)
                if d <= 1 and q in GLOWABLE:
                    c.set(xx, yy, mix(q, SCREEN, 0.25 * p["glow"]))
    cx, top, bottom, a, b = body_geo(p)
    shy = top + 2 * b * 0.6
    arms = Canvas()
    for side, down in zip((-1, 1), p["paws"]):
        sx = cx + side * 9.5
        hx = CX + side * 5.5
        hy = ly0 + (1.5 if down else -0.5)
        seg = Canvas().capsule(sx, shy + 1.0, hx, hy, 1.8, FUR)
        arms.paste(rim(seg, FUR_SH, FUR, FUR_LT))
        px = mirror_box(int(CX - 5.5 - 1.5), 3, side) if side > 0 else int(CX - 5.5 - 1.5)
        paw(arms, px, int(hy - 1), 3, 3)
    c.paste(arms.outline(OUT))
    c.paste(lap, lx0, ly0)
    for side, down in zip((-1, 1), p["paws"]):
        if down:
            tx = CX + side * 10 - (1 if side < 0 else 0)
            c.set(tx, ly0 - 1, TAP).set(tx + side, ly0 - 2, TAP)


# ---------------------------------------------------------------- scurry rig (side view)
def draw_run(p, s):
    """s = +1 running right, -1 running left. Geometry is laid out facing right and
    mirrored by X()/BX(); shading is computed on the mirrored geometry, so the light stays
    top-left either way."""
    def X(x):            # edge coordinate
        return x if s > 0 else 48 - x

    def BX(x, w):        # left edge of a w-wide box laid out at x facing right
        return x if s > 0 else 48 - x - w

    lift = p["lift"]
    lean = p["lean"] * s
    c = Canvas()
    cy = 29.5 - lift
    # speed lines behind the rump
    for (y, x0, ln) in p["speed"]:
        c.rect(BX(x0, ln), y - lift, ln, 1, SPEED)

    def foot(fx, fl, near):
        L = Canvas()
        y = 44 - fl
        L.ellipse(BX(fx - 2, 5), y, 5, 3, PINK)
        if near:
            L = rim(L, PINK_SH, PINK, PINK_LT)
        else:
            L = rim(L, shade(PINK, 0.32), PINK_SH, None)
        return L.outline(OUT)

    def swish(fx, fl):
        """Motion dashes trailing a foot that is whipping forward: the scurry blur."""
        g = Canvas()
        y = 45 - fl
        g.rect(BX(fx - 6, 3), y, 3, 1, SWISH)
        g.rect(BX(fx - 7, 2), y - 2, 2, 1, SWISH)
        return g

    feet = p["feet"]           # back-far, back-near, front-far, front-near: (x, lift)
    for (fx, fl) in feet:
        if fl > 0:
            c.paste(swish(fx, fl))
    for (fx, fl) in (feet[0], feet[2]):
        c.paste(foot(fx, fl, False))
    # ear, tail nub, body
    e = Canvas()
    egg(e, X(27.0), 18.0 - lift, 3.6, 3.6)
    egg(e, X(27.0), 18.6 - lift, 1.8, 2.0, tones=[PINK_SH, PINK, PINK], th=[0.3, 0.95])
    c.paste(e.outline(OUT))
    t = Canvas()
    egg(t, X(6.0), cy + 1.5, 2.0, 1.8)
    c.paste(t.outline(OUT))
    body = Canvas()
    egg(body, X(23.0), cy, 17.0, 12.5, k=-0.12 * s, axis="h")
    m = Canvas()
    egg(m, X(34.0), cy + 3.5, 7.5, 5.5, tones=CREAM_T, th=[0.2, 2.0])
    egg(m, X(21.0), cy + 10.0, 13.0, 6.0, tones=CREAM_T, th=[0.2, 2.0])
    body.paste(m, inside=True)
    nose = Canvas().rect(BX(38, 3), int(cy) - 1, 3, 2, NOSE).set(BX(40, 1), int(cy) - 1, CLEAR)
    body.paste(nose)
    if lean:
        body = body.sheared(lean, int(cy - 12), int(cy + 12))
    c.paste(body.outline(OUT))
    # face
    ey = int(cy) - 6
    c.grid(BX(31, 2) + lean, ey, "w#\n##\n##", {"#": INK, "w": WHITE})
    c.rect(BX(29, 2) + lean, ey + 4, 2, 1, BLUSH)
    c.rect(BX(37, 1) + lean, int(cy) + 2, 1, 1, INK).rect(BX(36, 1) + lean, int(cy) + 3, 1, 1, INK)
    # whiskers fan forward off the snout
    for (y0, y1) in ((int(cy) - 1, int(cy) - 2), (int(cy) + 1, int(cy) + 2)):
        c.line(BX(41, 1) + lean, y0, BX(43, 1) + lean, y1, WHISK)
    # near feet in front
    for (fx, fl) in (feet[1], feet[3]):
        c.paste(foot(fx, fl, True))
    return c


# ---------------------------------------------------------------- flop rig (failed)
def draw_flop(p):
    """Flopped onto its back: the body lies belly up on the right with all four feet in
    the air, the head rests on the floor on the left with its face turned to us. dx rocks
    it; legs are (base_x, tip_x, tip_y) per foot, front pair first."""
    dx = p["dx"]
    c = Canvas()
    # body: belly up, behind the head
    bcx, bcy, ba, bb = 32.0 + dx, 38.5, 12.0, 8.5
    for i, (bx, tx, ty) in enumerate(p["legs"]):
        w = 3 if i < 2 else 4
        leg = rim(Canvas().capsule(bx + dx, 34.0, tx + dx, ty + 2.0, 1.7, FUR),
                  FUR_SH, FUR, FUR_LT)
        paw(leg, int(math.floor(tx + dx - w / 2.0)), ty, w, 3)
        c.paste(leg.outline(OUT))
    t = Canvas()
    egg(t, bcx + ba - 2.5, bcy + 1.5, 2.0, 1.8)
    c.paste(t.outline(OUT))
    body = Canvas()
    egg(body, bcx, bcy, ba, bb, axis="h")
    m = Canvas()
    egg(m, bcx + 0.5, bcy - 5.5, 11.0, 4.5, tones=CREAM_T, th=[0.2, 2.0])
    body.paste(m, inside=True)
    c.paste(body.outline(OUT))
    # head on the floor, face to us
    hcx, hcy, ha, hb = 19.0 + dx, 36.0, 11.0, 10.5
    e = Canvas()
    for side in (-1, 1):
        egg(e, hcx + side * 7.0, hcy - hb + 2.4, 3.2, 3.2)
        egg(e, hcx + side * 6.8, hcy - hb + 2.8, 1.6, 1.8, tones=[PINK_SH, PINK, PINK],
            th=[0.3, 0.95])
    c.paste(e.outline(OUT))
    h = Canvas()
    egg(h, hcx, hcy, ha, hb, k=0.1)
    m = Canvas()
    egg(m, hcx, hcy + 4.5, 8.5, 5.0, tones=CREAM_T, th=[0.2, 2.0])
    h.paste(m, inside=True)
    c.paste(h.outline(OUT))
    ex, ey = int(hcx), int(hcy) - 2
    ink = {"#": INK, "w": WHITE, "t": TONGUE, "n": NOSE}
    (ox, oy), mirror, pat = EYE[p["eyes"]]
    pw = len(pat.split("\n")[0])
    lx, rx = ex - 6, ex + 4
    c.grid(lx + ox, ey + oy, pat, ink)
    c.grid(rx + (1 - ox - (pw - 1) if mirror else ox), ey + oy, pat, ink, flip=mirror)
    c.grid(ex - 3, ey + 3, MOUTH[p["mouth"]], ink)
    for spr, x, y in p["seeds"]:
        c.paste(spr, x, y)
    for spr, fx_x, fx_y in p["fx"]:
        c.paste(spr, fx_x, fx_y)
    return c


# ---------------------------------------------------------------- rows
def idle():
    h = dict(arm_l="hold", arm_r="hold", seed=32)
    return [draw_sit(P(**dict(h, **kw))) for kw in (
        dict(),
        dict(eyes="half", whisk=1),
        dict(eyes="closed"),
        dict(sq=-1, arm_l="nibble", arm_r="nibble", seed=29, mouth="teeth"),
        dict(sq=-1, arm_l="nibble", arm_r="nibble", seed=29, mouth="teeth", whisk=1, puff=1),
        dict(),
    )]


def run_pose(i):
    """Fast scurry: two full strides per 8 frames, diagonal pairs in step. Each foot is
    (x, lift); a lifted foot trails motion dashes."""
    ph = (i % 4) / 4.0

    def f(base, phase):
        phase %= 1.0
        if phase < 0.5:     # stance: sweep back
            return base + 3 - 12 * phase, 0
        t = (phase - 0.5) / 0.5
        return base - 3 + 6 * t, int(round(2 * math.sin(math.pi * t)))

    out = []
    for base, off in ((12, 0.0), (15, 0.5), (28, 0.5), (31, 0.0)):
        x, fl = f(base, ph + off)
        out.append((int(round(x)), fl))
    bob = (0, -1, 0, 1)[i % 4]
    k = i % 2
    speed = [(24, 3 + k, 3), (30, 2 + k, 4), (36, 3 + k, 3)]
    return dict(feet=out, lift=bob, lean=1 if bob > 0 else 0, speed=speed)


def run(direction):
    s = 1 if direction == "right" else -1
    return [draw_run(dict(P(), **run_pose(i)), s) for i in range(8)]


def waving():
    return [draw_sit(P(arm_r=pos, arm_l="tuck", eyes="happy", mouth="open", whiskers=False))
            for pos in WAVE]


def jumping():
    """A popcorn hop: wind-up squash, a stretched launch, a twisting kick at the peak."""
    j = dict(whiskers=False)
    return [
        draw_sit(P(sq=4, eyes="squint", mouth="flat", ears="flat", **j)),
        draw_sit(P(lift=7, sq=-2, eyes="open", mouth="o", arm_l=(10.5, 24.0), arm_r=(10.5, 24.0),
                   hang=2, **j)),
        draw_sit(P(lift=10, eyes="happy", mouth="open", lean=2, arm_l=(8.0, 22.0), arm_r=(8.0, 22.0),
                   feet=((3, 1), (-1, 3)), hang=1, **j)),
        draw_sit(P(lift=5, sq=-1, eyes="open", mouth="o", arm_l=(9.0, 28.0), arm_r=(9.0, 28.0),
                   hang=2, **j)),
        draw_sit(P(sq=3, eyes="happy", mouth="smile", **j)),
    ]


def failed():
    cross, sweat = fx_cross(), fx_sweat()
    seeds = [(seed_sprite("diag"), 2, 37), (seed_sprite("small"), 4, 43)]
    out = []
    for i, dx in enumerate((-1, 1, -1, 0)):
        k = i % 2
        legs = [(27.0, 26.0 - k, 22 + k), (30.5, 30.5, 22 - k), (37.0, 37.5, 21 + k),
                (40.0, 41.5 + k, 23 - k)]
        out.append(draw_flop(dict(P(eyes="x", mouth="frown"), dx=dx, legs=legs, seeds=seeds,
                                  fx=[(cross, 23 + dx, 11 + k)])))
    for i in range(4):
        k = (0, 1, 1, 0)[i]
        legs = [(27.0, 26.5, 23 + k), (30.5, 30.5, 22), (37.0, 37.5, 22 + k), (40.0, 41.0, 23)]
        out.append(draw_flop(dict(P(eyes="sad", mouth="frown"), dx=0, legs=legs, seeds=seeds,
                                  fx=[(sweat, 6, 20 + 2 * i)])))
    return out


def waiting():
    big, small = fx_exclaim(), fx_exclaim(big=False)
    o = dict(stand=4, eyes="open", mouth="o", ears="perk", arm_l="beg", arm_r="beg", whisk=1)
    bx = 39
    return [
        draw_sit(P(**dict(o, fx=[(small, bx, 6)]))),
        draw_sit(P(**dict(o, stand=5, fx=[(big, bx, 1)]))),
        draw_sit(P(**dict(o, feet=((0, 0), (0, 2)), fx=[(big, bx, 2)]))),
        draw_sit(P(**dict(o, fx=[(big, bx, 3)]))),
        draw_sit(P(**dict(o, feet=((0, 0), (0, 2)), fx=[(big, bx, 2)]))),
        draw_sit(P(**dict(o, fx=[(big, bx, 2)]))),
    ]


def working():
    out = []
    paws = ((1, 0), (0, 1), (1, 0), (0, 1), (1, 0), (0, 1))
    for i in range(6):
        # the signature gag: the cheek pouches swell a size every frame as it works.
        # The dots bubble sits at y=2 (not 4) so its tail clears the right ear.
        out.append(draw_sit(P(eyes="down", mouth="small", laptop=i, paws=paws[i], puff=1 + i,
                              glow=(0.8 if i % 3 else 1.0), fx=[(fx_dots(1 + i // 2), 33, 2)])))
    return out


def review():
    bounce = (0, 1, 0, -1, 0, 0)
    sparkles = [
        (6, 17, (0, 1, 2, 1, 0, None)),
        (41, 18, (None, 0, 1, 2, 1, 0)),
    ]
    heart = fx_heart()
    arms = (((8.5, 24.0, 0.46), (7.5, 21.0, 0.46)), ((7.5, 21.0, 0.46), (8.5, 24.0, 0.46)))
    out = []
    for i in range(6):
        fx = []
        for sx, sy, sizes in sparkles:
            s = sizes[i]
            if s is not None:
                spr = fx_sparkle(s)
                fx.append((spr, sx - spr.w // 2, sy - spr.h // 2))
        fx.append((heart, 34, 3 - (1 if i in (2, 3) else 0)))
        al, ar = arms[i % 2]
        out.append(draw_sit(P(sq=-bounce[i], eyes="happy", mouth="smile", puff=4, arm_l=al, arm_r=ar,
                              whiskers=False, fx=fx)))
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
