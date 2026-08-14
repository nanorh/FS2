# Pointer input over the simulation grid, ported from cursor.js and
# extended with brush shapes and a bucket fill.
#
# The control covers the sim view 1:1, so local coordinates are grid
# coordinates. While the pointer is held down we stamp a stroke from the
# previous to the current position every frame, which matches the
# original's interpolated drawing. It also draws the cursor preview:
# because the grid is one cell per pixel, the outline is a literal
# preview of the cells the next stroke will cover.
class_name Brush
extends Control

const MODE_CIRCLE := 0
const MODE_SQUARE := 1
const MODE_SPRAY := 2
const MODE_FILL := 3

var sim: FallingSand

var selected_elem := Elements.WALL:
	set(value):
		selected_elem = value
		queue_redraw()

var pen_radius := 2:
	set(value):
		pen_radius = value
		queue_redraw()

var mode := MODE_CIRCLE:
	set(value):
		mode = value
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
			_pos = Vector2i(event.position)
			_prev = _pos
			if mode == MODE_FILL:
				# One-shot: fill does not drag.
				if sim:
					sim.flood_fill(_pos.x, _pos.y, selected_elem)
			else:
				_pressed = true
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
	sim.stamp_stroke(selected_elem, _stamp_kind(),
		_prev.x, _prev.y, _pos.x, _pos.y, pen_radius, ow)
	_prev = _pos


func _stamp_kind() -> int:
	match mode:
		MODE_SQUARE:
			return FallingSand.CMD_SQUARE
		MODE_SPRAY:
			return FallingSand.CMD_SPRAY
	return FallingSand.CMD_SEGMENT


func _draw() -> void:
	if not _hovering:
		return

	# The eraser's element colour is black, which would be invisible
	# against the canvas, so it gets a neutral outline instead.
	var tint := UITheme.TEXT if selected_elem == Elements.BACKGROUND \
		else Elements.COLORS[selected_elem]
	var line := Color(tint.r, tint.g, tint.b, 0.95 if _pressed else 0.7)
	var halo := Color(0, 0, 0, 0.55)
	var centre := Vector2(_pos) + Vector2(0.5, 0.5)
	var r := maxf(float(pen_radius), 1.5)

	match mode:
		MODE_SQUARE:
			# Halo drawn as a slightly larger outline so the preview
			# stays legible over pale materials.
			_rect(centre, r + 1.0, halo, 2.0)
			_rect(centre, r, line, 1.0)
		MODE_SPRAY:
			# Dashed ring reads as "soft edge" rather than a hard cut.
			for i in 16:
				if i % 2 == 1:
					continue
				var a0 := TAU * float(i) / 16.0
				var a1 := TAU * float(i + 1) / 16.0
				draw_arc(centre, r + 1.0, a0, a1, 4, halo, 2.0, true)
				draw_arc(centre, r, a0, a1, 4, line, 1.0, true)
		MODE_FILL:
			# Crosshair: fill has no area, only a seed point.
			var s := 7.0
			draw_line(centre - Vector2(s, 0), centre + Vector2(s, 0), halo, 3.0, true)
			draw_line(centre - Vector2(0, s), centre + Vector2(0, s), halo, 3.0, true)
			draw_line(centre - Vector2(s, 0), centre + Vector2(s, 0), line, 1.0, true)
			draw_line(centre - Vector2(0, s), centre + Vector2(0, s), line, 1.0, true)
			draw_arc(centre, 2.5, 0.0, TAU, 12, line, 1.0, true)
		_:
			draw_arc(centre, r + 1.0, 0.0, TAU, 48, halo, 2.0, true)
			draw_arc(centre, r, 0.0, TAU, 48, line, 1.0, true)

	# Centre pip helps aim when the brush is large.
	if mode != MODE_FILL and r > 6.0:
		draw_arc(centre, 1.0, 0.0, TAU, 8, Color(tint.r, tint.g, tint.b, 0.8), 1.0, true)


func _rect(centre: Vector2, half: float, colour: Color, width: float) -> void:
	var rect := Rect2(centre - Vector2(half, half), Vector2(half * 2.0, half * 2.0))
	draw_rect(rect, colour, false, width)
