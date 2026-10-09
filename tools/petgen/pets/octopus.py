"""Octopus: a soft coral-pink octopus with a shiny dome, big eyes and curly tentacles.

    python3 tools/petgen/petgen.py build octopus

Rig: a toon-shaded dome (head and body in one) over six visible tentacles. The four
inner ones are legs that stand on the ground and curl outward at the tip; the two outer
ones are arms that hook up at the sides and do the waving, typing and cheering. Every
tentacle is a turtle path (root, heading, then segments that each turn by a set angle),
drawn as a tapered tube, rim-shaded after it is placed (so the natively drawn left run
keeps the light top-left) and outlined on its own layer, back to front.

Signature rows: the runs jet-propel (the dome tilts into the travel direction, lit in
world space, with the tentacles streaming behind and bubbles trailing), and the working
row multitasks (three tentacles type over the laptop lid while the left arm holds a
phone, the two devices clicking in turn).
"""
import math

from petgen import *

PET = {
    "id": "octopus",
    "displayName": "Octopus",
    "description": "Eight arms, eight threads, zero problems.",
}

# ---------------------------------------------------------------- palette
BASE = rgba("#FF8FA3")
SHADE = rgba("#E0607A")
DEEP = shade("#E0607A", 0.2)
HI = rgba("#FFC2CC")
GLOSS = tint("#FFC2CC", 0.7)
SPOT = rgba("#FFD6DD")
SPOT_SH = mix("#FFD6DD", "#E0607A", 0.4)
OUT = rgba("#6E2238")
TONES = [DEEP, SHADE, BASE, HI]
TH = [0.1, 0.48, 0.93]
BLUSH = rgba("#FF5F86")
TONGUE = rgba("#FF7A9C")
TAP = mix(SCREEN, WHITE, 0.4)
GLOWABLE = {BASE, SHADE, HI}

# ink cloud (failed) and bubbles (runs)
INKC = [rgba("#352C4C"), rgba("#4C4268"), rgba("#6C6290")]       # dark, base, light
INK_OUT = rgba("#211B32")
INK_THIN = rgba("#A49CC0")      # what the ink fades toward as it disperses
BUB = {"b": rgba("#8EC8F0"), "c": rgba("#D9F1FF"), "w": WHITE}
BUB_OUT = rgba("#4F86BF")
# phone (working)
PH_BODY, PH_EDGE = rgba("#5A6072"), rgba("#7D8599")      # the laptop's own greys
PH_OUT = outline_of("#7D8599", 0.55)

DW = 28                   # dome width
DH = 26                   # dome ellipse height (CUT rows are cut off the bottom)
CUT = 6
DBOT = 34                 # lowest dome fill row at rest (top fill row 15)

# ---------------------------------------------------------------- pose
REST = dict(
    dx=0, lift=0,            # whole-body offset (lift > 0 = up)
    dh=0, dwid=0,            # dome height / width change (squash and stretch)
    look=0,                  # face turn (px)
    eyes="open", mouth="smile", blush=True,
    curl=1.0,                # leg tip curl amount (1 = rest)
    spread=0.0,              # legs splay outward (+) or hang together (-)
    legs_up=(0, 0, 0, 0),    # per-leg lift (px), legs left to right
    arm_l=("rest", 1.0), arm_r=("rest", 1.0),
    laptop=None, typing=(0, 0, 0), glow=0.0, phone=None,
    fx=(), under=(),         # fx pasted last / behind everything
)


def P(**kw):
    p = dict(REST)
    p.update(kw)
    return p


# ---------------------------------------------------------------- tentacle geometry
def path(x, y, head, segs, step=0.2):
    """Turtle path from (x, y): heading in degrees (0 right, 90 down, 180 left, 270 up),
    then segments of (length, turn) that each turn linearly by `turn` degrees."""
    pts = [(x, y)]
    th = math.radians(head)
    for ln, turn in segs:
        n = max(1, int(round(ln / step)))
        dth, ds = math.radians(turn) / n, ln / n
        for _ in range(n):
            th += dth
            x += ds * math.cos(th)
            y += ds * math.sin(th)
            pts.append((x, y))
    return pts


