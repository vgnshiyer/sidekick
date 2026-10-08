#!/usr/bin/env python3
"""petgen: a stdlib-only pixel-art pipeline for Sidekick pets (Codex pets format).

    python3 tools/petgen/petgen.py build <id>|all [--preview-only]
    python3 tools/petgen/petgen.py zoom <id> <row> [frame]

A pet is a module tools/petgen/pets/<id>.py that exposes

    PET = {"id": "<id>", "displayName": "...", "description": "...",
           "quips": {"sent": "...", "working": "..."}}    # quips optional
    def frames() -> {row_name: [Canvas(48x52), ...]}

Pet modules do `from petgen import *`. See STYLE.md and pets/_example.py.
`build` writes the pack to Sources/Sidekick/Resources/Pets/<id>/ (underscore-prefixed
modules go to out/<id>/pack/ instead) and previews to tools/petgen/out/<id>/.

Coordinates: x right, y down, (0, 0) top-left of a 48x52 cell. Colours are
'#rrggbb' / '#rrggbbaa' strings or (r, g, b[, a]) tuples everywhere. Drawing with
CLEAR erases. Every drawing method returns the canvas, so calls chain.

API at a glance
  contract   W=48 H=52 GROUND=47 CX=24 SCALE=4 COLS=8 ROWS ROW_NAMES FRAME_COUNTS
             TIMINGS IDLE_LOOP_MULT=6 LIGHT
  colour     rgba(c, a=None) hexstr(c) mix(c1, c2, t) shade(c, amount=.2, hue_shift=12)
             tint(c, amount=.2, hue_shift=10) ramp(base, dark=2, light=1, step=.18)
             outline_of(base, amount=.62) luminance(c)
  Canvas(w=48, h=52, fill=None)
    pixels   get(x,y) set(x,y,c) blend(x,y,c) opaque(x,y) fill(c) clear() copy()
    shapes   rect(x,y,w,h,c,fill=True) hline(x0,x1,y,c) vline(x,y0,y1,c) line(x0,y0,x1,y1,c)
             ellipse(x,y,w,h,c,fill=True) disc(cx,cy,r,c) capsule(x0,y0,x1,y1,r,c)
             sphere(x,y,w,h,tones,light=LIGHT,cut_bottom=0,thresholds=None)
             grid(x,y,text,palette,flip=False) text(x,y,s,c,scale=1,spacing=1)
    colour   replace(old,new) recolor({old:new}) tinted(c,t) silhouette(c)
    outline  outline(color|fn, corners=False) outlined(...) inline(color, corners=False)
    layers   paste(src,x=0,y=0,flip=False,inside=False) under(src,x=0,y=0)
             flipped() translated(dx,dy) scaled(sx,sy,ax=CX,ay=48) squash(rows,...)
             sheared(dx_top,y_top=0,y_bottom=GROUND) bbox() crop(x,y,w,h) trimmed()
             upscaled(k) over(bg) save(path,scale=1) Canvas.load(path)
  sprite(text, palette) compose(*layers) text_width(s, scale=1)
  fx         AMBER RED GREEN SLEEPY SPARKLE SCREEN INK WHITE
             fx_exclaim(color=AMBER, big=True) fx_question() fx_z(size=1) fx_sweat()
             fx_sparkle(size=1) fx_cross() fx_check() fx_heart() fx_dots(n=3)
             prop_laptop(frame=0, width=16, glow=True)
  build      mirror_row(frames) validate(frames) lint(frames) build_atlas(frames)
             write_pack(pet, frames, dir) write_previews(pet, frames, dir) build_pet(stem)
             zoom(frame, k=10) write_zoom(stem, row, idx=None)
             write_png(path,w,h,rows) read_png(path) write_gif(path,canvases,delays_ms,scale,bg)
"""
from __future__ import annotations

import colorsys
import importlib.util
import json
import math
import os
import struct
import sys
import textwrap
import zlib
from functools import lru_cache

__all__ = [
    # contract
    "W", "H", "GROUND", "CX", "SCALE", "COLS", "ROWS", "ROW_NAMES", "FRAME_COUNTS",
    "TIMINGS", "IDLE_LOOP_MULT", "LIGHT",
    # colour
    "CLEAR", "rgba", "hexstr", "mix", "shade", "tint", "ramp", "outline_of", "luminance",
    # canvas
    "Canvas", "sprite", "compose", "PetError",
    # font + fx
    "FONT", "text_width", "AMBER", "RED", "GREEN", "SLEEPY", "SPARKLE", "WHITE", "INK",
    "SCREEN", "fx_exclaim", "fx_question", "fx_z", "fx_sweat", "fx_sparkle", "fx_cross",
    "fx_check", "fx_dots", "fx_heart", "prop_laptop",
    # io + build
    "write_png", "read_png", "write_gif", "build_atlas", "validate", "lint",
    "mirror_row", "write_pack", "write_previews", "build_pet", "zoom", "write_zoom",
]

# --------------------------------------------------------------------------------------
# Contract
# --------------------------------------------------------------------------------------

W, H = 48, 52          # logical cell size
GROUND = 47            # feet touch this row (lowest opaque row, outline included)
CX = 24                # horizontal centre line sits between columns 23 and 24 (x -> 47 - x mirrors)
SCALE = 4              # logical -> atlas
COLS = 8
ROWS = [
    ("idle", 6),
    ("running-right", 8),
    ("running-left", 8),
    ("waving", 4),
    ("jumping", 5),
    ("failed", 8),
    ("waiting", 6),
    ("running", 6),
    ("review", 6),
]
ROW_NAMES = [r for r, _ in ROWS]
FRAME_COUNTS = dict(ROWS)
TIMINGS = {
    "idle": [280, 110, 110, 140, 140, 320],
    "running-right": [120] * 7 + [220],
    "running-left": [120] * 7 + [220],
    "waving": [140] * 3 + [280],
    "jumping": [140] * 4 + [280],
    "failed": [140] * 7 + [240],
    "waiting": [150] * 5 + [260],
    "running": [120] * 5 + [220],
    "review": [150] * 5 + [280],
}
IDLE_LOOP_MULT = 6     # the app loops idle about 6x slower than the listed timings
LIGHT = (-0.4, -0.55, 0.73)    # light comes from the top-left, mostly from the front

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
PETS_SRC = os.path.join(HERE, "pets")
OUT_ROOT = os.path.join(HERE, "out")
RESOURCES = os.path.join(REPO, "Sources", "Sidekick", "Resources", "Pets")


class PetError(Exception):
    pass


# --------------------------------------------------------------------------------------
# Colour
# --------------------------------------------------------------------------------------

CLEAR = (0, 0, 0, 0)


@lru_cache(maxsize=8192)
def _parse_hex(s):
    h = s.lstrip("#")
    if len(h) in (3, 4):
        h = "".join(ch * 2 for ch in h)
    if len(h) == 6:
        h += "ff"
    if len(h) != 8:
        raise ValueError(f"bad colour {s!r}")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4, 6))


