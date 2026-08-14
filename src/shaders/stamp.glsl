#[compute]
#version 450

// Applies CPU-issued stamp commands (brush strokes, particle strokes,
// spigot emitters) to the grid. One thread per cell; commands are
// applied in order so later strokes win, like the original canvas draws.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, r32ui) uniform restrict uimage2D grid;

// Each command is 8 ints:
//   [0] kind: 0 = circle, 1 = round segment (capsule),
//             2 = dithered rect, 3 = square segment, 4 = spray segment
//   [1] element id
//   [2] flags: bit0 overwrite (else only paints BACKGROUND),
//              bit1 never paint over WALL (tree strokes),
//              bit2 paint as a source rather than loose material
//   [3] x0  [4] y0  [5] x1  [6] y1
//   [7] radius (circle/segment, in cells) or density 0-99 (rect)
layout(set = 0, binding = 1, std430) restrict readonly buffer Commands {
	int data[];
} cmds;

layout(push_constant) uniform Params {
	uint cmd_count;
	uint tick;
	uint pad0;
	uint pad1;
} params;

const uint EL_BACKGROUND = 0u;
const uint EL_WALL = 1u;
// Bit 7 marks a cell as a fixed source of its own element.
const uint EMITTER_BIT = 128u;

// Bits 8-23 hold temperature in tenths of a degree, offset so it can go
// below zero: stored = celsius * 10 + TEMP_OFFSET.
const int TEMP_OFFSET = 5000;
const int AMBIENT_C = 20;

const uint EL_FIRE = 5u;
const uint EL_ICE = 20u;
const uint EL_CHILLED_ICE = 21u;
const uint EL_LAVA = 22u;
const uint EL_STEAM = 24u;
const uint EL_CRYO = 25u;
const uint EL_TORCH = 11u;

// Freshly painted material arrives at its own natural temperature, so
// lava is hot and ice is cold the instant you place them.
int spawn_temp(uint e) {
	switch (e) {
		case EL_LAVA: return 1200;
		case EL_TORCH: return 900;
		case EL_FIRE: return 850;
		case EL_STEAM: return 110;
		case EL_ICE: return -8;
		case EL_CHILLED_ICE: return -40;
		case EL_CRYO: return -200;
	}
	return AMBIENT_C;
}

uint temp_bits(int celsius) {
	return uint(clamp(celsius * 10 + TEMP_OFFSET, 0, 65535)) << 8;
}

// Bits 24-31: pressure in quarter units, offset by 128.
const int PRESS_OFFSET = 128;
const float BLAST_PRESSURE = 28.0;

uint press_bits(float p) {
	return uint(clamp(int(round(p * 4.0)) + PRESS_OFFSET, 0, 255)) << 24;
}

uint pcg(uint v) {
	v = v * 747796405u + 2891336453u;
	uint w = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
	return (w >> 22u) ^ w;
}

uint rnd100(uint cell_idx, uint salt) {
	return pcg(cell_idx ^ pcg(salt ^ (params.tick * 0x9E3779B9u))) % 100u;
}

// Closest point on segment ab to p.
vec2 closest_on_segment(vec2 p, vec2 a, vec2 b) {
	vec2 ab = b - a;
	float len2 = dot(ab, ab);
	float t = len2 > 0.0 ? clamp(dot(p - a, ab) / len2, 0.0, 1.0) : 0.0;
	return a + t * ab;
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(grid);
	if (p.x >= size.x || p.y >= size.y) return;

	uint cell = imageLoad(grid, p).r;
	uint elem = cell & 63u;
	// Source bit and temperature: a paint replaces both.
	uint extra = cell & 0x00FFFF80u;
	// Pressure belongs to the space rather than the material, so it
	// survives an ordinary paint and only a blast overwrites it.
	uint press = cell & 0xFF000000u;
	bool changed = false;
	vec2 pf = vec2(p) + vec2(0.5);

	for (uint c = 0u; c < params.cmd_count; c++) {
		uint base = c * 8u;
		int kind = cmds.data[base + 0u];
		int stamp_elem = cmds.data[base + 1u];
		int flags = cmds.data[base + 2u];
		ivec2 p0 = ivec2(cmds.data[base + 3u], cmds.data[base + 4u]);
		ivec2 p1 = ivec2(cmds.data[base + 5u], cmds.data[base + 6u]);
		int r = cmds.data[base + 7u];

		bool covered = false;
		if (kind == 0) {
			covered = distance(pf, vec2(p0) + vec2(0.5)) <= float(r);
		} else if (kind == 1) {
			vec2 q = closest_on_segment(pf, vec2(p0) + vec2(0.5), vec2(p1) + vec2(0.5));
			covered = distance(pf, q) <= float(r);
		} else if (kind == 2) {
			if (p.x >= p0.x && p.x < p1.x && p.y >= p0.y && p.y < p1.y) {
				covered = rnd100(uint(p.y * size.x + p.x), 0xABCDu + c) < uint(r);
			}
		} else if (kind == 3) {
			// Square profile: Chebyshev distance to the stroke.
			vec2 q = closest_on_segment(pf, vec2(p0) + vec2(0.5), vec2(p1) + vec2(0.5));
			vec2 d = abs(pf - q);
			covered = max(d.x, d.y) <= float(r);
		} else if (kind == 4) {
			// Spray: round profile, but only a fraction of the covered
			// cells actually take. Density falls off toward the edge so
			// the spatter looks airbrushed rather than cut out.
			vec2 q = closest_on_segment(pf, vec2(p0) + vec2(0.5), vec2(p1) + vec2(0.5));
			float d = distance(pf, q);
			if (d <= float(r)) {
				float falloff = 1.0 - d / max(float(r), 1.0);
				uint chance = uint(clamp(14.0 * falloff * falloff + 3.0, 1.0, 99.0));
				covered = rnd100(uint(p.y * size.x + p.x), 0x5EEDu + c) < chance;
			}
		}
		if (!covered) continue;

		bool overwrite = (flags & 1) != 0;
		bool skip_wall = (flags & 2) != 0;
		if (!overwrite && elem != EL_BACKGROUND) continue;
		if (skip_wall && elem == EL_WALL) continue;

		elem = uint(stamp_elem);
		extra = ((flags & 4) != 0 ? EMITTER_BIT : 0u) | temp_bits(spawn_temp(elem));
		if ((flags & 8) != 0) {
			press = press_bits(BLAST_PRESSURE);
		}
		changed = true;
	}

	if (changed) {
		imageStore(grid, p, uvec4(elem | extra | press, 0u, 0u, 0u));
	}
}
