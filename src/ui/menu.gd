# Bottom control panel: element palette, pen size, overwrite toggle,
# speed slider, spigot configuration, and clear/save/load. Mirrors the
# original menu.js options. Built in code to keep the scene minimal.
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
const PEN_SIZE_LABELS: Array[String] = ["1px", "2px", "4px", "8px", "16px", "32px"]
const DEFAULT_PEN_IDX := 1
const DEFAULT_FPS := 60
const MAX_FPS := 120

var _fps_label: Label
var _element_buttons := {}
var _selected := Elements.WALL


func _ready() -> void:
	# The default panel stylebox is translucent, which lets the
	# simulation show through the controls once the grid reaches the
	# panel's top edge.
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.11, 0.11, 0.12)
	add_theme_stylebox_override("panel", bg)

	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 16)
	add_child(root)

	root.add_child(_build_element_grid())
	root.add_child(_build_draw_controls())
	root.add_child(_build_spigot_controls())
	root.add_child(_build_actions())


func set_fps_text(fps: int) -> void:
	if _fps_label:
		_fps_label.text = "FPS: %d" % fps


func _build_element_grid() -> Control:
	var grid := GridContainer.new()
	grid.columns = 8
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	var group := ButtonGroup.new()
	for elem in Elements.MENU_ITEMS:
		var btn := Button.new()
		btn.text = Elements.MENU_NAMES[elem]
		btn.toggle_mode = true
		btn.button_group = group
		btn.add_theme_font_size_override("font_size", 11)
		btn.add_theme_color_override("font_color", Elements.menu_color(elem))
		btn.add_theme_color_override("font_pressed_color", Color.WHITE)
		btn.add_theme_color_override("font_hover_color", Elements.menu_color(elem).lightened(0.3))
		btn.custom_minimum_size = Vector2(86, 0)
		btn.focus_mode = Control.FOCUS_NONE
		var e := elem
		btn.pressed.connect(func() -> void:
			_selected = e
			element_selected.emit(e))
		grid.add_child(btn)
		_element_buttons[elem] = btn
	_element_buttons[Elements.WALL].button_pressed = true
	return grid


func _build_draw_controls() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var pen_row := HBoxContainer.new()
	var pen_label := Label.new()
	pen_label.text = "Pen:"
	pen_label.add_theme_font_size_override("font_size", 12)
	pen_row.add_child(pen_label)
	var pen := OptionButton.new()
	pen.focus_mode = Control.FOCUS_NONE
	for i in PEN_SIZES.size():
		pen.add_item(PEN_SIZE_LABELS[i], i)
	pen.select(DEFAULT_PEN_IDX)
	pen.item_selected.connect(func(idx: int) -> void:
		pen_size_changed.emit(PEN_SIZES[idx] / 2))
	pen_row.add_child(pen)
	box.add_child(pen_row)

	var ow := CheckBox.new()
	ow.text = "Overwrite"
	ow.button_pressed = true
	ow.focus_mode = Control.FOCUS_NONE
	ow.add_theme_font_size_override("font_size", 12)
	ow.toggled.connect(func(on: bool) -> void: overwrite_changed.emit(on))
	box.add_child(ow)

	var speed_row := HBoxContainer.new()
	var speed_label := Label.new()
	speed_label.text = "Speed:"
	speed_label.add_theme_font_size_override("font_size", 12)
	speed_row.add_child(speed_label)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = MAX_FPS
	slider.value = DEFAULT_FPS
	slider.step = 1
	slider.custom_minimum_size = Vector2(140, 0)
	slider.focus_mode = Control.FOCUS_NONE
	slider.value_changed.connect(func(v: float) -> void:
		# Magnetic toward the default, like the original slider.
		var val := int(v)
		if absi(val - DEFAULT_FPS) < 10 and val != DEFAULT_FPS:
			slider.set_value_no_signal(DEFAULT_FPS)
			val = DEFAULT_FPS
		speed_changed.emit(val))
	speed_row.add_child(slider)
	box.add_child(speed_row)

	_fps_label = Label.new()
	_fps_label.text = "FPS: 0"
	_fps_label.add_theme_font_size_override("font_size", 12)
	box.add_child(_fps_label)
	return box


func _build_spigot_controls() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var title := Label.new()
	title.text = "Spigots"
	title.add_theme_font_size_override("font_size", 12)
	box.add_child(title)
	for i in Spigots.NUM_SPIGOTS:
		var row := HBoxContainer.new()
		var type_btn := OptionButton.new()
		type_btn.focus_mode = Control.FOCUS_NONE
		type_btn.add_theme_font_size_override("font_size", 11)
		for k in Elements.SPIGOT_OPTIONS.size():
			type_btn.add_item(Elements.MENU_NAMES[Elements.SPIGOT_OPTIONS[k]], k)
		type_btn.select(i) # spigot i defaults to option i, like the original
		var idx := i
		type_btn.item_selected.connect(func(opt: int) -> void:
			spigot_element_changed.emit(idx, Elements.SPIGOT_OPTIONS[opt]))
		row.add_child(type_btn)

		var size_btn := OptionButton.new()
		size_btn.focus_mode = Control.FOCUS_NONE
		size_btn.add_theme_font_size_override("font_size", 11)
		for k in Spigots.SIZE_OPTIONS.size():
			size_btn.add_item(str(k), k)
		size_btn.select(Spigots.DEFAULT_SIZE_IDX)
		size_btn.item_selected.connect(func(opt: int) -> void:
			spigot_size_changed.emit(idx, Spigots.SIZE_OPTIONS[opt]))
		row.add_child(size_btn)
		box.add_child(row)
	return box


func _build_actions() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var clear := Button.new()
	clear.text = "Clear"
	clear.focus_mode = Control.FOCUS_NONE
	clear.pressed.connect(func() -> void: clear_pressed.emit())
	box.add_child(clear)
	var save := Button.new()
	save.text = "Save"
	save.focus_mode = Control.FOCUS_NONE
	save.pressed.connect(func() -> void: save_pressed.emit())
	box.add_child(save)
	var load_btn := Button.new()
	load_btn.text = "Load"
	load_btn.focus_mode = Control.FOCUS_NONE
	load_btn.pressed.connect(func() -> void: load_pressed.emit())
	box.add_child(load_btn)
	return box
