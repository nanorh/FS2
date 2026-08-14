# The four top-of-canvas emitters, ported from spigots.js.
class_name Spigots
extends RefCounted

const NUM_SPIGOTS := 4
const SPIGOT_HEIGHT := 10
const SIZE_OPTIONS: Array[int] = [0, 5, 10, 15, 20, 25]
const DEFAULT_SIZE_IDX := 1

var elements: Array[int] = [Elements.SAND, Elements.WATER, Elements.SALT, Elements.OIL]
var sizes: Array[int] = []

var _spacing: int
var _max_width: int
var _grid_width: int


func _init(grid_width: int) -> void:
	_max_width = SIZE_OPTIONS.max()
	set_width(grid_width)
	for i in NUM_SPIGOTS:
		sizes.append(SIZE_OPTIONS[DEFAULT_SIZE_IDX])


# Spigots stay evenly spread as the window widens.
func set_width(grid_width: int) -> void:
	_grid_width = grid_width
	_spacing = int(round(
		float(grid_width - _max_width * NUM_SPIGOTS) / float(NUM_SPIGOTS + 1)
		+ float(_max_width)))


func update(sim: FallingSand) -> void:
	for i in NUM_SPIGOTS:
		var size := sizes[i]
		if size <= 0:
			continue
		var left := _spacing * (i + 1) - _max_width
		var right := left + size
		if left < 0 or right > _grid_width - 1:
			continue
		# 10% of covered cells emit per tick, like the original.
		sim.stamp_rect(elements[i], left, 0, right, SPIGOT_HEIGHT, 10)
