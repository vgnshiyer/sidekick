"""Rubber Duck: the rubber-duck-debugging pet. A glossy yellow bath duck in 3/4 side view.

    python3 tools/petgen/petgen.py build duck

Rig: every part (body with its perky tail tuft, wing nubs, round head, two-part beak) is
an analytic shape in a local, facing-right frame. A per-frame transform (facing, tilt
about a pivot, an optional head turn about the neck, offset) maps screen pixels back into
that frame, so the same pose re-renders natively facing left or tipped over, with the
normals rotated too: the light always stays top-left. Each part is toon-shaded and
outlined on its own layer, back to front; the face (ink eyes, blush) goes on last.
Frames are composed on a canvas with a margin, so a tipped pose can be re-planted on the
ground line without clipping.

At rest the duck faces left (like the emoji), so its face catches the top-left light and
the space above its tail is free for the wave, the "!", the red x and the dots bubble.
"""
import math

from petgen import *

PET = {
    "id": "duck",
    "displayName": "Rubber Duck",
    "description": "Explain your bug to the duck. It's listening.",
}

# ---------------------------------------------------------------- palette
BODY = rgba("#FFD43B")
BODY_SH = rgba("#F2A91F")
BODY_DK = shade("#F2A91F", 0.16)
BODY_HI = rgba("#FFF4B0")
BODY_T = [BODY_DK, BODY_SH, BODY, BODY_HI]
FAR_T = [BODY_DK, BODY_DK, BODY_SH, BODY]        # the far wing sits in the body's shadow
OUT = rgba("#7A4A0E")

BEAK = rgba("#FF8A1F")
BEAK_SH = rgba("#E0651A")
BEAK_LT = tint("#FF8A1F", 0.38)
BEAK_T = [BEAK_SH, BEAK, BEAK_LT]
BEAK_OUT = rgba("#7A2C0C")
MOUTH = rgba("#8E2B22")
TONGUE = rgba("#FF7A9C")

BLUSH = mix("#FF7A9C", "#FFD43B", 0.3)
WATER = rgba("#8FD3F5")
WATER_LT = tint("#8FD3F5", 0.6)
WATER_DK = shade("#8FD3F5", 0.22)
WATER_OUT = outline_of("#8FD3F5", 0.5)
TAP = mix(SCREEN, WHITE, 0.4)
GLOW = mix(SCREEN, WHITE, 0.55)          # screen light on yellow (pure cyan would turn it green)
GLOWABLE = {BODY_DK, BODY_SH, BODY}

_ln = math.sqrt(sum(v * v for v in LIGHT))
LX, LY, LZ = (v / _ln for v in LIGHT)

TH_BODY = [0.14, 0.52, 0.965]   # rim shadow, shade, base, gloss spot
TH_HEAD = [0.14, 0.52, 0.95]
TH_WING = [0.25, 0.6, 0.985]
TH_BEAK = [0.45, 0.93]
TH_TIP = [0.3, 0.7, 0.9]
TIP_NEAR = [BODY_SH, BODY, BODY_HI, BODY_HI]   # wing tips on the lid catch the light
TIP_FAR = [BODY_DK, BODY_SH, BODY, BODY_HI]

M = 14                          # compose margin around the 48x52 cell


def big():
    return Canvas(W + 2 * M, H + 2 * M)


