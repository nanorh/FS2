# Element ids, palette, and UI metadata.
# Ids and colors match the order/values in Project Sand's elements.js
# (GPL-3.0, Josh Don). The GLSL shaders hard-code the same ids.
class_name Elements

const BACKGROUND := 0
const WALL := 1
const SAND := 2
const WATER := 3
const PLANT := 4
const FIRE := 5
const SALT := 6
const SALT_WATER := 7
const OIL := 8
const SPOUT := 9
const WELL := 10
const TORCH := 11
const GUNPOWDER := 12
const WAX := 13
const FALLING_WAX := 14
const NITRO := 15
const NAPALM := 16
const C4 := 17
const CONCRETE := 18
const FUSE := 19
const ICE := 20
const CHILLED_ICE := 21
const LAVA := 22
const ROCK := 23
const STEAM := 24
const CRYO := 25
const MYSTERY := 26
const METHANE := 27
const SOIL := 28
const WET_SOIL := 29
const BRANCH := 30
const LEAF := 31
const POLLEN := 32
const CHARGED_NITRO := 33

const NUM_ELEMENTS := 34

# The moved-this-tick flag stored in cell bit 6 by the movement shader.
const MOVED_BIT := 64

static var COLORS := PackedColorArray([
	Color8(0, 0, 0),        # BACKGROUND
	Color8(127, 127, 127),  # WALL
	Color8(223, 193, 99),   # SAND
	Color8(0, 10, 255),     # WATER
	Color8(0, 220, 0),      # PLANT
	Color8(255, 0, 10),     # FIRE
	Color8(253, 253, 253),  # SALT
	Color8(127, 175, 255),  # SALT_WATER
	Color8(150, 60, 0),     # OIL
	Color8(117, 189, 252),  # SPOUT
	Color8(131, 11, 28),    # WELL
	Color8(200, 5, 0),      # TORCH
	Color8(170, 170, 140),  # GUNPOWDER
	Color8(239, 225, 211),  # WAX
	Color8(240, 225, 211),  # FALLING_WAX
	Color8(0, 150, 26),     # NITRO
	Color8(220, 128, 70),   # NAPALM
	Color8(240, 230, 150),  # C4
	Color8(180, 180, 180),  # CONCRETE
	Color8(219, 175, 199),  # FUSE
	Color8(161, 232, 255),  # ICE
	Color8(20, 153, 220),   # CHILLED_ICE
	Color8(245, 110, 40),   # LAVA
	Color8(68, 40, 8),      # ROCK
	Color8(195, 214, 235),  # STEAM
	Color8(0, 213, 255),    # CRYO
	Color8(162, 232, 196),  # MYSTERY
	Color8(140, 140, 140),  # METHANE
	Color8(120, 75, 33),    # SOIL
	Color8(70, 35, 10),     # WET_SOIL
	Color8(166, 128, 100),  # BRANCH
	Color8(82, 107, 45),    # LEAF
	Color8(230, 235, 110),  # POLLEN
	Color8(245, 98, 78),    # CHARGED_NITRO
])

# Elements shown in the drawing menu, in original menu order.
static var MENU_ITEMS: Array[int] = [
	WALL, SAND, WATER, PLANT,
	FIRE, SPOUT, WELL, SALT,
	OIL, WAX, TORCH, ICE,
	GUNPOWDER, NAPALM, NITRO, C4,
	LAVA, CRYO, FUSE, MYSTERY,
	CONCRETE, METHANE, SOIL, BACKGROUND,
]

static var MENU_NAMES := {
	WALL: "WALL", SAND: "SAND", WATER: "WATER", PLANT: "PLANT",
	FIRE: "FIRE", SALT: "SALT", OIL: "OIL", SPOUT: "SPOUT",
	WELL: "WELL", TORCH: "TORCH", GUNPOWDER: "GUNPOWDER", WAX: "WAX",
	NITRO: "NITRO", NAPALM: "NAPALM", C4: "C-4", CONCRETE: "CONCRETE",
	BACKGROUND: "ERASER", FUSE: "FUSE", ICE: "ICE", LAVA: "LAVA",
	METHANE: "METHANE", CRYO: "CRYO", MYSTERY: "???", SOIL: "SOIL",
}

# Menu text colors for elements whose in-game color has poor contrast.
static var MENU_ALT_COLORS := {
	WATER: Color8(0, 130, 255),
	WALL: Color8(160, 160, 160),
	BACKGROUND: Color8(200, 100, 200),
	WELL: Color8(158, 13, 33),
	SOIL: Color8(171, 110, 53),
}

# Elements offered by the spigot dropdowns (original SPIGOT_ELEMENT_OPTIONS).
static var SPIGOT_OPTIONS: Array[int] = [
	SAND, WATER, SALT, OIL, GUNPOWDER, NITRO,
	NAPALM, CONCRETE, LAVA, CRYO, MYSTERY,
]

static func menu_color(elem: int) -> Color:
	if MENU_ALT_COLORS.has(elem):
		return MENU_ALT_COLORS[elem]
	return COLORS[elem]
