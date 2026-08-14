# Mouse/touch drawing onto the sim grid, ported from cursor.js.
# The control covers the sim view 1:1, so local coordinates are grid
# coordinates. While the pointer is held down we stamp a capsule from
# the previous to the current position every frame, which matches the
# original's interpolated stroke drawing.
#
# It also draws the cursor ring: the grid is one cell per pixel, so the
# ring is a literal preview of the area the next stamp will cover.
class_name Brush
extends Control

var sim: FallingSand

var selected_elem := Elements.WALL:
	set(value):
		selected_elem = value
		queue_redraw()

var pen_radius := 2:
	set(value):
		pen_radius = value
		queue_redraw()

var overwrite := true

var _pressed := false
var _pos := Vector2i.ZERO
var _prev := Vector2i.ZERO
var _hovering := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	mouse_entered.connect(func() -> void:
		_hovering = true
		queue_redraw())
	mouse_exited.connect(func() -> void:
		_hovering = false
		queue_redraw())


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressed = true
			_pos = Vector2i(event.position)
			_prev = _pos
		else:
			_pressed = false
		queue_redraw()
	elif event is InputEventMouseMotion:
		_pos = Vector2i(event.position)
		queue_redraw()


func update_stroke() -> void:
	if not _pressed or sim == null:
		return
	# Eraser always overwrites, like the original.
	var ow := overwrite or selected_elem == Elements.BACKGROUND
	sim.stamp_segment(selected_elem, _prev.x, _prev.y, _pos.x, _pos.y, pen_radius, ow)
	_prev = _pos


func _draw() -> void:
	if not _hovering:
		return

	# The eraser's element colour is black, which would be invisible
	# against the canvas, so it gets a neutral ring instead.
	var tint := UITheme.TEXT if selected_elem == Elements.BACKGROUND \
		else Elements.COLORS[selected_elem]
	var centre := Vector2(_pos) + Vector2(0.5, 0.5)
	var radius := maxf(float(pen_radius), 1.5)

	# Dark halo first so the ring stays legible over pale materials.
	draw_arc(centre, radius + 1.0, 0.0, TAU, 48, Color(0, 0, 0, 0.55), 2.0, true)
	draw_arc(centre, radius, 0.0, TAU, 48,
		Color(tint.r, tint.g, tint.b, 0.95 if _pressed else 0.7), 1.0, true)

	# Centre pip helps aim when the radius is large.
	if radius > 6.0:
		draw_arc(centre, 1.0, 0.0, TAU, 8, Color(tint.r, tint.g, tint.b, 0.8), 1.0, true)
