"""Pixel cat: a chunky ginger tabby with a big head, triangle ears and a curly tail.

    python3 tools/petgen/petgen.py build cat

Two rigs share one head:
  * the sitting rig (front view) for idle, waving, jumping, failed, waiting, working, review;
  * the trotting rig (three-quarter side view) for running-right / running-left. It is drawn
    natively for each direction (geometry mirrored, shading computed afterwards so the light
    stays top-left).
Every part is a shape drawn in code, shaded, and outlined separately, back to front.
"""
import math

from petgen import *

PET = {
    "id": "cat",
    "displayName": "Cat",
    "description": "Kneads your keyboard while the agents work.",
}

# ---------------------------------------------------------------- palette
FUR = rgba("#F2A65A")
FUR_SH = rgba("#D9803A")
FUR_DK = shade("#D9803A", 0.14)
FUR_LT = tint("#F2A65A", 0.36)
FUR_T = [FUR_DK, FUR_SH, FUR, FUR_LT]
FUR_TH = [0.12, 0.5, 0.975]          # sphere band cut-offs (small top-left highlight)
STRIPE = rgba("#C46A2C")
STRIPE_DK = shade("#C46A2C", 0.16)
CREAM = rgba("#FFE3BF")
CREAM_SH = mix("#FFE3BF", "#E9A766", 0.42)
CREAM_LT = tint("#FFE3BF", 0.5)
OUT = rgba("#5B3420")
PINK = rgba("#F28B9B")
PINK_SH = shade("#F28B9B", 0.16)
BLUSH = mix("#F28B9B", "#F2A65A", 0.15)
TONGUE = rgba("#FF7A9C")
TAP = mix(SCREEN, WHITE, 0.4)
GLOWABLE = {FUR, FUR_SH, FUR_DK, FUR_LT, STRIPE, STRIPE_DK}

HW, HH = 30, 24          # head ellipse box
BW, BH = 24, 21          # sitting body ellipse box (3 rows cut off the bottom)


