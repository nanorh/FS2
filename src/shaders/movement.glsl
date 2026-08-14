#[compute]
#version 450

// Margolus 2x2 block movement pass. Each thread owns one 2x2 block
// (shifted by the per-pass offset), so all writes are race-free.
// Four passes per tick cycle the offsets; a per-cell "moved" bit
// (bit 6) caps every cell at one move per tick, matching the
// original's one action per frame. The gravity roll is salted by
// tick (not pass), so a cell gets exactly one 95%-style roll per
// tick like the original doGravity().
//
// Behaviors ported from Project Sand's elements.js movement helpers:
// doGravity (fall -> diagonal -> sideways), doDensitySink,
// doDensityLiquid, doRise, doDensityGas, lava/steam pass-through.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, r32ui) uniform restrict uimage2D grid;

layout(push_constant) uniform Params {
	int offset_x;
	int offset_y;
	uint tick;
	uint pass_index;
} params;

const uint EL_BACKGROUND = 0u;
const uint EL_WALL = 1u;
const uint EL_SAND = 2u;
const uint EL_WATER = 3u;
const uint EL_PLANT = 4u;
const uint EL_FIRE = 5u;
const uint EL_SALT = 6u;
const uint EL_SALT_WATER = 7u;
const uint EL_OIL = 8u;
const uint EL_SPOUT = 9u;
const uint EL_WELL = 10u;
const uint EL_TORCH = 11u;
const uint EL_GUNPOWDER = 12u;
const uint EL_WAX = 13u;
const uint EL_FALLING_WAX = 14u;
const uint EL_NITRO = 15u;
const uint EL_NAPALM = 16u;
const uint EL_C4 = 17u;
const uint EL_CONCRETE = 18u;
const uint EL_FUSE = 19u;
const uint EL_ICE = 20u;
const uint EL_CHILLED_ICE = 21u;
const uint EL_LAVA = 22u;
const uint EL_ROCK = 23u;
const uint EL_STEAM = 24u;
const uint EL_CRYO = 25u;
const uint EL_MYSTERY = 26u;
const uint EL_METHANE = 27u;
const uint EL_SOIL = 28u;
const uint EL_WET_SOIL = 29u;
const uint EL_BRANCH = 30u;
const uint EL_LEAF = 31u;
const uint EL_POLLEN = 32u;
const uint EL_CHARGED_NITRO = 33u;
const uint EL_OOB = 63u; // sentinel for out-of-grid: immovable, non-background

const uint MOVED_BIT = 64u;
// Bit 7 marks a fixed source. Source cells never move and nothing may
// displace them, so they are loaded as already-moved.
const uint EMITTER_BIT = 128u;

// RNG salts (shared meanings with reaction.glsl where replayed)
const uint SALT_GRAV = 1u;
const uint SALT_SINK = 2u;
const uint SALT_RISE = 3u;
const uint SALT_GASR = 4u;
const uint SALT_LVP = 5u;
const uint SALT_EQ = 6u;
const uint SALT_GSIDE = 7u;
const uint SALT_GSIDE2 = 8u;
const uint SALT_ORDER = 9u;

uint pcg(uint v) {
	v = v * 747796405u + 2891336453u;
	uint w = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
	return (w >> 22u) ^ w;
}

ivec2 grid_size;

uint rnd100_at(ivec2 p, uint salt) {
	uint idx = uint(p.y * grid_size.x + p.x);
	return pcg(idx ^ pcg(salt ^ (params.tick * 0x9E3779B9u))) % 100u;
}

// Per-frame gravity chance; 0 = does not fall.
uint grav_chance(uint e) {
	switch (e) {
		case EL_SAND: case EL_WATER: case EL_SALT: case EL_SALT_WATER:
		case EL_OIL: case EL_GUNPOWDER: case EL_NITRO: case EL_NAPALM:
		case EL_CONCRETE: case EL_CRYO: case EL_MYSTERY: case EL_POLLEN:
		case EL_CHARGED_NITRO:
			return 95u;
		case EL_LAVA: case EL_FALLING_WAX:
			return 100u;
		case EL_ROCK: case EL_SOIL: case EL_WET_SOIL:
			return 99u;
	}
	return 0u;
}

