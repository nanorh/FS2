#[compute]
#version 450

// MYSTERY + FIRE canvas scramble. The original does a full Fisher-Yates
// style shuffle of every non-WALL cell (deleting FIRE and MYSTERY cells
// along the way). A sequential shuffle can't run on the GPU, so we run
// several passes of pairwise "butterfly" swaps: each cell pairs with
// partner = index XOR mask (an involution, so both sides agree) and the
// pair swaps. With a handful of passes using different masks this mixes
// the canvas globally.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, r32ui) uniform restrict uimage2D grid;

layout(push_constant) uniform Params {
	uint mask;     // XOR mask for pairing (in linear cell index space)
	uint tick;
	uint mode;     // 0 = clear fire/mystery pre-pass, 1 = swap pass
	uint pad0;
} params;

const uint EL_WALL = 1u;
const uint EL_FIRE = 5u;
const uint EL_MYSTERY = 26u;
const uint EL_BACKGROUND = 0u;

uint pcg(uint v) {
	v = v * 747796405u + 2891336453u;
	uint w = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
	return (w >> 22u) ^ w;
}

void main() {
	ivec2 size = imageSize(grid);
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= size.x || p.y >= size.y) return;

	uint idx = uint(p.y * size.x + p.x);
	uint total = uint(size.x * size.y);
	uint self = imageLoad(grid, p).r & 63u;

	if (params.mode == 0u) {
		// Original scramble deletes fire and mystery as it goes.
		if (self == EL_FIRE || self == EL_MYSTERY) {
			imageStore(grid, p, uvec4(EL_BACKGROUND, 0u, 0u, 0u));
		}
		return;
	}

	if (self == EL_WALL) return;

	uint partner = idx ^ params.mask;
	if (partner >= total || partner <= idx) return; // lower index owns the swap

	ivec2 q = ivec2(int(partner % uint(size.x)), int(partner / uint(size.x)));
	uint other = imageLoad(grid, q).r & 63u;
	if (other == EL_WALL) return;

	// Randomly skip some pairs so the result isn't a pure permutation
	// pattern.
	if (pcg(idx ^ pcg(params.mask ^ params.tick)) % 100u < 25u) return;

	imageStore(grid, p, uvec4(other, 0u, 0u, 0u));
	imageStore(grid, q, uvec4(self, 0u, 0u, 0u));
}
