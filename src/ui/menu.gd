# Control panel: element palette, tools, brush size, simulation speed,
# spigot configuration and canvas actions.
#
# Two centred rows. The palette on top stretches to the full width, so
# widening the window makes the chips grow rather than leaving a gap at
# the right; the controls below stay centred under it. Hovering any
# element describes what it does.
class_name SandMenu
extends PanelContainer

signal element_selected(elem: int)
signal pen_size_changed(radius: int)
signal mode_changed(mode: int)
signal overwrite_changed(enabled: bool)
signal speed_changed(fps: int)
signal solid_floor_changed(enabled: bool)
signal solid_ceiling_changed(enabled: bool)
signal spigot_element_changed(index: int, elem: int)
signal spigot_size_changed(index: int, size: int)
signal clear_pressed
signal save_pressed
signal load_pressed

const DEFAULT_FPS := 60
const MAX_FPS := 120

const MIN_RADIUS := 1
const MAX_RADIUS := 64
const DEFAULT_RADIUS := 2

# Fixed column count keeps the palette exactly two rows tall at every
# window size, so the panel height never changes and cannot feed back
# into the grid resize. Chips are a fixed width and the block is centred:
# stretching them to the window only moves the empty space inside the
# chips.
const PALETTE_COLUMNS := 12
const CHIP_WIDTH := 98

var _size_label: Label
var _speed_label: Label
var _fps := 0
var _speed := DEFAULT_FPS


func _ready() -> void:
	UITheme.style_panel(self)

	var root := MarginContainer.new()
	root.add_theme_constant_override("margin_left", 16)
	root.add_theme_constant_override("margin_right", 16)
	root.add_theme_constant_override("margin_top", 10)
	root.add_theme_constant_override("margin_bottom", 10)
	add_child(root)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 10)
	root.add_child(rows)

	rows.add_child(_build_palette())
	rows.add_child(_build_controls())


func set_fps_text(fps: int) -> void:
	_fps = fps
	_refresh_speed_label()


# A control with a small heading above it.
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
		var colour: Color = Elements.menu_color(elem)
		var btn := Button.new()
		btn.text = Elements.MENU_NAMES[elem]
		btn.toggle_mode = true
		btn.button_group = group
		btn.icon = UITheme.dot(colour, 9)
		btn.tooltip_text = Elements.describe(elem)
		btn.custom_minimum_size = Vector2(CHIP_WIDTH, 0)
		UITheme.style_swatch(btn, colour)
		var e := elem
		btn.pressed.connect(func() -> void: element_selected.emit(e))
		grid.add_child(btn)
		if elem == Elements.WALL:
			btn.button_pressed = true

	return grid


func _build_controls() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 26)
	row.add_child(_build_tools())
	row.add_child(_build_size())
	row.add_child(_build_speed())
	row.add_child(_build_bounds())
	row.add_child(_build_spigots())
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


func _build_spigots() -> Control:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 3)

	for i in Spigots.NUM_SPIGOTS:
		var idx := i
		var cell := HBoxContainer.new()
		cell.add_theme_constant_override("separation", 4)

		var type_btn := OptionButton.new()
		for k in Elements.SPIGOT_OPTIONS.size():
			type_btn.add_item(Elements.MENU_NAMES[Elements.SPIGOT_OPTIONS[k]], k)
		type_btn.select(i) # spigot i defaults to option i, as in the original
		type_btn.custom_minimum_size = Vector2(96, 0)
		type_btn.tooltip_text = "Spigot %d material" % (i + 1)
		UITheme.style_option(type_btn)
		type_btn.item_selected.connect(func(opt: int) -> void:
			spigot_element_changed.emit(idx, Elements.SPIGOT_OPTIONS[opt]))
		cell.add_child(type_btn)

		var size_btn := OptionButton.new()
		for k in Spigots.SIZE_OPTIONS.size():
			size_btn.add_item(str(k), k)
		size_btn.select(Spigots.DEFAULT_SIZE_IDX)
		size_btn.custom_minimum_size = Vector2(40, 0)
		size_btn.tooltip_text = "Spigot %d width (0 turns it off)" % (i + 1)
		UITheme.style_option(size_btn)
		size_btn.item_selected.connect(func(opt: int) -> void:
			spigot_size_changed.emit(idx, Spigots.SIZE_OPTIONS[opt]))
		cell.add_child(size_btn)

		grid.add_child(cell)

	return _column(UITheme.caption("Spigots"), grid)


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