# ---------------------------------------------------------------- transform
class Rig:
    """Local (facing-right rest frame, pixel-edge coords) -> screen. tilt is degrees,
    positive = rocks back onto the tail (counter-clockwise in the local frame) about
    `pivot`; s = -1 mirrors the result (x -> 48 - x) after the rotations."""

    def __init__(self, s=1, tilt=0.0, pivot=(22.0, 40.0), dx=0, lift=0):
        self.s, self.dx, self.lift = s, dx, lift
        a = math.radians(tilt)
        self.rots = [(math.cos(a), math.sin(a), pivot[0], pivot[1])]

    def part(self, deg, pivot):
        """The same transform with an extra rotation of one part about a local pivot."""
        r = Rig(self.s, 0.0, (0, 0), self.dx, self.lift)
        a = math.radians(deg)
        r.rots = [(math.cos(a), math.sin(a), pivot[0], pivot[1])] + self.rots
        return r

    def fwd(self, x, y):
        for c, s, px, py in self.rots:
            vx, vy = x - px, y - py
            x, y = px + vx * c + vy * s, py - vx * s + vy * c
        if self.s < 0:
            x = 48 - x
        return x + self.dx, y - self.lift

    def inv(self, X, Y):
        X -= self.dx
        Y += self.lift
        if self.s < 0:
            X = 48 - X
        for c, s, px, py in reversed(self.rots):
            rx, ry = X - px, Y - py
            X, Y = px + rx * c - ry * s, py + rx * s + ry * c
        return X, Y

    def nrm(self, nx, ny):
        for c, s, _, _ in self.rots:
            nx, ny = nx * c + ny * s, -nx * s + ny * c
        return (-nx if self.s < 0 else nx), ny


def band(d, th):
    i = 0
    for t in th:
        if d > t:
            i += 1
    return i


def _span(rig, fn):
    bx, by, br = fn.bound
    X, Y = rig.fwd(bx, by)
    x0 = max(-M, int(math.floor(X - br)) - 1)
    x1 = min(W + M, int(math.ceil(X + br)) + 2)
    y0 = max(-M, int(math.floor(Y - br)) - 1)
    y1 = min(H + M, int(math.ceil(Y + br)) + 2)
    return x0, x1, y0, y1


def render(rig, fn, tones, th, out=None):
    """Rasterise shape fn(x, y) -> local normal (nx, ny, nz) or None, toon-shaded,
    onto a margin canvas (screen pixel X lands at X + M)."""
    out = out or big()
    x0, x1, y0, y1 = _span(rig, fn)
    for Y in range(y0, y1):
        for X in range(x0, x1):
            x, y = rig.inv(X + 0.5, Y + 0.5)
            n = fn(x, y)
            if n is None:
                continue
            nx, ny = rig.nrm(n[0], n[1])
            out.set(X + M, Y + M, tones[band(nx * LX + ny * LY + n[2] * LZ, th)])
    return out


def fill(rig, fn, col, out=None):
    out = out or big()
    x0, x1, y0, y1 = _span(rig, fn)
    for Y in range(y0, y1):
        for X in range(x0, x1):
            x, y = rig.inv(X + 0.5, Y + 0.5)
            if fn(x, y) is not None:
                out.set(X + M, Y + M, col)
    return out


# ---------------------------------------------------------------- shapes (local frame)
def ell(cx, cy, rx, ry, cut=None, ang=0.0):
    """Ellipse; ang rotates it counter-clockwise (degrees). Normal from the ellipsoid."""
    a = math.radians(ang)
    ca, sa = math.cos(a), math.sin(a)

    def f(x, y):
        if cut is not None and y > cut:
            return None
        vx, vy = x - cx, y - cy
        ex, ey = vx * ca - vy * sa, vx * sa + vy * ca
        u, v = ex / rx, ey / ry
        r2 = u * u + v * v
        if r2 > 1.0:
            return None
        return u * ca + v * sa, -u * sa + v * ca, math.sqrt(1.0 - r2)
    f.bound = (cx, cy, max(rx, ry))
    return f


def taper(pts, r0, r1):
    """Tapered tube along a polyline: radius r0 at the first point, r1 at the last."""
    segs = list(zip(pts, pts[1:]))
    lens = [math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in segs]
    total = sum(lens) or 1.0

    def f(x, y):
        best = None
        acc = 0.0
        for (a, b), ln in zip(segs, lens):
            dx, dy = b[0] - a[0], b[1] - a[1]
            L2 = dx * dx + dy * dy or 1e-9
            t = max(0.0, min(1.0, ((x - a[0]) * dx + (y - a[1]) * dy) / L2))
            qx, qy = a[0] + dx * t, a[1] + dy * t
            d = math.hypot(x - qx, y - qy)
            r = r0 + (r1 - r0) * (acc + ln * t) / total
            if d <= r and (best is None or d / r < best[0]):
                best = (d / r, (x - qx) / r, (y - qy) / r)
            acc += ln
        if best is None:
            return None
        k, nx, ny = best
        return nx, ny, math.sqrt(max(0.0, 1.0 - k * k))
    cx = sum(p[0] for p in pts) / len(pts)
    cy = sum(p[1] for p in pts) / len(pts)
    f.bound = (cx, cy, max(math.hypot(p[0] - cx, p[1] - cy) for p in pts) + max(r0, r1))
    return f