// May fall diagonally and slide sideways (doGravity fallAdjacent=true).
bool falls_adjacent(uint e) {
	switch (e) {
		case EL_SAND: case EL_WATER: case EL_SALT: case EL_SALT_WATER:
		case EL_OIL: case EL_GUNPOWDER: case EL_NITRO: case EL_NAPALM:
		case EL_CONCRETE: case EL_CRYO: case EL_MYSTERY: case EL_POLLEN:
		case EL_CHARGED_NITRO: case EL_LAVA:
			return true;
	}
	return false;
}

// doDensitySink / doDensityLiquid vertical chances: element a sinking
// through element b directly below it.
uint sink_chance(uint a, uint b) {
	switch (a) {
		case EL_SAND:
			if (b == EL_WATER || b == EL_SALT_WATER) return 25u;
			break;
		case EL_SALT:
			if (b == EL_SALT_WATER) return 25u;
			break;
		case EL_WATER:
			if (b == EL_OIL) return 25u;
			break;
		case EL_SALT_WATER:
			if (b == EL_WATER) return 50u;
			break;
		case EL_NITRO:
			if (b == EL_OIL || b == EL_WATER || b == EL_SALT_WATER || b == EL_POLLEN) return 25u;
			break;
		case EL_CONCRETE:
			if (b == EL_WATER || b == EL_SALT_WATER) return 35u;
			break;
		case EL_ROCK:
			if (b == EL_WATER || b == EL_OIL || b == EL_SALT_WATER) return 95u;
			if (b == EL_LAVA) return 20u;
			break;
		case EL_SOIL:
			if (b == EL_WATER || b == EL_SALT_WATER || b == EL_POLLEN) return 50u;
			break;
		case EL_WET_SOIL:
			if (b == EL_WATER || b == EL_SALT_WATER) return 50u;
			break;
		case EL_CHARGED_NITRO:
			if (b == EL_SOIL || b == EL_WET_SOIL || b == EL_NITRO || b == EL_POLLEN) return 25u;
			break;
	}
	return 0u;
}

// Whether the element may density-sink diagonally (sinkAdjacent flag).
bool sink_adjacent_ok(uint a) {
	return a != EL_ROCK;
}

// Horizontal density equalization (doDensityLiquid adjacent swap).
uint equalize_chance(uint a, uint b) {
	if ((a == EL_WATER && b == EL_OIL) || (a == EL_OIL && b == EL_WATER)) return 50u;
	if ((a == EL_SALT_WATER && b == EL_WATER) || (a == EL_WATER && b == EL_SALT_WATER)) return 50u;
	return 0u;
}

bool is_gas(uint e) {
	return e == EL_STEAM || e == EL_METHANE;
}

uint rise_chance(uint e) {
	return e == EL_STEAM ? 70u : 25u;
}

uint side_chance(uint e) {
	return e == EL_STEAM ? 60u : 65u;
}

bool gas_permeable(uint e) {
	switch (e) {
		case EL_SAND: case EL_WATER: case EL_SALT: case EL_SALT_WATER:
		case EL_OIL: case EL_GUNPOWDER: case EL_FALLING_WAX: case EL_NITRO:
		case EL_NAPALM: case EL_CONCRETE: case EL_ROCK: case EL_CRYO:
		case EL_MYSTERY: case EL_SOIL: case EL_WET_SOIL: case EL_POLLEN:
		case EL_CHARGED_NITRO:
			return true;
	}
	return false;
}

// Block state: index 0 = top-left, 1 = top-right, 2 = bottom-left,
// 3 = bottom-right.
ivec2 cpos[4];
uint ce[4];
bool cmoved[4];
bool cvalid[4];
bool cdirty[4];

bool in_grid(ivec2 p) {
	return p.x >= 0 && p.y >= 0 && p.x < grid_size.x && p.y < grid_size.y;
}

uint load_elem_global(ivec2 p) {
	if (!in_grid(p)) return EL_OOB;
	return imageLoad(grid, p).r & 63u;
}

