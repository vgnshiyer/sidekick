# Sidekick pet style guide

Six pets, one family. Every pet is drawn in code with `petgen.py`, follows the same
canvas, light, outline, face and motion rules below, and uses the shared effect glyphs.
Start by copying `pets/_example.py` (a lilac blob). It exercises every row.

## Rules

- **Original art only.** Draw every pixel yourself, as grids or shapes in code. Never copy,
  trace or download sprites: no Codex built-in pets, no Clawd sprites, no fan art.
- **Python 3 standard library only.** Use `from petgen import *` and nothing else.
- **Binary alpha.** Every pixel is fully opaque or fully transparent. No anti-aliasing and no
  soft shadows on the ground.

## Workflow

```sh
python3 tools/petgen/petgen.py build <id>          # pack + previews
python3 tools/petgen/petgen.py build <id> --preview-only
python3 tools/petgen/petgen.py zoom <id> <row> [frame]   # x10 pixel-grid inspection PNGs
python3 tools/petgen/petgen.py build all           # every pets/*.py not starting with _
```

1. Create `tools/petgen/pets/<id>.py`, using a lowercase id such as `fox` or `moth`. It exposes
   `PET = {"id", "displayName", "description"}` and `frames() -> {row: [Canvas, ...]}`.
   The `id` must match the file name. `PET` may also carry `"quips": {"sent": "...", "working": "..."}`,
   one-line speech-bubble lines Sidekick shows after a send and when work starts (Codex ignores them).
2. Build. The pack goes to `Sources/Sidekick/Resources/Pets/<id>/`, as `spritesheet.png`
   (1536x1872) plus `pet.json`. Previews go to `tools/petgen/out/<id>/`:
   - `sheet.png`: every row at x2 over a checker, with a red ground guide and timings.
   - `rows/<row>.png`: one row at x4. **Look at these.**
   - `frames_dark.png`: frame 0 of each row on `#1e1e1e`, to check the silhouette on dark wallpaper.
   - `<row>.gif` and `all.gif`: the motion with the real timings. Idle runs at the app's 6x
     loop speed.
   - `zoom/<row>_<i>.png`: x10 with a pixel grid, for hunting stray pixels.
3. Fix every `warn:` line, or have a reason it's intentional.
4. Look, fix, rebuild. Use the Read tool on the PNGs. A GIF only shows you its first frame, so
   judge motion from `rows/<row>.png` side by side.

## The contract

| Row | Name | Frames | Timing (ms) | Shown when |
|---|---|---|---|---|
| 0 | idle | 6 | 280, 110, 110, 140, 140, 320, looped about 6x slower | nothing is happening |
| 1 | running-right | 8 | 120 each, last 220 | being dragged right |
| 2 | running-left | 8 | 120 each, last 220 | being dragged left |
| 3 | waving | 4 | 140 each, last 280 | hover |
| 4 | jumping | 5 | 140 each, last 280 | a thread finished (plays, then review) |
| 5 | failed | 8 | 140 each, last 240 | a thread failed (loops) |
| 6 | waiting | 6 | 150 each, last 260 | a thread needs input (loops) |
| 7 | running | 6 | 120 each, last 220 | an agent is working: **at a tiny laptop** |
| 8 | review | 6 | 150 each, last 280 | done and happy (loops) |

Art is authored at 48x52 per cell and scaled x4 nearest-neighbour. The app shows the pet at
96x104 pt (1 art pixel = 2x2 device pixels on Retina), and also at 48x52 and 144x156 pt. Any
feature under 2 px wide disappears at Small, so faces use 2-px features.

## Canvas layout

- **Ground line y = 47.** In resting poses, the lowest opaque row, outline included, is
  y=47. Rows 48-51 stay empty. Feet are planted there. A planted foot never sinks below it,
  even on a "down" bob frame.
- **Centre line between x=23 and x=24.** `CX = 24`, and mirroring maps x to 47 - x. Use even
  widths centred on CX so shapes stay symmetric (`x = CX - w // 2`).
- **Body 30-40 px tall** including the outline, centred. The example runs from y=16 to y=47,
  32 px tall and 32 px wide. Keep the top of the head at about y=8-17 at rest.
- **Headroom.** A jump lifts the body by up to about 11 px. Effect glyphs live above the head
  in y 1-14, or beside it. Keep 1 px clear of every cell edge (lint warns).