def polyf(pts):
    """Flat polygon (pixel-centre test)."""
    def f(x, y):
        inside = False
        j = len(pts) - 1
        for i in range(len(pts)):
            xi, yi = pts[i]
            xj, yj = pts[j]
            if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
                inside = not inside
            j = i
        return (0.0, 0.0, 1.0) if inside else None
    cx = sum(p[0] for p in pts) / len(pts)
    cy = sum(p[1] for p in pts) / len(pts)
    f.bound = (cx, cy, max(math.hypot(p[0] - cx, p[1] - cy) for p in pts))
    return f


def union(*fns):
    def f(x, y):
        for g in fns:
            n = g(x, y)
            if n is not None:
                return n
        return None
    x0 = min(g.bound[0] - g.bound[2] for g in fns)
    x1 = max(g.bound[0] + g.bound[2] for g in fns)
    y0 = min(g.bound[1] - g.bound[2] for g in fns)
    y1 = max(g.bound[1] + g.bound[2] for g in fns)
    f.bound = ((x0 + x1) / 2, (y0 + y1) / 2, max(x1 - x0, y1 - y0) / 2 * 1.42)
    return f


# ---------------------------------------------------------------- pose
REST = dict(
    s=-1, dx=0, lift=0,         # facing (-1 left = rest, +1 right); whole-body offset (lift > 0 = up)
    tilt=0.0, pivot=(22.0, 40.0),   # rock back (+) / tip forward (-) about pivot (local frame)
    ground=False,               # re-plant the lowest pixel on y=47 after a tilt
    center=None,                # with ground: also centre the silhouette on this x (+ dx shake)
    sq=0,                       # body squash rows (> 0 shorter + wider, < 0 taller)
    hdx=0, hdy=0,               # head offset (inhale)
    htilt=0.0,                  # extra head rotation about the neck (deg, + = back, - = nod)
    lean=0,                     # head lean into a run (px)
    look=0,                     # face turn toward the facing (px)
    eyes="open", beak="smile", blush=True,
    wing=12.0,                  # near wing elevation (deg; 0 = pointing straight back, 90 = up)
    far=None,                   # far wing elevation when it peeks over the back
    tail=0.0,                   # tail tuft flick (px at the tip, + = up)
    laptop=None, taps=(0, 0), glow=0.0,
    fx=(),                      # (sprite, x, y) drawn last
    under=(),                   # (sprite, x, y) drawn behind the duck (wake, splash)
)


def P(**kw):
    p = dict(REST)
    p.update(kw)
    return p


def geom(p):
    """Rest-frame part geometry from the pose numbers."""
    sq = p["sq"]
    top = 28.0 + sq                       # body top edge (bottom fixed at the 48 edge, cut at 47)
    bry = (48.0 - top) / 2.0
    brx = 15.5 + (sq * 0.6 if sq > 0 else sq * 0.4)
    g = dict(bcx=22.0, bcy=top + bry, brx=brx, bry=bry, top=top)
    g["hcx"] = 29.5 + p["hdx"] + p["lean"]
    g["hcy"] = top - 6.0 + p["hdy"]
    g["hrx"], g["hry"] = 10.3, 10.0
    return g


def tail_fn(p, g):
    w = p["tail"]
    t0 = g["top"]
    pts = [(12.5, t0 + 5.0), (9.0, t0 + 1.5), (6.8 - 0.2 * w, t0 - 2.0 - 0.5 * w), (5.6 - 0.2 * w, t0 - 4.4 - w)]
    return taper(pts, 3.6, 1.0)


