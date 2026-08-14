# FS2 — Falling Sand

A Godot 4.7 GPU port of [Project Sand](https://github.com/joshdon) by Josh Don, the
falling sand game hosted at boredhumans.com. The simulation runs entirely in Vulkan
compute shaders at a locked 60 simulation ticks per second, on a grid that **fills
the window at one cell per pixel** — 922k cells at the default 1280×720, and still
60 ticks/second at 2400×1200 (2.9M cells, 10.7× the original's 560×480).

Licensed GPL-3.0, inherited from the original. See `LICENSE`.

## Running

The project needs the standard (non-.NET) Godot 4.7 build. Open the folder in the
editor, or from a shell:

```
godot --path C:\Users\user\Godot\FS2
```

Click on the canvas to draw the selected element. The cursor outline previews
exactly which cells the next stroke will cover — the grid is one cell per pixel, so
it is literal, not an approximation — and it takes the shape of the active tool.

Four tools:

| Tool | Behaviour |
| --- | --- |
| Round | Capsule stroke — the classic brush |
| Square | Square profile, for straight edges and blocks |
| Spray | Scattered spatter, densest at the centre and thinning toward the rim |
| Fill | Bucket: replaces the connected region of whatever you click on |

The toolbar is two centred rows. On top, the **palette**: every material as a
colour dot beside its name, at a fixed chip size so the block stays compact and
centred rather than stretching edge to edge. Hovering any element describes what it
actually does in the simulation. Below, centred under it: **Tool** (the four tools and the
overwrite toggle), **Size** (brush radius, 1–64 cells), **Speed** (target ticks per
second — 0 pauses — beside the measured rate), **Spigots**, and **Canvas**
(Save / Load / Clear).

**Click a material a second time to make it a source.** The chip's dot gains a
ring, and strokes then lay down fixed emitters that feed that material
continuously instead of dropping loose material — water once gives you water,
water twice gives you a spring. Sources never move, never react and never burn
away; only the eraser removes them, and fills stop at them rather than wiping them
out. They render washed toward white so they read as fixtures. Anything that flows
can be a source: powders, liquids, gases, and fire, which gives you a torch.

This replaces the original's dedicated `SPOUT`, `WELL` and `TORCH` elements and the
four fixed spigots along the top of the canvas, all of which are gone from the UI.
Their simulation code is untouched, so a saved canvas containing them still behaves
correctly, and `src/sim/spigots.gd` is left in the tree unused.

The panel is **draggable** — grab any empty part of the card — and **collapsible**
via the caret at its right, which shrinks it to just its header.

`SOIL` is currently withheld from the palette. Its simulation is untouched — soil,
wet soil and the trees they sprout all still run, and any already on the canvas
behaves normally; it is only hidden from the picker. Restore it by adding `SOIL`
back to `MENU_ITEMS` in `src/sim/elements.gd`.

**Solid** toggles what the edges of the world do. By default material that falls off
the bottom is discarded and gas that rises off the top escapes, as in the original.
Turn on **Floor** and material piles up against the bottom instead; turn on
**Ceiling** and gases collect against the top rather than venting away.

The control panel floats over the canvas rather than taking a slice out of it, so
the grid fills the whole window. It is slightly translucent, which keeps material
moving behind it readable instead of cut off dead — though note the strip behind
the panel is otherwise hidden, which matters most with a solid floor.

Resize the window and the grid grows or shrinks with it — you get more world, not
a scaled-up picture. Existing contents are anchored to the **bottom-left**, so
whatever was resting on the floor stays on the floor; growing reveals empty space
above and to the right, shrinking crops from the top and right. Spigots
redistribute across the new width. Saved snapshots are re-anchored the same way,
so a save taken at one size loads correctly at another.

## Architecture

The grid lives in two ping-ponged `R32UI` storage textures. A cell's low 6 bits are
its element id — the same 34 ids, in the same order, as the original's
`elements.js`. Bit 6 is a "moved this tick" flag used by the movement passes, and
bit 7 marks the cell as a source of its own element. Sources cost no extra memory
and need no new element ids; the movement pass loads them as already-moved so
nothing can shift or displace them, and the reaction pass rewrites every cell, so
it is the one place the bit could be lost and the one place it is preserved.

Every shader derives its bounds from `imageSize()`, so resizing needs no
recompilation: `FallingSand.resize()` allocates new textures, blits the overlapping
region across with `texture_copy` (a GPU-side copy, no readback), and rebuilds the
uniform sets. Resizes are debounced by 150 ms so dragging a window edge reallocates
once rather than every event.

Bucket fill is the one operation that does not run on the GPU. A parallel flood
would need one propagation pass per cell of travel, so instead it reads the grid
back once, runs a scanline fill on the CPU and uploads the result — a one-off cost
on click rather than per frame. A fill covering ~900k cells measures within noise
of no fill at all (175 versus 173 ticks over the same 400 frames).

One sharp edge worth knowing: `Texture2DRD` does **not** take ownership of the RID
you hand it, but the canvas renderer may still reference the old texture for a
frame or two after the swap. Replaced display textures are therefore retired on an
8-frame delay rather than freed immediately — see `_retired_displays`.

Each simulation tick runs these compute passes:

| Pass | Shader | Job |
| --- | --- | --- |
| Stamp | `stamp.glsl` | Applies CPU-issued draw commands (brush strokes, particle strokes, spigot emitters) from an SSBO |
| Reaction | `reaction.glsl` | Every non-movement element rule; emits particle-spawn events to an SSBO |
| Movement ×6 | `movement.glsl` | Margolus 2×2 block partitioning: gravity, density sinking, liquid spread, gas rise |
| Colorize | `colorize.glsl` | Converts element ids to an RGBA8 texture for display |

Because GPU cells update in parallel, the original's sequential bottom-to-top scan
can't be copied literally. Two techniques recover the behavior:

**Rule inversion.** "Fire converts a neighbouring plant" becomes "a plant bordering
fire becomes fire", so every cell writes only itself. Where the original picked
*one* neighbour to convert, the inverted rule divides the probability by the number
of candidate neighbours so the aggregate rate matches.

**Deterministic RNG replay.** All per-cell randomness is `pcg_hash(cell_index, tick,
salt)`, so any cell can recompute a *neighbour's* dice roll. That is how a cell next
to igniting nitro knows to turn into fire on the same tick, without scatter writes.

**Margolus blocks.** Movement partitions the grid into 2×2 blocks whose offset
shifts each pass, so writes are race-free by construction. Row parity strictly
alternates across the six passes, letting a vacancy opened in one pass be filled
from above in the next; the moved-bit still caps each cell at one move per tick,
matching the original's one-action-per-frame rule.

Particles (explosions, lava spurts, procedural trees, the magic star and spiral,
the nuke) stay on the CPU in `src/sim/particles.gd`, ported nearly line-for-line
from `particles.js`. Instead of drawing to an offscreen canvas they emit stamp
commands, and they are spawned from the events the reaction pass reports.

## Layout

```
src/
  main.gd / main.tscn     Root: tick accumulator, wiring, demo + screenshot hooks
  sim/
    falling_sand.gd       RenderingDevice orchestration, ping-pong, event readback
    elements.gd           Element ids, palette, menu metadata
    particles.gd          CPU particle pool and tree growth
    spigots.gd            The four top-of-canvas emitters
  ui/
    ui_theme.gd           Design tokens and style factories
    menu.gd               Control panel
    brush.gd              Pointer drawing and cursor ring
  shaders/                stamp / reaction / movement / scramble / colorize
```

## Testing

`main.gd` accepts test arguments after `--`:

```
godot --path . -- --demo=liquids --screenshot=out.png --frames=1200
```

Demos: `sand`, `liquids`, `fire`, `boom`, `boom2`, `lava`, `tree`, `magic`,
`stress`, `brushes` (the three stroke profiles), `fillbox` (a divided container for
testing fill), `sources` (water, sand and fire emitters) and `bounds` (material
heading for the floor and gas for the ceiling). Add `--test-saveload` to exercise a save → clear → load round
trip, `--test-fill=x,y[,element]` to seed a bucket fill mid-run, and
`--resize=1400x900,1700x1000` to drive one or more window resizes (spread through
the first half of the frame budget).

Also `--solid=floor,ceiling` to start with solid edges, `--hide-ui` to drop the
floating panel (the only way to see what is happening at the very bottom of the
canvas), `--collapsed` to start with the panel collapsed, and `--panel-at=x,y` to
place it, which exercises the same path a drag does.

The window renders uncapped, so `--frames=N` is *not* N simulation ticks; the
screenshot log prints the actual tick count and the final grid size.

**After editing any `.glsl`, run `godot --headless --path . --import` before
testing.** Running the project directly does not reliably reimport a changed
shader, and the stale SPIR-V is used silently — a shader change that appears to
have no effect is usually this rather than a logic error.

## Known deviations from the original

These are consequences of parallel evaluation and are the first places to look when
tuning:

- Free-falling blobs of solid material dilate slightly at the edges, because
  vacancies propagate upward one block per pass rather than instantaneously.
- Liquids equalize a little more slowly than the sequential original.
- Rules of the form "convert one random neighbour" are approximated by dividing the
  probability by the neighbour count, which matches the rate but not the exact
  correlation between neighbours.
- The MYSTERY + FIRE canvas scramble is a butterfly-swap approximation of a
  Fisher-Yates shuffle, which cannot run sequentially on the GPU.