def radii(pts, r0, r1, k=1.0):
    n = len(pts) - 1
    return [r0 + (r1 - r0) * (i / n) ** k for i in range(n + 1)]


def mirror_pts(pts):
    return [(48 - x, y) for x, y in pts]


def tube(pts, rs, col=BASE):
    c = Canvas()
    for (x0, y0), (x1, y1), r in zip(pts, pts[1:], rs[1:]):
        c.capsule(x0, y0, x1, y1, r, col)
    return c


def rim(layer, dark, mid, light):
    """Tube shading: bottom/right edge dark, top/left edge light, the rest mid."""
    out = Canvas(layer.w, layer.h)
    for y in range(layer.h):
        for x in range(layer.w):
            if not layer.opaque(x, y):
                continue
            if not layer.opaque(x + 1, y) or not layer.opaque(x, y + 1):
                col = dark
            elif light is not None and (not layer.opaque(x - 1, y) or not layer.opaque(x, y - 1)):
                col = light
            else:
                col = mid
            out.set(x, y, col)
    return out


def ground_fit(pts, rs, floor=47.0):
    """Shift a path vertically so its lowest tube edge sits at `floor` (47.0 puts the
    lowest fill on row 46 and the outline on the ground row 47)."""
    low = max(y + r for (x, y), r in zip(pts, rs))
    d = floor - low
    return [(x, y + d) for x, y in pts]


def shaded(pts, rs, back=False):
    t = tube(pts, rs)
    return rim(t, DEEP, SHADE, BASE) if back else rim(t, SHADE, BASE, HI)


def tentacle_layer(pts, rs, back=False):
    return shaded(pts, rs, back).outline(OUT)


# legs, left side (mirrored for the right)
LEGS = (
    # root, heading, stem (len, turn), sweep (len, turn), curl (len, turn), r0, r1
    ((21.5, 30.5), 95, (11.0, 12), (3.0, 73), (4.5, 185), 2.3, 0.9),     # inner
    ((17.0, 30.0), 108, (10.0, 22), (3.0, 50), (5.0, 195), 2.2, 0.9),    # outer
)


def leg_pts(i, side, p):
    """i = 0 inner leg, 1 outer leg; side -1 left, +1 right."""
    c, sp = p["curl"], p["spread"]
    root, head, stem, sweep, curl, r0, r1 = LEGS[i]
    segs = [(stem[0] - 1.5 * min(0, sp), stem[1] + 14 * sp), (sweep[0], sweep[1] - 8 * sp),
            (0.6, 0), (curl[0], curl[1] * c)]
    k = (1 - i) if side < 0 else 2 + i          # leg index left to right
    up = p["legs_up"][k]
    pts = path(root[0], root[1], head, segs)
    rs = radii(pts, r0, r1, 1.1)
    pts = ground_fit(pts, rs, 47.0 - p["lift"] - up)
    pts = [(x + p["dx"], y) for x, y in pts]
    if side > 0:
        pts = mirror_pts([(x - 2 * p["dx"], y) for x, y in pts])
    return pts, rs


