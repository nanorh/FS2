# Control panel: element palette, tools, brush size, simulation speed,
# world bounds and canvas actions.
#
# A floating card the user can drag anywhere and collapse to its header.
# Two centred rows of controls sit under that header.
#
# Clicking an already-selected material a second time switches it to
# source mode, which paints a fixed emitter of that material instead of
# loose material. That replaces the original's dedicated spout, well and
# torch elements.
class_name SandMenu
extends PanelContainer

signal element_selected(elem: int)
signal emitter_changed(enabled: bool)
signal pen_size_changed(radius: int)
signal mode_changed(mode: int)
signal overwrite_changed(enabled: bool)
signal speed_changed(fps: int)
signal solid_floor_changed(enabled: bool)
signal solid_ceiling_changed(enabled: bool)
signal clear_pressed
signal save_pressed
signal load_pressed
# Emitted when the panel's own size changes, so the owner can reposition it.
signal layout_changed

const DEFAULT_FPS := 60
const MAX_FPS := 120

const MIN_RADIUS := 1
const MAX_RADIUS := 64
const DEFAULT_RADIUS := 2

# 20 materials as 10x2. Chips are a fixed width and the block is centred:
# stretching them to the window only moves the empty space inside them.
const PALETTE_COLUMNS := 10
const CHIP_WIDTH := 98

# True once the user has dragged the panel; the owner then stops
# re-centring it and only clamps it back inside the window.
var user_positioned := false

var _size_label: Label
var _speed_label: Label
var _fps := 0
var _speed := DEFAULT_FPS

var _body: VBoxContainer
var _collapse_button: Button
var _chips := {}
var _selected := Elements.WALL
var _emitter := false

var _dragging := false
var _drag_offset := Vector2.ZERO


func _ready() -> void:
	UITheme.style_panel(self)

	var root := MarginContainer.new()
	root.add_theme_constant_override("margin_left", 16)
	root.add_theme_constant_override("margin_right", 16)
	root.add_theme_constant_override("margin_top", 8)
	root.add_theme_constant_override("margin_bottom", 10)
	add_child(root)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	root.add_child(outer)
	outer.add_child(_build_header())

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 10)
	outer.add_child(_body)
	_body.add_child(_build_palette())
	_body.add_child(_build_controls())


func set_fps_text(fps: int) -> void:
	_fps = fps
	_refresh_speed_label()


# ------------------------------------------------------------------
# Header: drag handle and collapse
# ------------------------------------------------------------------

func _build_header() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)

	var grip := TextureRect.new()
	grip.texture = UITheme.glyph(UITheme.GLYPH_GRIP, 14, UITheme.TEXT_FAINT)
	grip.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	grip.custom_minimum_size = Vector2(14, 14)
	grip.tooltip_text = "Drag to move the panel"
	bar.add_child(grip)

	var title := UITheme.caption("Falling Sand")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(title)

	_collapse_button = Button.new()
	_collapse_button.custom_minimum_size = Vector2(22, 16)
	_collapse_button.tooltip_text = "Collapse the panel"
	_collapse_button.icon = UITheme.glyph(UITheme.GLYPH_CARET_DOWN, 14, Color.WHITE)
	UITheme.style_tool(_collapse_button)
	_collapse_button.pressed.connect(_toggle_collapsed)
	bar.add_child(_collapse_button)

	return bar


func set_collapsed(collapsed: bool) -> void:
	_body.visible = not collapsed
	_collapse_button.icon = UITheme.glyph(
		UITheme.GLYPH_CARET_DOWN if _body.visible else UITheme.GLYPH_CARET_UP,
		14, Color.WHITE)
	_collapse_button.tooltip_text = \
		"Collapse the panel" if _body.visible else "Expand the panel"
	# The card shrinks to its header; let the owner re-place it.
	reset_size()
	layout_changed.emit()


func _toggle_collapsed() -> void:
	set_collapsed(_body.visible)


# Dragging anywhere on the card that is not itself a control.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_offset = get_global_mouse_position() - global_position
		else:
			_dragging = false
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		user_positioned = true
		var vp := get_viewport_rect().size
		var wanted := get_global_mouse_position() - _drag_offset
		position = Vector2(
			clampf(wanted.x, 0.0, maxf(0.0, vp.x - size.x)),
			clampf(wanted.y, 0.0, maxf(0.0, vp.y - size.y)))
		accept_event()


