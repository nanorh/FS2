#[compute]
#version 450

// Converts the R32UI element grid into an RGBA8 texture for display
// (Texture2DRD cannot expose uint textures to the canvas renderer).
// Colors are the original Project Sand palette.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, r32ui) uniform restrict readonly uimage2D grid;
layout(set = 0, binding = 1, rgba8) uniform restrict writeonly image2D display_img;

layout(push_constant) uniform Params {
	uint view_mode; // 0 materials, 1 temperature, 2 pressure
	uint pad0;
	uint pad1;
	uint pad2;
} params;

const int TEMP_OFFSET = 5000; // temperature is stored in tenths of a degree
const int PRESS_OFFSET = 128; // pressure is stored in quarter units

// Suction teal through neutral to blast white.
vec3 pressure_ramp(float p) {
	if (p < 0.0) {
		return mix(vec3(0.10, 0.12, 0.14), vec3(0.0, 0.65, 0.60),
			clamp(-p / 12.0, 0.0, 1.0));
	}
	return mix(vec3(0.10, 0.12, 0.14), vec3(1.0, 0.95, 0.85),
		clamp(p / 24.0, 0.0, 1.0));
}

// Cold blue through room-temperature grey to red, orange and white hot.
vec3 heat_ramp(float c) {
	if (c < 20.0) {
		return mix(vec3(0.10, 0.30, 0.85), vec3(0.18, 0.18, 0.20),
			clamp((c + 200.0) / 220.0, 0.0, 1.0));
	}
	if (c < 300.0) {
		return mix(vec3(0.18, 0.18, 0.20), vec3(0.85, 0.15, 0.05),
			clamp((c - 20.0) / 280.0, 0.0, 1.0));
	}
	if (c < 900.0) {
		return mix(vec3(0.85, 0.15, 0.05), vec3(1.0, 0.72, 0.0),
			clamp((c - 300.0) / 600.0, 0.0, 1.0));
	}
	return mix(vec3(1.0, 0.72, 0.0), vec3(1.0, 1.0, 0.95),
		clamp((c - 900.0) / 500.0, 0.0, 1.0));
}

const vec3 PALETTE[34] = {
	vec3(0.0, 0.0, 0.0),          // BACKGROUND
	vec3(0.498, 0.498, 0.498),    // WALL
	vec3(0.875, 0.757, 0.388),    // SAND
	vec3(0.0, 0.039, 1.0),        // WATER
	vec3(0.0, 0.863, 0.0),        // PLANT
	vec3(1.0, 0.0, 0.039),        // FIRE
	vec3(0.992, 0.992, 0.992),    // SALT
	vec3(0.498, 0.686, 1.0),      // SALT_WATER
	vec3(0.588, 0.235, 0.0),      // OIL
	vec3(0.459, 0.741, 0.988),    // SPOUT
	vec3(0.514, 0.043, 0.11),     // WELL
	vec3(0.784, 0.02, 0.0),       // TORCH
	vec3(0.667, 0.667, 0.549),    // GUNPOWDER
	vec3(0.937, 0.882, 0.827),    // WAX
	vec3(0.941, 0.882, 0.827),    // FALLING_WAX
	vec3(0.0, 0.588, 0.102),      // NITRO
	vec3(0.863, 0.502, 0.275),    // NAPALM
	vec3(0.941, 0.902, 0.588),    // C4
	vec3(0.706, 0.706, 0.706),    // CONCRETE
	vec3(0.859, 0.686, 0.78),     // FUSE
	vec3(0.631, 0.91, 1.0),       // ICE
	vec3(0.078, 0.6, 0.863),      // CHILLED_ICE
	vec3(0.961, 0.431, 0.157),    // LAVA
	vec3(0.267, 0.157, 0.031),    // ROCK
	vec3(0.765, 0.839, 0.922),    // STEAM
	vec3(0.0, 0.835, 1.0),        // CRYO
	vec3(0.635, 0.91, 0.769),     // MYSTERY
	vec3(0.549, 0.549, 0.549),    // METHANE
	vec3(0.471, 0.294, 0.129),    // SOIL
	vec3(0.275, 0.137, 0.039),    // WET_SOIL
	vec3(0.651, 0.502, 0.392),    // BRANCH
	vec3(0.322, 0.42, 0.176),     // LEAF
	vec3(0.902, 0.922, 0.431),    // POLLEN
	vec3(0.961, 0.384, 0.306)     // CHARGED_NITRO
};

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(grid);
	if (p.x >= size.x || p.y >= size.y) return;
	uint raw = imageLoad(grid, p).r;

	if (params.view_mode == 1u) {
		float celsius = float(int((raw >> 8) & 0xFFFFu) - TEMP_OFFSET) * 0.1;
		imageStore(display_img, p, vec4(heat_ramp(celsius), 1.0));
		return;
	}
	if (params.view_mode == 2u) {
		float press = float(int((raw >> 24) & 0xFFu) - PRESS_OFFSET) * 0.25;
		imageStore(display_img, p, vec4(pressure_ramp(press), 1.0));
		return;
	}

	vec3 colour = PALETTE[min(raw & 63u, 33u)];
	// Sources are washed toward white so they read as fixed fixtures
	// rather than loose material of the same kind.
	if ((raw & 128u) != 0u) {
		colour = mix(colour, vec3(1.0), 0.45);
	}
	imageStore(display_img, p, vec4(colour, 1.0));
}
