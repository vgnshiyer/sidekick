"""Robot: a tiny boxy robot whose antenna bulb is the state cue.

    python3 tools/petgen/petgen.py build robot

Rig: a rounded plate head with a recessed dark face screen (LED eyes + mouth), ear
bolts, a small torso plate, stubby legs with boots, thin arms with round hands, and an
antenna whose bulb colour follows the state (idle cyan, waiting amber, failed red,
review green, working blue). Every part is drawn from the pose numbers and outlined on
its own layer, back to front, so squash and stretch re-render clean pixels.
"""
import math

from petgen import *

PET = {
    "id": "robot",
    "displayName": "Robot",
    "description": "A tiny robot whose antenna tells you when you're needed.",
}

# ---------------------------------------------------------------- palette
PLATE = rgba("#DCE3EA")
PLATE_SH = rgba("#AEB9C6")
PLATE_HI = WHITE
PLATE_LT = mix(PLATE, WHITE, 0.55)
PLATE_DK = rgba("#8B97A8")
SIDE_LIT = mix(PLATE, PLATE_SH, 0.8)        # 3/4 side panel facing left (toward the light)
SIDE_SH = mix(PLATE_SH, PLATE_DK, 0.6)      # 3/4 side panel facing right (in shadow)
OUT = rgba("#2B3440")
JOINT = [rgba("#4F5A6C"), rgba("#6F7B8E"), rgba("#97A3B4")]      # dark, base, light
FACE = rgba("#18202B")
GLASS = rgba("#2C394B")
LED = rgba("#49D3F2")
LED_HI = rgba("#D2F8FF")
LED_LO = rgba("#2A8DB2")
BLUSH = rgba("#E2668F")
ERR = rgba("#FF5D62")
ERR_HI = rgba("#FFD0D2")
BLUE = rgba("#4D86FF")
BULB = {"cyan": LED, "amber": AMBER, "red": RED, "green": GREEN, "blue": BLUE}
SMOKE = [rgba("#9AA2AE"), rgba("#C2C8D1"), rgba("#E6EAEE")]
SMOKE_OUT = rgba("#727B89")
TAP = mix(SCREEN, WHITE, 0.4)

# ---------------------------------------------------------------- pose
REST = dict(
    dx=0, lift=0,             # whole-body offset (lift > 0 = up)
    lean=0,                   # torso + head shift over planted feet (runs)
    hw=24, hh=14,             # head box
    hdx=0,                    # head lean (px) relative to the torso
    tw=16, th=7,              # torso box
    leg=3,                    # visible leg length (squash 1-2, stretch 4)
    look=0,                   # face turn in px (screen +look//2, eyes +look)
    turn=0,                   # 3/4 view toward +1 (right) / -1 (left): side panels show
    eyes="open", mouth="smile", eye_col="led", blush=False,
    ant="up", bulb="cyan", bulb_on=True, rays=False,
    arm_l=-62, arm_r=-62, arm_len=5.0,
    feet=((0, 0), (0, 0)),    # (dx, lift) per foot, left then right
    laptop=None, paws=(0, 0), glow=0.0,
    fx=(),
)


def P(**kw):
    p = dict(REST)
    p.update(kw)
    return p


def layout(p):
    """Part boxes (fill pixels; outlines go outside) from the pose numbers."""
    base = GROUND - p["lift"]                      # 47 at rest
    tb = base - 6 - p["leg"]                       # torso bottom fill row (38)
    tt = tb - p["th"] + 1                          # torso top fill row (32)
    hb = tt - 2                                    # head bottom fill row (30)
    ht = hb - p["hh"] + 1                          # head top fill row (17)
    tx = CX - p["tw"] // 2 + p["dx"] + p["lean"]
    hx = CX - p["hw"] // 2 + p["dx"] + p["lean"] + p["hdx"]
    return dict(base=base, tb=tb, tt=tt, hb=hb, ht=ht, tx=tx, hx=hx)


# ---------------------------------------------------------------- helpers
PROF = {0: (), 1: (1,), 2: (2, 1), 3: (3, 1, 1)}