def rgba(c, a=None):
    """Normalise '#rgb', '#rrggbb', '#rrggbbaa', (r,g,b) or (r,g,b,a) to an RGBA tuple.
    None -> CLEAR. `a` overrides alpha (0-255)."""
    if c is None:
        out = CLEAR
    elif isinstance(c, str):
        out = _parse_hex(c)
    elif len(c) == 3:
        out = (int(c[0]), int(c[1]), int(c[2]), 255)
    else:
        out = (int(c[0]), int(c[1]), int(c[2]), int(c[3]))
    if a is not None:
        out = (out[0], out[1], out[2], int(a))
    return out


def hexstr(c):
    r, g, b, a = rgba(c)
    return f"#{r:02x}{g:02x}{b:02x}" + ("" if a == 255 else f"{a:02x}")


def mix(c1, c2, t):
    """Linear blend c1 -> c2 by t (0..1)."""
    a, b = rgba(c1), rgba(c2)
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(4))


def luminance(c):
    r, g, b, _ = rgba(c)
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0


def _hue_toward(h, target, deg):
    d = (target - h + 0.5) % 1.0 - 0.5
    step = deg / 360.0
    if abs(d) <= step:
        return target % 1.0
    return (h + math.copysign(step, d)) % 1.0


def shade(c, amount=0.2, hue_shift=12):
    """Darker version of c (HSV): value * (1 - amount), saturation raised a little, hue
    nudged toward blue-violet by up to hue_shift degrees (classic pixel-art shadow).
    amount 0..1."""
    r, g, b, a = rgba(c)
    h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
    if s > 0.05:
        h = _hue_toward(h, 0.68, hue_shift * min(1.0, amount / 0.3))
        s = min(1.0, s + (1 - s) * 0.35 * amount + 0.12 * amount)
    v = v * (1 - amount)
    r2, g2, b2 = colorsys.hsv_to_rgb(h, s, v)
    return (round(r2 * 255), round(g2 * 255), round(b2 * 255), a)


def tint(c, amount=0.2, hue_shift=10):
    """Lighter version of c (HSV): value raised toward 1, saturation eased toward 0, hue
    nudged toward warm yellow by up to hue_shift degrees (classic pixel-art highlight)."""
    r, g, b, a = rgba(c)
    h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
    if s > 0.05:
        h = _hue_toward(h, 0.15, hue_shift * min(1.0, amount / 0.3))
    s = s * (1 - 0.75 * amount)
    v = v + (1 - v) * amount
    r2, g2, b2 = colorsys.hsv_to_rgb(h, s, v)
    return (round(r2 * 255), round(g2 * 255), round(b2 * 255), a)


def ramp(base, dark=2, light=1, step=0.18):
    """Hue-shifted ramp [darkest, ..., base, ..., lightest] with `dark` shades and
    `light` tints around base."""
    out = [shade(base, step * i) for i in range(dark, 0, -1)]
    out.append(rgba(base))
    out += [tint(base, step * 1.6 * i) for i in range(1, light + 1)]
    return out


def outline_of(base, amount=0.62):
    """The family outline colour for a material: a deep, hue-shifted shade (never pure black)."""
    return shade(base, amount, hue_shift=14)


# --------------------------------------------------------------------------------------
# Canvas
# --------------------------------------------------------------------------------------

_NEIGH4 = ((1, 0), (-1, 0), (0, 1), (0, -1))
_NEIGH8 = _NEIGH4 + ((1, 1), (1, -1), (-1, 1), (-1, -1))