# ---------------------------------------------------------------- helpers
def _inside(x, y, pts):
    c = False
    j = len(pts) - 1
    for i in range(len(pts)):
        xi, yi = pts[i]
        xj, yj = pts[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            c = not c
        j = i
    return c


def poly(c, pts, col):
    """Fill a polygon (float edge coordinates) by pixel centres."""
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    for py in range(int(math.floor(min(ys))) - 1, int(math.ceil(max(ys))) + 1):
        for px in range(int(math.floor(min(xs))) - 1, int(math.ceil(max(xs))) + 1):
            if _inside(px + 0.5, py + 0.5, pts):
                c.set(px, py, col)
    return c


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


def spline(ctrl, n=8):
    """Catmull-Rom curve through the control points (dense point list)."""
    P = [ctrl[0]] + list(ctrl) + [ctrl[-1]]
    out = []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        for k in range(n):
            t = k / n
            out.append(tuple(
                0.5 * (2 * p1[j] + (p2[j] - p0[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t * t
                       + (3 * p1[j] - p0[j] - 3 * p2[j] + p3[j]) * t * t * t) for j in (0, 1)))
    out.append(tuple(ctrl[-1]))
    return out


def tail_layer(ctrl, r0=1.9, r1=1.4, puff=False, rings=(0.42, 0.62, 0.82), spike=1.7, every=2.6):
    """A shaded, ringed, outlined tail along a spline. puff=True bristles it up: a sawtooth
    of fur spikes swept toward the tip, `spike` px long on the outer (left-hand) side and
    shorter on the inner side, one every `every` px of length."""
    pts = spline(ctrl)
    n = len(pts) - 1
    t = Canvas()
    for i, ((x0, y0), (x1, y1)) in enumerate(zip(pts, pts[1:])):
        r = r0 + (r1 - r0) * i / n + (0.8 if puff else 0.0)
        t.capsule(x0, y0, x1, y1, r, FUR)
    if puff:
        arc = [0.0]
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            arc.append(arc[-1] + math.hypot(x1 - x0, y1 - y0))
        a = arc[-1] * 0.3
        while a < arc[-1] - 0.5:
            i = max(1, min(n - 1, next(k for k, v in enumerate(arc) if v >= a)))
            (x0, y0), (x1, y1) = pts[i - 1], pts[i + 1]
            d = math.hypot(x1 - x0, y1 - y0) or 1
            tx, ty = (x1 - x0) / d, (y1 - y0) / d
            nx, ny = -ty, tx
            x, y = pts[i]
            r = r0 + (r1 - r0) * i / n + 0.8
            for sgn, ln in ((-1, spike), (1, spike * 0.55)):
                ex, ey = x + nx * sgn * (r - 0.5), y + ny * sgn * (r - 0.5)
                poly(t, [(ex - tx * 1.3, ey - ty * 1.3), (ex + tx * 0.9, ey + ty * 0.9),
                         (ex + tx * 1.6 + nx * sgn * ln, ey + ty * 1.6 + ny * sgn * ln)], FUR)
            a += every
        # the tip draws out to a point, like a brush
        (x0, y0), (x1, y1) = pts[-4], pts[-1]
        d = math.hypot(x1 - x0, y1 - y0) or 1
        tx, ty = (x1 - x0) / d, (y1 - y0) / d
        nx, ny = -ty, tx
        r = r1 + 0.8
        poly(t, [(x1 - nx * r * 0.95, y1 - ny * r * 0.95), (x1 + nx * r * 0.95, y1 + ny * r * 0.95),
                 (x1 + tx * (r + spike), y1 + ty * (r + spike))], FUR)
    sh = rim(t, FUR_SH, FUR, FUR_LT)
    m = Canvas()
    for f in rings:
        i = max(1, min(n - 1, int(f * n)))
        (x0, y0), (x1, y1) = pts[i - 1], pts[i + 1]
        d = math.hypot(x1 - x0, y1 - y0) or 1
        nx, ny = -(y1 - y0) / d, (x1 - x0) / d
        x, y = pts[i]
        m.capsule(x - nx * 4, y - ny * 4, x + nx * 4, y + ny * 4, 0.6, STRIPE)
    sh.paste(m, inside=True)
    return sh.outline(OUT)


# ---------------------------------------------------------------- pose
REST = dict(
    dx=0, lift=0,             # whole-body offset (lift > 0 = up)
    sq=0,                     # body squash rows (> 0 shorter + wider, < 0 taller + narrower)
    wide=True,                # False: squash only shortens the body (a slump, not a loaf)
    hsq=0,                    # head squash rows
    head_dy=0,                # extra head offset (inhale -1)
    look=0,                   # face turn (px)
    eyes="open", mouth="smile", blush=True,
    ears="up",                # up, perk, flat, back
    tail=0.0,                 # tail sway (-1..1)
    curl=1.0,                 # how far the tail tip curls (0..1)
    puff=False,               # bottle-brush tail swung out to the left (failed, startled)
    limp=False,               # deflated tail drooping to the floor on the left (failed, sad)
    arm_l="rest", arm_r="rest",   # "rest" or (paw_x, paw_y) raised (given for the right side)
    tap=(0, 0),               # front paw lift (px) while resting
    hind=0,                   # > 0 hind feet dangle below the body; < 0 tucked up under it (airborne)
    laptop=None, paws=(0, 0), glow=0.0,
    fx=(),
)


def P(**kw):
    p = dict(REST)
    p.update(kw)
    return p


# ---------------------------------------------------------------- head (shared by both rigs)
def ear_polys(hx, hy, hw, ears, turn):
    """Outer and inner triangles for both ears."""
    t = turn * 0.6
    if ears == "flat":        # airplane ears: rotated out and down
        outer = [(2.0, 10.5), (-3.0, 5.5), (9.5, 1.5)]
        inner = [(1.8, 8.2), (-0.8, 5.6), (7.0, 2.8)]
    elif ears == "perk":
        outer = [(1.0, 8.0), (3.0, -6.0), (11.5, 1.5)]
        inner = [(3.3, 5.5), (4.3, -2.5), (9.2, 2.6)]
    elif ears == "back":
        outer = [(1.0, 8.0), (0.5, -3.5), (11.5, 1.5)]
        inner = [(3.0, 5.5), (2.4, -0.5), (9.0, 2.6)]
    else:
        outer = [(1.0, 8.0), (3.0, -5.0), (11.5, 1.5)]
        inner = [(3.3, 5.5), (4.3, -1.5), (9.2, 2.6)]
    L = ([(hx + x + t, hy + y) for x, y in outer], [(hx + x + t, hy + y) for x, y in inner])
    R = ([(hx + hw - x + t, hy + y) for x, y in outer], [(hx + hw - x + t, hy + y) for x, y in inner])
    return L, R


def head_layer(hx, hy, p, hw=HW, hh=HH):
    turn = p["look"]
    L = Canvas()
    (lo, li), (ro, ri) = ear_polys(hx, hy, hw, p["ears"], turn)
    for outer in (lo, ro):
        L.paste(rim(poly(Canvas(), outer, FUR), FUR_SH, FUR, FUR_LT))
    # fluffy cheek tufts at the lower sides
    for side in (-1, 1):
        ex = hx + hw / 2 + side * (hw / 2)
        pts = [(ex - side * 3.0, hy + hh * 0.50), (ex + side * 2.0, hy + hh * 0.64),
               (ex - side * 0.6, hy + hh * 0.68), (ex + side * 1.2, hy + hh * 0.79),
               (ex - side * 3.0, hy + hh * 0.86)]
        poly(L, pts, FUR_SH if side > 0 else FUR)
    L.sphere(hx, hy, hw, hh, FUR_T, thresholds=FUR_TH)
    for inner in (li, ri):
        L.paste(rim(poly(Canvas(), inner, PINK), PINK_SH, PINK, None), inside=True)
    # tabby forehead "M" and side-of-head stripes
    hcx = hx + hw // 2 + turn
    m = Canvas()
    m.rect(hcx - 1, hy + 1, 2, 4, STRIPE)
    m.rect(hcx - 4, hy + 2, 1, 3, STRIPE).set(hcx - 5, hy + 2, STRIPE)
    m.rect(hcx + 3, hy + 2, 1, 3, STRIPE).set(hcx + 4, hy + 2, STRIPE)
    for yy in (hy + 10, hy + 13):
        m.rect(hx, yy, 3, 1, STRIPE)
        m.rect(hx + hw - 3, yy, 3, 1, STRIPE_DK)
    L.paste(m, inside=True)
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

MOUTH = {   # 6 wide; the pink nose 'p' sits on top, centred
    "smile": "..pp..\n#.##.#\n.#..#.",
    "open":  "..pp..\n.####.\n.#tt#.\n..##..",
    "o":     "..pp..\n..##..\n.#..#.\n..##..",
    "small": "..pp..\n..##..",
    "flat":  "..pp..\n.####.",
    "frown": "..pp..\n......\n.####.\n#....#",
}


def draw_face(c, hx, hy, p, hw=HW, hh=HH):
    turn = p["look"]
    hcx = hx + hw // 2 + turn
    ey = hy + 9 + (hh - HH) // 2
    ink = {"#": INK, "w": WHITE, "t": TONGUE, "p": PINK}
    my = ey + 5
    mz = Canvas()
    mz.ellipse(hcx - 6, my, 6, 5, CREAM).ellipse(hcx, my, 6, 5, CREAM)
    mz.rect(hcx - 3, my + 1, 6, 4, CREAM)
    c.paste(rim(mz, CREAM_SH, CREAM, None), inside=True)
    lx, rx = hcx - 7, hcx + 5
    (ox, oy), mirror, pat = EYE[p["eyes"]]
    pw = len(pat.split("\n")[0])
    c.grid(lx + ox, ey + oy, pat, ink)
    c.grid(rx + (1 - ox - (pw - 1) if mirror else ox), ey + oy, pat, ink, flip=mirror)
    if p["blush"]:
        for bx in (lx - 2, rx + 2):
            c.rect(bx, ey + 4, 2, 1, BLUSH)
    c.grid(hcx - 3, my, MOUTH[p["mouth"]], ink)


# ---------------------------------------------------------------- sitting rig
def body_box(p):
    sq = p["sq"]
    bw = BW + 2 * ((sq + 1) // 2 if sq > 0 else -((-sq) // 2))
    if not p["wide"]:
        bw = min(bw, BW)
    bh = BH - sq
    bottom = 46 - p["lift"]
    bx = CX - bw // 2 + p["dx"]
    by = bottom - (bh - 3) + 1
    return bx, by, bw, bh


def head_box(p):
    bx, by, bw, bh = body_box(p)
    hw, hh = HW + (2 if p["hsq"] > 0 else 0), HH - p["hsq"]
    hx = CX - hw // 2 + p["dx"]
    hy = by - 13 + p["head_dy"] + p["hsq"]
    return hx, hy, hw, hh


def sit_tail(p):
    """S-curve up the right side with a hooked tip; tail = sway (-1..1), curl = hook amount.
    A puffed (startled) tail swings out to the left of the body and bristles up, clear of
    the head; a limp (sad) tail droops from the left hip and lies on the floor."""
    s, k = p["tail"], p["curl"]
    g = 46 - p["lift"]
    if p["puff"]:
        ctrl = [(20, g - 3), (13, g - 3), (9.4, g - 6), (7.6, g - 12), (6.9, g - 19),
                (7.0 + 0.3 * s, g - 25.5), (8.2 + 0.6 * s, g - 31)]
        # the tail's base is hidden, so it stays put on the shake's left jolts (keeps x >= 2)
        return tail_layer([(x + max(0, p["dx"]), y) for x, y in ctrl], r0=1.6, r1=1.9, puff=True, spike=2.4)
    if p["limp"]:
        ctrl = [(20, g - 9), (12.5, g - 8.5), (8.6, g - 6.2), (6.8, g - 3.4), (5.2, g - 2.2),
                (4.2 + 0.4 * s, g - 3.6)]
        return tail_layer([(x + p["dx"], y) for x, y in ctrl], r0=1.8, r1=1.2, rings=(0.5, 0.72))
    ctrl = [(30, g - 2), (37, g - 1), (41.5, g - 4), (42, g - 9),
            (39.8 + 0.4 * s, g - 13.5), (40.0 + 1.0 * s, g - 17.5),
            (41.6 + 1.2 * s + 0.4 * k, g - 20.0), (41.2 + 1.4 * s + 1.4 * k, g - 23.0 + 0.4 * (1 - k)),
            (41.2 + 1.4 * s + 1.0 * (1 - k), g - 25.0 + 1.2 * (1 - k))]
    return tail_layer([(x + p["dx"], y) for x, y in ctrl])


def sit_body(p):
    bx, by, bw, bh = body_box(p)
    L = Canvas().sphere(bx, by, bw, bh, FUR_T, cut_bottom=3, thresholds=FUR_TH)
    bib = Canvas().ellipse(CX - 5 + p["dx"], by + 4, 10, bh - 4, CREAM)
    L.paste(rim(bib, CREAM_SH, CREAM, None, dw=1), inside=True)
    m = Canvas()
    for k, yy in enumerate((by + 6, by + 10, by + 14)):
        m.rect(bx, yy, 3 - (k == 2), 1, STRIPE)
        m.rect(bx + bw - 3 + (k == 2), yy, 3 - (k == 2), 1, STRIPE_DK)
    L.paste(m, inside=True)
    return L.outline(OUT)


def hind_feet(p):
    bx, by, bw, bh = body_box(p)
    L = Canvas()
    if p["hind"] < 0:           # airborne, tucked: feet pulled in under the belly, soles out
        bottom = 46 - p["lift"]
        boxes = [((CX - 9 if side < 0 else CX + 2) + p["dx"], bottom - 2 + p["hind"]) for side in (-1, 1)]
        for x, y in boxes:
            L.ellipse(x, y, 7, 5, FUR)
        L = rim(L, FUR_SH, FUR, FUR_LT)
        for x, y in boxes:
            sole = rim(Canvas().ellipse(x + 1, y + 1, 5, 4, CREAM), CREAM_SH, CREAM, None)
            sole.set(x + 2, y + 3, PINK).set(x + 4, y + 3, PINK)
            L.paste(sole)
        return L.outline(OUT)
    if p["hind"] > 0:           # airborne: hind legs dangle below the body
        bottom = 46 - p["lift"]
        for side in (-1, 1):
            hx0 = CX + side * 7.5 + p["dx"]
            fy = bottom + p["hind"]
            L.capsule(hx0, bottom - 4, hx0 - side * 0.5, fy - 1.5, 2.2, FUR)
            L.ellipse(int(hx0 - side * 0.5) - 3, fy - 3, 6, 4, FUR)
        L = rim(L, FUR_SH, FUR, FUR_LT)
        for side in (-1, 1):
            hx0 = CX + side * 7.5 + p["dx"]
            x = int(hx0 - side * 0.5) - 3
            fy = bottom + p["hind"]
            L.set(x + 2, fy, CREAM_SH).set(x + 3, fy, CREAM_SH)
        return L.outline(OUT)
    for side in (-1, 1):
        x = (CX - 14 if side < 0 else CX + 7) + p["dx"]
        L.ellipse(x, 42, 7, 5, FUR)
    return rim(L, FUR_SH, FUR, FUR_LT).outline(OUT)


def paw(c, x, y, w=6, h=4, beans=False):
    """Cream paw (box x, y, w, h) with toe lines; beans=True shows the pink pads."""
    x, y = int(round(x)), int(round(y))
    pw = rim(Canvas().ellipse(x, y, w, h, CREAM), CREAM_SH, CREAM, CREAM_LT)
    if beans:
        pw.rect(x + w // 2 - 1, y + h // 2, 2, 2, PINK)
        pw.set(x + 1, y + 1, PINK).set(x + w // 2 - 1 + (w % 2), y, PINK).set(x + w - 2, y + 1, PINK)
    else:
        pw.set(x + 2, y + h - 1, CREAM_SH).set(x + w - 3, y + h - 1, CREAM_SH)
    c.paste(pw)
    return c


def front_legs(p, which):
    bx, by, bw, bh = body_box(p)
    L = Canvas()
    for side in which:
        a = p["arm_l" if side < 0 else "arm_r"]
        sy = by + 6
        if a == "rest":
            sx = CX + side * 3.5 + p["dx"]
            up = p["tap"][0 if side < 0 else 1]
            fy = min(46, 46 - p["lift"] + max(0, p["hind"])) - up
            seg = Canvas().capsule(sx, sy, sx, fy - 2.0, 2.4, FUR)
            L.paste(rim(seg, FUR_SH, FUR, FUR_LT))
            paw(L, sx - 3, fy - 3, 6, 4)
        else:
            px, py = a
            if side < 0:
                px = 48 - px
            px += p["dx"]
            py -= p["lift"]
            sx = CX + side * 7.0 + p["dx"]
            seg = Canvas().capsule(sx, sy + 1, px, py, 2.2, FUR)
            L.paste(rim(seg, FUR_SH, FUR, FUR_LT))
            paw(L, px - 3, py - 2.5, 6, 5, beans=True)
    return L.outline(OUT)


def draw_sit(p):
    c = Canvas()
    c.paste(sit_tail(p))
    c.paste(sit_body(p))
    c.paste(hind_feet(p))
    hx, hy, hw, hh = head_box(p)
    rest = [s for s, k in ((-1, "arm_l"), (1, "arm_r")) if p[k] == "rest"]
    raised = [s for s, k in ((-1, "arm_l"), (1, "arm_r")) if p[k] != "rest"]
    if p["laptop"] is None and rest:
        c.paste(front_legs(p, rest))
    head = head_layer(hx, hy, p, hw, hh)
    draw_face(head, hx, hy, p, hw, hh)
    c.paste(head)
    if p["laptop"] is not None:
        draw_laptop(c, p)
    elif raised:
        c.paste(front_legs(p, raised))
    for spr, fx_x, fx_y in p["fx"]:
        c.paste(spr, fx_x, fx_y)
    return c


def draw_laptop(c, p):
    lap = prop_laptop(p["laptop"], width=16)
    lx0, ly0 = CX - lap.w // 2, GROUND - lap.h + 1
    if p["glow"]:   # screen light on the chin and chest just above the lid
        for yy in range(ly0 - 4, ly0 + 1):
            for xx in range(lx0 + 2, lx0 + lap.w - 2):
                d = ((xx + 0.5 - CX) / 9.0) ** 2 + ((yy + 0.5 - ly0) / 4.0) ** 2
                q = c.get(xx, yy)
                if d <= 1 and q in GLOWABLE:
                    c.set(xx, yy, mix(q, SCREEN, 0.28 * p["glow"]))
    # paws over the lid, reaching down to the keys behind it: the lifted paw shows whole,
    # the typing paw dips 2 px so only its top peeks over the lid edge
    arms = Canvas()
    for side, up in zip((-1, 1), p["paws"]):
        x0 = CX - 9 if side < 0 else CX + 3      # 6-wide paw box, mirrored about CX
        y = ly0 - up * 2
        seg = Canvas().capsule(CX + side * 7, ly0 + 7, x0 + 3, y + 1, 2.2, FUR)
        arms.paste(rim(seg, FUR_SH, FUR, FUR_LT))
        if up:    # lifted (kneading): the paw tips toward us and shows its pink beans
            paw(arms, x0, y - 3, 6, 5, beans=True)
        else:     # pressing: squashed flat, mostly behind the lid
            paw(arms, x0, y - 2, 6, 4)
    c.paste(arms.outline(OUT))
    c.paste(lap, lx0, ly0)
    for side, up in zip((-1, 1), p["paws"]):
        if not up:   # key-tap flick beside the pressing paw
            tx = CX + side * 10 - (1 if side < 0 else 0)
            c.set(tx, ly0 - 1, TAP).set(tx + side, ly0 - 2, TAP)


# ---------------------------------------------------------------- trotting rig (side view)
def draw_run(p, s):
    """s = +1 running right, -1 running left. Geometry is laid out facing right and
    mirrored by X(); shading is computed after mirroring so the light stays top-left."""
    def X(x):
        return x if s > 0 else 48 - x

    def BX(x, w):
        return x if s > 0 else 48 - x - w

    lift = p["lift"]
    by = 26 - lift
    c = Canvas()
    # tail: up from the rump, tip curling forward
    sw = p["tail"]
    ctrl = [(9, by + 5), (6.2, by + 1.5), (5.0 - 0.3 * sw, by - 3), (5.2 - 0.8 * sw, by - 7.5),
            (6.8 - 1.2 * sw, by - 11), (9.2 - 1.2 * sw, by - 12.3), (10.8 - 1.0 * sw, by - 10.8)]
    c.paste(tail_layer([(X(x + 0.8), y) for x, y in ctrl], r0=1.9, r1=1.5))

    hips = (9.5, 11.5, 23.5, 26.5)           # back-far, back-near, front-far, front-near
    legs = p["legs"]

    def leg(i, near):
        fdx, fl = legs[i]
        hx0 = hips[i]
        fx = hx0 + fdx
        fy = 45.5 - fl
        L = Canvas().capsule(X(hx0), by + 9, X(fx), fy - 0.5, 2.0, FUR)
        L = rim(L, FUR_SH, FUR, FUR_LT) if near else rim(L, FUR_DK, FUR_SH, None)
        pw = Canvas().ellipse(int(round(BX(fx - 2.5, 5))), int(round(fy - 1.5)), 5, 3, CREAM)
        pw = rim(pw, CREAM_SH, CREAM, CREAM_LT) if near else rim(pw, mix(CREAM_SH, FUR_SH, 0.5), CREAM_SH, None)
        L.paste(pw)
        return L.outline(OUT)

    for i in (0, 2):
        c.paste(leg(i, False))
    body = Canvas().sphere(BX(4, 27), by, 27, 14, FUR_T, thresholds=FUR_TH)
    m = Canvas()
    for k, xx in enumerate((7, 10, 13)):
        m.rect(xx if s > 0 else 47 - xx, by, 1, 4 - (k == 2), STRIPE)
    body.paste(m, inside=True)
    c.paste(body.outline(OUT))
    # back-near leg: tucked under the thigh when planted, in front of it when stepping;
    # front-near leg: always tucked under the head (the head is in front of the chest)
    if legs[1][1] < 2:
        c.paste(leg(1, True))
    thigh = Canvas().sphere(BX(5, 11), by + 1, 11, 11, FUR_T, thresholds=FUR_TH)
    c.paste(thigh.outline(OUT))
    if legs[1][1] >= 2:
        c.paste(leg(1, True))
    c.paste(leg(3, True))
    hx = BX(13, HW)
    hy = 16 - p.get("head_bob", lift)   # same head height as the sitting rows (head_box: y=16)
    hp = dict(p)
    hp["look"] = 3 * s
    head = head_layer(hx, hy, hp)
    draw_face(head, hx, hy, hp)
    if p.get("lean"):
        head = head.sheared(p["lean"] * s, hy, hy + HH)
    c.paste(head)
    return c


# ---------------------------------------------------------------- rows
def idle():
    return [draw_sit(P(**kw)) for kw in (
        dict(tail=0.0),
        dict(tail=0.3, eyes="half"),
        dict(tail=0.5, eyes="closed"),
        dict(tail=0.8, head_dy=-1),
        dict(tail=0.5, head_dy=-1),
        dict(tail=0.2),
    )]


def _gait(phase, amp=3.5, rise=3):
    """Foot offset (dx, lift) for a gait phase 0..1: stance sweeps back, swing arcs forward."""
    phase %= 1.0
    if phase < 0.5:
        return amp - 4 * amp * phase, 0
    t = (phase - 0.5) / 0.5
    return -amp + 2 * amp * t, int(round(rise * math.sin(math.pi * t)))


BOB = (0, -1, 0, 1, 0, -1, 0, 1)        # contact, down, passing, up (x2)


def run_pose(i):
    a, b = i / 8, i / 8 + 0.5           # diagonal pairs: (back-far, front-near), (back-near, front-far)
    legs = [_gait(a), _gait(b), _gait(b), _gait(a)]
    return dict(legs=legs, lift=BOB[i], head_bob=BOB[(i - 1) % 8], tail=math.sin(2 * math.pi * i / 8),
                lean=1 if BOB[i] > 0 else 0)


RUN = [run_pose(i) for i in range(8)]


def run(direction):
    s = 1 if direction == "right" else -1
    return [draw_run(dict(P(eyes="open", mouth="smile"), **f), s) for f in RUN]


def waving():
    return [draw_sit(P(arm_r=pos, eyes="happy", mouth="open", tail=t))
            for pos, t in (((38, 32), 0.0), ((40, 27), 0.4), ((39, 22), 0.8), ((40, 27), 0.4))]


def jumping():
    return [
        draw_sit(P(sq=4, hsq=1, eyes="squint", mouth="flat", ears="back", tail=-0.5, curl=0.5)),
        draw_sit(P(lift=5, eyes="open", mouth="o", arm_l=(38, 27), arm_r=(38, 27), hind=-2, tail=0.8)),
        draw_sit(P(lift=7, eyes="happy", mouth="open", arm_l=(42, 26), arm_r=(42, 26), hind=-2, tail=1.0)),
        draw_sit(P(lift=4, eyes="open", mouth="o", arm_l=(39, 33), arm_r=(39, 33), hind=-2, tail=0.4)),
        draw_sit(P(sq=3, hsq=1, eyes="happy", mouth="smile", tail=0.0)),
    ]


def failed():
    cross, sweat = fx_cross(), fx_sweat()
    out = []
    for i, (dx, sq) in enumerate(((-1, 0), (1, 1), (-1, 2), (0, 2))):
        out.append(draw_sit(P(dx=dx, sq=sq, wide=False, eyes="x", mouth="frown", blush=False, ears="flat",
                              puff=True, tail=(0.0, 0.6, -0.2, 0.3)[i], fx=[(cross, 35 + dx, 5 + (i % 2))])))
    for i, sy in enumerate((0, 2, 4, 6)):
        out.append(draw_sit(P(sq=3, wide=False, eyes="sad", mouth="frown", blush=False, ears="flat",
                              limp=True, tail=(0.0, 0.3, 0.6, 0.3)[i], fx=[(sweat, 32, 13 + sy)])))
    return out


def waiting():
    big, small = fx_exclaim(), fx_exclaim(big=False)
    bx, sx = CX - big.w // 2, CX - small.w // 2
    o = dict(eyes="open", mouth="o", ears="perk")
    return [
        draw_sit(P(fx=[(small, sx, 5)], tail=0.0, **o)),
        draw_sit(P(sq=-1, fx=[(big, bx, 1)], tail=0.9, **o)),
        draw_sit(P(tap=(0, 2), fx=[(big, bx, 2)], tail=0.4, **o)),
        draw_sit(P(fx=[(big, bx, 3)], tail=-0.3, **o)),
        draw_sit(P(tap=(0, 2), fx=[(big, bx, 2)], tail=0.4, **o)),
        draw_sit(P(fx=[(big, bx, 2)], tail=0.0, **o)),
    ]


def working():
    out = []
    paws = ((1, 0), (0, 1), (1, 0), (0, 1), (1, 0), (0, 1))
    for i in range(6):
        out.append(draw_sit(P(eyes="down", mouth="small", laptop=i, paws=paws[i], tail=(0, 0.2, 0.4, 0.4, 0.2, 0)[i],
                              glow=(0.8 if i % 3 else 1.0), fx=[(fx_dots(1 + i // 2), 33, 1)])))
    return out


def review():
    bounce = (0, 1, 0, -1, 0, 0)
    sparkles = [
        (6, 16, (0, 1, 2, 1, 0, None)),
        (41, 10, (None, 0, 1, 2, 1, 0)),
        (6, 32, (2, 1, 0, None, 0, 1)),
    ]
    taps = ((2, 0), (0, 0), (0, 2), (0, 0), (2, 0), (0, 0))
    out = []
    for i in range(6):
        fx = []
        for sx, sy, sizes in sparkles:
            s = sizes[i]
            if s is not None:
                spr = fx_sparkle(s)
                fx.append((spr, sx - spr.w // 2, sy - spr.h // 2))
        out.append(draw_sit(P(sq=-bounce[i], eyes="happy", mouth="open", tap=taps[i],
                              tail=(-0.5, 0.0, 0.5, 1.0, 0.5, 0.0)[i], fx=fx)))
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
