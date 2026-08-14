#[compute]
#version 450

// Reaction pass: every non-movement rule from Project Sand's
// elements.js, recast as a parallel cellular automaton where each
// cell writes only itself. Rules where element A mutated a
// neighbouring element B are inverted ("B checks for A"), and A's
// probabilistic decision is replayed deterministically from B's
// thread via the shared hash-based RNG (same cell index, tick and
// salt always produce the same roll).
//
// Where the original picked ONE neighbour to convert, the inverted
// rule divides the probability by the count of candidate neighbours
// (condition `rnd * count < chance`) so the aggregate rate matches.
//
// Rare, area-of-effect behaviors (explosions, trees, magic, the
// mystery scramble) are emitted as events for the CPU to handle via
// particles and stamp commands, mirroring the original's particle
// system.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, r32ui) uniform restrict readonly uimage2D src_grid;
layout(set = 0, binding = 1, r32ui) uniform restrict writeonly uimage2D dst_grid;

layout(set = 0, binding = 3, r32ui) uniform restrict readonly uimage2D src_vel;
layout(set = 0, binding = 4, r32ui) uniform restrict writeonly uimage2D dst_vel;

layout(set = 0, binding = 2, std430) restrict buffer Events {
	uint count;
	uint capacity;
	uint _pad0;
	uint _pad1;
	uvec4 items[];
} events;

layout(push_constant) uniform Params {
	uint tick;
	uint flags;
	uint pad0;
	uint pad1;
} params;

// flags bits
const uint FLAG_MAGIC = 1u;          // magic particles active (evaporates MYSTERY)
const uint FLAG_SOLID_FLOOR = 2u;    // material piles on the bottom row
const uint FLAG_SOLID_CEILING = 4u;  // gases collect against the top row

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
const uint EL_OOB = 63u;
// Bit 7 marks a fixed source of its own element.
const uint EMITTER_BIT = 128u;

// Event types consumed by the CPU (see falling_sand.gd).
const uint EV_NITRO = 1u;
const uint EV_NAPALM = 2u;
const uint EV_C4 = 3u;
const uint EV_LAVA_SPURT = 4u;
const uint EV_METHANE = 5u;
const uint EV_TREE = 6u;
const uint EV_ROCKET = 7u;
const uint EV_GUNPOWDER = 8u;
const uint EV_MAGIC1 = 9u;
const uint EV_MAGIC2 = 10u;
const uint EV_NUKE = 11u;
const uint EV_SCRAMBLE = 12u;

// Salts shared with movement.glsl
const uint SALT_GRAV = 1u;
const uint SALT_RISE = 3u;
// Reaction-only salts
const uint SALT_TORCH = 21u;
const uint SALT_OILIGN = 22u;
const uint SALT_NITROIGN = 23u;
const uint SALT_NITROIGN2 = 24u;
const uint SALT_LAVABURN = 25u;
const uint SALT_FIREWATER = 26u;
const uint SALT_SALTT = 27u;
const uint SALT_PLANTG = 28u;
const uint SALT_CHILLG = 29u;
const uint SALT_CRYO = 30u;
const uint SALT_SOILABS = 31u;
const uint SALT_WSOILABS = 32u;
const uint SALT_FIREPLANT = 33u;
const uint SALT_PLANTSALT = 34u;
const uint SALT_FLAMEOUT = 35u;
const uint SALT_FLAMEOIL = 36u;
const uint SALT_LAVASIDE = 37u;
const uint SALT_GUNP = 38u;
const uint SALT_WAXMELT = 39u;
const uint SALT_CONC1 = 40u;
const uint SALT_CONC2 = 41u;
const uint SALT_CONC3 = 42u;
const uint SALT_CONC4 = 43u;
const uint SALT_CONC5 = 44u;
const uint SALT_FIREFUSE = 45u;
const uint SALT_ICEW = 46u;
const uint SALT_ICES = 47u;
const uint SALT_ICES2 = 48u;
const uint SALT_ICESALT = 49u;
const uint SALT_ICEFIRE = 50u;
const uint SALT_ICELAVA = 51u;
const uint SALT_CHILL_THAW = 52u;
const uint SALT_WALLMELT = 53u;
const uint SALT_WALLMELT2 = 54u;
const uint SALT_LAVAOIL1 = 55u;
const uint SALT_LAVAOIL2 = 56u;
const uint SALT_LAVAFIRE = 57u;
const uint SALT_ROCKM1 = 58u;
const uint SALT_ROCKM2 = 59u;
const uint SALT_ROCKM3 = 60u;
const uint SALT_STMW = 61u;
const uint SALT_STMA1 = 62u;
const uint SALT_STMA2 = 63u;
const uint SALT_STMA3 = 64u;
const uint SALT_STMS = 65u;
const uint SALT_STMT1 = 66u;
const uint SALT_STMT2 = 67u;
const uint SALT_CRYO1 = 68u;
const uint SALT_CRYO2 = 69u;
const uint SALT_CRYO3 = 70u;
const uint SALT_CRYO4 = 71u;
const uint SALT_MYST0 = 72u;
const uint SALT_METH = 73u;
const uint SALT_SOILN = 74u;
const uint SALT_WSOIL1 = 75u;
const uint SALT_WSOIL2 = 76u;
const uint SALT_WSOIL3 = 77u;
const uint SALT_BRANCHF = 78u;
const uint SALT_LEAFF = 79u;
const uint SALT_LEAFS = 80u;
const uint SALT_LEAFP1 = 81u;
const uint SALT_LEAFP2 = 82u;
const uint SALT_NAPALM = 83u;
const uint SALT_C4 = 84u;
const uint SALT_SPOUT = 85u;
const uint SALT_WELL = 86u;
const uint SALT_FIRERISE = 87u;
const uint SALT_CNITRO = 88u;
const uint SALT_EMIT = 89u;
const uint SALT_BOIL = 90u;
const uint SALT_FREEZE = 91u;
const uint SALT_MELT = 92u;
const uint SALT_CONDENSE = 93u;

ivec2 grid_size;
ivec2 P;

uint pcg(uint v) {
	v = v * 747796405u + 2891336453u;
	uint w = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
	return (w >> 22u) ^ w;
}

