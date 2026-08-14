# Game root: wires the sim, display, brush, particles and menu together
# and drives the fixed-rate tick loop (frameDebt accumulator, like
# game.js mainLoop).
#
# The four fixed spigots are gone: any flowing material can now be
# painted as a source instead. src/sim/spigots.gd is left in the tree
# unused so the old behaviour can be restored if wanted.
extends Control

const MAX_FRAME_DEBT := 5.0
const MAX_TICKS_PER_FRAME := 5

# Height reserved for the control panel; the grid gets everything above
# it. Measured from the panel's own content rather than hard-coded, so
# editing the toolbar can't silently clip it. The palette's column count
# is fixed, so this does not vary with window width and cannot feed back
# into the grid resize. project.godot's default viewport height is this
# plus 720, so a fresh window starts at the reference 1280x720 grid.
var menu_height := 128

# Rebuilding the grid textures is not free, so wait for the drag to
# settle rather than reallocating on every resize event.
const RESIZE_SETTLE_SEC := 0.15

# Gap between the floating panel and the bottom of the window.
const PANEL_MARGIN := 18

var sim: FallingSand
var particles: SandParticles
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
	# The panel is built first because its measured height determines how
	# much of the window is left for the grid.
	menu = SandMenu.new()
	add_child(menu)
	var menu_min := menu.get_combined_minimum_size()
	menu_height = maxi(int(ceil(menu_min.y)), 80)
	# Keep the window large enough that the floating panel always fits
	# with its margins, and that some canvas remains visible above it.
	DisplayServer.window_set_min_size(Vector2i(
		maxi(int(ceil(menu_min.x)) + PANEL_MARGIN * 2, 640),
		menu_height + PANEL_MARGIN + 200))

	var grid := _grid_size_for_window()

	sim = FallingSand.new()
	sim.width = grid.x
	sim.height = grid.y
	add_child(sim)

	particles = SandParticles.new(grid.x, grid.y)

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

	# The panel was added before the canvas, so lift it back on top.
	menu.move_to_front()

	_resize_timer = Timer.new()
	_resize_timer.one_shot = true
	_resize_timer.wait_time = RESIZE_SETTLE_SEC
	_resize_timer.timeout.connect(_apply_grid_resize)
	add_child(_resize_timer)

	get_viewport().size_changed.connect(_on_viewport_resized)
	_layout(grid)

	menu.layout_changed.connect(_position_menu)
	menu.element_selected.connect(func(e: int) -> void: brush.selected_elem = e)
	menu.emitter_changed.connect(func(on: bool) -> void: brush.emitter = on)
	menu.pen_size_changed.connect(func(r: int) -> void: brush.pen_radius = r)
	menu.mode_changed.connect(func(m: int) -> void: brush.mode = m)
	menu.overwrite_changed.connect(func(on: bool) -> void: brush.overwrite = on)
	menu.speed_changed.connect(func(fps: int) -> void: fps_setting = fps)
	menu.solid_floor_changed.connect(func(on: bool) -> void: sim.solid_floor = on)
	menu.solid_ceiling_changed.connect(func(on: bool) -> void: sim.solid_ceiling = on)
	menu.heat_view_changed.connect(func(on: bool) -> void: sim.heat_view = on)
	menu.clear_pressed.connect(_on_clear)
	menu.save_pressed.connect(func() -> void: sim.save_canvas())
	menu.load_pressed.connect(_on_load)

	_parse_test_args()


# The grid fills the whole window, one cell per pixel. The control panel
# floats over the bottom of it rather than taking a slice out.
func _grid_size_for_window() -> Vector2i:
	var vp := get_viewport().get_visible_rect().size
	return Vector2i(
		maxi(int(vp.x), FallingSand.MIN_DIM),
		maxi(int(vp.y), FallingSand.MIN_DIM))


func _layout(grid: Vector2i) -> void:
	view.position = Vector2.ZERO
	view.size = Vector2(grid)
	brush.position = Vector2.ZERO
	brush.size = Vector2(grid)
	_position_menu()


