"""Ghost: a small round terminal ghost with a dark screen for a face.

    python3 tools/petgen/petgen.py build ghost

Rig: a dome-topped sheet with a 3-scallop hem (procedural, so squash/stretch and the
hem ripple re-render cleanly), a dark rounded screen inset in the upper body that shows
green-phosphor terminal-glyph eyes, two stubby arms, and a flat shadow on the ground line.
The ghost never touches the ground: it hovers, and the shadow carries the ground contact
(its lowest row is the shadow's, on y=47; the shadow shrinks as the ghost rises).

Face glyphs are drawn on a 14x10 glass with a horizontal phosphor bleed (a dim pixel
either side of each lit run), which reads as a glowing CRT at 96x104 pt while keeping the
eyes and mouth vertically separate. Row notes:
  idle      block cursor eyes blink half -> underscore; 1-px hover; slow hem sway
  runs      re-rendered per direction (light stays top-left): lean + hem trail, front arm
            reaches ahead, wisps peel off the back of the hem
  waving    the upper arm holds out, the forearm swings about the elbow (35-80 degrees)
            so the raised mitten clears the dome
  waiting   wide 'O O' eyes and an 'o' mouth under the amber "!"; a 1-px hop that rocks
            left, then right
  failed    "x x" with a red scanline that tears the glyph rows, then a dimmed, sad slump
  running   eyes down, faint code scrolls across the top of the screen (period 6),
            short arms drop to mittens on the lid's corners and hop as they type
"""
import math

from petgen import *

PET = {
    "id": "ghost",
    "displayName": "Ghost",
    "description": "A friendly terminal ghost with a blinking cursor.",
}

# ---------------------------------------------------------------- palette
BASE = rgba("#EEEAFB")
SHADE = rgba("#C8C0EE")
HI = rgba("#FFFFFF")
OUTLINE = rgba("#4A4270")
DEEP = mix(SHADE, OUTLINE, 0.22)
TONES = [DEEP, SHADE, BASE]                # dark -> light (white is kept for the gloss)
SCR = rgba("#1D1A2B")                       # face screen
SCR_GLINT = mix(SCR, "#8E86C0", 0.22)
GLYPH = rgba("#9CF594")                    # warm green phosphor, apart from the robot's cyan LEDs
GLYPH_DIM = mix(GLYPH, SCR, 0.68)          # phosphor bloom around lit glyph pixels
GLYPH_FAINT = mix(GLYPH, SCR, 0.45)        # working: code scrolling past behind the eyes
RIM_DARK = mix(SHADE, OUTLINE, 0.12)       # inset bezel: top/left wall in shadow
RIM_LIGHT = HI                              # inset bezel: bottom/right lip catches light
SHADOW = [rgba("#AEA6D0"), rgba("#8E86BA")]   # ground shadow: rim, core (opaque, no outline)
BLUSH = rgba("#FFA9C6")
WISP_OUT = mix(OUTLINE, SHADE, 0.3)        # wisps get a softer outline than the body
INK_LOW = mix(GLYPH, SCR, 0.3)             # failed, slumped: the screen dims
GLOW = {t: mix(t, SCREEN, 0.3) for t in (BASE, SHADE, DEEP, HI)}

# ---------------------------------------------------------------- knobs (tuned by eye)
SW, SH = 14, 10          # face screen size (glass)
SCR_TOP = 6              # glass top, rows below the dome top
EYE_X = 2                # left eye's left column inside the glass (eyes are 2 px wide)
EYE_Y = 2                # eye top row inside the glass
MOUTH_Y = 7              # mouth top row inside the glass
BLOOM = True             # dim phosphor halo around lit glyph pixels
DOME = 1.10              # dome height / half-width
FLARE = 1.0              # px the skirt widens (each side) from the dome centre to the hem
GLOSS_ARC = (104, 142)   # degrees (from the dome centre) the gloss arc spans