def rr_mask(x, y, w, h, r):
    prof = PROF[r]
    pts = set()
    for j in range(h):
        k = min(j, h - 1 - j)
        ins = prof[k] if k < len(prof) else 0
        for i in range(ins, w - ins):
            pts.add((x + i, y + j))
    return pts


def plate(c, pts, top=PLATE_HI, base=PLATE, left=PLATE_LT, right=PLATE_SH,
          bottom=(PLATE_SH, PLATE_DK)):
    """Bevel-shade a filled mask: lit top/left edges, shaded right edge and bottom rows."""
    for (x, y) in pts:
        up = (x, y - 1) in pts
        dn1 = (x, y + 1) in pts
        dn2 = (x, y + 2) in pts
        lf = (x - 1, y) in pts
        rt = (x + 1, y) in pts
        if not dn1:
            col = bottom[1]
        elif not dn2 and bottom[0] is not None:
            col = bottom[0]
        elif not up:
            col = top if rt else base
        elif not rt:
            col = right
        elif not lf:
            col = left
        else:
            col = base
        c.set(x, y, col)
    return c


# ---------------------------------------------------------------- parts
def draw_legs_feet(c, p, L, front):
    """Legs + boots. A foot lifted 2+ px is drawn in front (front=True pass)."""
    legs, feet = Canvas(), Canvas()
    any_part = False
    for side, (fdx, flift) in zip((-1, 1), p["feet"]):
        if (flift >= 2) != front:
            continue
        any_part = True
        fx0 = (16 if side < 0 else 26) + p["dx"] + fdx
        fy = min(GROUND - 3, L["base"] - 3 - flift)          # boot top fill row
        lx = fx0 + 2 if side < 0 else fx0 + 1
        top = L["tb"] - 1
        legs.rect(lx, top, 3, fy - top + 1, JOINT[1])
        legs.rect(lx, top, 1, fy - top + 1, JOINT[2])
        legs.rect(lx + 2, top, 1, fy - top + 1, JOINT[0])
        pts = rr_mask(fx0, fy, 6, 3, 1)
        pts |= {(fx0, fy + 1), (fx0 + 5, fy + 1)}
        plate(feet, pts, top=PLATE_HI, bottom=(None, JOINT[0]))
    if any_part:
        c.paste(legs.outline(OUT))
        c.paste(feet.outline(OUT))


def boot_pts(x0, y0, t):
    """A 7x3 boot seen 3/4, its toe pointing toward t (+1 right, -1 left)."""
    rows = (".pppp..", "ppppppp", ".pppppp")
    pts = set()
    for j, r in enumerate(rows):
        for i, ch in enumerate(r if t > 0 else r[::-1]):
            if ch == "p":
                pts.add((x0 + i, y0 + j))
    return pts


def draw_legs_feet_turn(c, p, L):
    """3/4 legs: the far leg first, then the near one (its outline cuts the far boot).
    Each leg slants from its hip under the torso to a boot that strides along x."""
    t = p["turn"]
    tcx = L["tx"] + p["tw"] / 2.0
    near, far = p["feet"]                     # (stride dx along the run, lift)
    for which, (fdx, flift) in (("far", far), ("near", near)):
        s = t if which == "far" else -t
        x0 = (19 if s < 0 else 21) if t > 0 else (22 if s > 0 else 20)
        x0 += p["dx"] + t * fdx
        fy = min(GROUND - 3, L["base"] - 3 - flift)
        hip = tcx + s * 1.5
        ank = x0 + (2.5 if t > 0 else 4.5)
        leg = Canvas().capsule(hip, L["tb"] - 0.5, ank, fy + 0.5, 1.5, JOINT[1])
        for y in range(leg.h):
            xs = [x for x in range(leg.w) if leg.opaque(x, y)]
            if xs:
                leg.set(xs[0], y, JOINT[2]).set(xs[-1], y, JOINT[0])
        boot = plate(Canvas(), boot_pts(x0, fy, t), top=PLATE_HI, bottom=(None, JOINT[0]))
        c.paste(leg.outline(OUT))
        c.paste(boot.outline(OUT))