# arm specs: ("rest", curl) hooked up at the side; ("up", angle, curl) raised, angle in
# degrees above the outward horizontal (curl < 0 flicks the tip outward); ("trail",)
# streaming down in the air; ("droop", 0) limp on the floor; ("none",) not drawn (the
# working row draws the phone arm itself).
def arm_pts(side, p, spec):
    kind = spec[0]
    if kind == "rest":
        c = spec[1]
        pts = path(13.5, 31.0, 145, [(5.0, 25), (3.0, 30), (5.5, 190 * c)])
        rs = radii(pts, 1.9, 0.8, 1.0)
        pts = [(x, y - p["lift"]) for x, y in pts]
    elif kind == "up":
        # a "(" curve bowed away from the dome: its chord points `a` degrees above the
        # outward horizontal, and the tip curls back toward the head by `c` degrees
        a, c = spec[1], spec[2]
        pts = path(13.0, 31.0, 150 + a, [(5.6, 40), (4.8, 20), (3.6, c)])
        rs = radii(pts, 1.9, 0.85, 1.0)
        pts = [(x, y - p["lift"]) for x, y in pts]
    elif kind == "trail":       # airborne, streaming down beside the legs
        pts = path(13.5, 31.0, 112, [(5.0, -12), (4.5, -8), (3.0, 70)])
        rs = radii(pts, 1.9, 0.8, 1.0)
        pts = [(x, y - p["lift"]) for x, y in pts]
    elif kind == "droop":
        pts = path(13.5, 31.0, 122, [(5.0, 42), (3.2, 16), (3.0, 105)])
        rs = radii(pts, 1.9, 0.8, 1.0)
        pts = ground_fit(pts, rs, 47.0 - p["lift"])
    else:
        raise ValueError(spec)
    pts = [(x + p["dx"], y) for x, y in pts]
    if side > 0:
        pts = mirror_pts([(x - 2 * p["dx"], y) for x, y in pts])
    return pts, rs


# ---------------------------------------------------------------- dome + face
def dome_box(p):
    dw = DW + p["dwid"]
    dh = DH + p["dh"]
    bot = DBOT - p["lift"]
    x = CX - dw // 2 + p["dx"]
    y = bot - (dh - CUT) + 1
    return x, y, dw, dh


def dome_layer(p):
    x, y, w, h = dome_box(p)
    L = Canvas().sphere(x, y, w, h, TONES, cut_bottom=CUT, thresholds=TH)
    # spots: light freckles on the crown, darker where they fall in shadow
    spots = Canvas()
    spots.rect(x + w - 8, y + 4, 3, 3, SPOT).set(x + w - 8, y + 4, CLEAR).set(x + w - 6, y + 6, CLEAR)
    spots.rect(x + w - 5, y + 9, 2, 2, SPOT)
    for yy in range(L.h):
        for xx in range(L.w):
            if spots.opaque(xx, yy) and L.opaque(xx, yy):
                L.set(xx, yy, SPOT if L.get(xx, yy) in (BASE, HI) else SPOT_SH)
    gx, gy = x + 6, y + 3
    L.set(gx, gy, GLOSS).set(gx + 1, gy, GLOSS).set(gx, gy + 1, GLOSS)
    return L.outline(OUT)


EYE = {
    # (dy in the 4x5 eye box, left pattern, right pattern or None = same unflipped,
    #  mirror the left pattern for the right eye). '#' ink, 'w' highlight.
    "open":   (0, ".##.\n#w##\n####\n####\n.##.", None, False),
    "half":   (2, "####\n####\n.##.", None, False),
    "closed": (3, "####", None, False),
    "down":   (2, ".##.\n#w##\n.##.", None, False),
    "happy":  (1, ".##.\n#..#", None, False),
    "squint": (1, "##..\n..##\n##..", None, True),
    "x":      (0, "#..#\n.##.\n.##.\n#..#", None, False),
    "sad":    (1, "..##\n.w##\n####\n.##.", "##..\n#w#.\n####\n.##.", False),
}

MOUTH = {   # 4 wide, centred
    "smile": "#..#\n.##.",
    "open":  "####\n#tt#\n.##.",
    "o":     ".##.\n#..#\n.##.",
    "small": ".##.",
    "flat":  "####",
    "frown": ".##.\n#..#",
}


