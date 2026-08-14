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

Click on the canvas to draw the selected element. The panel below the canvas holds
the element palette, pen size, overwrite toggle, spigot configuration, a speed
slider (0 pauses), and Clear/Save/Load.

Resize the window and the grid grows or shrinks with it — you get more world, not
a scaled-up picture. Existing contents are anchored to the **bottom-left**, so
whatever was resting on the floor stays on the floor; growing reveals empty space
above and to the right, shrinking crops from the top and right. Spigots
redistribute across the new width. Saved snapshots are re-anchored the same way,
so a save taken at one size loads correctly at another.

## Architecture

The grid lives in two ping-ponged `R32UI` storage textures. A cell's low 6 bits are
its element id — the same 34 ids, in the same order, as the original's
`elements.js`. Bit 6 is a "moved this tick" flag used by the movement passes.

Every shader derives its bounds from `imageSize()`, so resizing needs no
recompilation: `FallingSand.resize()` allocates new textures, blits the overlapping
region across with `texture_copy` (a GPU-side copy, no readback), and rebuilds the
uniform sets. Resizes are debounced by 150 ms so dragging a window edge reallocates
once rather than every event.

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
    menu.gd               Control panel
    brush.gd              Pointer drawing
  shaders/                stamp / reaction / movement / scramble / colorize
```

## Testing

`main.gd` accepts test arguments after `--`:

```
godot --path . -- --demo=liquids --screenshot=out.png --frames=1200
```

Demos: `sand`, `liquids`, `fire`, `boom`, `boom2`, `lava`, `tree`, `magic`,
`stress`. Add `--test-saveload` to exercise a save → clear → load round trip, and
`--resize=1400x900,1700x1000` to drive one or more window resizes mid-run (spread
through the first half of the frame budget).

The window renders uncapped, so `--frames=N` is *not* N simulation ticks; the
screenshot log prints the actual tick count and the final grid size.

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