- **Width.** Keep the character, including its arms, inside x 2-45 in every frame.

## Light, colour and outline

- **Light comes from the top-left** (`LIGHT`). Highlights go on the top and left, shadows on
  the bottom and right. Mirrored frames must not flip the light: re-render the pose mirrored
  instead (see "running-left" below).
- **2-3 tones per material, plus one highlight at most.** Build each ramp from one base colour:
  `TONES = [shade(B, .34), shade(B, .17), B, tint(B, .42)]`. `shade` and `tint` hue-shift
  toward violet and warm yellow, so shadows are never grey mud. Use `sphere(...)` for round
  masses, which gives toon bands in the family's lighting. A 2-3 px gloss (`tint(B, .8)`) in
  the light band is optional.
- **Outline: 1 px, outside the silhouette, in a deep shade of the character's own colour.**
  Get it from `outline_of(base)`. Never use pure black. Use 4-neighbour outlines
  (`corners=False`, the default) for clean diagonals.
- **Outline each part separately before pasting**, back to front: far foot, body, face, near
  foot or arm, props. A front part's outline then draws the interior line where it overlaps.
  For multi-material characters, `outline(fn)` picks the outline per neighbouring colour.
- **Keep it under about 32 colours per frame.** No gradients and no dithering noise.
- **Dark check.** On `#1e1e1e` the outline mostly disappears, so the body's darkest tone must
  still separate from the background. Check `frames_dark.png`.

## Face