void move_cell(int from, int to) {
	ce[to] = ce[from];
	ce[from] = EL_BACKGROUND;
	cmoved[to] = true;
	cdirty[from] = true;
	cdirty[to] = true;
}

void swap_cells(int a, int b) {
	uint tmp = ce[a];
	ce[a] = ce[b];
	ce[b] = tmp;
	cmoved[a] = true;
	cmoved[b] = true;
	cdirty[a] = true;
	cdirty[b] = true;
}

bool roll_grav(int i) {
	return rnd100_at(cpos[i], SALT_GRAV) < grav_chance(ce[i]);
}

// Vertical resolution for one column: t = top index, b = bottom index.
void resolve_vertical(int t, int b) {
	if (!cvalid[t] || !cvalid[b]) return;

	uint et = ce[t];
	uint eb = ce[b];

	// Fall / density sink
	if (!cmoved[t] && grav_chance(et) > 0u) {
		if (eb == EL_BACKGROUND && roll_grav(t)) {
			move_cell(t, b);
			return;
		}
		uint sc = sink_chance(et, eb);
		if (sc > 0u && !cmoved[b] && rnd100_at(cpos[t], SALT_SINK) < sc) {
			swap_cells(t, b);
			return;
		}
	}

	et = ce[t];
	eb = ce[b];

	// Gas rise (doRise into background / doDensityGas through permeable)
	if (!cmoved[b] && is_gas(eb)) {
		if (et == EL_BACKGROUND && rnd100_at(cpos[b], SALT_RISE) < rise_chance(eb)) {
			move_cell(b, t);
			return;
		}
		if (!cmoved[t] && gas_permeable(et) && rnd100_at(cpos[b], SALT_GASR) < 70u) {
			swap_cells(t, b);
			return;
		}
		// Steam rises through lava (LAVA_ACTION pass-through, 95%)
		if (!cmoved[t] && eb == EL_STEAM && et == EL_LAVA && rnd100_at(cpos[b], SALT_LVP) < 95u) {
			swap_cells(t, b);
			return;
		}
	}
}

// Diagonal fall: top cell t into the bottom cell of the other column d.
void resolve_diagonal(int t, int d) {
	if (!cvalid[t] || !cvalid[d]) return;
	uint et = ce[t];
	if (cmoved[t] || grav_chance(et) == 0u) return;

	// Only when the straight-down slot (in-block) is occupied.
	int straight = t + 2;
	if (cvalid[straight] && ce[straight] == EL_BACKGROUND) return;

	if (!roll_grav(t)) return;

	uint ed = ce[d];
	if (falls_adjacent(et) && ed == EL_BACKGROUND && !cmoved[d]) {
		move_cell(t, d);
		return;
	}
	uint sc = sink_chance(et, ed);
	if (sc > 0u && sink_adjacent_ok(et) && !cmoved[d] && rnd100_at(cpos[t], SALT_SINK) < sc) {
		swap_cells(t, d);
	}
}

// Diagonal gas rise: bottom cell b into the top cell of the other column u.
void resolve_diagonal_rise(int b, int u) {
	if (!cvalid[b] || !cvalid[u]) return;
	uint eb = ce[b];
	if (cmoved[b] || !is_gas(eb)) return;

	// Only when straight-up (in-block) is occupied.
	int straight = b - 2;
	if (cvalid[straight] && ce[straight] == EL_BACKGROUND) return;

	uint eu = ce[u];
	if (eu == EL_BACKGROUND && !cmoved[u] && rnd100_at(cpos[b], SALT_RISE) < rise_chance(eb)) {
		move_cell(b, u);
		return;
	}
	if (gas_permeable(eu) && !cmoved[u] && rnd100_at(cpos[b], SALT_GASR) < 70u) {
		swap_cells(b, u);
	}
}

// True when the cell can't fall anywhere below (global peek, may race
// with neighbouring blocks; only used as a heuristic gate for the
// sideways-slide fallback of doGravity).
bool below_blocked(ivec2 p) {
	if (load_elem_global(p + ivec2(0, 1)) == EL_BACKGROUND) return false;
	if (load_elem_global(p + ivec2(-1, 1)) == EL_BACKGROUND) return false;
	if (load_elem_global(p + ivec2(1, 1)) == EL_BACKGROUND) return false;
	return true;
}