uint rnd100_at(ivec2 p, uint salt) {
	uint idx = uint(p.y * grid_size.x + p.x);
	return pcg(idx ^ pcg(salt ^ (params.tick * 0x9E3779B9u))) % 100u;
}

bool in_grid(ivec2 p) {
	return p.x >= 0 && p.y >= 0 && p.x < grid_size.x && p.y < grid_size.y;
}

uint E(ivec2 p) {
	if (!in_grid(p)) return EL_OOB;
	return imageLoad(src_grid, p).r & 63u;
}

const ivec2 DIR4[4] = { ivec2(0, 1), ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1) };
const ivec2 DIR8[8] = {
	ivec2(0, 1), ivec2(-1, 1), ivec2(1, 1),
	ivec2(-1, 0), ivec2(1, 0),
	ivec2(0, -1), ivec2(-1, -1), ivec2(1, -1)
};

bool borders4_at(ivec2 p, uint t) {
	for (int i = 0; i < 4; i++) if (E(p + DIR4[i]) == t) return true;
	return false;
}

bool borders8_at(ivec2 p, uint t) {
	for (int i = 0; i < 8; i++) if (E(p + DIR8[i]) == t) return true;
	return false;
}

uint count4_at(ivec2 p, uint t) {
	uint c = 0u;
	for (int i = 0; i < 4; i++) if (E(p + DIR4[i]) == t) c++;
	return c;
}

uint count8_at(ivec2 p, uint t) {
	uint c = 0u;
	for (int i = 0; i < 8; i++) if (E(p + DIR8[i]) == t) c++;
	return c;
}

bool surrounded4_at(ivec2 p, uint t) {
	for (int i = 0; i < 4; i++) {
		uint e = E(p + DIR4[i]);
		if (e != t && e != EL_OOB) return false;
	}
	return true;
}

bool surrounded8_at(ivec2 p, uint t) {
	for (int i = 0; i < 8; i++) {
		uint e = E(p + DIR8[i]);
		if (e != t && e != EL_OOB) return false;
	}
	return true;
}

void emit_event(uint type, ivec2 p, uint aux) {
	uint idx = atomicAdd(events.count, 1u);
	if (idx < events.capacity) {
		events.items[idx] = uvec4(type, uint(p.x), uint(p.y), aux);
	}
}

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

bool lava_immune(uint e) {
	return e == EL_LAVA || e == EL_BACKGROUND || e == EL_FIRE || e == EL_WALL
		|| e == EL_ROCK || e == EL_WATER || e == EL_SALT_WATER || e == EL_STEAM;
}

// Replay: does the OIL at q ignite (border-burn) this tick?  (OIL_ACTION)
bool oil_ignites(ivec2 q) {
	return rnd100_at(q, SALT_OILIGN) < 30u && borders4_at(q, EL_FIRE);
}

// Replay: does the NITRO at q border-burn this tick?  (NITRO_ACTION p30 branch)
bool nitro_ignites(ivec2 q) {
	if (surrounded8_at(q, EL_NITRO)) return false;
	if (!borders8_at(q, EL_FIRE)) return false;
	return rnd100_at(q, SALT_NITROIGN) < 30u;
}

// Replay: does the WAX at q melt this tick?  (FIRE_ACTION wax branch, p1)
bool wax_melts(ivec2 q) {
	return rnd100_at(q, SALT_WAXMELT) < 1u && borders4_at(q, EL_FIRE);
}

/* ------------------------------ Heat ------------------------------ */
//
// Every cell carries a temperature in bits 8-23 (celsius + TEMP_OFFSET).
// Heat conducts between neighbours each tick, leaks slowly toward room
// temperature, and a few materials act as reservoirs that hold their own
// temperature and so warm or chill everything around them.
//
// g_temp is computed once per cell before any rule runs, and store()
// writes it back, so every existing rule carries temperature across an
// element change for free: water that boils becomes steam at the water's
// temperature.

// Stored in TENTHS of a degree. Whole degrees are not enough: the slow
// leak toward room temperature moves a cell by a fraction of a degree
// per tick, which rounds back to the same integer every time and leaves
// the temperature frozen forever.
const int TEMP_OFFSET = 5000;
const float AMBIENT_C = 20.0;

float g_temp;

float temp_of_raw(uint r) {
	return float(int((r >> 8) & 0xFFFFu) - TEMP_OFFSET) * 0.1;
}

uint temp_bits(float celsius) {
	return uint(clamp(int(round(celsius * 10.0)) + TEMP_OFFSET, 0, 65535)) << 8;
}

// Neighbour temperature; outside the grid counts as room temperature so
// the edges of the world act as a heat sink rather than a mirror.
float Temp(ivec2 p) {
	if (!in_grid(p)) return AMBIENT_C;
	return temp_of_raw(imageLoad(src_grid, p).r);
}

// Reservoir temperature, or -10000 for materials that merely conduct.
int source_temp(uint e) {
	switch (e) {
		case EL_LAVA: return 1200;
		case EL_TORCH: return 900;
		case EL_FIRE: return 850;
		case EL_CRYO: return -200;
	}
	return -10000;
}

// How readily a material passes heat on, 0..1.
float conductivity(uint e) {
	switch (e) {
		case EL_BACKGROUND: return 0.10;  // air is a poor conductor
		case EL_STEAM: case EL_METHANE: return 0.15;
		case EL_WALL: case EL_ROCK: case EL_CONCRETE: return 0.32;
		case EL_ICE: case EL_CHILLED_ICE: return 0.34;
		case EL_WATER: case EL_SALT_WATER: return 0.28;
		case EL_LAVA: case EL_FIRE: return 0.45;
	}
	return 0.22;
}

/* ---------------------------- Pressure ---------------------------- */
//
// Bits 24-31, in quarter units offset by 128. Explosions drive a spike
// in, it spreads outward as a wave, and the movement pass shoves
// material down the gradient. Decay is subtractive so a value always
// reaches zero rather than stalling on a rounding boundary.

const int PRESS_OFFSET = 128;
const float BLAST_P = 26.0;

float g_press;

float press_of_raw(uint r) {
	return float(int((r >> 24) & 0xFFu) - PRESS_OFFSET) * 0.25;
}

uint press_bits(float p) {
	return uint(clamp(int(round(p * 4.0)) + PRESS_OFFSET, 0, 255)) << 24;
}

