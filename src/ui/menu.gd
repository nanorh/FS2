# Control panel: element palette, brush settings, simulation speed,
# spigot configuration and canvas actions. Mirrors the options of the
# original menu.js, restyled as a dark sectioned toolbar (see ui_theme.gd).
class_name SandMenu
extends PanelContainer

signal element_selected(elem: int)
signal pen_size_changed(radius: int)
signal overwrite_changed(enabled: bool)
signal speed_changed(fps: int)
signal spigot_element_changed(index: int, elem: int)
signal spigot_size_changed(index: int, size: int)
signal clear_pressed
signal save_pressed
signal load_pressed

const PEN_SIZES: Array[int] = [2, 4, 8, 16, 32, 64]
const PEN_SIZE_LABELS: Array[String] = ["1", "2", "4", "8", "16", "32"]
const DEFAULT_PEN_IDX := 1
const DEFAULT_FPS := 60
const MAX_FPS := 120

# 24 elements as 6x4 rather than 8x3: the taller block is squarer, and
# it keeps the whole toolbar inside a 1280px window.
const SWATCH_COLUMNS := 6
const SWATCH_WIDTH := 86

var _fps_value: Label
var _speed_value: Label
var _element_buttons := {}


func _ready() -> void:
	UITheme.style_panel(self)

	var root := MarginContainer.new()
	root.add_theme_constant_override("margin_left", 14)
	root.add_theme_constant_override("margin_right", 14)
	root.add_theme_constant_override("margin_top", 10)
	root.add_theme_constant_override("margin_bottom", 10)
	add_child(root)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	root.add_child(row)

	row.add_child(_section("Elements", _build_element_grid()))
	row.add_child(UITheme.divider())
	row.add_child(_section("Brush", _build_brush_controls()))
	row.add_child(UITheme.divider())
	row.add_child(_section("Simulation", _build_sim_controls()))
	row.add_child(UITheme.divider())
	row.add_child(_section("Spigots", _build_spigot_controls()))
	row.add_child(UITheme.divider())
	row.add_child(_section("Canvas", _build_actions()))


func set_fps_text(fps: int) -> void:
	if not _fps_value:
		return
	_fps_value.text = "%d fps" % fps
	# Amber while keeping up, dimmed once the sim falls behind the
	# requested rate.
	_fps_value.add_theme_color_override("font_color",
		UITheme.ACCENT if fps >= 55 else UITheme.TEXT_DIM)


# A captioned column: heading above, content below.
func _section(title: String, content: Control) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 7)
	# Hug the top: without this the row's spare height stretches the
	# controls inside each section.
	col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	col.add_child(UITheme.caption(title))
	col.add_child(content)
	return col


func _build_element_grid() -> Control:
	var grid := GridContainer.new()
	grid.columns = SWATCH_COLUMNS
	grid.add_theme_constant_override("h_separation", 3)
	grid.add_theme_constant_override("v_separation", 3)

	var group := ButtonGroup.new()
	for elem in Elements.MENU_ITEMS:
		var colour: Color = Elements.menu_color(elem)
		var btn := Button.new()
		btn.text = Elements.MENU_NAMES[elem]
		btn.toggle_mode = true
		btn.button_group = group
		btn.icon = UITheme.dot(colour, 9)
		btn.custom_minimum_size = Vector2(SWATCH_WIDTH, 0)
		UITheme.style_swatch(btn, colour)
		var e := elem
		btn.pressed.connect(func() -> void: element_selected.emit(e))
		grid.add_child(btn)
		_element_buttons[elem] = btn

	_element_buttons[Elements.WALL].button_pressed = true
	return grid


func _build_brush_controls() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)

	# Pen size as a segmented control rather than a dropdown: all the
	# options are visible and one click wide.
	var sizes := HBoxContainer.new()
	sizes.add_theme_constant_override("separation", 3)
	var group := ButtonGroup.new()
	for i in PEN_SIZES.size():
		var b := Button.new()
		b.text = PEN_SIZE_LABELS[i]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(26, 0)
		UITheme.style_button(b, UITheme.ACCENT, 10)
		var idx := i
		b.pressed.connect(func() -> void:
			pen_size_changed.emit(PEN_SIZES[idx] / 2))
		sizes.add_child(b)
		if i == DEFAULT_PEN_IDX:
			b.button_pressed = true
	col.add_child(sizes)

	var overwrite := Button.new()
	overwrite.text = "Overwrite"
	overwrite.toggle_mode = true
	overwrite.button_pressed = true
	UITheme.style_button(overwrite, UITheme.ACCENT, 10)
	overwrite.toggled.connect(func(on: bool) -> void: overwrite_changed.emit(on))
	col.add_child(overwrite)
	return col