def split_panel(pts, x0, w, t, sp):
    """Split a part mask into (front, side) for a 3/4 turn: the side panel is the sp
    columns on the trailing edge (left when turned right)."""
    if t > 0:
        side = {q for q in pts if q[0] < x0 + sp}
    else:
        side = {q for q in pts if q[0] >= x0 + w - sp}
    return pts - side, side


def shade_side(c, side, t):
    """Side panel: lit when it faces left (turned right), shadowed when it faces right."""
    if t > 0:
        plate(c, side, top=PLATE, base=SIDE_LIT, left=SIDE_LIT, right=SIDE_LIT,
              bottom=(PLATE_DK, PLATE_DK))
    else:
        plate(c, side, top=PLATE_SH, base=SIDE_SH, left=SIDE_SH, right=PLATE_DK,
              bottom=(PLATE_DK, PLATE_DK))


def draw_torso(c, p, L):
    t = Canvas()
    pts = rr_mask(L["tx"], L["tt"], p["tw"], p["th"], 1)
    turn = p["turn"]
    if turn:
        front, side = split_panel(pts, L["tx"], p["tw"], turn, 3)
        plate(t, front, top=PLATE_SH, bottom=(PLATE_SH, PLATE_DK))
        shade_side(t, side, turn)
    else:
        plate(t, pts, top=PLATE_SH, bottom=(PLATE_SH, PLATE_DK))
    for (x, y) in pts:                 # the head shades the top row
        if y == L["tt"]:
            t.set(x, y, PLATE_DK)
    # chest: a small dark plate with one LED
    cx = L["tx"] + p["tw"] // 2
    if turn:
        cx += 2 if turn > 0 else -2
    cy = L["tt"] + 2
    t.rect(cx - 3, cy, 6, 2, JOINT[0])
    t.set(cx - 2, cy, LED).set(cx - 2, cy + 1, LED_LO)
    t.rect(cx, cy, 2, 1, JOINT[1])
    c.paste(t.outline(OUT))


# antenna poses: grid rows from the top; the bottom row sits under the head's outline.
# 'col' is the grid column that lands on x = 23 (left stem column at rest).
_STEM = "LM"
ANT = {
    "up": (2, """
        .bbbb.
        bwlbbb
        blbbbd
        bbbbdd
        .bddd.
        ..LM..
        ..LM..
        ..LM..
        ..LM..
        """),
    "short": (2, """
        .bbbb.
        bwlbbb
        blbbbd
        bbbbdd
        .bddd.
        ..LM..
        ..LM..
        """),
    "long": (2, """
        .bbbb.
        bwlbbb
        blbbbd
        bbbbdd
        .bddd.
        ..LM..
        ..LM..
        ..LM..
        ..LM..
        ..LM..
        """),
    "lean+": (2, """
        ..bbbb.
        .bwlbbb
        .blbbbd
        .bbbbdd
        ..bddd.
        ...LM..
        ..LM...
        ..LM...
        ..LM...
        """),
    "lean-": (3, """
        .bbbb..
        bwlbbb.
        blbbbd.
        bbbbdd.
        .bddd..
        ..LM...
        ...LM..
        ...LM..
        ...LM..
        """),
    "tilt": (2, """
        ......bbbb.
        .....bwlbbb
        .....blbbbd
        .....bbbbdd
        ....LMbddd.
        ...LM......
        ..LM.......
        ..LM.......
        """),
}


def bulb_pal(col, level=1.0):
    """Bulb ramp at a brightness level (1 = lit with a white gloss, 0 = off)."""
    lit = {"b": rgba(col), "l": tint(col, 0.5), "w": WHITE, "d": shade(col, 0.24)}
    off = {"b": shade(col, 0.34), "l": shade(col, 0.2), "w": shade(col, 0.08), "d": shade(col, 0.5)}
    t = float(level)
    return {k: mix(off[k], lit[k], t) for k in lit}