def wing_fn(g, elev, far=False, ln=None):
    """Teardrop wing nub: round at the shoulder, pointed tip toward the tail. Raising it
    slides the shoulder back so the wing clears the head, and fans the tip into three
    feathers so a raised wing reads as a wing (a little hand), not a second tail."""
    k = max(0.0, min(1.0, (elev - 15.0) / 45.0)) if elev <= 120 else 0.0
    sx = g["bcx"] - 4.0 * k
    sy = g["top"] + 8.5 - 2.0 * k
    if far:
        sx, sy = sx + 3.5, sy - 3.0
    a = math.radians(elev)
    ln = ln or (9.0 + 2.5 * k)
    ca, sa = math.cos(a), math.sin(a)
    tx, ty = sx - ln * ca, sy - ln * sa
    # the trailing edge bows down a little, like a folded wing
    mx, my = sx - ln * 0.5 * ca - 0.7 * sa, sy - ln * 0.5 * sa + 0.7 * ca
    main = taper([(sx, sy), (mx, my), (tx, ty)], 3.5 - 0.1 * k, 1.1 + 0.2 * k)
    if k < 0.5 or far:
        return main
    parts = [main]
    bx, by = sx - ln * 0.58 * ca, sy - ln * 0.58 * sa
    for da, f in ((38.0, 0.36), (-38.0, 0.36)):
        b = a + math.radians(da)
        fl = ln * f
        parts.append(taper([(bx, by), (bx - fl * math.cos(b), by - fl * math.sin(b))], 2.0, 1.0))
    return union(*parts)


OPEN = {"smile": 0.0, "closed": 0.0, "frown": 0.0, "gasp": 1.0, "o": 1.4, "open": 2.0, "squeak": 3.0}


def beak_layer(rig, p, g):
    """Upper and lower mandible; an open beak drops the lower jaw and shows the gape."""
    hx, hy = g["hcx"] + p["look"], g["hcy"]
    op = OPEN[p["beak"]]
    ux, uy = hx + 8.0, hy + 3.2
    upper = ell(ux, uy - op * 0.25, 5.8, 2.5, ang=op * 2.0)
    lower = ell(ux - 1.0, uy + 2.4 + op * 0.8, 4.6, 1.7, ang=-op * 5.0)
    bk = render(rig, lower, [BEAK_SH, BEAK_SH, BEAK], [0.3, 0.85])
    if op:
        gape = polyf([(ux - 4.2, uy + 0.8), (ux + 4.6, uy + 0.8), (ux + 3.4, uy + 2.0 + op * 1.1),
                      (ux - 3.6, uy + 2.2)])
        fill(rig, gape, MOUTH, bk)
        fill(rig, ell(ux - 0.3, uy + 2.0 + op * 0.9, 2.4, 0.9), TONGUE, bk)
    render(rig, upper, BEAK_T, TH_BEAK, bk)
    return bk.outline(BEAK_OUT)


# ---------------------------------------------------------------- face
EYE = {
    # (dx, dy, grid); '#' ink, 'w' highlight. Same grid for both eyes (highlight stays top-left).
    "open":   (0, 0, "w#\n##\n##"),
    "half":   (0, 1, "##\n##"),
    "closed": (0, 2, "##"),
    "down":   (0, 1, "w#\n##\n##"),
    "wide":   (0, -1, "w#\n##\n##\n##"),
    "happy":  (-1, 1, ".##.\n#..#"),
    "squint": (-1, 0, None),
    "x":      (-1, 0, "#.#\n.#.\n#.#"),
    "sad":    (0, 0, None),
}
SQUINT = ("##..\n..##\n##..", "..##\n##..\n..##")     # screen-left eye, screen-right eye
SAD = ("..#\n##.\n##.", "#..\n.##\n.##")      # brows raised at the inner ends


def draw_face(c, rig, p, g):
    ink = {"#": INK, "w": WHITE}
    hx, hy = g["hcx"] + p["look"], g["hcy"]
    slots = [(hx - 4.5, hy - 4.0), (hx + 3.5, hy - 4.0)]   # near eye, far eye (2x3 slot top-left)
    pos = []
    for ex, ey in slots:
        X, Y = rig.fwd(ex + 1.0, ey + 1.5)          # slot centre on screen
        pos.append((int(math.floor(X - 0.5)), int(math.floor(Y - 1.0))))
    pos.sort()
    key = p["eyes"]
    for k, (X0, Y0) in enumerate(pos):
        dx, dy, pat = EYE[key]
        if key == "squint":
            pat = SQUINT[k]
        elif key == "sad":
            pat = SAD[k]
            dx = 0 if k == 0 else -1
        c.grid(X0 + dx + M, Y0 + dy + M, pat, ink)
    if p["blush"]:
        X, Y = rig.fwd(hx - 6.0, hy + 1.5)
        c.rect(int(math.floor(X - 0.5)) + M, int(math.floor(Y)) + M, 2, 1, BLUSH)