func _build_sim_controls() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)

	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = MAX_FPS
	slider.value = DEFAULT_FPS
	slider.step = 1
	slider.custom_minimum_size = Vector2(150, 16)
	UITheme.style_slider(slider)
	slider.value_changed.connect(func(v: float) -> void:
		var val := int(v)
		# Magnetic toward the default, like the original slider.
		if absi(val - DEFAULT_FPS) < 8 and val != DEFAULT_FPS:
			slider.set_value_no_signal(DEFAULT_FPS)
			val = DEFAULT_FPS
		_set_speed_label(val)
		speed_changed.emit(val))
	col.add_child(slider)

	var readout := HBoxContainer.new()
	readout.add_theme_constant_override("separation", 10)

	_speed_value = Label.new()
	_speed_value.add_theme_font_size_override("font_size", 10)
	_speed_value.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	_speed_value.custom_minimum_size = Vector2(78, 0)
	readout.add_child(_speed_value)

	_fps_value = Label.new()
	_fps_value.text = "0 fps"
	_fps_value.add_theme_font_size_override("font_size", 10)
	_fps_value.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	readout.add_child(_fps_value)

	col.add_child(readout)
	_set_speed_label(DEFAULT_FPS)
	return col


func _set_speed_label(fps: int) -> void:
	if not _speed_value:
		return
	_speed_value.text = "paused" if fps == 0 else "target %d" % fps


func _build_spigot_controls() -> Control:
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 5)
	grid.add_theme_constant_override("v_separation", 3)

	for i in Spigots.NUM_SPIGOTS:
		var idx := i

		var swatch := TextureRect.new()
		swatch.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		swatch.custom_minimum_size = Vector2(10, 10)
		swatch.texture = UITheme.dot(
			Elements.menu_color(Elements.SPIGOT_OPTIONS[i]), 9)
		grid.add_child(swatch)

		var type_btn := OptionButton.new()
		for k in Elements.SPIGOT_OPTIONS.size():
			type_btn.add_item(Elements.MENU_NAMES[Elements.SPIGOT_OPTIONS[k]], k)
		type_btn.select(i) # spigot i defaults to option i, as in the original
		type_btn.custom_minimum_size = Vector2(104, 0)
		UITheme.style_option(type_btn)
		type_btn.item_selected.connect(func(opt: int) -> void:
			var elem: int = Elements.SPIGOT_OPTIONS[opt]
			swatch.texture = UITheme.dot(Elements.menu_color(elem), 9)
			spigot_element_changed.emit(idx, elem))
		grid.add_child(type_btn)

		var size_btn := OptionButton.new()
		for k in Spigots.SIZE_OPTIONS.size():
			size_btn.add_item(str(k), k)
		size_btn.select(Spigots.DEFAULT_SIZE_IDX)
		size_btn.custom_minimum_size = Vector2(44, 0)
		UITheme.style_option(size_btn)
		size_btn.item_selected.connect(func(opt: int) -> void:
			spigot_size_changed.emit(idx, Spigots.SIZE_OPTIONS[opt]))
		grid.add_child(size_btn)

		var tag := Label.new()
		tag.text = str(i + 1)
		tag.add_theme_font_size_override("font_size", 9)
		tag.add_theme_color_override("font_color", UITheme.TEXT_FAINT)
		grid.add_child(tag)

	return grid


func _build_actions() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)

	var save := Button.new()
	save.text = "Save"
	UITheme.style_button(save, UITheme.ACCENT, 10)
	save.pressed.connect(func() -> void: save_pressed.emit())
	col.add_child(save)

	var load_btn := Button.new()
	load_btn.text = "Load"
	UITheme.style_button(load_btn, UITheme.ACCENT, 10)
	load_btn.pressed.connect(func() -> void: load_pressed.emit())
	col.add_child(load_btn)

	var clear := Button.new()
	clear.text = "Clear"
	UITheme.style_button(clear, UITheme.DANGER, 10)
	clear.pressed.connect(func() -> void: clear_pressed.emit())
	col.add_child(clear)

	return col