def draw_face(c, p):
    x, y, w, h = dome_box(p)
    lk = p["look"]
    ey = y + 8
    ink = {"#": INK, "w": WHITE, "t": TONGUE}
    dy, left, right, mirror = EYE[p["eyes"]]
    lx = CX - 8 + p["dx"]                 # left eye box x 16..19, right 28..31
    rx = CX + 4 + p["dx"]
    c.grid(lx + lk, ey + dy, left, ink)
    c.grid(rx + lk, ey + dy, right or left, ink, flip=mirror)
    if p["blush"]:
        c.rect(lx - 1 + lk, ey + 5, 2, 1, BLUSH).rect(rx + 3 + lk, ey + 5, 2, 1, BLUSH)
    c.grid(CX - 2 + p["dx"] + lk, ey + 6, MOUTH[p["mouth"]], ink)


# ---------------------------------------------------------------- props + fx of our own
def bubble(size):
    g = {
        0: """
            bb
            bc
            """,
        1: """
            .bb.
            bwcb
            bccb
            .bb.
            """,
    }[size]
    s = sprite(g, BUB)
    return Canvas(s.w + 2, s.h + 2).paste(s, 1, 1).outline(BUB_OUT)


INK_PUFFS = (
    # (cx, cy, r) bumps per failed frame, back to front: a cloud bursts out from behind
    # the dome's left side, billows up and away from it, drifts off and is gone before
    # the loop restarts
    ((8.0, 27.5, 3.2), (5.5, 30.5, 2.4), (10.0, 24.5, 2.2)),
    ((7.0, 23.5, 3.6), (5.5, 28.5, 2.4), (10.0, 19.5, 2.8), (6.0, 18.5, 2.2)),
    ((6.5, 19.0, 3.4), (5.0, 24.5, 2.4), (10.0, 14.5, 3.4), (6.0, 12.5, 2.6), (14.0, 11.0, 2.4)),
    ((6.5, 12.5, 2.6), (10.0, 9.0, 3.0), (5.5, 7.0, 2.0), (14.0, 6.5, 2.0)),
    ((7.0, 5.5, 2.0), (11.0, 3.5, 1.6)),
    (),
    (),
    (),
)


def ink_cloud(i):
    """A billowing ink cloud for failed frame i: each bump is a small toon sphere lit from
    the top-left, overlapping back to front, then the whole cloud is outlined."""
    fade = {3: 0.3, 4: 0.55}.get(i, 0.0)        # the ink thins as it drifts off
    tones = [mix(t, INK_THIN, fade) for t in INKC]
    m = Canvas()
    for bx, by, r in INK_PUFFS[i]:
        d = 2 * r
        m.sphere(int(round(bx - r)), int(round(by - r)), int(round(d)), int(round(d)), tones,
                 thresholds=[0.35, 0.85])
    return m.outline(mix(INK_OUT, INK_THIN, fade * 0.6))


def phone(screen_n):
    """A tiny phone, screen toward us, with `screen_n` (0-3) message lines lit."""
    s = Canvas(6, 9)
    s.rect(0, 0, 6, 9, PH_BODY)
    s.rect(0, 0, 6, 1, PH_EDGE).rect(0, 0, 1, 9, PH_EDGE)
    s.rect(1, 1, 4, 6, SCREEN)
    s.set(1, 1, WHITE)
    for k in range(screen_n):
        s.rect(2 if k % 2 else 1, 2 + k * 2 - (1 if k else 0), 2 + (k % 2), 1, mix(SCREEN, PH_BODY, 0.6))
    s.rect(2, 7, 2, 1, PH_EDGE)
    return Canvas(8, 11).paste(s, 1, 1).outline(PH_OUT)


# ---------------------------------------------------------------- compose
def draw(p):
    c = Canvas()
    for spr, fx_x, fx_y in p["under"]:
        c.paste(spr, fx_x, fx_y)
    front_arms = []
    for side, key in ((-1, "arm_l"), (1, "arm_r")):
        spec = p[key]
        if spec[0] == "none":
            continue
        if spec[0] in ("rest", "droop", "trail"):
            pts, rs = arm_pts(side, p, spec)
            c.paste(tentacle_layer(pts, rs, back=True))
        elif spec[0] == "up":
            front_arms.append((side, spec))
    for i in (1, 0):
        for side in (-1, 1):
            pts, rs = leg_pts(i, side, p)
            c.paste(tentacle_layer(pts, rs, back=(i == 1)))
    for side, spec in front_arms:     # raised arms rise from behind the dome's sides
        pts, rs = arm_pts(side, p, spec)
        c.paste(tentacle_layer(pts, rs))
    d = dome_layer(p)
    draw_face(d, p)
    c.paste(d)
    if p["laptop"] is not None:
        draw_desk(c, p)
    if p["phone"] is not None:
        draw_phone(c, p)
    for spr, fx_x, fx_y in p["fx"]:
        c.paste(spr, fx_x, fx_y)
    return c


