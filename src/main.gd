# Game root: wires the sim, display, brush, particles, spigots and menu
# together and drives the fixed-rate tick loop (frameDebt accumulator,
# like game.js mainLoop).
extends Control

const MAX_FRAME_DEBT := 5.0
const MAX_TICKS_PER_FRAME := 5

# Height reserved for the control panel; the grid gets everything above it.
# project.godot's default viewport height is this plus 720, so a fresh
# window still starts at the reference 1280x720 grid.
const MENU_HEIGHT := 96

# Rebuilding the grid textures is not free, so wait for the drag to
# settle rather than reallocating on every resize event.
const RESIZE_SETTLE_SEC := 0.15

var sim: FallingSand
var particles: SandParticles
var spigots: Spigots
var brush: Brush
var menu: SandMenu
var view: TextureRect

var fps_setting := 60
var _frame_debt := 0.0
var _tick_times: Array[float] = []
var _last_fps_update := 0.0

# Test hooks (--screenshot=path, --frames=N, --demo=name via user args)
var _screenshot_path := ""
var _screenshot_frames := 180
var _frame_count := 0
var _test_saveload := false
var _resize_steps: Array[Vector2i] = []
var _fill_at := Vector2i(-1, -1)
var _fill_elem := Elements.WATER

var _resize_timer: Timer


func _ready() -> void:
	var grid := _grid_size_for_window()

	sim = FallingSand.new()
	sim.width = grid.x
	sim.height = grid.y
	add_child(sim)

	particles = SandParticles.new(grid.x, grid.y)
	spigots = Spigots.new(grid.x)

	view = TextureRect.new()
	view.texture = sim.texture_rd
	view.stretch_mode = TextureRect.STRETCH_SCALE
	# Without this the rect's minimum size tracks the texture, so on a
	# shrink it refuses to get smaller than the outgoing texture and the
	# grid renders stretched until the swap catches up.
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(view)

	brush = Brush.new()
	brush.sim = sim
	add_child(brush)

	menu = SandMenu.new()
	add_child(menu)

	# Never let the window get narrow enough to clip the control panel.
	var menu_min := menu.get_combined_minimum_size()
	DisplayServer.window_set_min_size(Vector2i(
		maxi(int(ceil(menu_min.x)), 640),
		MENU_HEIGHT + 160))

	_resize_timer = Timer.new()
	_resize_timer.one_shot = true
	_resize_timer.wait_time = RESIZE_SETTLE_SEC
	_resize_timer.timeout.connect(_apply_grid_resize)
	add_child(_resize_timer)

	get_viewport().size_changed.connect(_on_viewport_resized)
	_layout(grid)

	menu.element_selected.connect(func(e: int) -> void: brush.selected_elem = e)
	menu.pen_size_changed.connect(func(r: int) -> void: brush.pen_radius = r)
	menu.mode_changed.connect(func(m: int) -> void: brush.mode = m)
	menu.overwrite_changed.connect(func(on: bool) -> void: brush.overwrite = on)
	menu.speed_changed.connect(func(fps: int) -> void: fps_setting = fps)
	menu.spigot_element_changed.connect(func(i: int, e: int) -> void: spigots.elements[i] = e)
	menu.spigot_size_changed.connect(func(i: int, s: int) -> void: spigots.sizes[i] = s)
	menu.clear_pressed.connect(_on_clear)
	menu.save_pressed.connect(func() -> void: sim.save_canvas())
	menu.load_pressed.connect(_on_load)

	_parse_test_args()


# The grid fills the window above the control panel, one cell per pixel.
func _grid_size_for_window() -> Vector2i:
	var vp := get_viewport().get_visible_rect().size
	return Vector2i(
		maxi(int(vp.x), FallingSand.MIN_DIM),
		maxi(int(vp.y) - MENU_HEIGHT, FallingSand.MIN_DIM))


func _layout(grid: Vector2i) -> void:
	var vp := get_viewport().get_visible_rect().size
	view.position = Vector2.ZERO
	view.size = Vector2(grid)
	brush.position = Vector2.ZERO
	brush.size = Vector2(grid)
	menu.position = Vector2(0, vp.y - MENU_HEIGHT)
	menu.size = Vector2(vp.x, MENU_HEIGHT)


func _on_viewport_resized() -> void:
	# Keep the panel glued to the bottom edge straight away; defer the
	# expensive grid reallocation until the drag stops.
	var vp := get_viewport().get_visible_rect().size
	menu.position = Vector2(0, vp.y - MENU_HEIGHT)
	menu.size = Vector2(vp.x, MENU_HEIGHT)
	_resize_timer.start()


func _apply_grid_resize() -> void:
	var grid := _grid_size_for_window()
	if grid.x == sim.width and grid.y == sim.height:
		return
	sim.resize(grid.x, grid.y)
	particles.set_size(grid.x, grid.y)
	spigots.set_width(grid.x)
	_layout(grid)