// Outside the grid reads as zero, so the world's edges vent a blast
// rather than reflecting it back inward.
float Press(ivec2 p) {
	if (!in_grid(p)) return 0.0;
	return press_of_raw(imageLoad(src_grid, p).r);
}

bool is_liquid(uint e) {
	return e == EL_WATER || e == EL_SALT_WATER || e == EL_OIL || e == EL_LAVA;
}

// Rigid material is a no-flow boundary: it transmits pressure rather
// than swallowing it. Reading a wall as zero made every wall a sink, so
// liquid all round a tank was accelerated into the walls and the breach
// was no more inviting than solid stone.
bool rigid(uint e) {
	return e == EL_WALL || e == EL_WAX || e == EL_FUSE
		|| e == EL_SPOUT || e == EL_WELL || e == EL_TORCH || e == EL_OOB;
}

// Neighbour pressure for diffusion and gradient. A rigid neighbour
// reflects our own value back, contributing nothing either way.
float press_bound(ivec2 q, float self_p) {
	if (!in_grid(q)) return 0.0;
	uint r = imageLoad(src_grid, q).r;
	if (rigid(r & 63u) || (r & EMITTER_BIT) != 0u) return self_p;
	return press_of_raw(r);
}

// Hydrostatic rest pressure: a liquid cell sits at the pressure of the
// liquid directly above it plus its own weight, and a free surface sits
// at zero. Each tick this reads the previous tick's value from above, so
// a column fills in downward at one cell per tick and settles into the
// right profile without ever needing to sum the whole column.
const float LIQUID_WEIGHT = 0.25;
const float MAX_HYDRO = 20.0;

float hydro_rest(uint e) {
	if (!is_liquid(e)) return 0.0;
	ivec2 up = P + ivec2(0, -1);
	if (!is_liquid(E(up))) return 0.0;
	return min(Press(up) + LIQUID_WEIGHT, MAX_HYDRO);
}

/* ---------------------------- Velocity ---------------------------- */
//
// Its own texture, since the cell has no room left and a velocity needs
// two components. Packed as two int16 in 1/64ths of a cell per tick.
//
// A pressure gradient accelerates material, and drag bleeds the speed
// off. This is what lets material keep travelling after it leaves the
// gradient that launched it: without it a breach only pushes at the
// opening and everything goes ballistic the instant it is clear.

const float VEL_SCALE = 64.0;
// Light drag: material that has been thrown should coast, not stop
// dead a couple of cells later.
const float VEL_DRAG = 0.96;
// Material passes through the gradient at a breach in roughly one tick,
// so the gain has to be big enough that a single tick there imparts
// speed worth carrying. Too small and everything leaves at well under
// one cell per tick and never gets off the ground.
const float VEL_GAIN = 0.40;
const float VEL_MAX = 6.0;

vec2 vel_of(uint r) {
	return vec2(float(int(r & 0xFFFFu) - 32768),
		float(int((r >> 16) & 0xFFFFu) - 32768)) / VEL_SCALE;
}

uint vel_bits(vec2 v) {
	ivec2 q = clamp(ivec2(round(v * VEL_SCALE)) + 32768, ivec2(0), ivec2(65535));
	return uint(q.x) | (uint(q.y) << 16);
}

void store(uint e) {
	imageStore(dst_grid, P, uvec4(e | temp_bits(g_temp) | press_bits(g_press),
		0u, 0u, 0u));
}