// Horizontal resolution for one row pair (l, r).
void resolve_horizontal(int l, int r) {
	if (!cvalid[l] || !cvalid[r]) return;

	// Randomize which side acts first.
	int first = l;
	int second = r;
	uint order = pcg(uint(cpos[l].y * grid_size.x + cpos[l].x) ^ pcg(SALT_ORDER ^ params.tick ^ params.pass_index));
	if ((order & 1u) == 1u) { first = r; second = l; }

	for (int k = 0; k < 2; k++) {
		int a = (k == 0) ? first : second;
		int b = (k == 0) ? second : first;
		uint ea = ce[a];
		if (cmoved[a]) continue;

		// Sideways slide (doGravity fallback into background).
		if (falls_adjacent(ea) && ce[b] == EL_BACKGROUND && !cmoved[b]
				&& roll_grav(a) && below_blocked(cpos[a])) {
			move_cell(a, b);
			continue;
		}

		// Liquid horizontal equalization (doDensityLiquid).
		uint eq = equalize_chance(ea, ce[b]);
		if (eq > 0u && !cmoved[b] && rnd100_at(cpos[a], SALT_EQ) < eq
				&& below_blocked(cpos[a])) {
			swap_cells(a, b);
			continue;
		}

		// Gas sideways drift (doRise adjacent / doDensityGas adjacent).
		if (is_gas(ea)) {
			if (ce[b] == EL_BACKGROUND && !cmoved[b]
					&& rnd100_at(cpos[a], SALT_GSIDE) < side_chance(ea)) {
				move_cell(a, b);
				continue;
			}
			if (gas_permeable(ce[b]) && !cmoved[b]
					&& rnd100_at(cpos[a], SALT_GSIDE2) < 35u) {
				swap_cells(a, b);
				continue;
			}
		}
	}
}

void main() {
	grid_size = imageSize(grid);
	ivec2 block = ivec2(gl_GlobalInvocationID.xy);
	ivec2 origin = block * 2 - ivec2(params.offset_x, params.offset_y);
	if (origin.x >= grid_size.x || origin.y >= grid_size.y) return;

	for (int i = 0; i < 4; i++) {
		cpos[i] = origin + ivec2(i & 1, i >> 1);
		cvalid[i] = in_grid(cpos[i]);
		cdirty[i] = false;
		if (cvalid[i]) {
			uint raw = imageLoad(grid, cpos[i]).r;
			ce[i] = raw & 63u;
			cmoved[i] = (raw & (MOVED_BIT | EMITTER_BIT)) != 0u;
		} else {
			ce[i] = EL_OOB;
			cmoved[i] = true;
		}
	}

	uint order = pcg(uint(block.y * 4096 + block.x) ^ pcg(SALT_ORDER ^ (params.tick * 0x9E3779B9u) ^ params.pass_index));

	// Vertical: columns in random order.
	if ((order & 1u) == 0u) {
		resolve_vertical(0, 2);
		resolve_vertical(1, 3);
	} else {
		resolve_vertical(1, 3);
		resolve_vertical(0, 2);
	}

	// Diagonal falls, then diagonal gas rises, in random order.
	if ((order & 2u) == 0u) {
		resolve_diagonal(0, 3);
		resolve_diagonal(1, 2);
	} else {
		resolve_diagonal(1, 2);
		resolve_diagonal(0, 3);
	}
	if ((order & 4u) == 0u) {
		resolve_diagonal_rise(2, 1);
		resolve_diagonal_rise(3, 0);
	} else {
		resolve_diagonal_rise(3, 0);
		resolve_diagonal_rise(2, 1);
	}

	// Horizontal rows.
	resolve_horizontal(0, 1);
	resolve_horizontal(2, 3);

	for (int i = 0; i < 4; i++) {
		if (cvalid[i] && cdirty[i]) {
			uint raw = ce[i] | (cmoved[i] ? MOVED_BIT : 0u);
			imageStore(grid, cpos[i], uvec4(raw, 0u, 0u, 0u));
		}
	}
}