TYPERS = (17.5, 22.5, 27.5)       # x of the three typing tentacles (each hooks right)


def typer_layer(x0, down, hook, ly0):
    """A tentacle that rises from behind the lid, crests its top edge and hangs its tip
    over the front; a pressing tip hangs 2 px lower. Returns (behind, front) layers: the
    whole outlined tentacle, and the part that lies in front of the lid."""
    pts = path(x0, ly0 + 2.0 + down, 270, [(2.6, 0), (3.0, 180 * hook), (1.2 + 2 * down, 0)])
    rs = [1.35] * len(pts)
    full = shaded(pts, rs).outline(OUT)
    front = Canvas()
    for y in range(ly0, H):
        for x in range(W):
            if full.opaque(x, y) and (x + 0.5 - x0) * hook >= 1.0:
                front.set(x, y, full.get(x, y))
    return full, front


def draw_desk(c, p):
    lap = prop_laptop(p["laptop"], width=16)
    lx0, ly0 = CX - lap.w // 2, GROUND - lap.h + 1
    if p["glow"]:   # screen light on the lower dome just above the lid
        for yy in range(ly0 - 4, ly0 + 1):
            for xx in range(lx0, lx0 + lap.w):
                d = ((xx + 0.5 - CX) / 10.0) ** 2 + ((yy + 0.5 - ly0) / 4.0) ** 2
                q = c.get(xx, yy)
                if d <= 1 and q in GLOWABLE:
                    c.set(xx, yy, mix(q, SCREEN, 0.2 * p["glow"]))
    fronts = []
    for tx, down in zip(TYPERS, p["typing"]):
        full, front = typer_layer(tx, down, 1, ly0)
        c.paste(full)
        fronts.append(front)
    c.paste(lap, lx0, ly0)
    for f in fronts:
        c.paste(f)
    if p["typing"][2]:   # key-tap flick beside the lid's right corner (the cat's spot)
        c.set(lx0 + lap.w, ly0 + 1, TAP).set(lx0 + lap.w + 1, ly0, TAP)


def draw_phone(c, p):
    """Multitasking: the left arm cradles a tiny phone up beside the laptop; its tip curls
    up the phone's side and taps the screen (tap = 1 reaches in and flicks)."""
    n, tap = p["phone"]
    ph = phone(n)
    px0, py0 = 2, 22
    c.paste(ph, px0, py0)
    pts = path(13.0, 34.0, 176, [(4.5, 8), (2.5, 75), (2.5, 100 + 30 * tap), (2.0, 40 + 50 * tap)])
    rs = radii(pts, 1.9, 0.9, 1.0)
    c.paste(tentacle_layer(pts, rs))
    if tap:
        c.set(px0 + 8, py0 + 3, TAP).set(px0 + 9, py0 + 2, TAP)


# ---------------------------------------------------------------- run (jet propulsion)
def rot(lx, ly, t):
    """Local -> world offset for a dome tilted clockwise by t radians (y down)."""
    return lx * math.cos(t) - ly * math.sin(t), lx * math.sin(t) + ly * math.cos(t)