# ------------------------------------------------------------------
# Palette
# ------------------------------------------------------------------

func _column(heading: Label, content: Control) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 5)
	col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	col.add_child(heading)
	col.add_child(content)
	return col


func _build_palette() -> Control:
	var grid := GridContainer.new()
	grid.columns = PALETTE_COLUMNS
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	var group := ButtonGroup.new()
	for elem in Elements.MENU_ITEMS:
		var btn := Button.new()
		btn.text = Elements.MENU_NAMES[elem]
		btn.toggle_mode = true
		btn.button_group = group
		btn.icon = UITheme.dot(Elements.menu_color(elem), 9)
		btn.custom_minimum_size = Vector2(CHIP_WIDTH, 0)
		UITheme.style_swatch(btn, Elements.menu_color(elem))
		var e := elem
		# button_down rather than pressed: a ButtonGroup swallows the
		# pressed signal when the already-selected button is clicked, and
		# that second click is exactly what toggles source mode.
		btn.button_down.connect(func() -> void: _on_chip_pressed(e))
		grid.add_child(btn)
		_chips[elem] = btn
		_refresh_chip(elem)

	_chips[Elements.WALL].button_pressed = true
	return grid


func _on_chip_pressed(elem: int) -> void:
	if elem == _selected and Elements.can_emit(elem):
		_emitter = not _emitter
	else:
		var was := _selected
		_selected = elem
		_emitter = false
		_refresh_chip(was)
	_refresh_chip(elem)
	element_selected.emit(elem)
	emitter_changed.emit(_emitter)


# Source-mode chips swap their dot for a ringed dot and say so on hover.
func _refresh_chip(elem: int) -> void:
	var btn: Button = _chips.get(elem)
	if btn == null:
		return
	var colour: Color = Elements.menu_color(elem)
	var on := elem == _selected and _emitter
	btn.icon = UITheme.source_dot(colour, 9) if on else UITheme.dot(colour, 9)
	var tip := Elements.describe(elem)
	if Elements.can_emit(elem):
		tip += "\n\nClick again for a source that emits it continuously."
		if on:
			tip = "%s (source)\n%s" % [Elements.MENU_NAMES[elem],
				"Paints a fixed emitter. Click again for loose material."]
	btn.tooltip_text = tip


# ------------------------------------------------------------------
# Controls
# ------------------------------------------------------------------

func _build_controls() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 26)
	row.add_child(_build_tools())
	row.add_child(_build_size())
	row.add_child(_build_speed())
	row.add_child(_build_bounds())
	row.add_child(_build_actions())
	return row


func _build_tools() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 3)

	var group := ButtonGroup.new()
	var tools := [
		[Brush.MODE_CIRCLE, UITheme.GLYPH_CIRCLE, "Round brush",
			"Draws a capsule stroke with rounded ends."],
		[Brush.MODE_SQUARE, UITheme.GLYPH_SQUARE, "Square brush",
			"Draws with a square profile, for straight edges and blocks."],
		[Brush.MODE_SPRAY, UITheme.GLYPH_SPRAY, "Spray",
			"Scatters material, densest at the centre and thinning outward."],
		[Brush.MODE_FILL, UITheme.GLYPH_FILL, "Fill",
			"Replaces the whole connected region you click on."],
	]
	for t in tools:
		var btn := Button.new()
		btn.toggle_mode = true
		btn.button_group = group
		btn.custom_minimum_size = Vector2(28, 28)
		btn.tooltip_text = "%s\n%s" % [t[2], t[3]]
		btn.icon = UITheme.glyph(t[1], 16, Color.WHITE)
		UITheme.style_tool(btn)
		var mode: int = t[0]
		btn.pressed.connect(func() -> void: mode_changed.emit(mode))
		bar.add_child(btn)
		if mode == Brush.MODE_CIRCLE:
			btn.button_pressed = true

	var overwrite := Button.new()
	overwrite.text = "Overwrite"
	overwrite.toggle_mode = true
	overwrite.button_pressed = true
	overwrite.tooltip_text = "Overwrite\nDraw over existing material instead of only empty space."
	UITheme.style_ghost(overwrite, UITheme.ACCENT)
	overwrite.toggled.connect(func(on: bool) -> void: overwrite_changed.emit(on))
	bar.add_child(overwrite)

	return _column(UITheme.caption("Tool"), bar)