# ---------------------------------------------------------------- pose
REST = dict(
    dx=0, lift=0,          # whole-body offset (lift > 0 = up)
    bw=30, bh=29,          # body box: width, height from dome top to the lowest hem tip
    lean=0,                # px the top of the body leans (runs)
    trail=0,               # px the hem streams backward (runs)
    hem=0.0,               # hem phase in px (ripple)
    drop=(0, 0, 0),        # extra px each of the 3 scallops hangs down (ripple)
    depth=3,               # scallop notch depth
    eyes="block", look=0,  # eye glyph; look shifts the glyphs inside the screen (px)
    face=0,                # screen offset (turning the face with the body)
    mouth="smile", blush=False,
    ink=None,              # glyph colour override (dim screen)
    arm_l=None, arm_r=None,   # None = resting nub, else angle in degrees (0 out, 90 up)
    arm_len=5,
    shoulder=0.0,          # px the shoulders sit outward (waving clears the body edge)
    arm_y=2.5,             # shoulder height below the dome centre
    wave=None,             # waving: right-arm overrides (shoulder, arm_y, upper=(deg, px))
    laptop=None, paws=(0, 0),   # working: 1 = that mitten is lifted off the lid this frame
    glitch=None,           # failed: (row inside the glass, tear px)
    code=None,             # working: frame index of the typing / scrolling text
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
    tip = 42 - p["lift"]                    # lowest hem-tip row
    top = tip - h + 1
    cx = CX + p["dx"]                       # centre line (pixel-edge coordinate)
    rx = w / 2.0
    ry = rx * DOME
    return dict(w=w, h=h, tip=tip, top=top, cx=cx, rx=rx, ry=ry, cy=top + ry)


def half_width(g, y):
    """Half-width of the sheet at pixel row y: a dome above its centre, then a skirt
    that flares slightly toward the hem."""
    yc = y + 0.5
    if yc < g["cy"]:
        v = (yc - g["cy"]) / g["ry"]
        return g["rx"] * math.sqrt(max(0.0, 1 - v * v))
    t = (yc - g["cy"]) / max(1.0, g["tip"] + 1 - g["cy"])
    return g["rx"] + FLARE * t * t


def hem_bottom(g, p, x):
    """Lowest filled row of column x: three rounded scallops with notches between."""
    wb = g["w"] + 2 * FLARE
    seg = wb / 3.0
    s = (x + 0.5 - (g["cx"] - wb / 2.0) - p["hem"]) / seg
    k = int(math.floor(s))
    f = s - k
    t = 2 * f - 1                           # -1 .. 1 across one scallop
    up = p["depth"] * (1 - math.sqrt(max(0.0, 1 - t * t))) ** 0.8
    drop = p["drop"][min(2, max(0, k))]
    return g["tip"] - int(round(up)) + drop


def body_layer(p):
    g = geom(p)
    ln = math.sqrt(sum(v * v for v in LIGHT))
    lx, ly, lz = (v / ln for v in LIGHT)
    c = Canvas()
    x_lo = int(math.floor(g["cx"] - g["rx"] - FLARE)) - 1
    x_hi = int(math.ceil(g["cx"] + g["rx"] + FLARE)) + 1
    low = max(1.0, g["tip"] + 1 - g["cy"])
    for x in range(x_lo, x_hi):
        bot = hem_bottom(g, p, x)
        for y in range(g["top"], bot + 1):
            hw = half_width(g, y)
            dxp = x + 0.5 - g["cx"]
            if abs(dxp) > hw:
                continue
            u = dxp / hw if hw > 0 else 0.0
            yc = y + 0.5
            if yc < g["cy"]:
                u = dxp / g["rx"]
                v = (yc - g["cy"]) / g["ry"]
            else:   # the skirt turns away a little toward the hem
                v = 0.32 * (yc - g["cy"]) / low
            nz = math.sqrt(max(0.0, 1 - u * u - v * v))
            d = u * lx + v * ly + nz * lz
            idx = sum(1 for t in (0.12, 0.46) if d > t)
            # the hem curls under: its last two rows turn one band darker
            if bot - y < 2 and idx > 0:
                idx -= 1
            c.set(x, y, TONES[idx])
    # gloss: the ring of pixels one in from the dome's edge, over an upper-left arc,
    # so it runs parallel to the outline as one clean line
    edge = {(x, y) for y in range(H) for x in range(W)
            if c.opaque(x, y) and any(not c.opaque(x + ox, y + oy) for ox, oy in ((1, 0), (-1, 0), (0, 1), (0, -1)))}
    lo, hi = GLOSS_ARC
    for y in range(g["top"], int(g["cy"])):
        for x in range(W):
            if not c.opaque(x, y) or (x, y) in edge:
                continue
            if not any((x + ox, y + oy) in edge for ox, oy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                continue
            ang = math.degrees(math.atan2(g["cy"] - (y + 0.5), (x + 0.5) - g["cx"]))
            if lo <= ang <= hi:
                c.set(x, y, HI)
    return c, g


def shear_rows(layer, p, g):
    """Lean the top forward and stream the hem backward."""
    lean, trail = p["lean"], p["trail"]
    if not lean and not trail:
        return layer
    return layer.sheared(lean + trail, g["top"], g["tip"]).translated(-trail, 0)


def shear_at(p, g, y):
    lean, trail = p["lean"], p["trail"]
    if not lean and not trail:
        return 0
    span = max(1, g["tip"] - g["top"])
    t = min(1.0, max(0.0, (g["tip"] - y) / span))
    return int(round((lean + trail) * t)) - trail


# ---------------------------------------------------------------- face screen
EYES = {
    # left-eye glyphs ('#' lit); the right eye is the mirror image around the screen
    # centre. (dy, grid) -- dy is relative to the eye slot top.
    "block":  (0, "##\n##\n##\n##"),
    "half":   (2, "##\n##"),
    "closed": (3, "##"),
    "down":   (3, "##\n##"),
    "happy":  (1, ".##.\n#..#\n#..#"),
    "squint": (0, "##..\n..##\n##.."),
    "x":      (0, "#..#\n.##.\n.##.\n#..#"),
    "sad":    (1, ".#\n##\n##"),
    "wide":   (0, ".##.\n#oo#\n#oo#\n.##."),     # waiting: round, wide-open 'O' eyes
}
# 'o' marks glass that stays dark: the phosphor bleed never fills a glyph's hole

MOUTH = {
    "smile": "#..#\n.##.",
    "small": ".##.",
    "open":  "####\n.##.",
    "o":     ".##.\n#..#\n.##.",
    "oh":    ".##.\n#oo#\n.##.",           # the same 'o' with a dark (unbled) centre
    "flat":  "####",
    "frown": ".##.\n#..#",
    "wavy":  "#.#.\n.#.#",
}


def bleed(lit, col):
    """CRT phosphor bleed: a dim pixel either side of each lit run, along the scanline
    only, so glyphs keep their vertical separation."""
    out = Canvas(lit.w, lit.h)
    for y in range(lit.h):
        for x in range(lit.w):
            if not lit.opaque(x, y) and (lit.opaque(x - 1, y) or lit.opaque(x + 1, y)):
                out.set(x, y, col)
    return out


def screen_box(p, g):
    sy = g["top"] + SCR_TOP
    sx = int(round(g["cx"])) - SW // 2 + p["face"] + shear_at(p, g, sy + SH // 2)
    return sx, sy


def glyph_w(pat):
    return max(len(r) for r in pat.split("\n"))


def draw_screen(c, p, g):
    sx, sy = screen_box(p, g)
    ink = rgba(p["ink"]) if p["ink"] else GLYPH
    # inset bezel ring around the glass
    ring = Canvas()
    ring.rect(sx - 1, sy - 1, SW + 2, SH + 2, RIM_DARK)
    ring.rect(sx, sy + SH, SW + 1, 1, RIM_LIGHT)        # bottom lip
    ring.rect(sx + SW, sy, 1, SH + 1, RIM_LIGHT)        # right lip
    for (x, y) in ((sx - 1, sy - 1), (sx + SW, sy - 1), (sx - 1, sy + SH), (sx + SW, sy + SH)):
        ring.set(x, y, CLEAR)
    c.paste(ring, inside=True)
    glass = Canvas()
    glass.rect(sx, sy, SW, SH, SCR)
    for (x, y) in ((sx, sy), (sx + SW - 1, sy), (sx, sy + SH - 1), (sx + SW - 1, sy + SH - 1)):
        glass.set(x, y, RIM_DARK if (y == sy or x == sx) and not (y == sy + SH - 1 and x == sx + SW - 1) else RIM_LIGHT)
    glass.set(sx + SW - 1, sy, RIM_DARK).set(sx, sy + SH - 1, RIM_DARK)
    lit, holes = Canvas(), Canvas()
    look = p["look"]
    dy, pat = EYES[p["eyes"]]
    gw = glyph_w(pat)
    eye_cx = sx + EYE_X + 1.0                    # centre (edge coords) of the 2-px eye slot
    lx = int(math.floor(eye_cx - gw / 2.0 + 0.01))
    rx = (2 * sx + SW - 1) - (lx + gw - 1)
    ey = sy + EYE_Y + dy
    for gx, flip in ((lx, False), (rx, True)):
        lit.grid(gx + look, ey, pat, {"#": ink, "o": CLEAR}, flip=flip)
        holes.grid(gx + look, ey, pat, {"#": CLEAR, "o": SCR}, flip=flip)
    if p["mouth"]:
        m = MOUTH[p["mouth"]]
        mw = glyph_w(m)
        lit.grid(sx + (SW - mw) // 2 + look, sy + MOUTH_Y, m, {"#": ink, "o": CLEAR})
        holes.grid(sx + (SW - mw) // 2 + look, sy + MOUTH_Y, m, {"#": CLEAR, "o": SCR})
    if BLOOM:
        glass.paste(bleed(lit, GLYPH_DIM), inside=True)
    glass.paste(holes, inside=True)
    glass.paste(lit, inside=True)
    if p["code"] is not None:
        draw_code(glass, sx, sy, p["code"])
    if p["glitch"] is not None:
        gy, tear = p["glitch"]
        # a torn scanline: the two rows under the red line slide sideways
        band = glass.crop(sx + 1, sy + gy + 1, SW - 2, 2)
        glass.rect(sx + 1, sy + gy + 1, SW - 2, 2, SCR)
        glass.paste(band, sx + 1 + tear, sy + gy + 1)
        glass.rect(sx, sy + gy + 1, 1, 2, SCR).rect(sx + SW - 1, sy + gy + 1, 1, 2, SCR)
        for x in range(sx, sx + SW):
            glass.set(x, sy + gy, RED)
    # glass glint, top-left
    glass.set(sx + 1, sy + 1, SCR_GLINT).set(sx + 2, sy + 1, SCR_GLINT).set(sx + 1, sy + 2, SCR_GLINT)
    c.paste(glass, inside=True)
    if p["blush"]:
        for bx in (sx - 3, sx + SW + 1):
            c.rect(bx, sy + SH - 1, 2, 1, BLUSH)


CODE = ["### ##.#", "  ## ###", "#### #", "  # ####", "## ###", "  ### #"]


def draw_code(glass, sx, sy, i):
    """Working: faint lines of code scroll up past the top of the screen, one line per
    frame, above the lowered eyes (period 6, so the loop is seamless)."""
    for r in range(2):
        line = CODE[(i + r) % len(CODE)]
        for j, ch in enumerate(line[:9]):
            if ch == "#":
                glass.set(sx + 3 + j, sy + 1 + 2 * r, GLYPH_FAINT)


# ---------------------------------------------------------------- arms
def arm_layer(side, p, g, angle, shoulder=None, arm_y=None, upper=None):
    """A stubby arm from the body's side. angle None = resting nub. upper=(deg, px) adds an
    elbow: the upper arm goes out at that angle first, then the forearm swings at `angle`
    (waving, so the raised hand stays clear of the dome)."""
    sy = g["cy"] + (p["arm_y"] if arm_y is None else arm_y)
    hw = half_width(g, int(sy))
    sh = p["shoulder"] if shoulder is None else shoulder
    sx = g["cx"] + side * (hw - 1.5 + sh) + shear_at(p, g, int(sy))
    pts = [(sx, sy)]
    if angle is None:
        pts.append((sx + side * 2.0, sy + 2.2))
        r = 1.6
    else:
        if upper:
            ua, ul = upper
            a = math.radians(ua)
            pts.append((sx + side * ul * math.cos(a), sy - ul * math.sin(a)))
        a = math.radians(angle)
        L = p["arm_len"]
        x0, y0 = pts[-1]
        pts.append((x0 + side * L * math.cos(a), y0 - L * math.sin(a)))
        r = 1.5
    ex, ey = pts[-1]
    layer = Canvas()
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        layer.capsule(x0, y0, x1, y1, r, SHADE)
    layer.disc(ex + 0.3, ey + 0.4, r + 0.4, SHADE)
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        layer.capsule(x0 - 0.4, y0 - 0.5, x1 - 0.4, y1 - 0.5, r - 0.5, BASE)
    layer.disc(ex - 0.2, ey - 0.2, r - 0.1, BASE)
    return layer.outline(OUTLINE)


LAP_ARM = dict(root_dx=11.0, root_y=29.5, hand_dx=8.5, hand_dy=2.0, lift=2.0, flick=1.0)


def laptop_arms(c, p, ly0):
    """Working: each arm drops from the front of the sheet, just outside the screen,
    down to a mitten that sits on the lid's top corner (no arm crosses the body);
    a typing mitten hops 2 px up off the lid and flicks 1 px out, clear of the screen."""
    k = LAP_ARM
    for side, up in zip((-1, 1), p["paws"]):
        sx, sy = CX + side * k["root_dx"], k["root_y"]
        hx = CX + side * (k["hand_dx"] + (k["flick"] if up else 0))
        hy = ly0 - k["hand_dy"] - (k["lift"] if up else 0)
        arm = Canvas()
        arm.capsule(sx, sy, hx, hy, 1.5, SHADE)
        arm.disc(hx + 0.2, hy + 0.3, 2.0, SHADE)
        arm.capsule(sx - 0.3, sy - 0.5, hx - 0.3, hy - 0.5, 0.9, BASE)
        arm.disc(hx - 0.3, hy - 0.3, 1.5, BASE)
        c.paste(arm.outline(OUTLINE))


# ---------------------------------------------------------------- shadow
def draw_shadow(c, p):
    if not p["shadow"]:
        return
    lift = max(0, p["lift"])
    w = 20 - 2 * int(round(lift / 3.0))
    x = CX - w // 2 + p["dx"]
    c.ellipse(x, 45, w, 3, SHADOW[0])
    c.ellipse(x + 3, 46, w - 6, 2, SHADOW[1])


# ---------------------------------------------------------------- compose
def draw(p):
    c = Canvas()
    draw_shadow(c, p)
    body, g = body_layer(p)
    body = shear_rows(body, p, g)
    draw_screen(body, p, g)
    c.paste(body.outline(OUTLINE))
    if p["laptop"] is not None:
        lap = prop_laptop(p["laptop"], width=16)
        lx0, ly0 = CX - lap.w // 2, GROUND - lap.h + 1
        # the laptop's light spills onto the sheet just above the lid
        for yy in range(ly0 - 4, ly0 + 1):
            for xx in range(lx0 + 1, lx0 + lap.w - 1):
                d = ((xx + 0.5 - CX) / 9.5) ** 2 + ((yy + 0.5 - ly0) / 4.0) ** 2
                q = c.get(xx, yy)
                if d <= 1 and q in (BASE, SHADE, DEEP, HI):
                    c.set(xx, yy, GLOW[q])
        c.paste(lap, lx0, ly0)
        laptop_arms(c, p, ly0)
    else:
        c.paste(arm_layer(-1, p, g, p["arm_l"]))
        if p["wave"]:
            c.paste(arm_layer(1, p, g, p["arm_r"], **p["wave"]))
        else:
            c.paste(arm_layer(1, p, g, p["arm_r"]))
    for item in p["fx"]:
        if callable(item):
            item(c)
        else:
            spr, fx_x, fx_y = item
            c.paste(spr, fx_x, fx_y)
    return c


# ---------------------------------------------------------------- rows
def idle():
    return [draw(P(**kw)) for kw in (
        dict(hem=0.0),
        dict(hem=0.8, eyes="half"),
        dict(hem=1.6, eyes="closed"),
        dict(hem=1.6, lift=1, drop=(0, 1, 0)),
        dict(hem=0.8, lift=1),
        dict(hem=0.0),
    )]


def _wisp(size):
    grids = {
        0: ".aa.\nabbb",
        1: "aa\nbb",
        2: "ab",
        3: "b",
    }
    spr = sprite(grids[size], {"a": BASE, "b": SHADE})
    return Canvas(spr.w + 2, spr.h + 2).paste(spr, 1, 1).outline(WISP_OUT)


WISPS = [_wisp(k) for k in range(4)]
# a wisp's life over the 8-frame cycle: (px behind the hem, px risen, size); None = gone
WISP_LIFE = [(1, 0, 0), (2, 1, 1), (4, 1, 2), (5, 2, 3), None, None, None, None]


def wisps(i, sgn):
    """Trailing wisp pixels: little puffs that peel off the back of the hem, drift back,
    rise and shrink. Placed against the hem's actual outline in the composed frame."""
    def fn(c):
        for wy, ph in ((38, 0), (42, 4)):
            life = WISP_LIFE[(i + ph) % 8]
            if life is None:
                continue
            back, rise, size = life
            spr = WISPS[size]
            y = wy - rise
            xs = [x for x in range(W) if c.opaque(x, y)]
            if not xs:
                continue
            if sgn > 0:
                x = xs[0] - back - spr.w + 1
                c.paste(spr, max(1, x), y - spr.h // 2)
            else:
                x = xs[-1] + back
                c.paste(spr.flipped(), min(W - 1 - spr.w, x), y - spr.h // 2)
    return fn


RUN_LIFT = (0, -1, 0, 1, 0, -1, 0, 1)        # 2-px float bob, "up" on the held last frame


def run(direction):
    sgn = 1 if direction == "right" else -1
    out = []
    for i, lift in enumerate(RUN_LIFT):
        # the front arm reaches ahead, the back arm trails low; both swing with the bob
        swing = 6 * lift
        back_arm, front_arm = -35 - swing, 10 + swing
        al, ar = (back_arm, front_arm) if sgn > 0 else (front_arm, back_arm)
        out.append(draw(P(dx=3 * sgn, lean=2 * sgn, trail=2 * sgn, face=sgn, look=sgn,
                          mouth="small", arm_l=al, arm_r=ar, arm_len=4.5,
                          hem=-1.5 * i * sgn, lift=lift, fx=[wisps(i, sgn)])))
    return out


def waving():
    # the upper arm holds out at 40 degrees and the forearm swings about the elbow
    # (35, 60, 80, 60), so the raised hand clears the dome by 1-2 px at the top of the
    # arc; the left nub stays exactly as in idle
    out = []
    for a, fore, upper, h in ((35, 2.5, 4.0, 0.0), (60, 3.5, 4.5, 0.8),
                              (80, 4.5, 4.5, 1.6), (60, 3.5, 4.5, 0.8)):
        out.append(draw(P(arm_r=a, arm_len=fore, eyes="happy", mouth="open", hem=h,
                          wave=dict(shoulder=0.5, arm_y=0.0, upper=(40, upper)))))
    return out


def jumping():
    return [
        draw(P(bw=34, bh=25, lift=-1, eyes="squint", mouth="flat", arm_l=-20, arm_r=-20,
               arm_len=4, depth=2)),                                          # anticipation
        draw(P(bw=26, bh=32, lift=7, eyes="block", mouth="o", arm_l=60, arm_r=60,
               depth=4, hem=1.0)),                                            # rise
        draw(P(lift=10, eyes="happy", mouth="open", arm_l=80, arm_r=80, arm_len=7,
               hem=2.0)),                                                     # peak
        draw(P(bw=28, bh=31, lift=5, eyes="block", mouth="o", arm_l=30, arm_r=30,
               depth=4, hem=3.0)),                                            # fall
        draw(P(bw=34, bh=26, eyes="happy", mouth="smile", arm_l=-15, arm_r=-15,
               arm_len=4, depth=2, hem=4.0)),                                 # land
    ]


def failed():
    cross = fx_cross()
    sweat = fx_sweat()
    out = []
    for i, (dx, sq) in enumerate(((-1, 0), (1, 1), (-1, 2), (0, 2))):
        out.append(draw(P(dx=dx, bw=30 + 2 * (sq // 2), bh=29 - sq, eyes="x", mouth=None,
                          arm_l=-65, arm_r=-65, arm_len=3.5, glitch=((8, 3, 1, 7)[i], (0, 1, -1, 0)[i]),
                          fx=[(cross, 33 + dx, 10 + (1 if i % 2 else 0))])))
    for i, sy in enumerate((0, 2, 4, 6)):
        out.append(draw(P(bw=32, bh=26, lift=-1, eyes="sad", mouth="frown", ink=INK_LOW,
                          arm_l=-75, arm_r=-75, arm_len=3, hem=0.5 * i,
                          fx=[(sweat, 35, 17 + sy)])))
    return out


def waiting():
    big, small = fx_exclaim(), fx_exclaim(big=False)
    bx = CX - big.w // 2
    sx = CX - small.w // 2
    e = dict(eyes="wide", mouth="oh")
    # after the pop the ghost hops 1 px and rocks 1 px left, then right; the '!' rides
    # the hop, so it bobs 1 px and keeps its 1-px gap above the dome
    return [
        draw(P(fx=[(small, sx, 4)], **e)),
        draw(P(bh=30, arm_l=20, arm_r=20, fx=[(big, bx, 1)], hem=0.8, **e)),
        draw(P(lift=1, lean=-1, fx=[(big, bx, 1)], hem=1.6, **e)),
        draw(P(fx=[(big, bx, 2)], hem=2.4, **e)),
        draw(P(lift=1, lean=1, fx=[(big, bx, 1)], hem=1.6, **e)),
        draw(P(fx=[(big, bx, 2)], hem=0.8, **e)),
    ]


def working():
    out = []
    paws = ((1, 0), (0, 1), (1, 0), (0, 0), (0, 1), (1, 0))
    for i in range(6):
        dots = fx_dots(1 + (i // 2))
        out.append(draw(P(eyes="down", mouth=None, laptop=i, paws=paws[i], code=i,
                          shadow=False, hem=0.5 * i, fx=[(dots, 33, 4)])))
    return out


def review():
    bounce = (0, 1, 0, -1, 0, 0)
    sparkles = [
        (6, 17, (0, 1, 2, 1, 0, None)),
        (40, 11, (None, 0, 1, 2, 1, 0)),
        (42, 27, (2, 1, 0, None, 0, 1)),
    ]
    out = []
    for i in range(6):
        fx = []
        for sx, sy, sizes in sparkles:
            s = sizes[i]
            if s is not None:
                spr = fx_sparkle(s)
                fx.append((spr, sx - spr.w // 2, sy - spr.h // 2))
        out.append(draw(P(bh=29 + bounce[i], eyes="happy", mouth="open", blush=True,
                          arm_l=25 + 15 * (i % 2), arm_r=25 + 15 * ((i + 1) % 2),
                          hem=0.6 * i, fx=fx)))
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