def tilted_dome(cx, cy, w, h, cut, deg):
    """The dome sphere tilted clockwise by `deg` about its ellipse centre (cx, cy), lit in
    world space (so the light stays top-left), with its spots and gloss in local space.
    Returns (layer, to_world) where to_world maps local offsets to world points."""
    t = math.radians(deg)
    rx, ry = w / 2.0, h / 2.0
    lx_, ly_, lz_ = LIGHT
    ln = math.sqrt(lx_ * lx_ + ly_ * ly_ + lz_ * lz_)
    lx_, ly_, lz_ = lx_ / ln, ly_ / ln, lz_ / ln
    cut_y = ry - cut
    spots = ((rx - 6.5, -ry + 5.5, 1.6), (rx - 3.5, -ry + 10.0, 1.1))
    L = Canvas()
    for py in range(H):
        for px in range(W):
            dx, dy = px + 0.5 - cx, py + 0.5 - cy
            lx = dx * math.cos(t) + dy * math.sin(t)
            ly = -dx * math.sin(t) + dy * math.cos(t)
            u, v = lx / rx, ly / ry
            if u * u + v * v > 1.0 or ly > cut_y:
                continue
            nz = math.sqrt(max(0.0, 1.0 - u * u - v * v))
            nx, ny = rot(u, v, t)
            d = nx * lx_ + ny * ly_ + nz * lz_
            idx = sum(1 for th in TH if d > th)
            col = TONES[idx]
            for sx, sy, sr in spots:
                if (lx - sx) ** 2 + (ly - sy) ** 2 <= sr * sr:
                    col = SPOT if col in (BASE, HI) else SPOT_SH
            L.set(px, py, col)
    gx, gy = rot(-rx + 7.0, -ry + 4.0, t)
    gx, gy = int(math.floor(cx + gx)), int(math.floor(cy + gy))
    L.set(gx, gy, GLOSS).set(gx + 1, gy, GLOSS).set(gx, gy + 1, GLOSS)

    def to_world(lx, ly):
        wx, wy = rot(lx, ly, t)
        return cx + wx, cy + wy
    return L, to_world


def draw_run(f, s):
    """s = +1 running right, -1 running left: jet propulsion. The dome tilts into the
    travel direction and the six tentacles stream out behind its base with a wave running
    down them. Geometry is laid out facing right and mirrored; all shading is computed
    after mirroring, so the light stays top-left."""
    c = Canvas()
    deg = f["tilt"]
    w, h = DW + f["dw"], DH + f["dh"]
    cx = 27.5 if s > 0 else 48 - 27.5
    cy = 24.0 - f["lift"]
    dome, to_world = tilted_dome(cx, cy, w, h, CUT, deg * s)
    ph, bunch = f["phase"], f["bunch"]
    base_ly = h / 2.0 - CUT - 1.0
    tents = (
        # local root x, heading offset from the dome's local "down", length scale, far?
        (-8.0, 44, 0.85, True), (-3.0, 26, 1.1, True), (2.5, 8, 0.9, True),
        (-5.5, 36, 1.0, False), (0.0, 17, 1.15, False), (5.0, 0, 0.8, False),
    )
    for k, (lrx, hoff, lsc, far) in enumerate(tents):
        rxw, ryw = to_world(lrx * s, base_ly)
        if s < 0:
            rxw = 48 - rxw
        amp = 16 + 8 * bunch
        wv = [amp * math.sin(ph - 1.0 * j + 1.3 * k) for j in range(4)]
        ln = (3.1 - 0.5 * bunch) * lsc
        head = 90 + deg + hoff * (1.0 + 0.35 * bunch) - 14 * bunch
        sweep = max(0.0, 168 - head) * (0.8 - 0.35 * bunch)
        segs = [(ln, sweep * 0.55 + wv[0]), (ln, sweep * 0.45 + wv[1]), (ln, wv[2]), (ln * 0.8, wv[3]),
                (2.4, 140 + 60 * bunch)]
        pts = path(rxw, ryw, head, segs)
        rs = radii(pts, 2.0 if far else 2.2, 0.8, 1.0)
        if s < 0:
            pts = mirror_pts(pts)
        c.paste(tentacle_layer(pts, rs, back=far))
    if s < 0:   # re-light the mirrored dome: render it natively at the mirrored centre
        dome, to_world = tilted_dome(cx, cy, w, h, CUT, -deg)
    d = dome.outline(OUT)
    # face: eyes stay level, the face centre rides the tilt and looks ahead
    fx_, fy_ = to_world(0.0, -h / 2.0 + 9.5)
    fcx = int(round(fx_)) + 2 * s
    ey = int(round(fy_))
    ink = {"#": INK, "w": WHITE, "t": TONGUE}
    _, pat, _, _ = EYE["open"]
    d.grid(fcx - 8, ey, pat, ink).grid(fcx + 4, ey, pat, ink)
    d.rect(fcx - 9, ey + 5, 2, 1, BLUSH).rect(fcx + 7, ey + 5, 2, 1, BLUSH)
    d.grid(fcx - 2, ey + 6, MOUTH[f.get("mouth", "smile")], ink)
    c.paste(d)
    for spr, bx, by in f["bubbles"]:
        c.paste(spr, bx if s > 0 else 48 - bx - spr.w, by)
    return c