func _build_size() -> Control:
	_size_label = UITheme.caption("Size  %d" % DEFAULT_RADIUS)

	var slider := HSlider.new()
	slider.min_value = MIN_RADIUS
	slider.max_value = MAX_RADIUS
	slider.value = DEFAULT_RADIUS
	slider.step = 1
	slider.custom_minimum_size = Vector2(118, 16)
	slider.tooltip_text = "Brush radius in cells"
	UITheme.style_slider(slider)
	slider.value_changed.connect(func(v: float) -> void:
		var r := int(v)
		_size_label.text = "Size  %d" % r
		pen_size_changed.emit(r))

	return _column(_size_label, slider)


func _build_speed() -> Control:
	_speed_label = UITheme.caption("")
	_refresh_speed_label()

	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = MAX_FPS
	slider.value = DEFAULT_FPS
	slider.step = 1
	slider.custom_minimum_size = Vector2(118, 16)
	slider.tooltip_text = "Target simulation ticks per second (0 pauses)"
	UITheme.style_slider(slider)
	slider.value_changed.connect(func(v: float) -> void:
		var val := int(v)
		# Magnetic toward the default, like the original slider.
		if absi(val - DEFAULT_FPS) < 8 and val != DEFAULT_FPS:
			slider.set_value_no_signal(DEFAULT_FPS)
			val = DEFAULT_FPS
		_speed = val
		_refresh_speed_label()
		speed_changed.emit(val))

	return _column(_speed_label, slider)


func _refresh_speed_label() -> void:
	if not _speed_label:
		return
	if _speed == 0:
		_speed_label.text = "Paused"
	else:
		_speed_label.text = "Speed  %d   ·   %d fps" % [_speed, _fps]
	_speed_label.add_theme_color_override("font_color",
		UITheme.TEXT_FAINT if _speed == 0 or _fps < _speed - 6 else UITheme.ACCENT)


func _build_bounds() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)

	var ceiling := Button.new()
	ceiling.text = "Ceiling"
	ceiling.toggle_mode = true
	ceiling.tooltip_text = "Solid ceiling\nGases collect against the top edge instead of escaping."
	UITheme.style_ghost(ceiling, UITheme.ACCENT)
	ceiling.toggled.connect(func(on: bool) -> void: solid_ceiling_changed.emit(on))
	col.add_child(ceiling)

	var floor_btn := Button.new()
	floor_btn.text = "Floor"
	floor_btn.toggle_mode = true
	floor_btn.tooltip_text = "Solid floor\nMaterial piles up on the bottom edge instead of falling away."
	UITheme.style_ghost(floor_btn, UITheme.ACCENT)
	floor_btn.toggled.connect(func(on: bool) -> void: solid_floor_changed.emit(on))
	col.add_child(floor_btn)

	return _column(UITheme.caption("Solid"), col)


func _build_actions() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 2)

	var save := Button.new()
	save.text = "Save"
	save.tooltip_text = "Save\nStore a snapshot of the canvas."
	UITheme.style_ghost(save, UITheme.ACCENT)
	save.pressed.connect(func() -> void: save_pressed.emit())
	bar.add_child(save)

	var load_btn := Button.new()
	load_btn.text = "Load"
	load_btn.tooltip_text = "Load\nRestore the last saved snapshot."
	UITheme.style_ghost(load_btn, UITheme.ACCENT)
	load_btn.pressed.connect(func() -> void: load_pressed.emit())
	bar.add_child(load_btn)

	var clear := Button.new()
	clear.text = "Clear"
	clear.tooltip_text = "Clear\nEmpty the canvas."
	UITheme.style_ghost(clear, UITheme.DANGER)
	clear.pressed.connect(func() -> void: clear_pressed.emit())
	bar.add_child(clear)

	return _column(UITheme.caption("Canvas"), bar)