# ---------------------------------------------------------------- draw
def draw(p):
    rig = Rig(p["s"], p["tilt"], p["pivot"], p["dx"], p["lift"])
    g = geom(p)
    c = big()
    if p["far"] is not None:
        c.paste(render(rig, wing_fn(g, p["far"], far=True), FAR_T, TH_WING).outline(OUT))
    body_f = union(ell(g["bcx"], g["bcy"], g["brx"], g["bry"], cut=47.0), tail_fn(p, g))
    c.paste(render(rig, body_f, BODY_T, TH_BODY).outline(OUT))
    raised = p["wing"] > 30
    wing = None
    if p["laptop"] is None:
        wing = render(rig, wing_fn(g, p["wing"]), BODY_T, TH_WING).outline(OUT)
        if not raised:
            c.paste(wing)
    hrig = rig.part(p["htilt"], (g["hcx"] - 2.0, g["hcy"] + 8.0)) if p["htilt"] else rig
    head = render(hrig, ell(g["hcx"], g["hcy"], g["hrx"], g["hry"]), BODY_T, TH_HEAD)
    c.paste(head.outline(OUT))
    c.paste(beak_layer(hrig, p, g))
    draw_face(c, hrig, p, g)
    if wing is not None and raised:
        c.paste(wing)
    tx = ty = 0
    if p["ground"]:
        bb = c.bbox()
        ty = GROUND + M - bb[3]
        if p["center"] is not None:
            tx = int(round(p["center"] + M - (bb[0] + bb[2] + 1) / 2.0)) + p["dx"]
    if p["laptop"] is not None:
        c = draw_laptop(c, rig, p, g)
    hb = head.bbox()
    meta = dict(head=(hb[0] - M + tx, hb[1] - M + ty, hb[2] - M + tx, hb[3] - M + ty))
    out = Canvas()
    for spr, x, y in p["under"]:
        out.paste(spr, x, y)
    out.paste(c.crop(M - tx, M - ty, W, H))
    for item in p["fx"]:
        spr, x, y = item(meta) if callable(item) else item
        out.paste(spr, x, y)
    return out


def draw_laptop(c, rig, p, g):
    """Laptop in front; both wing tips reach over the lid to the keys (the near wing on
    the right, the far one on the left), and the typing tip dips 2 px behind the lid
    edge. The screen light tints the chest just above the lid."""
    lap = prop_laptop(p["laptop"], width=16)
    lx0, ly0 = CX - lap.w // 2 + M, GROUND - lap.h + 1 + M
    if p["glow"]:
        for yy in range(ly0 - 3, ly0 + 1):
            for xx in range(lx0 + 1, lx0 + lap.w - 1):
                d = ((xx + 0.5 - CX - M) / 10.0) ** 2 + ((yy + 0.5 - ly0) / 3.5) ** 2
                q = c.get(xx, yy)
                if d <= 1 and q in GLOWABLE:
                    c.set(xx, yy, mix(q, GLOW, 0.32 * p["glow"]))
    # wing tips, given in the local (facing-right) frame: shoulder low behind the lid,
    # rounded tip resting on the lid's top edge
    for far, dip in ((True, p["taps"][1]), (False, p["taps"][0])):
        sx, tx = (31.0, 31.5) if far else (19.5, 20.5)
        ty = 31.5 + 2 * dip
        fn = taper([(sx, 41.0), (tx, ty)], 3.0, 2.8)
        layer = render(rig, fn, TIP_FAR if far else TIP_NEAR, TH_TIP)
        c.paste(layer.outline(OUT))
    c.paste(lap, lx0, ly0)
    for far, dip in ((True, p["taps"][1]), (False, p["taps"][0])):
        if dip:   # key-tap flick beside the pressing wing tip
            fx_ = lx0 + (3 if far else lap.w - 4)
            sgn = -1 if far else 1
            c.set(fx_, ly0 - 1, TAP).set(fx_ + sgn, ly0 - 2, TAP)
    return c