# ---------------------------------------------------------------- rows
def idle():
    return [draw(P(**kw)) for kw in (
        dict(),
        dict(eyes="half", curl=0.97, arm_l=("rest", 0.95), arm_r=("rest", 0.95)),
        dict(eyes="closed", curl=0.94, arm_l=("rest", 0.9), arm_r=("rest", 0.9)),
        dict(dh=1, curl=0.88, arm_l=("rest", 0.82), arm_r=("rest", 0.82)),
        dict(dh=1, curl=0.9, arm_l=("rest", 0.85), arm_r=("rest", 0.85)),
        dict(curl=0.97, arm_l=("rest", 0.95), arm_r=("rest", 0.95)),
    )]


RUN_DROP = 5


def run(direction):
    s = 1 if direction == "right" else -1
    b0, b1 = bubble(0), bubble(1)
    bob = (0, 1, 2, 1, 0, 1, 2, 1)
    out = []
    for i in range(8):
        pulse = i % 4
        bubbles = []
        for spr, x0, y0, ph in ((b1, 6, 32, 0), (b0, 5, 26, 3), (b0, 10, 38, 5)):
            t = (i + ph) % 8
            if t < 6:
                bubbles.append((spr, x0 - t // 2, y0 - 3 * t))
        f = dict(lift=2 + bob[i], tilt=28, dh=(-1, 1, 2, 0)[pulse], dw=(1, -1, -2, 0)[pulse],
                 phase=2 * math.pi * i / 4, bunch=(1.0, 0.2, -0.5, 0.3)[pulse], bubbles=bubbles)
        # swim low: drop the whole jet 5 px so the dome stays near its resting height and
        # the pet doesn't pop up when a drag starts (family registration)
        out.append(draw_run(f, s).translated(0, RUN_DROP))
    return out


def waving():
    o = dict(eyes="happy", mouth="open")
    return [draw(P(arm_r=("up", a, c), **o)) for a, c in ((26, 110), (38, 40), (50, -40), (38, 40))]


def jumping():
    return [
        draw(P(dh=-4, dwid=4, spread=1.0, curl=1.1, eyes="squint", mouth="flat",
               arm_l=("rest", 1.1), arm_r=("rest", 1.1))),
        draw(P(lift=7, dh=2, dwid=-2, spread=-1.0, curl=0.5, eyes="open", mouth="o",
               arm_l=("trail",), arm_r=("trail",))),
        draw(P(lift=11, spread=0.6, curl=0.8, eyes="happy", mouth="open",
               arm_l=("up", 44, 10), arm_r=("up", 44, 10))),
        draw(P(lift=5, dh=1, dwid=-1, spread=-0.6, curl=1.2, eyes="open", mouth="o",
               arm_l=("up", 32, 170), arm_r=("up", 32, 170))),
        draw(P(dh=-3, dwid=4, spread=1.0, curl=1.05, eyes="happy", mouth="smile")),
    ]


def failed():
    cross, sweat = fx_cross(), fx_sweat()
    out = []
    for i, (dx, sq) in enumerate(((-1, 1), (1, 1), (-1, 2), (0, 2))):
        arms = ("up", 42 - 4 * i, 150 - 20 * i)       # flung up in shock, sinking
        out.append(draw(P(dx=dx, dh=-sq, eyes="x", mouth="frown", blush=False, curl=0.8,
                          arm_l=arms, arm_r=arms,
                          under=[(ink_cloud(i), 0, 0)], fx=[(cross, 35 + dx, 6 + (i % 2))])))
    for i in range(4):
        out.append(draw(P(dh=-3, dwid=2, eyes="sad", mouth="frown", blush=False, curl=0.65,
                          spread=0.4, arm_l=("droop", 0), arm_r=("droop", 0),
                          under=[(ink_cloud(4 + i), 0, 0)], fx=[(sweat, 32, 15 + 2 * i)])))
    return out


def waiting():
    big, small = fx_exclaim(), fx_exclaim(big=False)
    bx, sx = CX - big.w // 2, CX - small.w // 2
    o = dict(eyes="open", mouth="o")
    up_a, up_b = (("up", 46, 0), ("up", 46, 0)), (("up", 38, 90), ("up", 38, 90))
    return [
        draw(P(fx=[(small, sx, 6)], **o)),
        draw(P(dh=1, arm_l=up_a[0], arm_r=up_a[1], fx=[(big, bx, 1)], **o)),
        draw(P(arm_l=up_b[0], arm_r=up_b[1], legs_up=(0, 0, 0, 2), fx=[(big, bx, 2)], **o)),
        draw(P(arm_l=up_a[0], arm_r=up_a[1], fx=[(big, bx, 3)], **o)),
        draw(P(arm_l=up_b[0], arm_r=up_b[1], legs_up=(0, 0, 0, 2), fx=[(big, bx, 2)], **o)),
        draw(P(arm_l=up_a[0], arm_r=up_a[1], fx=[(big, bx, 2)], **o)),
    ]


def working():
    out = []
    # the laptop's right tip clicks on even frames, the phone on odd ones: two devices in turn
    typing = ((0, 1, 1), (1, 0, 0), (1, 0, 1), (0, 1, 0), (0, 1, 1), (1, 0, 0))
    for i in range(6):
        out.append(draw(P(eyes="down", mouth="small", laptop=i, typing=typing[i], arm_l=("none",),
                          look=(0, 0, -1, -1, 0, 0)[i],
                          phone=((1, 2, 2, 3, 3, 1)[i], i % 2), glow=(0.8 if i % 3 else 1.0),
                          fx=[(fx_dots(1 + i // 2), 33, 4)])))
    return out


def cheer(a):
    """Tip curl for a cheering arm: a low arm curls in, a high one flicks its tip out."""
    return 200 - 4.2 * a


def review():
    bounce = (0, 1, 0, -1, 0, 0)
    sparkles = [
        (6, 18, (0, 1, 2, 1, 0, None)),
        (41, 22, (None, 0, 1, 2, 1, 0)),
    ]
    heart = fx_heart()
    arms = ((48, 30), (40, 36), (30, 48), (36, 40), (48, 30), (40, 36))
    out = []
    for i in range(6):
        fx = []
        for sx, sy, sizes in sparkles:
            s = sizes[i]
            if s is not None:
                spr = fx_sparkle(s)
                fx.append((spr, sx - spr.w // 2, sy - spr.h // 2))
        fx.append((heart, 33, (6, 5, 4, 4, 5, 6)[i]))
        al, ar = arms[i]
        out.append(draw(P(dh=bounce[i], eyes="happy", mouth="open", curl=(1.0, 0.85, 0.7, 0.85, 1.0, 1.05)[i],
                          arm_l=("up", al, cheer(al)), arm_r=("up", ar, cheer(ar)), fx=fx)))
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