def antenna_layer(p, L):
    col0, g = ANT[p["ant"]]
    rows = [r.strip() for r in g.strip().split("\n")]
    pal = dict(bulb_pal(BULB[p["bulb"]], p["bulb_on"]))
    pal["L"], pal["M"] = JOINT[2], JOINT[1]
    a = Canvas()
    gx = L["hx"] + p["hw"] // 2 - 1 - col0
    gy = L["ht"] - len(rows)
    a.grid(gx, gy, "\n".join(rows), pal)
    a.outline(OUT)
    if p["rays"] and p["bulb_on"] >= 1:
        # bulb centre: find the bulb pixels' bbox
        bx = [gx + i for j, r in enumerate(rows) for i, ch in enumerate(r) if ch in "bwld"]
        by = [gy + j for j, r in enumerate(rows) for i, ch in enumerate(r) if ch in "bwld"]
        x0, x1, y0, y1 = min(bx), max(bx), min(by), max(by)
        rc = rgba(BULB[p["bulb"]])
        cy = (y0 + y1) // 2
        a.set(x0 - 3, cy, rc).set(x0 - 4, cy, rc)
        a.set(x1 + 3, cy, rc).set(x1 + 4, cy, rc)
        a.set(x0 - 2, y0 - 2, rc).set(x0 - 3, y0 - 3, rc)
        a.set(x1 + 2, y0 - 2, rc).set(x1 + 3, y0 - 3, rc)
    return a


def draw_head(c, p, L):
    hx, ht, hw, hh = L["hx"], L["ht"], p["hw"], p["hh"]
    # ear bolts behind the head
    e = Canvas()
    ey = ht + 4
    eh = max(4, hh - 9)
    turn = p["turn"]
    for side, ex in ((-1, hx - 3), (1, hx + hw)):
        if turn:
            # near ear sits on the side panel (sticks out 2), far ear peeks out 1
            ex -= side if side == -turn else 2 * side
        elif p["look"] * side >= 3:
            ex -= side          # far ear tucks behind the head on a 3/4 turn
        e.rect(ex, ey, 3, eh, JOINT[1])
        e.rect(ex, ey, 3, 1, JOINT[2])
        e.rect(ex, ey + eh - 1, 3, 1, JOINT[0])
    c.paste(e.outline(OUT))
    h = Canvas()
    pts = rr_mask(hx, ht, hw, hh, 2)
    gx0 = hx
    if turn:
        front, side = split_panel(pts, hx, hw, turn, 4)
        plate(h, front, left=PLATE_HI, bottom=(PLATE_SH, PLATE_DK))
        shade_side(h, side, turn)
        gx0 = hx + 4 if turn > 0 else hx
    else:
        plate(h, pts, bottom=(PLATE_SH, PLATE_DK))
    h.set(gx0 + 2, ht + 1, PLATE_HI).set(gx0 + 3, ht + 1, PLATE_HI).set(gx0 + 1, ht + 2, PLATE_HI)
    c.paste(h.outline(OUT))
    # recessed face screen
    shift = int(round(p["look"] / 2.0))
    sx, sy = hx + 3 + shift, ht + 2
    sw, sh = hw - 6, hh - 4
    if turn:   # the screen sits on the front plate, foreshortened by 2
        sx, sw = (hx + 6 if turn > 0 else hx + 2), hw - 8
    spts = rr_mask(sx, sy, sw, sh, 1)
    for (x, y) in spts:   # bezel: shadowed top/left walls, lit bottom/right walls
        for (dx, dy, col) in ((0, -1, PLATE_SH), (-1, 0, PLATE_SH), (1, 0, PLATE_LT), (0, 1, PLATE_LT)):
            q = (x + dx, y + dy)
            if q not in spts and q in pts:
                c.set(q[0], q[1], col)
    for (x, y) in spts:
        c.set(x, y, FACE)
    # glass glare in the top-right corner
    c.set(sx + sw - 3, sy + 1, GLASS).set(sx + sw - 2, sy + 1, GLASS).set(sx + sw - 2, sy + 2, GLASS)
    draw_face(c, p, sx, sy, sw, sh)