# ---------------------------------------------------------------- water + fx
def _wsprite(text):
    s = sprite(text, {"l": WATER_LT, "b": WATER, "d": WATER_DK})
    return Canvas(s.w + 2, s.h + 2).paste(s, 1, 1).outline(WATER_OUT)


DASH = _wsprite("lbbb")
DROP = [_wsprite("l"), _wsprite("lb\nbd"), _wsprite(".l.\nlbb\nbbd\n.d.")]


def at(spr, x, y, s=-1):
    """Place a sprite given for the facing-left layout; mirrored when facing right."""
    if s < 0:
        return (spr, x, y)
    return (spr.flipped(), 48 - x - spr.w, y)


def burst(size):
    """Little "squeak" burst: three short amber strokes fanning out from the beak tip,
    outlined like the family glyphs. Paste at (0, 0); size 1 is the loud one."""
    c = Canvas(14, 24)
    hi, base = tint(AMBER, 0.45), AMBER
    if size:
        strokes = [((9, 9), (9, 11)), ((5, 14), (7, 15)), ((3, 19), (5, 19))]
    else:
        strokes = [((9, 10), (9, 11)), ((6, 15), (7, 15)), ((4, 19), (5, 19))]
    for (x0, y0), (x1, y1) in strokes:
        c.line(x0, y0, x1, y1, base)
        c.set(x0, y0, hi)
    return c.outline(outline_of(AMBER, 0.6))


# ---------------------------------------------------------------- rows
def idle():
    ripples = [at(DASH, 5, 44), at(DASH, 39, 44)]
    spread = [at(DASH, 4, 44), at(DASH, 40, 44)]
    return [draw(P(**kw)) for kw in (
        dict(under=ripples),
        dict(under=ripples, eyes="half"),
        dict(under=ripples, eyes="closed"),
        dict(under=spread, sq=-1, tail=1),
        dict(under=spread, sq=-1, tail=1),
        dict(under=ripples),
    )]


def run(direction):
    """A bobbing glide: contact, down, passing, up (x2). The body squashes on the down
    frames and rises 1 px on the up frames; the head leans in, the wing pumps, and
    droplets kick up behind the tail over a wake line."""
    s = 1 if direction == "right" else -1
    bob = (0, -1, 0, 1, 0, -1, 0, 1)
    wings = (10, 28, 42, 28, 10, 28, 42, 28)
    # facing-left layout (tail on the right); drawn behind the duck
    splash = [
        [(DROP[1], 38, 41), (DROP[0], 42, 43)],
        [(DROP[2], 39, 36), (DROP[0], 42, 40)],
        [(DROP[1], 40, 34), (DROP[1], 41, 39)],
        [(DROP[0], 41, 38), (DROP[0], 42, 42)],
    ]
    out = []
    for i in range(8):
        b = bob[i]
        under = [at(DASH, 36 + (i % 4 == 0), 45, s)] + [at(spr, x, y, s) for spr, x, y in splash[i % 4]]
        out.append(draw(P(s=s, dx=-s, lift=max(0, b), sq=(1 if b < 0 else (-1 if b > 0 else 0)),
                          lean=1, look=1, htilt=(-4 if b > 0 else 0), wing=wings[i],
                          tail=(1 if b > 0 else 0), under=under)))
    return out


def waving():
    return [draw(P(wing=a, eyes="happy", beak="open", tail=t))
            for a, t in ((35, -1), (60, -2), (80, -2), (60, -2))]


def jumping():
    land = [at(DROP[1], 4, 40), at(DROP[0], 2, 44), at(DROP[1], 40, 40), at(DROP[0], 43, 44)]
    return [
        draw(P(sq=4, eyes="squint", beak="closed", wing=0)),
        draw(P(lift=7, sq=-2, wing=62, far=48, eyes="open", beak="o", tail=1)),
        draw(P(lift=10, wing=80, far=66, eyes="happy", beak="open", tail=1)),
        draw(P(lift=5, sq=-1, wing=40, far=30, eyes="open", beak="o")),
        draw(P(sq=3, eyes="happy", beak="smile", wing=6, fx=land)),
    ]


