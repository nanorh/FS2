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

# Elements offered in the drawing palette, in original menu order.
#
# Withheld, with their simulation left completely intact:
#   SOIL              - temporarily hidden at request.
#   SPOUT/WELL/TORCH  - superseded by source mode, which turns any
#                       flowing material into an emitter. Cells of these
#                       types still behave normally if loaded from a
#                       save, and the reaction rules that reference them
#                       (steam condensing on a spout, for instance) are
#                       unchanged.
# Restore any of them by putting it back in this list.
static var MENU_ITEMS: Array[int] = [
	WALL, SAND, WATER, PLANT,
	FIRE, SALT, OIL, WAX,
	ICE, GUNPOWDER, NAPALM, NITRO,
	C4, LAVA, CRYO, FUSE,
	MYSTERY, CONCRETE, METHANE, BACKGROUND,
]

# Materials that can be placed as a source. Anything that flows - powder,
# liquid or gas - plus fire, which gives the old torch. Static solids are
# excluded: a source of something that never moves is just the solid.
static var EMITTABLE: Array[int] = [
	SAND, WATER, SALT, OIL, FIRE, GUNPOWDER,
	NAPALM, NITRO, LAVA, CRYO, MYSTERY, CONCRETE, METHANE,
]


static func can_emit(elem: int) -> bool:
	return EMITTABLE.has(elem)

static var MENU_NAMES := {
	WALL: "WALL", SAND: "SAND", WATER: "WATER", PLANT: "PLANT",
	FIRE: "FIRE", SALT: "SALT", OIL: "OIL", SPOUT: "SPOUT",
	WELL: "WELL", TORCH: "TORCH", GUNPOWDER: "GUNPOWDER", WAX: "WAX",
	NITRO: "NITRO", NAPALM: "NAPALM", C4: "C-4", CONCRETE: "CONCRETE",
	BACKGROUND: "ERASER", FUSE: "FUSE", ICE: "ICE", LAVA: "LAVA",
	METHANE: "METHANE", CRYO: "CRYO", MYSTERY: "???", SOIL: "SOIL",
}

# Shown on hover. Each line describes what the element actually does in
# the simulation, not just what it is.
static var DESCRIPTIONS := {
	WALL: "Immovable barrier. Lava melts it slowly; concrete hardens against it.",
	SAND: "Falls and piles up. Sinks through water and salt water.",
	WATER: "Flows and finds its level. Boils to steam near fire or lava, freezes near cryo.",
	PLANT: "Creeps through water and spreads. Burns easily; salt kills it.",
	FIRE: "Spreads through plant, fuse, oil and wax. Water quenches it; it dies without fuel.",
	SPOUT: "Fixed source. Emits water continuously, and condenses steam back to water.",
	WELL: "Fixed source. Emits oil continuously.",
	SALT: "Falls and piles. Dissolves into water to make salt water, kills plants, melts ice.",
	OIL: "Floats on water. Catches fire readily and burns hard.",
	WAX: "Static solid. Fire melts it into droplets that run and set again where they land.",
	TORCH: "Fixed source. Emits fire continuously.",
	ICE: "Melts to water near fire, lava, steam, salt or salt water.",
	GUNPOWDER: "Falls. Detonates on contact with fire and chains through nearby grains.",
	NAPALM: "Falls. Erupts into clinging fireballs when lit.",
	NITRO: "Falls and sinks through liquids. Detonates violently on contact with fire.",
	C4: "Static charge. Blows a wide crater when lit.",
	LAVA: "Flows and burns almost anything. Sets to rock on contact with water.",
	CRYO: "Falls and freezes what it touches into chilled ice. Quenches lava to rock.",
	FUSE: "Static. Carries fire quickly along its length.",
	MYSTERY: "Unstable. Reacts unpredictably with sand, salt, pollen and fire.",
	CONCRETE: "Falls, then sets into wall - faster where it settles against existing wall.",
	METHANE: "Rises as a gas. Explodes on contact with fire. Seeps from rock that touches oil.",
	SOIL: "Absorbs water to become wet soil, which can sprout a tree.",
	BACKGROUND: "Eraser. Removes whatever you paint over.",
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


# Tooltip text: the name, then what it does.
static func describe(elem: int) -> String:
	var name: String = MENU_NAMES.get(elem, "?")
	var body: String = DESCRIPTIONS.get(elem, "")
	return name if body.is_empty() else "%s\n%s" % [name, body]
