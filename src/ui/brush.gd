# Mouse/touch drawing onto the sim grid, ported from cursor.js.
# The control covers the sim view 1:1, so local coordinates are grid
# coordinates. While the pointer is held down we stamp a capsule from
# the previous to the current position every frame, which matches the
# original's interpolated stroke drawing.
class_name Brush
extends Control

var sim: FallingSand
var selected_elem := Elements.WALL
var pen_radius := 2
var overwrite := true

var _pressed := false
var _pos := Vector2i.ZERO
var _prev := Vector2i.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressed = true
			_pos = Vector2i(event.position)
			_prev = _pos
		else:
			_pressed = false
	elif event is InputEventMouseMotion and _pressed:
		_pos = Vector2i(event.position)


func update_stroke() -> void:
	if not _pressed or sim == null:
		return
	# Eraser always overwrites, like the original.
	var ow := overwrite or selected_elem == Elements.BACKGROUND
	sim.stamp_segment(selected_elem, _prev.x, _prev.y, _pos.x, _pos.y, pen_radius, ow)
	_prev = _pos