- **Eyes: 2x3 (or 2x2) in `INK` (#2A2238), with a 1-px `WHITE` highlight top-left.** The
  highlight stays top-left on both eyes; don't mirror it. Place the eyes about 38-45% of the
  way down the head and 8-12 px apart, centred on CX.
- **Mouth: 2-4 px of `INK`, centred.** It can have a `#FF7A9C` tongue inside when open.
  Optional blush is 2x1 below the outer corner of each eye.
- **Shared expressions** (pattern grids are in the example's `EYE` / `MOUTH`):
  `open`, `half`, `closed`, `down` (looking at the laptop), `happy` `^^`, `squint` `> <`,
  `x`, `sad`; and `smile`, `open`, `o`, `small`, `flat`, `frown`.
- **The face turns with the body.** Runs shift the whole face 2-3 px toward the travel
  direction.

## Shared effects (use these, don't draw your own)

| Colour | Hex | Use |
|---|---|---|
| `AMBER` | #F5A623 | attention: `fx_exclaim()`, `fx_question()` |
| `RED` | #E5484D | error: `fx_cross()` |
| `GREEN` | #30A46C | success: `fx_check()` |
| `SLEEPY` | #7FA7E8 | sleepy and sweat: `fx_z(size)`, `fx_sweat()` |
| `SPARKLE` | #FFE48A | celebration: `fx_sparkle(0/1/2)` |
| `SCREEN` | #8FE3FF | laptop glow: `prop_laptop(i)`, screen-light spill |

Every glyph comes pre-outlined. Paste it last, after the character. Placement:

- `!` goes centred above the head with a 2-4 px gap.
- The red `x` floats above-right of the head.
- The sweat drop starts at the head's upper-right edge and slides down.
- Sparkles go around the upper body.
- The dots bubble (`fx_dots(n)`) goes top-right, at about x=33 and y=4.
- The laptop is centred on the ground: `paste(lap, CX - lap.w // 2, GROUND - lap.h + 1)`.

## Motion, row by row

Keep registration stable. Nothing moves unless the motion calls for it: no accidental 1-px
jitter of the whole body. Anchor to GROUND and CX, keep the same body size across frames
except for deliberate squash and stretch, and keep the face slots fixed relative to the
body. Lint flags idle frames whose ground row changes.

- **idle (6)**: calm. Played about 6x slower, so each frame is held 0.7-2 s.
  f0 rest, f1 eyes `half`, f2 eyes `closed` (the blink sits on the two 110 ms frames),
  f3 inhale (+1 px taller: the top rises 1 px and the feet stay planted), f4 hold, f5 rest.
  No effect glyphs and nothing faster.
- **running-right (8)**: contact, down, passing, up, then the same for the other foot.
  The bob is 2 px in all: body -1 on the down frames and +1 on the up frames. Squash 1 px on
  contact and down, stretch 1 px on up. Lean the top 1-2 px into the run (`sheared`), turn
  the face 2-3 px, and swing the arms against the feet. Planted feet stay on y=47 and lifted
  feet rise 1-3 px. A foot lifted 2 px or more is drawn in front of the body, so the step
  reads. An optional dust puff goes behind the back foot on contact frames. Frame 7 is held
  220 ms, so make it an "up" pose.
- **running-left (8)**: the mirror image. Prefer re-rendering with the pose mirrored (feet,
  arms, look and lean negated) so the light stays top-left. `mirror_row()` flips pixels, and is
  only for a rig that can't do this.
- **waving (4)**: one arm, the viewer's right, raised. The hand arcs about 35, 65, 95, 65
  degrees, and f3 is held 280 ms. Happy eyes and an open smile. The rest of the body is still.
- **jumping (5)**: f0 anticipation squash (+3-4 wide, -4-5 tall, `squint`). f1 rise (stretch,
  lift about 7, arms up). f2 peak (lift about 11, normal shape, `happy`). f3 fall (slight
  stretch, lift about 5). f4 land squash (lift 0, wider, held 280 ms). Feet are on y=47 in
  f0 and f4.
- **failed (8)**: f0-f3 have `x` eyes, a frown, and a 1-px horizontal shake (-1, +1, -1, 0)
  with a growing 1-2 px slump; the red `x` floats above-right, bobbing 1 px. f4-f7 hold a
  slumped squash of about 3 px, `sad` eyes and drooping arms, while the sweat drop slides
  down 2 px per frame. It loops while the thread stays failed, so the loop must not look
  frantic.
- **waiting (6)**: f0 has a small `!`. On f1 the big `!` pops in highest, and the body hops
  or stretches 1 px. f2-f5 are a foot tap (one foot lifted 2 px on f2 and f4) while the `!`
  bobs 1 px. Wide-open eyes and an `o` mouth.
- **running = working (6)**: `prop_laptop(i)` sits in front on the ground, lid back toward
  the viewer. The eyes look `down`. The arms reach behind the lid. The typing paw alternates
  and dips 1 px, with a 2-px key-tap flick beside the lid. The screen light spills onto the
  body just above the lid as one `SCREEN`-tinted tone. The `fx_dots` bubble cycles 1, 2, 3
  dots, two frames each. The body itself barely moves.
- **review (6)**: `happy` `^^` eyes, an open smile and blush. A 1-px bounce on body height
  (0, +1, 0, -1, 0, 0). Arms up and out, alternating. Two or three sparkles in staggered
  phases grow and shrink (size 0, 1, 2, 1, 0).

## The rig approach (how to make 57 frames without drawing 57 frames)

`_example.py` uses this structure. Copy the structure, not the blob.

1. **Palette.** One base per material, then `TONES`, `OUTLINE = outline_of(base)`, and any
   accent colours.
2. **Pose dict.** `REST = dict(dx, lift, bw, bh, lean, eyes, look, mouth, arm_l, arm_r,
   feet, ...)` with `P(**overrides)`. Frames differ only in these numbers.
3. **Parts as functions.** Each part (body, feet, arms, eyes, mouth, props) draws onto its own
   layer: `sphere`, `ellipse`, `capsule`, `disc`, or `grid` strings for hand-placed detail.
   The layer is outlined, then pasted. Paint markings (stripes, belly, spots) with
   `paste(..., inside=True)` so they stay inside the body.
4. **`draw(p)`.** Composes back to front: far parts, body, face, near parts, props, fx.
5. **Squash and stretch.** Re-render shapes with new sizes (`bw`/`bh`); that gives the
   cleanest pixels. Use `squash()` or `scaled()` only on hand-drawn grid parts, *before*
   outlining, and draw the face afterwards so the eyes keep their shape.
6. **Rows.** Each row is a short list of pose overrides, as in the examples above.

## Hand-off checklist

- `build` passes with no `warn:` lines, or with a stated reason.
- `sheet.png` reads at a glance. Each row's intent is obvious without labels.
- `rows/<row>.png`: no jitter, feet on the guide, outline unbroken, no orphan pixels.
- `frames_dark.png`: the silhouette and face read on `#1e1e1e`.
- The face reads at 48x52 pt. No 1-px-only features carry an expression.
- Shared fx colours and glyphs are used. The laptop is `prop_laptop`.
- Every pixel is your own.