func _on_clear() -> void:
	particles.inactivate_all()
	sim.clear_canvas()


func _on_load() -> void:
	particles.inactivate_all()
	sim.load_canvas()


func _process(delta: float) -> void:
	if fps_setting > 0:
		_frame_debt = minf(_frame_debt + delta * float(fps_setting), MAX_FRAME_DEBT)
	var ticks := mini(int(_frame_debt), MAX_TICKS_PER_FRAME)
	_frame_debt -= float(ticks)

	# Stroke updates every frame regardless of sim speed (like the
	# original's updateUserStroke).
	brush.update_stroke()

	var scramble := false
	if ticks > 0:
		spigots.update(sim)
		var events := sim.take_events()
		scramble = particles.handle_events(events, sim)
		particles.update(sim)

	sim.step(ticks, particles.magic_active(), scramble)
	sim.update_display_texture()

	_update_fps_label(ticks)
	_handle_test_hooks()


func _update_fps_label(ticks: int) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for t in ticks:
		_tick_times.append(now)
	while _tick_times.size() > 0 and _tick_times[0] <= now - 1.0:
		_tick_times.pop_front()
	if now - _last_fps_update > 0.2:
		menu.set_fps_text(_tick_times.size())
		_last_fps_update = now


# ------------------------------------------------------------------
# Automated test support
# ------------------------------------------------------------------

func _parse_test_args() -> void:
	var demo := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshot="):
			_screenshot_path = arg.get_slice("=", 1)
		elif arg.begins_with("--frames="):
			_screenshot_frames = int(arg.get_slice("=", 1))
		elif arg.begins_with("--demo="):
			demo = arg.get_slice("=", 1)
		elif arg == "--test-saveload":
			_test_saveload = true
		elif arg.begins_with("--test-fill="):
			var f := arg.get_slice("=", 1).split(",")
			if f.size() >= 2:
				_fill_at = Vector2i(int(f[0]), int(f[1]))
				_fill_elem = int(f[2]) if f.size() > 2 else Elements.WATER
		elif arg.begins_with("--resize="):
			for spec in arg.get_slice("=", 1).split(","):
				var wh := spec.split("x")
				if wh.size() == 2:
					_resize_steps.append(Vector2i(int(wh[0]), int(wh[1])))
	if demo != "":
		_setup_demo(demo)