EYE = {
    # left-eye grids (4 wide); (dy in the screen, mirror for the right eye, grid)
    "open":   (1, False, ".bb.\nbwbb\nbbbb\nbbbb\n.bb."),
    "half":   (3, False, "bbbb\nbbbb\n.bb."),
    "closed": (4, False, "bbbb"),
    "down":   (2, False, "bbbb\nbwbb\nbbbb\n.bb."),
    "happy":  (2, False, ".bb.\nbbbb\nb..b"),
    "squint": (1, True, "b...\n.bb.\n..bb\n.bb.\nb..."),
    "x":      (1, False, "b..b\nb..b\n.bb.\nb..b\nb..b"),
    "sad":    (2, True, "..bb\n.bbb\nbbbb\n.bb."),
}

MOUTH = {
    # (dy in the screen, grid)
    "smile": (7, "b..b\n.bb."),
    "open":  (7, "bbbb\n.bb."),
    "o":     (7, ".bb.\n.bb."),
    "small": (7, ".bb."),
    "flat":  (7, "bbbb"),
    "frown": (7, ".bb.\nb..b"),
    "none":  (7, ""),
}


def draw_face(c, p, sx, sy, sw, sh):
    if p["eye_col"] == "err":
        pal = {"b": ERR, "w": ERR_HI}
    elif p["eye_col"] == "dim":
        pal = {"b": LED_LO, "w": LED}
    else:
        pal = {"b": LED, "w": LED_HI}
    shift = int(round(p["look"] / 2.0))
    e = p["look"] - shift
    dy, mirror, pat = EYE[p["eyes"]]
    lx = sx + 2 + e
    rx = sx + sw - 6 + e
    if p["turn"]:   # 3/4: eyes 8 apart, crowded toward the turn
        lx, rx = (sx + 3, sx + 11) if p["turn"] > 0 else (sx + 1, sx + 9)
        e = 1 if p["turn"] > 0 else -1
    c.grid(lx, sy + dy, pat, pal)
    c.grid(rx, sy + dy, pat, pal, flip=mirror)
    if p["blush"]:   # pink screen pixels under the outer corner of each eye
        c.rect(lx - 1, sy + 6, 2, 1, BLUSH).rect(rx + 3, sy + 6, 2, 1, BLUSH)
    mdy, m = MOUTH[p["mouth"]]
    if m:
        c.grid(sx + sw // 2 - 2 + e, sy + mdy, m, pal)


HAND = """
    .wp.
    wppd
    pppd
    .dd.
    """


def _snap(v):
    return int(math.floor(v + 0.5))


def limb_layer(sx, sy, ex, ey, elbow=None, side=-1):
    """Thin joint arm from the shoulder (optionally bent at an elbow), ending in a round
    4x4 plate hand centred on (ex, ey). The right hand snaps as the mirror of the left
    so symmetric poses stay pixel-symmetric."""
    layer = Canvas()
    if elbow:
        layer.capsule(sx, sy, elbow[0], elbow[1], 0.95, JOINT[1])
        layer.capsule(elbow[0], elbow[1], ex, ey, 0.95, JOINT[1])
    else:
        layer.capsule(sx, sy, ex, ey, 0.95, JOINT[1])
    hx = _snap(ex) - 2 if side < 0 else 44 - (_snap(48 - ex) - 2)
    hand = Canvas().grid(hx, _snap(ey) - 2, HAND, {"w": PLATE_HI, "p": PLATE, "d": PLATE_SH})
    layer.outline(OUT)
    layer.paste(hand.outline(OUT))
    return layer


def shoulder(p, L, side):
    sx = (L["tx"] + 0.5) if side < 0 else (L["tx"] + p["tw"] - 0.5)
    return sx, L["tt"] + 1.5


def arm_layer(p, L, side, spec):
    """spec: an angle (straight arm, 0 = out, 90 = up, -90 = down) or
    (elbow_dx, elbow_dy, forearm_angle, forearm_len) for a bent arm (wave, hooray)."""
    sx, sy = shoulder(p, L, side)
    if isinstance(spec, tuple):
        edx, edy, a2, l2 = spec
        exl, eyl = sx + side * edx, sy + edy
        a = math.radians(a2)
        return limb_layer(sx, sy, exl + side * l2 * math.cos(a), eyl - l2 * math.sin(a),
                          (exl, eyl), side)
    a = math.radians(spec)
    ln = p["arm_len"]
    return limb_layer(sx, sy, sx + side * ln * math.cos(a), sy - ln * math.sin(a), side=side)


def run_arm_layer(p, L, which, ang):
    """3/4 arm swinging along the run: ang in degrees from straight down, + = forward.
    The near arm hangs off the side panel, the far one off the far edge."""
    t = p["turn"]
    s = -t if which == "near" else t
    tcx = L["tx"] + p["tw"] / 2.0
    sx, sy = tcx + s * (p["tw"] / 2.0 - 1.5), L["tt"] + 1.5
    ln = p["arm_len"]
    if which == "far" and ang > 25:   # pumping forward past the chest: the forearm bends up
        a, b = math.radians(ang - 10), math.radians(ang + 45)
        ex, ey = sx + t * 3.0 * math.sin(a), sy + 3.0 * math.cos(a)
        return limb_layer(sx, sy, ex + t * (ln - 2.5) * math.sin(b), ey + (ln - 2.5) * math.cos(b),
                          (ex, ey), side=s)
    a = math.radians(ang)
    return limb_layer(sx, sy, sx + t * ln * math.sin(a), sy + ln * math.cos(a), side=s)


def draw(p):
    L = layout(p)
    c = Canvas()
    turn = p["turn"]
    if turn:
        draw_legs_feet_turn(c, p, L)
        c.paste(run_arm_layer(p, L, "far", p["arm_r"]))
    else:
        draw_legs_feet(c, p, L, front=False)
    draw_torso(c, p, L)
    c.paste(antenna_layer(p, L))
    draw_head(c, p, L)
    if turn:
        c.paste(run_arm_layer(p, L, "near", p["arm_l"]))
    else:
        draw_legs_feet(c, p, L, front=True)
    if p["laptop"] is not None:
        lap = prop_laptop(p["laptop"], width=16)
        lx0, ly0 = CX - lap.w // 2, GROUND - lap.h + 1
        if p["glow"]:
            for yy in range(ly0 - 7, ly0 + 1):
                for xx in range(lx0, lx0 + lap.w):
                    d = ((xx + 0.5 - CX) / 11.0) ** 2 + ((yy + 0.5 - ly0) / 7.0) ** 2
                    q = c.get(xx, yy)
                    if d <= 1 and q[3] and q not in (OUT, FACE, LED, LED_HI, LED_LO):
                        c.set(xx, yy, mix(q, SCREEN, 0.35 * p["glow"]))
        c.paste(lap, lx0, ly0)
        for side, down in zip((-1, 1), p["paws"]):
            # both hands reach over the lid's top edge to the keys; the pressing one
            # dips 2 px
            sx, sy = shoulder(p, L, side)
            c.paste(limb_layer(sx, sy, CX + side * 4.5, 37.0 if down else 35.0, side=side))
        for side, down in zip((-1, 1), p["paws"]):
            if down:
                tx = CX + side * 13 - (1 if side < 0 else 0)
                c.set(tx, 37, TAP).set(tx + side, 36, TAP)
    elif not turn:
        for side, key in ((-1, "arm_l"), (1, "arm_r")):
            c.paste(arm_layer(p, L, side, p[key]))
    for spr, fx_x, fx_y in p["fx"]:
        c.paste(spr, fx_x, fx_y)
    return c


# ---------------------------------------------------------------- fx of our own
def smoke(size):
    g = {
        0: """
            .bb.
            bccb
            abba
            .aa.
            """,
        1: """
            ..bb..
            .bccb.
            bcccbb
            bbbbba
            .aaaa.
            """,
        2: """
            ...bb...
            .bbccb..
            bccccbb.
            bcccbbbb
            abbbbbba
            .aaaaaa.
            """,
    }[size]
    s = sprite(g, {"a": SMOKE[0], "b": SMOKE[1], "c": SMOKE[2]})
    return Canvas(s.w + 2, s.h + 2).paste(s, 1, 1).outline(SMOKE_OUT)


# ---------------------------------------------------------------- rows
def idle():
    return [draw(P(**kw)) for kw in (
        {},
        {"eyes": "half"},
        {"eyes": "closed"},
        {"leg": 4},                     # inhale: the body rises 1 px, feet stay planted
        {"leg": 4},
        {},
    )]


# 3/4 run, facing the travel direction. feet = (near, far) as (stride dx along the run,
# lift); arms = (near, far) swing in degrees from straight down, + = forward. Each foot
# slides back under the body while planted, then swings forward lifted; the arms swing
# against the legs. leg = body height (2 down, 4 up).
RUN = [  # contact, down, passing, up, then the other foot
    dict(feet=((5, 0), (-5, 1)), arms=(-65, 65), leg=3, dust=0),
    dict(feet=((3, 0), (-3, 2)), arms=(-45, 45), leg=2, dust=1),
    dict(feet=((-1, 0), (3, 3)), arms=(-5, 5), leg=3),
    dict(feet=((-3, 1), (4, 2)), arms=(45, -45), leg=4),
    dict(feet=((-5, 1), (5, 0)), arms=(65, -65), leg=3, dust=0),
    dict(feet=((-3, 2), (3, 0)), arms=(45, -45), leg=2, dust=1),
    dict(feet=((3, 3), (-1, 0)), arms=(5, -5), leg=3),
    dict(feet=((4, 2), (-3, 1)), arms=(-45, 45), leg=4),
]
DUST = [sprite("""
    ..a..
    .abba
    abbba
    """, {"a": "#9AA4B2", "b": "#D3D9E1"}), sprite("""
    .a...a
    a.a...
    """, {"a": "#A9B2BE"})]


def run(direction):
    """Drawn natively per direction (a 3/4 turn: side panels, stride and swing mirrored)
    so the light stays top-left."""
    sgn = 1 if direction == "right" else -1
    out = []
    for f in RUN:
        f = dict(f)
        dust = f.pop("dust", None)
        near, far = f.pop("arms")
        leg = f.pop("leg")
        ant = ("lean-" if sgn > 0 else "lean+") if leg == 4 else "up"
        fx = []
        if dust is not None:
            d = DUST[dust]
            x = 8 - 2 * dust
            fx.append((d, x, 47 - d.h + 1) if sgn > 0 else (d.flipped(), 47 - x - d.w + 1, 47 - d.h + 1))
        out.append(draw(P(turn=sgn, arm_l=near, arm_r=far, arm_len=5.5, lean=sgn, hdx=sgn,
                          leg=leg, ant=ant, mouth="small", fx=fx, **f)))
    return out


def waving():
    out = []
    for i, a in enumerate((45, 70, 92, 70)):
        fx = []
        if i in (1, 2):
            s = fx_sparkle(0 if i == 1 else 1)
            fx.append((s, 33 - s.w // 2, 8 - s.h // 2))
        out.append(draw(P(arm_r=(6.5, -0.5, a, 5.5), eyes="happy", mouth="open", blush=True,
                          rays=(i == 2), fx=fx)))
    return out


def jumping():
    g = dict(bulb="green")
    return [
        draw(P(hw=26, hh=13, leg=1, eyes="squint", mouth="flat", arm_l=-30, arm_r=-30,
               ant="short", **g)),
        draw(P(lift=4, leg=4, eyes="open", mouth="o", arm_l=(5, 0, 50, 4.5), arm_r=(5, 0, 50, 4.5),
               ant="short", feet=((1, -1), (-1, -1)), **g)),
        draw(P(lift=7, eyes="happy", mouth="open", blush=True, arm_l=(5, 0, 82, 5), arm_r=(5, 0, 82, 5),
               ant="short", feet=((1, 1), (-1, 1)), **g)),
        draw(P(lift=3, leg=4, eyes="open", mouth="o", arm_l=12, arm_r=12, arm_len=6.5,
               ant="long", feet=((1, -1), (-1, -1)), **g)),
        draw(P(hw=26, hh=13, leg=1, eyes="happy", mouth="smile", blush=True, arm_l=-35, arm_r=-35,
               ant="short", **g)),
    ]


def failed():
    """Shock (red x eyes, the family's red x, a shake and a growing slump; the antenna
    kinks), then a calm 3-px slump: sad dim eyes, the antenna drooped 45 degrees, its
    bulb sputtering while one smoke puff curls up and away from it."""
    out = []
    cross = fx_cross()
    shakes = ((-1, 3, "up"), (1, 2, "lean+"), (-1, 2, "tilt"), (0, 1, "tilt"))
    pre = ((cross, 34, 5), (cross, 34, 4), (smoke(0), 30, 5), (smoke(1), 31, 2))
    for i, (dx, leg, ant) in enumerate(shakes):
        spr, x, y = pre[i]
        fx = [(spr, x + (dx if i >= 2 else 0), y)]
        out.append(draw(P(dx=dx, leg=leg, eyes="x", eye_col="err", mouth="frown",
                          bulb="red", ant=ant, arm_l=-78, arm_r=-78, arm_len=4.5, fx=fx)))
    puffs = ((0, 30, 7), (1, 31, 4), (2, 33, 1), (1, 37, 1))
    sputter = (0.15, 1.0, 0.45, 1.0)
    for i in range(4):
        sz, x, y = puffs[i]
        # slump: the legs fold to 1 px and the torso sinks 1 px under the head (3 px)
        out.append(draw(P(leg=1, th=6, eyes="sad", eye_col="dim", mouth="frown",
                          bulb="red", bulb_on=sputter[i], ant="tilt",
                          arm_l=-86, arm_r=-86, arm_len=5.0, fx=[(smoke(sz), x, y)])))
    return out


def waiting():
    big, small = fx_exclaim(), fx_exclaim(big=False)
    bx = 33
    am = dict(bulb="amber", eyes="open", mouth="o")
    return [
        draw(P(bulb_on=False, fx=[(small, bx, 6)], **am)),
        draw(P(leg=4, rays=True, arm_l=20, arm_r=20, arm_len=6, fx=[(big, bx, 1)], **am)),
        draw(P(bulb_on=False, feet=((0, 0), (1, 2)), fx=[(big, bx, 2)], **am)),
        draw(P(rays=True, fx=[(big, bx, 3)], **am)),
        draw(P(bulb_on=False, feet=((0, 0), (1, 2)), fx=[(big, bx, 2)], **am)),
        draw(P(rays=True, fx=[(big, bx, 2)], **am)),
    ]


def working():
    out = []
    paws = ((1, 0), (0, 1), (1, 0), (0, 0), (0, 1), (1, 0))
    for i in range(6):
        dots = fx_dots(1 + (i // 2))
        out.append(draw(P(eyes="down", mouth="small", laptop=i, paws=paws[i],
                          look=(0, 1, 1, 0, -1, -1)[i],
                          bulb="blue", bulb_on=(1.0, 0.7, 0.35, 0.1, 0.35, 0.7)[i],
                          glow=(0.8 if i % 3 else 1.0), fx=[(dots, 33, 4)])))
    return out


def review():
    bounce = (0, 1, 0, -1, 0, 0)
    sparkles = [
        (6, 15, (0, 1, 2, 1, 0, None)),
        (42, 20, (None, 0, 1, 2, 1, 0)),
        (5, 36, (2, 1, 0, None, 0, 1)),
    ]
    chk = fx_check()
    out = []
    for i in range(6):
        fx = []
        for sx, sy, sizes in sparkles:
            s = sizes[i]
            if s is not None:
                spr = fx_sparkle(s)
                fx.append((spr, sx - spr.w // 2, sy - spr.h // 2))
        fx.append((chk, 33, 3 + (1 if i in (2, 3) else 0)))
        up_l, up_r = (85, 60) if i % 2 == 0 else (60, 85)
        out.append(draw(P(leg=3 + bounce[i], eyes="happy", mouth="open", blush=True, bulb="green",
                          arm_l=(5, 0, up_l, 5), arm_r=(5, 0, up_r, 5), fx=fx)))
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
