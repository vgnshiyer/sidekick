#!/usr/bin/env python3
"""Family lineups: every petgen pet side by side, one row per animation row.

    python3 tools/petgen/lineup.py            # out/family_light.png, out/family_dark.png
    python3 tools/petgen/lineup.py waving DIR # DIR/lineup_waving.png: every frame of one row, x3

Frame 0 of every row is shown (frame 1 for waiting, where the big `!` pops in).
Saved at x2. Stdlib + petgen only.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import petgen as P  # noqa: E402

sys.modules.setdefault("petgen", P)

PETS = ["clawd", "cat", "capybara", "duck", "hamster", "octopus"]
BGS = {"light": "#F4F4F6", "dark": P.DARK_BG}
GAP = 4


def strip(frames, row, idx, bg):
    c = P.Canvas(len(PETS) * (P.W + GAP) + GAP, P.H + 2 * GAP, fill=bg)
    for k, pid in enumerate(PETS):
        fs = frames[pid][row]
        c.paste(fs[min(idx, len(fs) - 1)], GAP + k * (P.W + GAP), GAP)
    return c


def stack(canvases, bg):
    s = P.Canvas(canvases[0].w, sum(c.h for c in canvases), fill=bg)
    y = 0
    for c in canvases:
        s.paste(c, 0, y)
        y += c.h
    return s


def main(argv):
    frames = {pid: P._load_pet(pid).frames() for pid in PETS}
    if argv:
        row, out = argv[0], argv[1] if len(argv) > 1 else P.OUT_ROOT
        n = dict(P.ROWS)[row]
        img = stack([strip(frames, row, i, BGS["light"]) for i in range(n)], BGS["light"])
        print(img.save(os.path.join(out, f"lineup_{row}.png"), scale=3))
        return 0
    for name, bg in BGS.items():
        rows = [strip(frames, row, 1 if row == "waiting" else 0, bg) for row, _ in P.ROWS]
        print(stack(rows, bg).save(os.path.join(P.OUT_ROOT, f"family_{name}.png"), scale=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