def failed():
    """Shock and a 1-px shake, then the duck tips forward and face-plants, tail in the
    air (a splash on impact); it lies there sad while a sweat drop slides down."""
    cross, sweat = fx_cross(), fx_sweat()
    out = []
    tip = ((-1, 0, 0), (1, -12, 4), (-1, -32, 8), (0, -60, 14))
    for i, (dx, t, ht) in enumerate(tip):
        fx = [(cross, 34 + dx, 4 + (i % 2))]
        if i == 3:
            fx += [(DROP[1], 2, 37), (DROP[0], 3, 32)]
        out.append(draw(P(dx=dx, tilt=t, htilt=ht, pivot=(30.0, 46.0), ground=True, center=24,
                          eyes="x", beak="gasp", blush=False, fx=fx)))
    for i in range(4):
        def drop(m, i=i):
            x0, y0, x1, y1 = m["head"]
            return (sweat, x1 - 4, y0 + 1 + 2 * i)
        out.append(draw(P(tilt=-60, htilt=14, pivot=(30.0, 46.0), ground=True, center=24,
                          eyes="sad", beak="frown", blush=False, tail=(0, -1, -1, 0)[i], fx=[drop])))
    return out


def waiting():
    """"SQUEAK!": the small "!" first, then the big one pops in with a stretch and a wide
    squeak; the beak pulses wide/open with the burst while the tail flicks (the duck's
    foot tap) and the "!" bobs 1 px."""
    big_, small = fx_exclaim(), fx_exclaim(big=False)
    bx = 32
    w = dict(eyes="wide")
    return [
        draw(P(beak="o", fx=[(small, bx, 5)], **w)),
        draw(P(beak="squeak", sq=-1, fx=[(big_, bx, 1), (burst(1), 0, 0)], **w)),
        draw(P(beak="open", tail=2, fx=[(big_, bx, 2), (burst(0), 0, 0)], **w)),
        draw(P(beak="squeak", fx=[(big_, bx, 3), (burst(1), 0, 0)], **w)),
        draw(P(beak="open", tail=2, fx=[(big_, bx, 2), (burst(0), 0, 0)], **w)),
        draw(P(beak="o", fx=[(big_, bx, 2)], **w)),
    ]


def working():
    out = []
    taps = ((1, 0), (0, 1), (1, 0), (0, 1), (1, 0), (0, 1))
    for i in range(6):
        out.append(draw(P(eyes="down", beak="closed", htilt=-6, laptop=i, taps=taps[i],
                          glow=(0.8 if i % 3 else 1.0), fx=[(fx_dots(1 + i // 2), 33, 4)])))
    return out


def review():
    bounce = (0, 1, 0, -1, 0, 0)
    sparkles = [
        (7, 9, (0, 1, 2, 1, 0, None)),
        (40, 14, (None, 0, 1, 2, 1, 0)),
        (41, 36, (2, 1, 0, None, 0, 1)),
    ]
    # droplets hop up beside the base and fall back (left side, then right side)
    splash = [
        [(DROP[0], 9, 42)],
        [(DROP[1], 7, 38)],
        [(DROP[1], 6, 37), (DROP[0], 39, 42)],
        [(DROP[0], 5, 41), (DROP[1], 40, 38)],
        [(DROP[1], 41, 37)],
        [(DROP[0], 42, 41)],
    ]
    out = []
    for i in range(6):
        fx = []
        for sx, sy, sizes in sparkles:
            sz = sizes[i]
            if sz is not None:
                spr = fx_sparkle(sz)
                fx.append((spr, sx - spr.w // 2, sy - spr.h // 2))
        up = i % 2 == 0
        out.append(draw(P(sq=-bounce[i], eyes="happy", beak="open", wing=(76 if up else 48),
                          far=(50 if up else 72), tail=(1 if up else 0), fx=fx, under=splash[i])))
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