class Canvas:
    """An RGBA pixel grid (default 48x52). Drawing calls clip silently at the edges and
    return self so they can be chained. Drawing with CLEAR erases."""

    __slots__ = ("w", "h", "px")

    def __init__(self, w=W, h=H, fill=None):
        self.w, self.h = w, h
        self.px = [rgba(fill)] * (w * h)

    # ---- basics
    def copy(self):
        c = Canvas(self.w, self.h)
        c.px = self.px[:]
        return c

    def inb(self, x, y):
        return 0 <= x < self.w and 0 <= y < self.h

    def get(self, x, y):
        if 0 <= x < self.w and 0 <= y < self.h:
            return self.px[y * self.w + x]
        return CLEAR

    def opaque(self, x, y):
        return self.get(x, y)[3] > 0

    def set(self, x, y, c):
        x, y = int(x), int(y)
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y * self.w + x] = rgba(c)
        return self

    def blend(self, x, y, c):
        """Alpha-composite c over the pixel at (x, y)."""
        c = rgba(c)
        if c[3] == 0 or not self.inb(x, y):
            return self
        if c[3] == 255:
            self.px[y * self.w + x] = c
            return self
        d = self.px[y * self.w + x]
        sa, da = c[3] / 255, d[3] / 255
        oa = sa + da * (1 - sa)
        if oa <= 0:
            return self
        ch = [round((c[i] * sa + d[i] * da * (1 - sa)) / oa) for i in range(3)]
        self.px[y * self.w + x] = (ch[0], ch[1], ch[2], round(oa * 255))
        return self

    def fill(self, c):
        self.px = [rgba(c)] * (self.w * self.h)
        return self

    def clear(self):
        return self.fill(CLEAR)

    # ---- primitives
    def rect(self, x, y, w, h, c, fill=True):
        c = rgba(c)
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                if fill or yy in (y, y + h - 1) or xx in (x, x + w - 1):
                    self.set(xx, yy, c)
        return self

    def hline(self, x0, x1, y, c):
        for x in range(min(x0, x1), max(x0, x1) + 1):
            self.set(x, y, c)
        return self

    def vline(self, x, y0, y1, c):
        for y in range(min(y0, y1), max(y0, y1) + 1):
            self.set(x, y, c)
        return self

    def line(self, x0, y0, x1, y1, c):
        """1-px Bresenham line, endpoints inclusive."""
        c = rgba(c)
        x0, y0, x1, y1 = int(round(x0)), int(round(y0)), int(round(x1)), int(round(y1))
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
        err = dx + dy
        while True:
            self.set(x0, y0, c)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy
        return self

    def _ellipse_mask(self, x, y, w, h):
        rx, ry = w / 2.0, h / 2.0
        cx, cy = x + rx, y + ry
        for py in range(y, y + h):
            v = (py + 0.5 - cy) / ry
            for px in range(x, x + w):
                u = (px + 0.5 - cx) / rx
                if u * u + v * v <= 1.0:
                    yield px, py, u, v

    def ellipse(self, x, y, w, h, c, fill=True):
        """Ellipse inscribed in the box (x, y, w, h). Even widths centred on CX stay symmetric."""
        c = rgba(c)
        pts = {(px, py) for px, py, _, _ in self._ellipse_mask(x, y, w, h)}
        for px, py in pts:
            if fill or any((px + dx, py + dy) not in pts for dx, dy in _NEIGH4):
                self.set(px, py, c)
        return self

    def disc(self, cx, cy, r, c):
        """Filled circle by float centre/radius (pixel centres within r)."""
        c = rgba(c)
        for py in range(int(math.floor(cy - r)) - 1, int(math.ceil(cy + r)) + 1):
            for px in range(int(math.floor(cx - r)) - 1, int(math.ceil(cx + r)) + 1):
                if (px + 0.5 - cx) ** 2 + (py + 0.5 - cy) ** 2 <= r * r:
                    self.set(px, py, c)
        return self

    def capsule(self, x0, y0, x1, y1, r, c):
        """Rounded limb: every pixel whose centre is within r of the segment (x0,y0)-(x1,y1).
        Coordinates are pixel centres given as floats (use n + 0.5 for a pixel's centre)."""
        c = rgba(c)
        ax, ay, bx, by = x0, y0, x1, y1
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        for py in range(int(math.floor(min(ay, by) - r)) - 1, int(math.ceil(max(ay, by) + r)) + 1):
            for px in range(int(math.floor(min(ax, bx) - r)) - 1, int(math.ceil(max(ax, bx) + r)) + 1):
                qx, qy = px + 0.5, py + 0.5
                t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((qx - ax) * dx + (qy - ay) * dy) / L2))
                ex, ey = ax + dx * t - qx, ay + dy * t - qy
                if ex * ex + ey * ey <= r * r:
                    self.set(px, py, c)
        return self

    def sphere(self, x, y, w, h, tones, light=LIGHT, cut_bottom=0, thresholds=None):
        """Toon-shaded ellipse in box (x, y, w, h). tones = [darkest, ..., lightest]
        (2-5 colours). Light from the top-left by default. cut_bottom clips that many
        rows off the bottom (gumdrop/blob bases). thresholds overrides the band cut-offs
        (len(tones) - 1 ascending values of N.L)."""
        tones = [rgba(t) for t in tones]
        n = len(tones)
        lx, ly, lz = light
        ln = math.sqrt(lx * lx + ly * ly + lz * lz)
        lx, ly, lz = lx / ln, ly / ln, lz / ln
        if thresholds is None:
            thresholds = {2: [0.4], 3: [0.4, 0.92], 4: [0.15, 0.5, 0.93], 5: [0.05, 0.3, 0.55, 0.93]}.get(n)
            if thresholds is None:
                thresholds = [i / n for i in range(1, n)]
        for px, py, u, v in self._ellipse_mask(x, y, w, h):
            if py >= y + h - cut_bottom:
                continue
            nz = math.sqrt(max(0.0, 1.0 - u * u - v * v))
            d = u * lx + v * ly + nz * lz
            idx = 0
            for t in thresholds:
                if d > t:
                    idx += 1
            self.set(px, py, tones[idx])
        return self

    def grid(self, x, y, text, palette, flip=False):
        """Draw a multi-line string. palette maps char -> colour; '.' and ' ' are
        transparent (skipped). Common indentation and blank edge lines are stripped."""
        rows = _grid_rows(text)
        width = max((len(r) for r in rows), default=0)
        for j, row in enumerate(rows):
            for i, ch in enumerate(row):
                if ch in ". ":
                    continue
                if ch not in palette:
                    raise PetError(f"grid char {ch!r} not in palette (row {j}: {row!r})")
                xx = x + (width - 1 - i if flip else i)
                self.set(xx, y + j, palette[ch])
        return self

    def text(self, x, y, s, c, scale=1, spacing=1):
        """Draw text with the tiny pixel font (3x5 caps, digits, ! ? . , : - + / ( ) ^ x z ...)."""
        c = rgba(c)
        cx = x
        for ch in s:
            g = _glyph(ch)
            gw = len(g[0]) if g else 3
            for j, row in enumerate(g):
                for i, b in enumerate(row):
                    if b == "#":
                        self.rect(cx + i * scale, y + j * scale, scale, scale, c)
            cx += (gw + spacing) * scale
        return self

    # ---- colour ops
    def replace(self, old, new):
        old, new = rgba(old), rgba(new)
        self.px = [new if p == old else p for p in self.px]
        return self

    def recolor(self, mapping):
        m = {rgba(k): rgba(v) for k, v in mapping.items()}
        self.px = [m.get(p, p) for p in self.px]
        return self

    def tinted(self, c, t):
        """Copy with every opaque pixel blended toward colour c by t (flash / glow)."""
        c = rgba(c)
        out = self.copy()
        out.px = [p if not p[3] else mix(p, (c[0], c[1], c[2], p[3]), t) for p in out.px]
        return out

    def silhouette(self, c):
        """Copy with every opaque pixel set to c."""
        c = rgba(c)
        out = self.copy()
        out.px = [c if p[3] else CLEAR for p in out.px]
        return out

    # ---- outline
    def outline(self, color, corners=False):
        """Add a 1-px outline *outside* the silhouette, only on transparent pixels next to
        an opaque one (4-neighbour by default; corners=True also fills diagonals).
        color may be a colour or a callable(neighbour_rgba) -> colour; with a callable the
        darkest opaque neighbour decides (selective outlines per material). In place."""
        neigh = _NEIGH8 if corners else _NEIGH4
        w, h, src = self.w, self.h, self.px
        fixed = None if callable(color) else rgba(color)
        new = src[:]
        for y in range(h):
            for x in range(w):
                if src[y * w + x][3]:
                    continue
                best = None
                for dx, dy in neigh:
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h:
                        p = src[ny * w + nx]
                        if p[3]:
                            if fixed is not None:
                                best = p
                                break
                            if best is None or luminance(p) < luminance(best):
                                best = p
                if best is not None:
                    new[y * w + x] = fixed if fixed is not None else rgba(color(best))
        self.px = new
        return self

    def outlined(self, color, corners=False):
        return self.copy().outline(color, corners)

    def inline(self, color, corners=False):
        """Recolour the silhouette's own edge pixels (outline drawn *inside* the shape). In place."""
        neigh = _NEIGH8 if corners else _NEIGH4
        c = rgba(color)
        w, h, src = self.w, self.h, self.px
        new = src[:]
        for y in range(h):
            for x in range(w):
                if not src[y * w + x][3]:
                    continue
                for dx, dy in neigh:
                    nx, ny = x + dx, y + dy
                    if not (0 <= nx < w and 0 <= ny < h) or not src[ny * w + nx][3]:
                        new[y * w + x] = c
                        break
        self.px = new
        return self

    # ---- layers / transforms
    def paste(self, src, x=0, y=0, flip=False, inside=False):
        """Composite src onto self with its top-left at (x, y). flip mirrors src
        horizontally. inside=True only paints where self is already opaque (markings,
        stripes, spots and belly patches clipped to a body)."""
        sw, sh = src.w, src.h
        for j in range(sh):
            ty = y + j
            if not (0 <= ty < self.h):
                continue
            row = src.px[j * sw:(j + 1) * sw]
            if flip:
                row = row[::-1]
            for i, p in enumerate(row):
                a = p[3]
                if not a:
                    continue
                tx = x + i
                if 0 <= tx < self.w:
                    k = ty * self.w + tx
                    if inside and not self.px[k][3]:
                        continue
                    if a == 255:
                        self.px[k] = p
                    else:
                        self.blend(tx, ty, p)
        return self

    def under(self, src, x=0, y=0):
        """Paste src *behind* the existing pixels (only fills transparent pixels)."""
        for j in range(src.h):
            ty = y + j
            for i in range(src.w):
                p = src.px[j * src.w + i]
                tx = x + i
                if p[3] and 0 <= tx < self.w and 0 <= ty < self.h and not self.px[ty * self.w + tx][3]:
                    self.px[ty * self.w + tx] = p
        return self

    def flipped(self):
        """Horizontal mirror (x -> w - 1 - x)."""
        out = Canvas(self.w, self.h)
        w = self.w
        out.px = [p for y in range(self.h) for p in self.px[y * w:(y + 1) * w][::-1]]
        return out

    def translated(self, dx, dy):
        out = Canvas(self.w, self.h)
        return out.paste(self, dx, dy)

    def scaled(self, sx=1.0, sy=1.0, ax=CX, ay=GROUND + 1):
        """Nearest-neighbour resample around the anchor (ax, ay) in pixel-edge coordinates
        (default: bottom-centre, so feet stay planted). sy < 1 squashes, > 1 stretches.
        Best applied to un-outlined layers, then outline afterwards."""
        out = Canvas(self.w, self.h)
        for y in range(self.h):
            syf = ay + (y + 0.5 - ay) / sy
            yy = int(math.floor(syf))
            if not (0 <= yy < self.h):
                continue
            for x in range(self.w):
                sxf = ax + (x + 0.5 - ax) / sx
                xx = int(math.floor(sxf))
                if 0 <= xx < self.w:
                    out.px[y * self.w + x] = self.px[yy * self.w + xx]
        return out

    def sheared(self, dx_top, y_top=0, y_bottom=GROUND):
        """Lean: shift each row horizontally, by dx_top at y_top easing linearly to 0 at
        y_bottom (rows above y_top shift fully, rows below y_bottom stay). Use on an
        un-outlined layer (e.g. a body leaning into a run), then outline."""
        out = Canvas(self.w, self.h)
        span = max(1, y_bottom - y_top)
        for y in range(self.h):
            t = min(1.0, max(0.0, (y_bottom - y) / span))
            s = int(round(dx_top * t))
            row = self.px[y * self.w:(y + 1) * self.w]
            for x, p in enumerate(row):
                if p[3] and 0 <= x + s < self.w:
                    out.px[y * self.w + x + s] = p
        return out

    def squash(self, rows, ax=CX, ay=GROUND + 1, keep_volume=True):
        """Squash (rows > 0) or stretch (rows < 0) the opaque content by about `rows` px of
        height via row resampling, anchored at the ground. keep_volume widens on squash."""
        bb = self.bbox()
        if not bb or rows == 0:
            return self.copy()
        hgt = bb[3] - bb[1] + 1
        sy = max(0.1, (hgt - rows) / hgt)
        sx = (1.0 / sy) ** 0.5 if keep_volume else 1.0
        return self.scaled(sx, sy, ax, ay)

    def bbox(self):
        """(x0, y0, x1, y1) inclusive bounds of opaque pixels, or None."""
        xs, ys = [], []
        w = self.w
        for i, p in enumerate(self.px):
            if p[3]:
                xs.append(i % w)
                ys.append(i // w)
        if not xs:
            return None
        return min(xs), min(ys), max(xs), max(ys)

    def crop(self, x, y, w, h):
        out = Canvas(w, h)
        for j in range(h):
            for i in range(w):
                out.px[j * w + i] = self.get(x + i, y + j)
        return out

    def trimmed(self):
        bb = self.bbox()
        if not bb:
            return Canvas(1, 1)
        return self.crop(bb[0], bb[1], bb[2] - bb[0] + 1, bb[3] - bb[1] + 1)

    def upscaled(self, k):
        out = Canvas(self.w * k, self.h * k)
        ow = out.w
        for y in range(self.h):
            row = []
            for p in self.px[y * self.w:(y + 1) * self.w]:
                row.extend([p] * k)
            for r in range(k):
                out.px[(y * k + r) * ow:(y * k + r + 1) * ow] = row
        return out

    def over(self, bg):
        """Flatten onto an opaque background colour (for previews)."""
        bg = rgba(bg)
        out = Canvas(self.w, self.h)
        cache = {}
        for i, p in enumerate(self.px):
            a = p[3]
            if a == 255:
                out.px[i] = p
            elif a == 0:
                out.px[i] = bg
            else:
                q = cache.get(p)
                if q is None:
                    t = a / 255
                    q = tuple(round(p[k] * t + bg[k] * (1 - t)) for k in range(3)) + (255,)
                    cache[p] = q
                out.px[i] = q
        return out

    # ---- io
    def rows_bytes(self, scale=1):
        w = self.w
        out = []
        for y in range(self.h):
            row = self.px[y * w:(y + 1) * w]
            if scale == 1:
                b = bytes(v for p in row for v in p)
            else:
                b = b"".join(bytes(p) * scale for p in row)
            out.extend([b] * scale)
        return out

    def save(self, path, scale=1):
        write_png(path, self.w * scale, self.h * scale, self.rows_bytes(scale))
        return path

    @staticmethod
    def load(path):
        w, h, px = read_png(path)
        c = Canvas(w, h)
        c.px = px
        return c

    def __repr__(self):
        return f"<Canvas {self.w}x{self.h}>"


def _grid_rows(text):
    lines = textwrap.dedent(text).split("\n")
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return [ln.rstrip() for ln in lines]


def sprite(text, palette, w=None, h=None):
    """Canvas sized to a grid string (see Canvas.grid)."""
    rows = _grid_rows(text)
    cw = w or max((len(r) for r in rows), default=1)
    ch = h or len(rows)
    return Canvas(cw, ch).grid(0, 0, text, palette)


def compose(*layers, w=W, h=H):
    """New canvas from (canvas, x, y) or (canvas, x, y, flip) tuples, back to front."""
    out = Canvas(w, h)
    for layer in layers:
        if layer is None:
            continue
        if isinstance(layer, Canvas):
            out.paste(layer)
        else:
            out.paste(*layer)
    return out


# --------------------------------------------------------------------------------------
# Tiny pixel font (3x5; a few wider symbols)
# --------------------------------------------------------------------------------------

_F = """
A .#. #.# ### #.# #.#
B ##. #.# ##. #.# ##.
C .## #.. #.. #.. .##
D ##. #.# #.# #.# ##.
E ### #.. ##. #.. ###
F ### #.. ##. #.. #..
G .## #.. #.# #.# .##
H #.# #.# ### #.# #.#
I ### .#. .#. .#. ###
J ..# ..# ..# #.# .#.
K #.# #.# ##. #.# #.#
L #.. #.. #.. #.. ###
M #.# ### ### #.# #.#
N ##. #.# #.# #.# #.#
O .#. #.# #.# #.# .#.
P ##. #.# ##. #.. #..
Q .#. #.# #.# ##. .##
R ##. #.# ##. #.# #.#
S .## #.. .#. ..# ##.
T ### .#. .#. .#. .#.
U #.# #.# #.# #.# ###
V #.# #.# #.# #.# .#.
W #.# #.# ### ### #.#
X #.# #.# .#. #.# #.#
Y #.# #.# .#. .#. .#.
Z ### ..# .#. #.. ###
0 ### #.# #.# #.# ###
1 .#. ##. .#. .#. ###
2 ##. ..# .#. #.. ###
3 ##. ..# .#. ..# ##.
4 #.# #.# ### ..# ..#
5 ### #.. ##. ..# ##.
6 .## #.. ### #.# ###
7 ### ..# .#. .#. .#.
8 ### #.# ### #.# ###
9 ### #.# ### ..# ##.
! .#. .#. .#. ... .#.
? ##. ..# .#. ... .#.
. ... ... ... ... .#.
, ... ... ... .#. #..
: ... .#. ... .#. ...
- ... ... ### ... ...
+ ... .#. ### .#. ...
= ... ### ... ### ...
_ ... ... ... ... ###
/ ..# ..# .#. #.. #..
( .#. #.. #.. #.. .#.
) .#. ..# ..# ..# .#.
' .#. .#. ... ... ...
^ .#. #.# ... ... ...
x ... #.# .#. #.# ...
z ... ### .#. #.. ###
< ..# .#. #.. .#. ..#
> #.. .#. ..# .#. #..
* ... #.# .#. #.# ...
"""
FONT = {}
for _ln in _F.strip().split("\n"):
    _k, *_rows = _ln.split(" ")
    FONT[_k] = _rows
FONT[" "] = ["...", "...", "...", "...", "..."]
FONT["…"] = [".....", ".....", ".....", ".....", "#.#.#"]   # ellipsis
FONT["♥"] = [".#.#.", "#####", "#####", ".###.", "..#.."]   # heart
FONT["%"] = ["#.#", "..#", ".#.", "#..", "#.#"]


def _glyph(ch):
    if ch in FONT:
        return FONT[ch]
    if ch.upper() in FONT:
        return FONT[ch.upper()]
    return FONT["?"]


def text_width(s, scale=1, spacing=1):
    if not s:
        return 0
    return sum((len(_glyph(ch)[0]) + spacing) * scale for ch in s) - spacing * scale


# --------------------------------------------------------------------------------------
# Shared effect glyphs + props (one family look: use these instead of drawing your own)
# --------------------------------------------------------------------------------------

AMBER = rgba("#F5A623")     # attention / needs input
RED = rgba("#E5484D")       # error / failed
GREEN = rgba("#30A46C")     # success / done
SLEEPY = rgba("#7FA7E8")    # sleepy z, sweat drops, calm
SPARKLE = rgba("#FFE48A")   # celebration sparkles
WHITE = rgba("#FFFFFF")
INK = rgba("#2A2238")       # default eye / mouth ink (a warm near-black, never pure black)
SCREEN = rgba("#8FE3FF")    # laptop screen glow


def _fx(text, pal, color, outline=None):
    s = sprite(text, pal)
    pad = Canvas(s.w + 2, s.h + 2).paste(s, 1, 1)
    return pad.outline(outline or outline_of(color, 0.6))


def fx_exclaim(color=AMBER, big=True):
    """Bold '!' (4x10 outlined when big, 4x7 when small: use small for the pop-in frame).
    Centre it above the head."""
    pal = {"a": tint(color, 0.45), "b": rgba(color), "c": shade(color, 0.22)}
    if big:
        g = """
            ab
            ab
            ab
            bb
            bc
            ..
            ab
            bc
            """
    else:
        g = """
            ab
            ab
            bc
            ..
            bc
            """
    return _fx(g, pal, color)


def fx_question(color=AMBER):
    """'?' (7x10 outlined)."""
    pal = {"a": tint(color, 0.45), "b": rgba(color), "c": shade(color, 0.22)}
    g = """
        .aab.
        ab.bc
        ...bc
        ..bc.
        ..bc.
        .....
        ..bc.
        """
    return _fx(g, pal, color)


def fx_z(size=1, color=SLEEPY):
    """Sleepy 'z' (size 0: 3x4, 1: 4x4, 2: 5x5, plus outline)."""
    pal = {"b": rgba(color), "a": tint(color, 0.4)}
    g = {
        0: """
            aab
            .b.
            b..
            bbb
            """,
        1: """
            aabb
            ..b.
            .b..
            bbbb
            """,
        2: """
            aabbb
            ...b.
            ..b..
            .b...
            bbbbb
            """,
    }[size]
    return _fx(g, pal, color)


def fx_sweat(color=SLEEPY):
    """Sweat drop (4x5 + outline), light on the upper-left."""
    pal = {"w": tint(color, 0.7), "b": rgba(color), "c": shade(color, 0.18)}
    g = """
        .b..
        .bb.
        wbbb
        bbbc
        .cc.
        """
    return _fx(g, pal, color)


def fx_sparkle(size=1, color=SPARKLE):
    """Four-point sparkle with a white core. size 0: 3x3, 1: 5x5, 2: 7x7 (plus outline)."""
    w, c = WHITE, rgba(color)
    g = {
        0: """
            .c.
            cwc
            .c.
            """,
        1: """
            ..c..
            ..c..
            ccwcc
            ..c..
            ..c..
            """,
        2: """
            ...c...
            ...c...
            ..cwc..
            ccwwwcc
            ..cwc..
            ...c...
            ...c...
            """,
    }[size]
    return _fx(g, {"w": w, "c": c}, color, outline=shade(color, 0.45))


def fx_cross(color=RED):
    """Small error 'x' mark (5x5 + outline)."""
    pal = {"a": tint(color, 0.35), "b": rgba(color), "c": shade(color, 0.2)}
    g = """
        ab.ab
        .bbc.
        ..b..
        .bbc.
        bc.bc
        """
    return _fx(g, pal, color)


def fx_check(color=GREEN):
    """Success check mark (7x5 + outline)."""
    pal = {"a": tint(color, 0.35), "b": rgba(color), "c": shade(color, 0.2)}
    g = """
        .....ab
        ....bbc
        ab.bbc.
        .bbbc..
        ..bc...
        """
    return _fx(g, pal, color)


def fx_heart(color="#FF6F91"):
    """Heart (7x6 + outline)."""
    pal = {"a": tint(color, 0.5), "b": rgba(color), "c": shade(color, 0.2)}
    g = """
        .bb.bb.
        babbbbb
        bbbbbbc
        .bbbbc.
        ..bbc..
        ...c...
        """
    return _fx(g, pal, color)


def fx_dots(n=3, color=None, bubble=True):
    """Typing indicator: n (0-3) dots in a small speech bubble (13x9 outlined), tail at the
    bottom-left so it sits up and to the right of the head."""
    ink = rgba(color) if color else INK
    if not bubble:
        c = Canvas(8, 2)
        for i in range(max(0, min(3, n))):
            c.rect(i * 3, 0, 2, 2, ink)
        return c
    paper, edge = rgba("#FFFFFF"), rgba("#D9D4E4")
    b = sprite("""
        .ppppppppp.
        ppppppppppp
        ppppppppppp
        ppppppppppp
        .eeeeeeeee.
        ..pe.......
        ..e........
        """, {"p": paper, "e": edge})
    for i in range(max(0, min(3, n))):
        b.rect(2 + i * 3, 2, 2, 1, ink)
    return Canvas(b.w + 2, b.h + 2).paste(b, 1, 1).outline(outline_of("#B8B0C8", 0.5))


def prop_laptop(frame=0, width=16, glow=True):
    """Tiny laptop for the working row, lid back toward the viewer (the pet types behind
    it), hinge and base below. Size (width + 4) x 13 including outline; width = lid width
    (14-22). Centre it on the ground:
        lap = prop_laptop(i); canvas.paste(lap, CX - lap.w // 2, GROUND - lap.h + 1)
    The lid logo pulses with the screen colour by frame (0..5)."""
    lw = max(10, int(width))
    pulse = (0.0, 0.35, 0.15, 0.5, 0.1, 0.3)[frame % 6] if glow else 1.0
    E, Lt, M, D = rgba("#DCE2EE"), rgba("#B3BBCB"), rgba("#9AA2B5"), rgba("#7D8599")
    Hn, B0, B1, B2 = rgba("#5A6072"), rgba("#A9B1C2"), rgba("#8890A3"), rgba("#6E7588")
    ring = mix(Lt, SCREEN, 0.55 * (1 - pulse)) if glow else rgba("#A7AFC0")
    core = mix(WHITE, SCREEN, pulse) if glow else rgba("#C3CAD8")
    s = Canvas(lw + 2, 11)
    s.rect(1, 0, lw, 1, E)                       # lid top edge (its thickness catches light)
    s.rect(1, 1, lw, 7, M)
    s.rect(1, 1, 1, 7, Lt).set(2, 1, Lt)         # lit left edge
    s.rect(lw, 1, 1, 7, D)                       # shaded right edge
    s.rect(1, 8, lw, 1, D)                       # lid bottom
    s.rect(0, 9, lw + 2, 1, Hn)                  # hinge
    s.rect(0, 10, lw + 2, 1, B1).set(0, 10, B0).set(lw + 1, 10, B2)   # base edge
    cx = 1 + lw // 2 - 1
    for (dx, dy) in ((0, 3), (1, 3), (-1, 4), (2, 4), (0, 5), (1, 5)):
        s.set(cx + dx, dy, ring)
    s.set(cx, 4, core).set(cx + 1, 4, core)
    return Canvas(s.w + 2, s.h + 2).paste(s, 1, 1).outline(outline_of("#7D8599", 0.55))


# --------------------------------------------------------------------------------------
# PNG
# --------------------------------------------------------------------------------------

def _chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def write_png(path, w, h, rows):
    """Write RGBA8 PNG. rows: list of h bytes objects of length w*4 (or one flat bytes)."""
    if isinstance(rows, (bytes, bytearray)):
        stride = w * 4
        rows = [bytes(rows[i * stride:(i + 1) * stride]) for i in range(h)]
    if len(rows) != h or any(len(r) != w * 4 for r in rows):
        raise PetError("write_png: row data does not match size")
    raw = b"".join(b"\x00" + r for r in rows)
    data = b"\x89PNG\r\n\x1a\n"
    data += _chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    data += _chunk(b"IDAT", zlib.compress(raw, 9))
    data += _chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    return path


def read_png(path):
    """Read an 8-bit non-interlaced PNG (RGBA, RGB, grey, grey+alpha, palette).
    Returns (w, h, [rgba tuples])."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise PetError(f"{path}: not a PNG")
    pos, idat, plte, trns = 8, b"", None, None
    w = h = depth = ctype = interlace = None
    while pos < len(data):
        (ln,) = struct.unpack(">I", data[pos:pos + 4])
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if tag == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif tag == b"PLTE":
            plte = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif tag == b"tRNS":
            trns = body
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
    if depth != 8 or interlace:
        raise PetError(f"{path}: only 8-bit non-interlaced PNGs are supported")
    bpp = {6: 4, 2: 3, 0: 1, 4: 2, 3: 1}[ctype]
    raw = zlib.decompress(idat)
    stride = w * bpp
    out, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        ft = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if ft == 1:
                line[x] = (line[x] + a) & 255
            elif ft == 2:
                line[x] = (line[x] + b) & 255
            elif ft == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif ft == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        for x in range(w):
            o = x * bpp
            if ctype == 6:
                out.append(tuple(line[o:o + 4]))
            elif ctype == 2:
                out.append((line[o], line[o + 1], line[o + 2], 255))
            elif ctype == 0:
                out.append((line[o],) * 3 + (255,))
            elif ctype == 4:
                out.append((line[o],) * 3 + (line[o + 1],))
            else:
                k = line[o]
                a = trns[k] if trns and k < len(trns) else 255
                out.append(plte[k] + (a,))
        prev = line
    return w, h, out


# --------------------------------------------------------------------------------------
# GIF (GIF89a, global palette, LZW)
# --------------------------------------------------------------------------------------

def _lzw(indices, min_size):
    clear, eoi = 1 << min_size, (1 << min_size) + 1
    out = bytearray()
    acc = nbits = 0

    def emit(code, size):
        nonlocal acc, nbits
        acc |= code << nbits
        nbits += size
        while nbits >= 8:
            out.append(acc & 255)
            acc >>= 8
            nbits -= 8

    size = min_size + 1
    table = {}
    nxt = eoi + 1
    emit(clear, size)
    prefix = indices[0]
    for k in indices[1:]:
        key = (prefix << 8) | k
        code = table.get(key)
        if code is not None:
            prefix = code
            continue
        emit(prefix, size)
        table[key] = nxt
        nxt += 1
        if nxt == 4096:
            emit(clear, size)
            table = {}
            nxt = eoi + 1
            size = min_size + 1
        elif nxt > (1 << size):
            size += 1
        prefix = k
    emit(prefix, size)
    emit(eoi, size)
    if nbits:
        out.append(acc & 255)
    return bytes(out)


def write_gif(path, canvases, delays_ms, scale=1, bg="#D6D6D6", loop=0):
    """Animated GIF from Canvases (flattened over bg, upscaled by `scale`).
    delays_ms per frame (GIF stores centiseconds)."""
    frames = [c.over(bg) for c in canvases]
    w, h = frames[0].w, frames[0].h
    colors = {}
    for f in frames:
        for p in f.px:
            if p not in colors:
                colors[p] = len(colors)
    if len(colors) > 256:  # crude fallback quantiser; pets should never need it
        def q(p):
            return (p[0] & 0xE0 | 0x10, p[1] & 0xE0 | 0x10, p[2] & 0xC0 | 0x20, 255)
        frames2 = []
        for f in frames:
            g = f.copy()
            g.px = [q(p) for p in g.px]
            frames2.append(g)
        frames = frames2
        colors = {}
        for f in frames:
            for p in f.px:
                colors.setdefault(p, len(colors))
    bits = max(1, (len(colors) - 1).bit_length())
    table_size = 1 << bits
    pal = bytearray()
    for p, _ in sorted(colors.items(), key=lambda kv: kv[1]):
        pal += bytes(p[:3])
    pal += b"\x00" * (3 * table_size - len(pal))
    W2, H2 = w * scale, h * scale
    out = bytearray(b"GIF89a")
    out += struct.pack("<HHBBB", W2, H2, 0x80 | 0x70 | (bits - 1), 0, 0)
    out += pal
    out += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01" + struct.pack("<H", loop) + b"\x00"
    min_size = max(2, bits)
    for f, d in zip(frames, delays_ms):
        cs = max(2, int(round(d / 10.0)))
        out += b"\x21\xF9\x04" + bytes([0x04]) + struct.pack("<H", cs) + b"\x00\x00"
        out += b"\x2C" + struct.pack("<HHHHB", 0, 0, W2, H2, 0)
        idx = bytearray()
        for y in range(h):
            row = bytearray()
            for p in f.px[y * w:(y + 1) * w]:
                row += bytes([colors[p]]) * scale
            idx += bytes(row) * scale
        data = _lzw(idx, min_size)
        out.append(min_size)
        for i in range(0, len(data), 255):
            blk = data[i:i + 255]
            out.append(len(blk))
            out += blk
        out.append(0)
    out.append(0x3B)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(out)
    return path


# --------------------------------------------------------------------------------------
# Atlas, validation, lint
# --------------------------------------------------------------------------------------

def mirror_row(frames):
    """Mirror a list of frames horizontally (running-right -> running-left)."""
    return [f.flipped() for f in frames]


def validate(frames):
    """Hard checks against the contract. Raises PetError listing every problem."""
    errs = []
    if not isinstance(frames, dict):
        raise PetError("frames() must return a dict {row_name: [Canvas, ...]}")
    for name in frames:
        if name not in FRAME_COUNTS:
            errs.append(f"unknown row {name!r} (rows: {', '.join(ROW_NAMES)})")
    for name, n in ROWS:
        fs = frames.get(name)
        if fs is None:
            errs.append(f"missing row {name!r}")
            continue
        if len(fs) != n:
            errs.append(f"row {name!r} has {len(fs)} frames, needs {n}")
        for i, f in enumerate(fs):
            if not isinstance(f, Canvas):
                errs.append(f"{name}[{i}] is {type(f).__name__}, not Canvas")
            elif (f.w, f.h) != (W, H):
                errs.append(f"{name}[{i}] is {f.w}x{f.h}, needs {W}x{H}")
            elif f.bbox() is None:
                errs.append(f"{name}[{i}] is empty")
    if errs:
        raise PetError("invalid frames:\n  " + "\n  ".join(errs))


def lint(frames):
    """Soft checks: returns a list of warning strings."""
    warns = []
    for name, _ in ROWS:
        for i, f in enumerate(frames.get(name, [])):
            bb = f.bbox()
            if not bb:
                continue
            x0, y0, x1, y1 = bb
            if x0 == 0 or x1 == W - 1 or y0 == 0:
                warns.append(f"{name}[{i}]: touches the cell edge (bbox {bb}); it may look clipped")
            if y1 > GROUND:
                warns.append(f"{name}[{i}]: pixels below the ground line (lowest y={y1}, ground={GROUND})")
            semi = sum(1 for p in f.px if 0 < p[3] < 255)
            if semi:
                warns.append(f"{name}[{i}]: {semi} semi-transparent px (pixel art should be 0/255 alpha)")
            ncol = len({p for p in f.px if p[3]})
            if ncol > 40:
                warns.append(f"{name}[{i}]: {ncol} colours; keep ramps tight (<= ~32)")
    idle = frames.get("idle") or []
    if idle and idle[0].bbox() and idle[0].bbox()[3] != GROUND:
        warns.append(f"idle[0]: feet should touch y={GROUND} (lowest opaque row is {idle[0].bbox()[3]})")
    for name in ("idle", "running"):
        for i, f in enumerate(frames.get(name, [])):
            bb = f.bbox()
            if bb and bb[3] < GROUND:
                warns.append(f"{name}[{i}]: floats above the ground (lowest y={bb[3]})")
    # registration: planted feet must not slide between idle frames
    if idle:
        rows = [tuple(x for x in range(W) if f.opaque(x, GROUND)) for f in idle]
        for i, r in enumerate(rows[1:], 1):
            if r != rows[0]:
                warns.append(f"idle[{i}]: ground-row pixels differ from idle[0] (feet jitter?)")
    return warns


def build_atlas(frames):
    """Logical atlas Canvas (384x468); save with scale=SCALE for the 1536x1872 sheet."""
    validate(frames)
    atlas = Canvas(W * COLS, H * len(ROWS))
    for r, (name, n) in enumerate(ROWS):
        for i, f in enumerate(frames[name]):
            atlas.paste(f, i * W, r * H)
    return atlas


def write_pack(pet, frames, dest_dir):
    """Write spritesheet.png (1536x1872) + pet.json into dest_dir."""
    for k in ("id", "displayName", "description"):
        if not pet.get(k):
            raise PetError(f"PET is missing {k!r}")
    atlas = build_atlas(frames)
    os.makedirs(dest_dir, exist_ok=True)
    atlas.save(os.path.join(dest_dir, "spritesheet.png"), scale=SCALE)
    meta = {
        "id": pet["id"],
        "displayName": pet["displayName"],
        "description": pet["description"],
        "spriteVersionNumber": 1,
        "spritesheetPath": "spritesheet.png",
    }
    if pet.get("quips"):
        # Sidekick extension: {"sent": str, "working": str} speech-bubble lines. Codex ignores it.
        meta["quips"] = pet["quips"]
    with open(os.path.join(dest_dir, "pet.json"), "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    # round-trip check
    w, h, _ = read_png(os.path.join(dest_dir, "spritesheet.png"))
    if (w, h) != (W * COLS * SCALE, H * len(ROWS) * SCALE):
        raise PetError(f"spritesheet is {w}x{h}")
    return dest_dir


# --------------------------------------------------------------------------------------
# Previews
# --------------------------------------------------------------------------------------

CHECK_A, CHECK_B = rgba("#F4F4F6"), rgba("#E7E7EB")
GUIDE = rgba("#F2B8B8")
LABEL = rgba("#3B3B45")
LABEL_DIM = rgba("#8C8C99")
UNUSED = rgba("#D3D3DA")
PREVIEW_BG = rgba("#D6D6D6")
DARK_BG = rgba("#1E1E1E")


def _checker(c, x, y, w, h, sq=4):
    for j in range(h):
        for i in range(w):
            c.px[(y + j) * c.w + x + i] = CHECK_A if ((i // sq + j // sq) % 2 == 0) else CHECK_B


def _sheet(pet, frames):
    """Logical contact sheet; saved at x2."""
    label_w = max(text_width(f"{r} {n.upper()}") for r, n in enumerate(ROW_NAMES)) + 10
    gap, row_gap, top = 3, 10, 16
    sw = label_w + COLS * (W + gap) + 6
    sh = top + len(ROWS) * (H + row_gap) + 4
    s = Canvas(sw, sh, fill="#FFFFFF")
    s.text(4, 4, f"{pet['displayName'].upper()}  ({pet['id'].upper()})", LABEL)
    for r, (name, n) in enumerate(ROWS):
        y = top + r * (H + row_gap)
        s.text(4, y + H // 2 - 6, f"{r} {name.upper()}", LABEL)
        s.text(4, y + H // 2 + 2, f"{n} FR", LABEL_DIM)
        for i in range(COLS):
            x = label_w + i * (W + gap)
            if i >= n:
                s.rect(x, y, W, H, UNUSED)
                continue
            _checker(s, x, y, W, H)
            s.hline(x, x + W - 1, y + GROUND + 1, GUIDE)       # ground guide (just below feet)
            s.set(x + CX - 1, y + H - 1, GUIDE).set(x + CX, y + H - 1, GUIDE)  # centre tick
            s.set(x + CX - 1, y, GUIDE).set(x + CX, y, GUIDE)
            if name in frames and i < len(frames[name]):
                s.paste(frames[name][i], x, y)
            ms = TIMINGS[name][i]
            s.text(x + W - text_width(str(ms)) - 1, y + H + 2, str(ms), LABEL_DIM)
            s.text(x + 1, y + H + 2, str(i), LABEL_DIM)
    return s


def _dark(frames):
    gap = 6
    s = Canvas(len(ROWS) * (W + gap) + gap, H + gap * 2 + 8, fill=DARK_BG)
    for r, (name, _) in enumerate(ROWS):
        x = gap + r * (W + gap)
        if frames.get(name):
            s.paste(frames[name][0], x, gap)
        lbl = name.upper().replace("RUNNING-", "RUN-")
        s.text(x + (W - text_width(lbl)) // 2, gap + H + 2, lbl, "#8A8A8A")
    return s


def _strip(frames_row):
    gap = 2
    s = Canvas(len(frames_row) * (W + gap) - gap, H)
    for i, f in enumerate(frames_row):
        x = i * (W + gap)
        _checker(s, x, 0, W, H)
        s.hline(x, x + W - 1, GROUND + 1, GUIDE)
        s.paste(f, x, 0)
    return s


def zoom(frame, k=10):
    """Pixel-inspection image of one 48x52 frame: k x k blocks with a faint pixel grid,
    the ground row and centre line marked in red. Returns a Canvas (already scaled)."""
    out = Canvas(frame.w * k, frame.h * k)
    grid_dark = rgba("#00000022")
    for y in range(frame.h):
        for x in range(frame.w):
            p = frame.get(x, y)
            if not p[3]:
                p = CHECK_A if ((x // 4 + y // 4) % 2 == 0) else CHECK_B
            elif p[3] < 255:
                p = frame.copy().over(CHECK_A).get(x, y)
            out.rect(x * k, y * k, k, k, p)
            out.rect(x * k, y * k + k - 1, k, 1, mix(p, "#000000", 0.12))
            out.rect(x * k + k - 1, y * k, 1, k, mix(p, "#000000", 0.12))
    for x in range(frame.w * k):
        out.set(x, (GROUND + 1) * k, "#E5484D")
    for y in range(frame.h * k):
        if (y // 3) % 2 == 0:
            out.set(CX * k - 1, y, "#E5484D")
    return out


def write_zoom(stem, row, idx=None, k=10):
    """Write out/<stem>/zoom/<row>_<i>.png for one frame (or every frame of the row)."""
    mod = _load_pet(stem)
    frames = mod.frames()
    if row not in frames:
        raise PetError(f"no row {row!r}")
    idxs = range(len(frames[row])) if idx is None else [int(idx)]
    paths = []
    for i in idxs:
        path = os.path.join(OUT_ROOT, stem, "zoom", f"{row}_{i}.png")
        zoom(frames[row][i], k).save(path)
        paths.append(path)
    return paths


def write_previews(pet, frames, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    paths = []
    paths.append(_sheet(pet, frames).save(os.path.join(out_dir, "sheet.png"), scale=2))
    paths.append(_dark(frames).save(os.path.join(out_dir, "frames_dark.png"), scale=2))
    rows_dir = os.path.join(out_dir, "rows")
    for name, _ in ROWS:
        fs = frames[name]
        d = TIMINGS[name]
        if name == "idle":
            d = [t * IDLE_LOOP_MULT for t in d]
        paths.append(write_gif(os.path.join(out_dir, f"{name}.gif"), fs, d, scale=4, bg=PREVIEW_BG))
        _strip(fs).save(os.path.join(rows_dir, f"{name}.png"), scale=4)
    # all.gif: every row once at base timing, labelled
    allf, alld = [], []
    for name, _ in ROWS:
        for f, t in zip(frames[name], TIMINGS[name]):
            c = Canvas(W, H + 8)
            c.fill(PREVIEW_BG)
            c.paste(f, 0, 0)
            c.rect(0, H, W, 8, "#C4C4C4")
            lbl = name.upper()
            c.text((W - text_width(lbl)) // 2, H + 2, lbl, LABEL)
            allf.append(c)
            alld.append(t)
    paths.append(write_gif(os.path.join(out_dir, "all.gif"), allf, alld, scale=4, bg=PREVIEW_BG))
    return paths


# --------------------------------------------------------------------------------------
# Build / CLI
# --------------------------------------------------------------------------------------

def _load_pet(stem):
    path = os.path.join(PETS_SRC, f"{stem}.py")
    if not os.path.exists(path):
        raise PetError(f"no pet module at {path}")
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    sys.modules.setdefault("petgen", sys.modules[__name__])
    spec = importlib.util.spec_from_file_location(f"pets.{stem}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    if not hasattr(mod, "PET") or not hasattr(mod, "frames"):
        raise PetError(f"{path} must define PET and frames()")
    return mod


def build_pet(stem, preview_only=False, quiet=False):
    """Build one pet module. Underscore-prefixed modules (examples) never write into the
    app's Resources: their pack goes to out/<stem>/pack/."""
    mod = _load_pet(stem)
    pet = dict(mod.PET)
    if not stem.startswith("_") and pet.get("id") != stem:
        raise PetError(f"PET['id'] is {pet.get('id')!r} but the module is {stem}.py; they must match")
    frames = mod.frames()
    validate(frames)
    out_dir = os.path.join(OUT_ROOT, stem)
    if stem.startswith("_"):
        pack_dir = os.path.join(out_dir, "pack")
    else:
        pack_dir = os.path.join(RESOURCES, pet["id"])
    if not preview_only:
        write_pack(pet, frames, pack_dir)
    write_previews(pet, frames, out_dir)
    warns = lint(frames)
    if not quiet:
        print(f"[{stem}] {pet['displayName']}: {sum(len(v) for v in frames.values())} frames")
        if not preview_only:
            print(f"  pack     {pack_dir}/spritesheet.png, pet.json")
        print(f"  previews {out_dir}/sheet.png, frames_dark.png, all.gif, <row>.gif, rows/<row>.png")
        for w_ in warns:
            print("  warn:", w_)
    return pack_dir, out_dir, warns


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    usage = ("usage:\n"
             "  petgen.py build <id>|all [--preview-only]\n"
             "  petgen.py zoom <id> <row> [frame]     # x10 pixel-grid PNGs in out/<id>/zoom/")
    if len(argv) >= 3 and argv[0] == "zoom":
        try:
            for p in write_zoom(argv[1], argv[2], argv[3] if len(argv) > 3 else None):
                print(p)
            return 0
        except PetError as e:
            print(f"ERROR: {e}")
            return 1
    if len(argv) < 2 or argv[0] != "build":
        print(usage)
        return 2
    preview_only = "--preview-only" in argv
    target = argv[1]
    if target == "all":
        stems = sorted(f[:-3] for f in os.listdir(PETS_SRC) if f.endswith(".py") and not f.startswith("_"))
    else:
        stems = [target]
    if not stems:
        print("no pets in tools/petgen/pets/ (underscore-prefixed modules are skipped by 'all')")
    rc = 0
    for stem in stems:
        try:
            build_pet(stem, preview_only=preview_only)
        except PetError as e:
            print(f"[{stem}] ERROR: {e}")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    sys.modules.setdefault("petgen", sys.modules[__name__])
    sys.exit(main())