void main() {
	grid_size = imageSize(src_grid);
	P = ivec2(gl_GlobalInvocationID.xy);
	if (P.x >= grid_size.x || P.y >= grid_size.y) return;

	uint raw = imageLoad(src_grid, P).r;
	uint e = raw & 63u;

	// Conduct heat before anything else, so every rule below sees this
	// tick's temperature and store() carries it through any conversion.
	{
		float t = temp_of_raw(raw);
		float below = Temp(P + ivec2(0, 1));
		float above = Temp(P + ivec2(0, -1));
		float left = Temp(P + ivec2(-1, 0));
		float right = Temp(P + ivec2(1, 0));

		if (e == EL_BACKGROUND) {
			// Air moves heat by convection, not conduction: warm air
			// rises. Weighting the exchange heavily toward the cell
			// below makes warmth climb, and that is the only way an
			// enclosed space ever fills. Pure diffusion spreads about
			// sqrt(time) cells - roughly seven of them in a thousand
			// ticks - so a torch would heat its immediate neighbours
			// and a room would stay cold indefinitely.
			//
			// The weights sum to one, so this stays a weighted average
			// of the neighbours: a cell can never exceed its hottest
			// neighbour and no energy can appear from nowhere.
			float avg = 0.54 * below + 0.18 * (left + right) + 0.10 * above;
			t += 0.62 * (avg - t);
		} else {
			t += conductivity(e) * ((below + above + left + right) * 0.25 - t);
		}
		// Still air does not shed heat to anywhere: it only conducts to
		// what it touches, and the edges of the world are the sink,
		// since Temp() reads room temperature outside the grid.
		//
		// Air used to lose 4% a tick to the room while conducting at
		// only 0.10, which gives heat a decay length through air of
		// under a single cell. Nothing could warm a space it was not
		// touching, so a torch heated the cells beside it and an
		// enclosed room stayed cold; and conversely a pocket sealed
		// inside ice was warmed forever by a room it had no contact
		// with. Removing the term fixes both: heat now fills an
		// enclosure, and trapped air settles to whatever surrounds it.
		//
		// Gases keep the term, as a stand-in for their mixing and
		// venting away.
		if (e == EL_STEAM || e == EL_METHANE) {
			t += 0.04 * (AMBIENT_C - t);
		}
		int reservoir = source_temp(e);
		if (reservoir > -9999) t = float(reservoir);
		g_temp = t;
	}

	// Pressure spreads as a wave and bleeds off. Subtracting a fixed
	// amount guarantees it settles back to zero.
	{
		float p = press_of_raw(raw);
		float around =
			press_bound(P + ivec2(0, 1), p) + press_bound(P + ivec2(0, -1), p) +
			press_bound(P + ivec2(-1, 0), p) + press_bound(P + ivec2(1, 0), p);
		// Spread hard so the front actually travels. This also does the
		// horizontal equalisation a connected body of liquid needs.
		p += 0.55 * (around * 0.25 - p);
		// Settle toward the hydrostatic rest value rather than toward
		// zero: for air and solids that is zero and nothing changes, but
		// a liquid keeps the weight of everything above it. Whatever is
		// left over is the transient blast component, and that bleeds
		// off - subtractively, so it always reaches rest.
		float rest = hydro_rest(e);
		float over = p - rest;
		// Liquid holds its head; air does not. Without this, pressure
		// bleeds out of a tank into the air just outside the breach and
		// equalises it, destroying the very gradient that should be
		// driving the flow. Damping air hard keeps the step at the
		// opening sharp, and a blast still crosses open space because it
		// is an order of magnitude larger than any hydrostatic head.
		if (is_liquid(e)) {
			over = sign(over) * max(abs(over) * 0.97 - 0.15, 0.0);
		} else {
			over = sign(over) * max(abs(over) * 0.82 - 0.6, 0.0);
		}
		g_press = rest + over;
	}

	// Velocity: accelerate down the pressure gradient, then bleed off.
	// Empty space and anchored material never carry momentum.
	{
		vec2 v = vel_of(imageLoad(src_vel, P).r);
		float self_p = g_press;
		vec2 grad = vec2(
			press_bound(P + ivec2(1, 0), self_p) - press_bound(P + ivec2(-1, 0), self_p),
			press_bound(P + ivec2(0, 1), self_p) - press_bound(P + ivec2(0, -1), self_p)) * 0.5;
		// A fluid at rest already has a vertical pressure gradient, and
		// gravity is exactly what it balances - the falling rules
		// already account for it. Accelerating along it as well would
		// double-count and push water upward out of its own tank. Only
		// the part that departs from equilibrium drives flow, which at a
		// breach is the horizontal component nothing is balancing.
		if (is_liquid(e)) grad.y -= LIQUID_WEIGHT;
		v = v * VEL_DRAG - grad * VEL_GAIN;
		if (e == EL_BACKGROUND || e == EL_WALL || e == EL_OOB
				|| (raw & EMITTER_BIT) != 0u) {
			v = vec2(0.0);
		}
		if (length(v) > VEL_MAX) v = normalize(v) * VEL_MAX;
		if (length(v) < 0.06) v = vec2(0.0);
		imageStore(dst_vel, P, uvec4(vel_bits(v), 0u, 0u, 0u));
	}

	// A source is a fixed feature of the world: it never moves, never
	// reacts, and never burns away. Only the eraser removes it. Emission
	// itself is handled from the receiving background cell below, so
	// there is nothing to do here but survive the pass with the bit
	// intact - this is the only place it could be lost, since the
	// reaction pass rewrites every cell.
	if ((raw & EMITTER_BIT) != 0u) {
		imageStore(dst_grid, P, uvec4(
			e | EMITTER_BIT | temp_bits(g_temp) | press_bits(g_press), 0u, 0u, 0u));
		return;
	}

	// Cache the 4-neighbourhood (most rules only need it).
	uint n_dn = E(P + ivec2(0, 1));
	uint n_up = E(P + ivec2(0, -1));
	uint n_lf = E(P + ivec2(-1, 0));
	uint n_rt = E(P + ivec2(1, 0));

	/* ---------- Global incoming conversions (highest priority) ---------- */

	// TORCH_ACTION: doProducer(FIRE, overwrite=true, 25) hits all 4
	// direct neighbours regardless of what they are.
	if (e != EL_OOB) {
		for (int i = 0; i < 4; i++) {
			ivec2 q = P + DIR4[i];
			if (E(q) == EL_TORCH && rnd100_at(q, SALT_TORCH) < 25u) {
				store(EL_FIRE);
				return;
			}
		}
	}

	// __doBorderBurn from an igniting OIL or NITRO neighbour overwrites
	// this cell with FIRE unconditionally (yes, even walls - parity with
	// the original).
	{
		bool near_oil = (n_dn == EL_OIL || n_up == EL_OIL || n_lf == EL_OIL || n_rt == EL_OIL);
		bool near_nitro = (n_dn == EL_NITRO || n_up == EL_NITRO || n_lf == EL_NITRO || n_rt == EL_NITRO);
		if (near_oil || near_nitro) {
			for (int i = 0; i < 4; i++) {
				ivec2 q = P + DIR4[i];
				uint qe = E(q);
				if ((qe == EL_OIL && oil_ignites(q)) || (qe == EL_NITRO && nitro_ignites(q))) {
					store(EL_FIRE);
					return;
				}
			}
		}
	}

	// LAVA_ACTION burn: each lava neighbour rolls 25% to set its 4
	// non-immune neighbours on fire.
	if (!lava_immune(e) && e != EL_OOB) {
		for (int i = 0; i < 4; i++) {
			ivec2 q = P + DIR4[i];
			if (E(q) == EL_LAVA && rnd100_at(q, SALT_LAVABURN) < 25u) {
				store(EL_FIRE);
				return;
			}
		}
	}

	// doGravity falling off the bottom edge deletes the element, unless
	// the floor is solid, in which case material simply piles up.
	if (P.y == grid_size.y - 1 && (params.flags & FLAG_SOLID_FLOOR) == 0u) {
		uint gc = grav_chance(e);
		if (gc > 0u && rnd100_at(P, SALT_GRAV) < gc) {
			store(EL_BACKGROUND);
			return;
		}
	}

	// doRise off the top edge deletes gases, unless the ceiling is
	// solid, in which case they collect against it.
	if (P.y == 0 && (params.flags & FLAG_SOLID_CEILING) == 0u
			&& (e == EL_STEAM || e == EL_METHANE)) {
		uint rc = e == EL_STEAM ? 70u : 25u;
		if (rnd100_at(P, SALT_RISE) < rc) {
			store(EL_BACKGROUND);
			return;
		}
	}

	/* --------------------- Per-element behaviour --------------------- */

	switch (e) {
	case EL_BACKGROUND: {
		// FIRE_ACTION rising fire: copies itself into the background above.
		if (n_dn == EL_FIRE && rnd100_at(P + ivec2(0, 1), SALT_FIRERISE) < 50u) {
			store(EL_FIRE); return;
		}
		// LAVA_ACTION: background directly above lava catches fire (6%).
		if (n_dn == EL_LAVA && rnd100_at(P + ivec2(0, 1), SALT_LAVAFIRE) < 6u) {
			store(EL_FIRE); return;
		}
		// Sources fill bordering background with their own material.
		// The roll is keyed to the source cell, so all four of its
		// neighbours fill on the same tick, as doProducer did.
		for (int i = 0; i < 4; i++) {
			ivec2 q = P + DIR4[i];
			if (!in_grid(q)) continue;
			uint qraw = imageLoad(src_grid, q).r;
			if ((qraw & EMITTER_BIT) != 0u) {
				uint qe2 = qraw & 63u;
				uint chance = qe2 == EL_FIRE ? 25u : 10u;
				if (rnd100_at(q, SALT_EMIT) < chance) { store(qe2); return; }
			}
		}

		// SPOUT / WELL producers fill bordering background.
		for (int i = 0; i < 4; i++) {
			ivec2 q = P + DIR4[i];
			uint qe = E(q);
			if (qe == EL_SPOUT && rnd100_at(q, SALT_SPOUT) < 5u) { store(EL_WATER); return; }
			if (qe == EL_WELL && rnd100_at(q, SALT_WELL) < 10u) { store(EL_OIL); return; }
			// LEAF_ACTION pollen producer (1% * 9%).
			if (qe == EL_LEAF && rnd100_at(q, SALT_LEAFP1) < 1u && rnd100_at(q, SALT_LEAFP2) < 9u) {
				store(EL_POLLEN); return;
			}
		}
		// FIRE_ACTION wax branch: melting wax drops FALLING_WAX into the
		// background below it.
		if (n_up == EL_WAX && wax_melts(P + ivec2(0, -1))) {
			store(EL_FALLING_WAX); return;
		}
		break;
	}

	case EL_WALL: {
		// LAVA_ACTION: lava slowly melts bordering walls (1% * 50%).
		if (borders8_at(P, EL_LAVA)) {
			for (int i = 0; i < 8; i++) {
				ivec2 q = P + DIR8[i];
				if (E(q) == EL_LAVA && rnd100_at(q, SALT_WALLMELT) < 1u
						&& rnd100_at(q, SALT_WALLMELT2) < 50u) {
					store(EL_LAVA); return;
				}
			}
		}
		break;
	}

	case EL_WATER: {
		// Thermal phase changes. These are what the temperature field
		// buys: water boils wherever it gets hot enough and freezes
		// wherever it gets cold enough, with no rule naming a specific
		// heat source.
		// Latent heat: water pins itself at its boiling and freezing
		// points while it changes state, and the arriving or departing
		// heat drives the change instead of moving the temperature. A
		// pan of water therefore holds a lava pool near 100 rather than
		// racing past it, and the change rate follows the heat flux.
		if (g_temp > 100.0) {
			float excess = g_temp - 100.0;
			g_temp = 100.0;
			if (float(rnd100_at(P, SALT_BOIL)) < clamp(excess * 2.0, 0.0, 60.0)) {
				store(EL_STEAM);
				return;
			}
		}
		if (g_temp < 0.0) {
			float deficit = -g_temp;
			g_temp = 0.0;
			if (float(rnd100_at(P, SALT_FREEZE)) < clamp(deficit * 2.0, 0.0, 40.0)) {
				store(EL_ICE);
				return;
			}
		}

		// LAVA_ACTION: adjacent lava flashes water to steam (unconditional).
		if (n_dn == EL_LAVA || n_up == EL_LAVA || n_lf == EL_LAVA || n_rt == EL_LAVA) {
			store(EL_STEAM); return;
		}
		// FIRE_ACTION: fire turns one bordering water into steam (80%).
		for (int i = 0; i < 4; i++) {
			ivec2 q = P + DIR4[i];
			if (E(q) == EL_FIRE) {
				uint cnt = count4_at(q, EL_WATER);
				if (rnd100_at(q, SALT_FIREWATER) * cnt < 80u) { store(EL_STEAM); return; }
			}
		}
		// SALT_ACTION doTransform: both salt and this water become salt water.
		for (int i = 0; i < 4; i++) {
			ivec2 q = P + DIR4[i];
			if (E(q) == EL_SALT) {
				uint cnt = count4_at(q, EL_WATER);
				if (rnd100_at(q, SALT_SALTT) * cnt < 25u) { store(EL_SALT_WATER); return; }
			}
		}
		// CRYO_ACTION: freezes bordering water (both become chilled ice).
		for (int i = 0; i < 8; i++) {
			ivec2 q = P + DIR8[i];
			if (E(q) == EL_CRYO) {
				uint cnt = count8_at(q, EL_WATER) + count8_at(q, EL_ICE);
				if (rnd100_at(q, SALT_CRYO) * cnt < 100u) { store(EL_CHILLED_ICE); return; }
			}
		}
		// PLANT_ACTION doGrow / CHILLED_ICE_ACTION doGrow (50%).
		for (int i = 0; i < 8; i++) {
			ivec2 q = P + DIR8[i];
			uint qe = E(q);
			if (qe == EL_PLANT) {
				uint cnt = count8_at(q, EL_WATER);
				if (rnd100_at(q, SALT_PLANTG) * cnt < 50u) { store(EL_PLANT); return; }
			} else if (qe == EL_CHILLED_ICE) {
				uint cnt = count8_at(q, EL_WATER);
				if (rnd100_at(q, SALT_CHILLG) * cnt < 50u) { store(EL_CHILLED_ICE); return; }
			}
		}
		// SOIL/WET_SOIL absorb water from their aboveAdjacent cells (15%).
		for (int dx = -1; dx <= 1; dx++) {
			ivec2 q = P + ivec2(dx, 1);
			uint qe = E(q);
			if (qe == EL_SOIL) {
				uint cnt = 0u;
				for (int ax = -1; ax <= 1; ax++) if (E(q + ivec2(ax, -1)) == EL_WATER) cnt++;
				if (rnd100_at(q, SALT_SOILABS) * cnt < 15u) { store(EL_BACKGROUND); return; }
			} else if (qe == EL_WET_SOIL) {
				uint cnt = 0u;
				for (int ax = -1; ax <= 1; ax++) if (E(q + ivec2(ax, -1)) == EL_WATER) cnt++;
				if (rnd100_at(q, SALT_WSOILABS) * cnt < 15u) { store(EL_BACKGROUND); return; }
			}
		}
		break;
	}

	case EL_PLANT: {
		// PLANT_ACTION: dies near salt (5%).
		if (rnd100_at(P, SALT_PLANTSALT) < 5u && borders4_at(P, EL_SALT)) {
			store(EL_BACKGROUND); return;
		}
		// FIRE_ACTION: fire spreads to one bordering plant (20%, 8-dir).
		for (int i = 0; i < 8; i++) {
			ivec2 q = P + DIR8[i];
			if (E(q) == EL_FIRE) {
				uint cnt = count8_at(q, EL_PLANT);
				if (rnd100_at(q, SALT_FIREPLANT) * cnt < 20u) { store(EL_FIRE); return; }
			}
		}
		break;
	}

	case EL_FIRE: {
		// FIRE_ACTION: extinguish into the water it just boiled (80%).
		if (rnd100_at(P, SALT_FIREWATER) < 80u
				&& (borders4_at(P, EL_WATER) || borders4_at(P, EL_SALT_WATER))) {
			store(EL_BACKGROUND); return;
		}
		// LAVA_ACTION: lava consumes fire below and beside it.
		if (n_up == EL_LAVA) { store(EL_BACKGROUND); return; }
		if ((n_lf == EL_LAVA && rnd100_at(P + ivec2(-1, 0), SALT_LAVASIDE) < 15u)
				|| (n_rt == EL_LAVA && rnd100_at(P + ivec2(1, 0), SALT_LAVASIDE) < 15u)) {
			store(EL_BACKGROUND); return;
		}
		// FIRE_ACTION flame-out (40%) unless touching fuel.
		if (rnd100_at(P, SALT_FLAMEOUT) < 40u) {
			bool flame_out = true;
			for (int i = 0; i < 8; i++) {
				uint qe = E(P + DIR8[i]);
				if (qe == EL_PLANT || qe == EL_FUSE || qe == EL_BRANCH || qe == EL_LEAF) {
					flame_out = false; break;
				}
				if (qe == EL_OIL && rnd100_at(P, SALT_FLAMEOIL) < 50u) {
					flame_out = false; break;
				}
			}
			if (flame_out && borders4_at(P, EL_WAX)) flame_out = false;
			if (flame_out) { store(EL_BACKGROUND); return; }
		}
		break;
	}

	case EL_SALT: {
		// SALT_ACTION doTransform into salt water (25%).
		if (rnd100_at(P, SALT_SALTT) < 25u && borders4_at(P, EL_WATER)) {
			store(EL_SALT_WATER); return;
		}
		break;
	}

	case EL_SALT_WATER: {
		if (n_dn == EL_LAVA || n_up == EL_LAVA || n_lf == EL_LAVA || n_rt == EL_LAVA) {
			store(EL_STEAM); return;
		}
		// FIRE_ACTION prefers plain water; salt water boils only when the
		// fire has no plain water bordering it.
		for (int i = 0; i < 4; i++) {
			ivec2 q = P + DIR4[i];
			if (E(q) == EL_FIRE && count4_at(q, EL_WATER) == 0u) {
				uint cnt = count4_at(q, EL_SALT_WATER);
				if (rnd100_at(q, SALT_FIREWATER) * cnt < 80u) { store(EL_STEAM); return; }
			}
		}
		break;
	}

	case EL_OIL: {
		// OIL_ACTION: 30% border-burn when touching fire.
		if (oil_ignites(P)) { store(EL_FIRE); return; }
		// ROCK_ACTION: rock below produces methane from the oil above it.
		if (n_dn == EL_ROCK) {
			ivec2 q = P + ivec2(0, 1);
			if (rnd100_at(q, SALT_ROCKM1) < 1u && rnd100_at(q, SALT_ROCKM2) < 20u
					&& rnd100_at(q, SALT_ROCKM3) < 50u) {
				store(EL_METHANE); return;
			}
		}
		break;
	}

	case EL_GUNPOWDER: {
		// GUNPOWDER_ACTION: ignition (95%). The blast itself (3x3 stamp,
		// possible star particle) is resolved by the CPU from the event.
		if (rnd100_at(P, SALT_GUNP) < 95u && borders4_at(P, EL_FIRE)) {
			// The blast impulse is applied once by the explosion stamp,
			// not here. Injecting per detonating cell every tick kept a
			// cloud of powder airborne indefinitely: the explosion
			// regenerates powder, the powder stayed next to the fire
			// because the pressure held it up, and it detonated forever.
			emit_event(EV_GUNPOWDER, P, 0u);
			store(EL_FIRE);
			return;
		}
		break;
	}

	case EL_WAX: {
		if (wax_melts(P)) { store(EL_FIRE); return; }
		break;
	}

	case EL_FALLING_WAX: {
		// FALLING_WAX_ACTION: solidifies the moment it cannot fall.
		if (n_dn != EL_BACKGROUND) { store(EL_WAX); return; }
		break;
	}

	case EL_NITRO: {
		// SOIL_ACTION doTransform: soil converts bordering nitro too.
		for (int i = 0; i < 4; i++) {
			ivec2 q = P + DIR4[i];
			if (E(q) == EL_SOIL) {
				uint cnt = count4_at(q, EL_NITRO);
				if (rnd100_at(q, SALT_SOILN) * cnt < 25u) { store(EL_CHARGED_NITRO); return; }
			}
		}
		// NITRO_ACTION ignition.
		if (!surrounded8_at(P, EL_NITRO) && borders8_at(P, EL_FIRE)) {
			if (rnd100_at(P, SALT_NITROIGN) < 30u) {
				emit_event(EV_NITRO, P, 0u);
				g_press = max(g_press, BLAST_P);
				store(EL_FIRE);
				return;
			}
			if (rnd100_at(P, SALT_NITROIGN2) < 20u) { store(EL_FIRE); return; }
		}
		break;
	}

	case EL_NAPALM: {
		// NAPALM_ACTION: erupts fireball particles while burning.
		if (rnd100_at(P, SALT_NAPALM) < 25u && borders4_at(P, EL_FIRE)) {
			emit_event(EV_NAPALM, P, 0u);
		}
		break;
	}

	case EL_C4: {
		if (rnd100_at(P, SALT_C4) < 60u && borders4_at(P, EL_FIRE)) {
			// As with gunpowder: C-4 is not consumed here, so injecting
			// pressure each tick would be a standing source. Its
			// fireball carries the impulse instead.
			emit_event(EV_C4, P, 0u);
		}
		break;
	}

	case EL_CONCRETE: {
		// CONCRETE_ACTION: hardens against walls (1%-ish).
		if (rnd100_at(P, SALT_CONC1) < 10u && rnd100_at(P, SALT_CONC2) < 10u
				&& borders8_at(P, EL_WALL)) {
			store(EL_WALL); return;
		}
		// Spontaneous hardening once at rest (10% * 10% * 5%).
		if (n_dn != EL_BACKGROUND
				&& rnd100_at(P, SALT_CONC3) < 10u && rnd100_at(P, SALT_CONC4) < 10u
				&& rnd100_at(P, SALT_CONC5) < 5u) {
			store(EL_WALL); return;
		}
		break;
	}

	case EL_FUSE: {
		// FIRE_ACTION: fire spreads along fuse fast (80%, 8-dir).
		for (int i = 0; i < 8; i++) {
			ivec2 q = P + DIR8[i];
			if (E(q) == EL_FIRE) {
				uint cnt = count8_at(q, EL_FUSE);
				if (rnd100_at(q, SALT_FIREFUSE) * cnt < 80u) { store(EL_FIRE); return; }
			}
		}
		break;
	}

	case EL_ICE: {
		// Ice holds at its melting point while it melts: heat arriving
		// goes into the phase change rather than into its temperature.
		// That is what lets a block chill everything around it and melt
		// from the outside in, instead of simply warming up alongside
		// its surroundings and vanishing all at once.
		if (g_temp > 0.0) {
			float excess = g_temp;
			g_temp = 0.0;
			if (float(rnd100_at(P, SALT_MELT)) < clamp(excess * 2.5, 0.0, 50.0)) {
				store(EL_WATER);
				return;
			}
		}
		if (surrounded4_at(P, EL_ICE)) break;
		// ICE_ACTION melt matrix.
		if (rnd100_at(P, SALT_ICEW) < 1u && borders4_at(P, EL_WATER)) { store(EL_WATER); return; }
		if (rnd100_at(P, SALT_ICES) < 70u && borders4_at(P, EL_STEAM)) { store(EL_WATER); return; }
		if (rnd100_at(P, SALT_ICESALT) < 10u
				&& (borders4_at(P, EL_SALT) || borders4_at(P, EL_SALT_WATER))) {
			store(EL_WATER); return;
		}
		if (rnd100_at(P, SALT_ICEFIRE) < 50u && borders4_at(P, EL_FIRE)) { store(EL_WATER); return; }
		if (rnd100_at(P, SALT_ICELAVA) < 50u && borders4_at(P, EL_LAVA)) { store(EL_WATER); return; }
		// CRYO_ACTION freezes ice into chilled ice.
		for (int i = 0; i < 8; i++) {
			ivec2 q = P + DIR8[i];
			if (E(q) == EL_CRYO) {
				uint cnt = count8_at(q, EL_WATER) + count8_at(q, EL_ICE);
				if (rnd100_at(q, SALT_CRYO) * cnt < 100u) { store(EL_CHILLED_ICE); return; }
			}
		}
		break;
	}

	case EL_CHILLED_ICE: {
		// CHILLED_ICE_ACTION: thaws to regular ice (6%), instantly near
		// salt / salt water / lava / fire / steam.
		if (rnd100_at(P, SALT_CHILL_THAW) < 6u) { store(EL_ICE); return; }
		if (borders4_at(P, EL_SALT) || borders4_at(P, EL_SALT_WATER)
				|| borders4_at(P, EL_LAVA) || borders4_at(P, EL_FIRE)
				|| borders4_at(P, EL_STEAM)) {
			store(EL_ICE); return;
		}
		break;
	}

	case EL_LAVA: {
		// LAVA_ACTION: water quenches lava to rock.
		if (n_dn == EL_WATER || n_up == EL_WATER || n_lf == EL_WATER || n_rt == EL_WATER
				|| n_dn == EL_SALT_WATER || n_up == EL_SALT_WATER
				|| n_lf == EL_SALT_WATER || n_rt == EL_SALT_WATER) {
			store(EL_ROCK); return;
		}
		// CRYO_ACTION: cryo flash-freezes lava to rock.
		if (borders8_at(P, EL_CRYO)) { store(EL_ROCK); return; }
		// LAVA_ACTION: burning oil launches a lava spurt particle.
		if (rnd100_at(P, SALT_LAVAOIL1) < 4u && rnd100_at(P, SALT_LAVAOIL2) < 50u
				&& borders4_at(P, EL_OIL)) {
			emit_event(EV_LAVA_SPURT, P, 0u);
			store(EL_BACKGROUND);
			return;
		}
		break;
	}

	case EL_ROCK: {
		// ROCK_ACTION: produces methane in contact with oil above (rock side).
		if (n_up == EL_OIL && rnd100_at(P, SALT_ROCKM1) < 1u
				&& rnd100_at(P, SALT_ROCKM2) < 20u && rnd100_at(P, SALT_ROCKM3) >= 50u) {
			store(EL_METHANE); return;
		}
		break;
	}

	case EL_STEAM: {
		// Condenses once it has cooled well below boiling, which is what
		// makes a plume shorten as it drifts away from its heat source.
		if (g_temp < 80.0 && rnd100_at(P, SALT_CONDENSE) < 2u) { store(EL_WATER); return; }

		// ICE_ACTION: ice condenses bordering steam (70% * 50%).
		for (int i = 0; i < 4; i++) {
			ivec2 q = P + DIR4[i];
			if (E(q) == EL_ICE) {
				uint cnt = count4_at(q, EL_STEAM);
				if (rnd100_at(q, SALT_ICES) < 70u && rnd100_at(q, SALT_ICES2) * cnt < 50u) {
					store(EL_WATER); return;
				}
			}
		}
		// STEAM_ACTION condensation rules.
		if (rnd100_at(P, SALT_STMW) < 5u && borders4_at(P, EL_WATER)) { store(EL_WATER); return; }
		if (rnd100_at(P, SALT_STMA1) < 5u && rnd100_at(P, SALT_STMA2) < 40u
				&& n_dn == EL_BACKGROUND && n_up != EL_BACKGROUND) {
			store(rnd100_at(P, SALT_STMA3) < 30u ? EL_WATER : EL_BACKGROUND);
			return;
		}
		if (rnd100_at(P, SALT_STMS) < 5u && borders4_at(P, EL_SPOUT)) { store(EL_WATER); return; }
		if (rnd100_at(P, SALT_STMT1) < 1u && rnd100_at(P, SALT_STMT2) < 5u
				&& n_dn != EL_STEAM) {
			store(EL_BACKGROUND); return;
		}
		break;
	}

	case EL_CRYO: {
		// CRYO_ACTION 3x3 scan.
		bool near_chilled = false;
		bool near_static = false;
		bool near_water_ice = false;
		bool near_lava = false;
		for (int i = 0; i < 8; i++) {
			uint qe = E(P + DIR8[i]);
			if (qe == EL_CHILLED_ICE) near_chilled = true;
			else if (qe == EL_WALL || qe == EL_SPOUT || qe == EL_WAX || qe == EL_WELL
					|| qe == EL_FUSE || qe == EL_PLANT || qe == EL_C4) near_static = true;
			else if (qe == EL_WATER || qe == EL_ICE) near_water_ice = true;
			else if (qe == EL_LAVA) near_lava = true;
		}
		if (near_chilled && rnd100_at(P, SALT_CRYO1) < 1u && rnd100_at(P, SALT_CRYO2) < 5u) {
			store(EL_CHILLED_ICE); return;
		}
		if (near_static) { store(EL_CHILLED_ICE); return; }
		if (near_water_ice) { store(EL_CHILLED_ICE); return; }
		if (near_lava) { store(EL_BACKGROUND); return; }
		// Freeze when fully enclosed (1% * 50%).
		if (rnd100_at(P, SALT_CRYO3) < 1u && rnd100_at(P, SALT_CRYO4) < 50u
				&& !borders4_at(P, EL_BACKGROUND) && !surrounded4_at(P, EL_CRYO)) {
			store(EL_CHILLED_ICE); return;
		}
		break;
	}

	case EL_MYSTERY: {
		// MYSTERY_ACTION: evaporates while magic particles are active.
		if ((params.flags & 1u) != 0u) { store(EL_BACKGROUND); return; }
		if (rnd100_at(P, SALT_MYST0) < 50u) break;
		if (borders8_at(P, EL_SAND)) {
			emit_event(EV_MAGIC1, P, 0u);
			store(EL_BACKGROUND); return;
		}
		if (borders8_at(P, EL_SALT)) {
			emit_event(EV_MAGIC2, P, 0u);
			store(EL_BACKGROUND); return;
		}
		if (borders4_at(P, EL_FIRE)) {
			emit_event(EV_SCRAMBLE, P, 0u);
			store(EL_BACKGROUND); return;
		}
		if (borders4_at(P, EL_POLLEN)) {
			emit_event(EV_NUKE, P, 0u);
			store(EL_BACKGROUND); return;
		}
		break;
	}

	case EL_METHANE: {
		if (rnd100_at(P, SALT_METH) < 25u && borders4_at(P, EL_FIRE)) {
			emit_event(EV_METHANE, P, 0u);
		}
		break;
	}

	case EL_SOIL: {
		// SOIL_ACTION doTransform with nitro (25%).
		if (rnd100_at(P, SALT_SOILN) < 25u && borders4_at(P, EL_NITRO)) {
			store(EL_CHARGED_NITRO); return;
		}
		// Absorb water from aboveAdjacent (15%).
		if (rnd100_at(P, SALT_SOILABS) < 15u) {
			for (int dx = -1; dx <= 1; dx++) {
				if (E(P + ivec2(dx, -1)) == EL_WATER) { store(EL_WET_SOIL); return; }
			}
		}
		break;
	}

	case EL_WET_SOIL: {
		// WET_SOIL_ACTION: dries out or sprouts a tree.
		if (rnd100_at(P, SALT_WSOIL1) < 5u) {
			if (rnd100_at(P, SALT_WSOIL2) < 97u) {
				if (!borders8_at(P, EL_WATER)) { store(EL_SOIL); return; }
			} else if (rnd100_at(P, SALT_WSOIL3) >= 35u) {
				bool bg_above = false;
				bool grounded = false;
				for (int dx = -1; dx <= 1; dx++) {
					if (E(P + ivec2(dx, -1)) == EL_BACKGROUND) bg_above = true;
					uint b = E(P + ivec2(dx, 1));
					if (b == EL_SOIL || b == EL_WALL) grounded = true;
				}
				if (bg_above && grounded) {
					emit_event(EV_TREE, P, 0u);
					store(EL_SOIL); return;
				}
			}
		}
		break;
	}

	case EL_BRANCH: {
		if (rnd100_at(P, SALT_BRANCHF) < 3u && borders8_at(P, EL_FIRE)) {
			store(EL_FIRE); return;
		}
		break;
	}

	case EL_LEAF: {
		if (rnd100_at(P, SALT_LEAFF) < 5u && borders8_at(P, EL_FIRE)) {
			store(EL_FIRE); return;
		}
		if (rnd100_at(P, SALT_LEAFS) < 20u && borders8_at(P, EL_SALT)) {
			store(EL_BACKGROUND); return;
		}
		break;
	}

	case EL_CHARGED_NITRO: {
		// CHARGED_NITRO_ACTION: rocket launch on fire contact.
		if (borders8_at(P, EL_FIRE)) {
			uint min_y = 0u; // 0 = no wall found (aux is minY+1)
			for (int yy = P.y - 4; yy >= 0; yy -= 4) {
				if (E(ivec2(P.x, yy)) == EL_WALL) { min_y = uint(yy) + 1u; break; }
			}
			emit_event(EV_ROCKET, P, min_y);
			store(EL_FIRE);
			return;
		}
		break;
	}

	default:
		break;
	}

	// No rule fired: pass the element through (this also strips the
	// movement pass's moved-bit for the new tick).
	store(e == EL_OOB ? EL_BACKGROUND : e);
}