# Centred horizontally and lifted clear of the bottom edge, so the panel
# reads as floating above the simulation. Once the user has dragged it,
# their placement is kept and only clamped back into view.
func _position_menu() -> void:
	var vp := get_viewport().get_visible_rect().size
	var wanted := menu.get_combined_minimum_size()
	menu.size = wanted
	if menu.user_positioned:
		menu.position = Vector2(
			clampf(menu.position.x, 0.0, maxf(0.0, vp.x - wanted.x)),
			clampf(menu.position.y, 0.0, maxf(0.0, vp.y - wanted.y)))
	else:
		menu.position = Vector2(
			round((vp.x - wanted.x) * 0.5),
			vp.y - wanted.y - PANEL_MARGIN)


func _on_viewport_resized() -> void:
	# Reposition the panel straight away; defer the expensive grid
	# reallocation until the drag stops.
	_position_menu()
	_resize_timer.start()


func _apply_grid_resize() -> void:
	var grid := _grid_size_for_window()
	if grid.x == sim.width and grid.y == sim.height:
		return
	sim.resize(grid.x, grid.y)
	particles.set_size(grid.x, grid.y)
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
		elif arg == "--collapsed":
			menu.set_collapsed(true)
		elif arg.begins_with("--panel-at="):
			# Exercises the same placement path a drag uses.
			var pa := arg.get_slice("=", 1).split(",")
			if pa.size() == 2:
				menu.user_positioned = true
				menu.position = Vector2(int(pa[0]), int(pa[1]))
				_position_menu()
		elif arg == "--heat":
			sim.heat_view = true
		elif arg == "--hide-ui":
			# The panel floats over the bottom of the canvas, so hiding it
			# is the only way to inspect what is happening at the floor.
			menu.visible = false
		elif arg.begins_with("--solid="):
			for part in arg.get_slice("=", 1).split(","):
				if part == "floor":
					sim.solid_floor = true
				elif part == "ceiling":
					sim.solid_ceiling = true
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
		"heat":
			# A lava pool in a basin, an ice block, and water poured on
			# both: conduction should melt the ice and boil the water
			# without any rule naming lava or ice specifically.
			sim.stamp_segment(Elements.WALL, 200, 620, 1100, 620, 5)
			sim.stamp_segment(Elements.WALL, 200, 470, 200, 620, 5)
			sim.stamp_segment(Elements.WALL, 1100, 470, 1100, 620, 5)
			sim.stamp_rect(Elements.LAVA, 210, 560, 520, 616, 100)
			sim.stamp_rect(Elements.ICE, 800, 500, 1000, 616, 100)
			sim.stamp_stroke(Elements.WATER, FallingSand.CMD_SEGMENT,
				650, 120, 650, 120, 6, true, true)
		"c4":
			# Three charges at the scale a player actually paints them,
			# all lit with the default radius-2 brush: dab beside, dab on
			# top, and a charge resting on a wall.
			sim.stamp_segment(Elements.WALL, 150, 600, 1150, 600, 4)
			sim.stamp_circle(Elements.C4, 300, 560, 14)
			sim.stamp_circle(Elements.FIRE, 283, 560, 2)
			sim.stamp_circle(Elements.C4, 640, 560, 14)
			sim.stamp_circle(Elements.FIRE, 640, 560, 2)
			sim.stamp_circle(Elements.C4, 980, 585, 14)
			sim.stamp_circle(Elements.FIRE, 980, 570, 2)
		"sources":
			# Fixed emitters: water, sand, and fire acting as a torch
			# over a plant field. Each should feed continuously without
			# moving or being consumed.
			sim.stamp_stroke(Elements.WATER, FallingSand.CMD_SEGMENT,
				260, 140, 260, 140, 7, true, true)
			sim.stamp_stroke(Elements.SAND, FallingSand.CMD_SEGMENT,
				640, 140, 640, 140, 7, true, true)
			# Fire rises, so the source sits just under the plants.
			sim.stamp_rect(Elements.PLANT, 930, 340, 1120, 424, 100)
			sim.stamp_stroke(Elements.FIRE, FallingSand.CMD_SEGMENT,
				1010, 438, 1010, 438, 5, true, true)
		"bounds":
			# Sand heads for the floor, steam and methane for the ceiling.
			sim.stamp_rect(Elements.SAND, 150, 60, 420, 190, 100)
			sim.stamp_rect(Elements.STEAM, 700, 430, 900, 560, 100)
			sim.stamp_rect(Elements.METHANE, 980, 430, 1150, 560, 100)
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
			" grid=", sim.width, "x", sim.height,
			" solid_floor=", sim.solid_floor, " solid_ceiling=", sim.solid_ceiling)
		get_tree().quit()