func _setup_demo(name: String) -> void:
	var w := sim.width
	var h := sim.height
	match name:
		"sand":
			# Wall shelf with a gap, sand pouring area above it.
			sim.stamp_segment(Elements.WALL, 200, 500, 700, 500, 4)
			sim.stamp_circle(Elements.SAND, 400, 200, 60)
		"liquids":
			# Water, oil and salt water in a wall basin.
			sim.stamp_segment(Elements.WALL, 300, 600, 900, 600, 4)
			sim.stamp_segment(Elements.WALL, 300, 400, 300, 600, 4)
			sim.stamp_segment(Elements.WALL, 900, 400, 900, 600, 4)
			sim.stamp_circle(Elements.WATER, 500, 300, 50)
			sim.stamp_circle(Elements.OIL, 650, 200, 50)
			sim.stamp_circle(Elements.SALT, 780, 250, 30)
		"fire":
			# Plant field ignited from inside, plus an embedded torch.
			sim.stamp_rect(Elements.PLANT, 300, 500, 900, 560, 100)
			sim.stamp_circle(Elements.FIRE, 450, 530, 6)
			sim.stamp_circle(Elements.TORCH, 700, 555, 3)
		"boom":
			# Gunpowder trail into a nitro cache, lit by fire.
			sim.stamp_segment(Elements.WALL, 200, 600, 1000, 600, 4)
			sim.stamp_segment(Elements.GUNPOWDER, 300, 590, 700, 590, 3)
			sim.stamp_circle(Elements.NITRO, 750, 570, 25)
			sim.stamp_circle(Elements.FIRE, 300, 585, 4)
		"tree":
			# Soil bed on a wall with water dripping onto it.
			sim.stamp_segment(Elements.WALL, 300, 600, 900, 600, 6)
			sim.stamp_rect(Elements.SOIL, 320, 560, 880, 598, 100)
			sim.stamp_rect(Elements.WATER, 400, 100, 800, 160, 100)
		"lava":
			sim.stamp_segment(Elements.WALL, 300, 600, 900, 600, 4)
			sim.stamp_segment(Elements.WALL, 300, 450, 300, 600, 4)
			sim.stamp_segment(Elements.WALL, 900, 450, 900, 600, 4)
			sim.stamp_circle(Elements.LAVA, 500, 300, 40)
			sim.stamp_circle(Elements.WATER, 700, 200, 40)
			sim.stamp_circle(Elements.ICE, 400, 550, 30)
		"boom2":
			# C4 block behind a fuse line, napalm pool, methane pocket.
			sim.stamp_segment(Elements.WALL, 100, 600, 1180, 600, 4)
			sim.stamp_segment(Elements.FUSE, 200, 590, 500, 590, 3)
			sim.stamp_rect(Elements.C4, 500, 550, 560, 596, 100)
			sim.stamp_rect(Elements.NAPALM, 700, 570, 820, 596, 100)
			sim.stamp_rect(Elements.METHANE, 950, 500, 1050, 590, 100)
			sim.stamp_circle(Elements.FIRE, 200, 585, 4)
		"magic":
			# Mystery + sand triggers star bursts; mystery + salt spirals.
			sim.stamp_segment(Elements.WALL, 200, 500, 600, 500, 4)
			sim.stamp_rect(Elements.MYSTERY, 300, 470, 340, 496, 100)
			sim.stamp_rect(Elements.SAND, 345, 470, 380, 496, 100)
			sim.stamp_segment(Elements.WALL, 700, 500, 1100, 500, 4)
			sim.stamp_rect(Elements.MYSTERY, 800, 470, 840, 496, 100)
			sim.stamp_rect(Elements.SALT, 845, 470, 880, 496, 100)
		"brushes":
			# Top row: dragged strokes. Bottom row: single dabs.
			sim.stamp_stroke(Elements.WALL, FallingSand.CMD_SEGMENT, 160, 180, 380, 180, 22)
			sim.stamp_stroke(Elements.WALL, FallingSand.CMD_SQUARE, 530, 180, 750, 180, 22)
			sim.stamp_stroke(Elements.WALL, FallingSand.CMD_SPRAY, 900, 180, 1120, 180, 26)
			sim.stamp_stroke(Elements.SAND, FallingSand.CMD_SEGMENT, 250, 420, 250, 420, 26)
			sim.stamp_stroke(Elements.SAND, FallingSand.CMD_SQUARE, 630, 420, 630, 420, 26)
			sim.stamp_stroke(Elements.SAND, FallingSand.CMD_SPRAY, 1010, 420, 1010, 420, 30)
		"fillbox":
			# Closed container: a fill seeded inside must stay inside.
			sim.stamp_stroke(Elements.WALL, FallingSand.CMD_SEGMENT, 300, 260, 900, 260, 4)
			sim.stamp_stroke(Elements.WALL, FallingSand.CMD_SEGMENT, 300, 620, 900, 620, 4)
			sim.stamp_stroke(Elements.WALL, FallingSand.CMD_SEGMENT, 300, 260, 300, 620, 4)
			sim.stamp_stroke(Elements.WALL, FallingSand.CMD_SEGMENT, 900, 260, 900, 620, 4)
			# A divider with no gap: only the left half should fill.
			sim.stamp_stroke(Elements.WALL, FallingSand.CMD_SEGMENT, 600, 260, 600, 620, 4)
		"stress":
			# Worst case: most of the grid full of active liquid and lava.
			sim.stamp_rect(Elements.WATER, 0, 0, w, h * 4 / 10, 100)
			sim.stamp_rect(Elements.OIL, 0, h * 4 / 10, w, h * 6 / 10, 100)
			sim.stamp_rect(Elements.SAND, 0, h * 6 / 10, w, h * 76 / 100, 100)
			sim.stamp_rect(Elements.LAVA, 0, h * 76 / 100, w, h * 9 / 10, 100)


func _handle_test_hooks() -> void:
	if _screenshot_path == "":
		return
	_frame_count += 1
	# Spread the requested resizes evenly through the first half of the run.
	if not _resize_steps.is_empty():
		var stride := maxi(_screenshot_frames / (2 * (_resize_steps.size() + 1)), 1)
		for i in _resize_steps.size():
			if _frame_count == stride * (i + 1):
				DisplayServer.window_set_size(_resize_steps[i])
				print("resize: window -> ", _resize_steps[i], " at frame ", _frame_count)
	if _fill_at.x >= 0 and _frame_count == _screenshot_frames / 3:
		sim.flood_fill(_fill_at.x, _fill_at.y, _fill_elem)
		print("fill: seeded at ", _fill_at, " with element ", _fill_elem)
	if _test_saveload:
		if _frame_count == _screenshot_frames / 4:
			sim.save_canvas()
			print("saveload: saved at frame ", _frame_count)
		elif _frame_count == _screenshot_frames / 2:
			_on_clear()
			print("saveload: cleared at frame ", _frame_count)
		elif _frame_count == _screenshot_frames * 3 / 4:
			_on_load()
			print("saveload: loaded at frame ", _frame_count)
	if _frame_count == _screenshot_frames:
		var img := get_viewport().get_texture().get_image()
		img.save_png(_screenshot_path)
		print("screenshot saved: ", _screenshot_path, " ticks=", sim._tick,
			" grid=", sim.width, "x", sim.height)
		get_tree().quit()
