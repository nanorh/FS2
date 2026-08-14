# GPU orchestration for the falling sand simulation.
#
# Owns the ping-pong R32UI grid textures, the four compute pipelines
# (stamp, reaction, movement, scramble) and the event/command buffers.
# All RenderingDevice work happens on the render thread via
# RenderingServer.call_on_render_thread; results (events, saved state)
# are handed back to the main thread under a mutex.
class_name FallingSand
extends Node

# Grid dimensions in cells. These follow the window: main.gd calls
# resize() whenever the viewport changes. `width`/`height` are the
# main-thread view (updated immediately so brush and particle code sees
# the new bounds); `_gpu_w`/`_gpu_h` are what the textures actually are.
var width := 1280
var height := 720

# Smallest grid we will ever allocate, so a collapsed window can't
# produce a zero-sized texture.
const MIN_DIM := 16

# Element id plus the source bit, skipping the movement pass's moved
# flag. Comparing fill cells through this mask means a source is never
# the same "colour" as loose material of its own element, so fills stop
# at sources instead of quietly wiping them out.
const FILL_MASK := 0b1011_1111

# Cell layout: bits 0-5 element, 6 moved-this-tick, 7 source,
# 8-23 temperature. Temperature is stored unsigned with an offset so it
# can go below zero: stored = celsius + TEMP_OFFSET.
# Temperature is kept in tenths of a degree, since the slow leak toward
# room temperature moves a cell by a fraction of a degree per tick and
# whole degrees would round that away to nothing.
const TEMP_SHIFT := 8
const TEMP_OFFSET := 5000
const AMBIENT_C := 20

# Bits 24-31: pressure, in quarter units offset by 128, so it can be
# negative (suction). Decay is subtractive rather than proportional so a
# value always reaches zero instead of stalling on a rounding boundary,
# the way whole-degree temperature did.
const PRESS_SHIFT := 24
const PRESS_OFFSET := 128

# A completely empty cell at room temperature. Textures are filled with
# this rather than zero, since zero would read as -500 C everywhere.
static func ambient_cell() -> int:
	return ((AMBIENT_C * 10 + TEMP_OFFSET) << TEMP_SHIFT) | (PRESS_OFFSET << PRESS_SHIFT)


# Overlays: 0 materials, 1 temperature, 2 pressure.
var heat_view := false
var pressure_view := false
var velocity_view := false


func view_mode() -> int:
	if velocity_view:
		return 3
	if pressure_view:
		return 2
	return 1 if heat_view else 0

const MAX_COMMANDS := 1024
const CMD_INTS := 8
const MAX_EVENTS := 4096

# Stamp command kinds (must match stamp.glsl)
const CMD_CIRCLE := 0
const CMD_SEGMENT := 1
const CMD_RECT := 2
const CMD_SQUARE := 3
const CMD_SPRAY := 4

# Stamp flags
const FLAG_OVERWRITE := 1
const FLAG_SKIP_WALL := 2
const FLAG_EMITTER := 4
const FLAG_PRESSURE := 8

# Event types (must match reaction.glsl)
const EV_NITRO := 1
const EV_NAPALM := 2
const EV_C4 := 3
const EV_LAVA_SPURT := 4
const EV_METHANE := 5
const EV_TREE := 6
const EV_ROCKET := 7
const EV_GUNPOWDER := 8
const EV_MAGIC1 := 9
const EV_MAGIC2 := 10
const EV_NUKE := 11
const EV_SCRAMBLE := 12

var texture_rd := Texture2DRD.new()

var _rd: RenderingDevice
var _tex: Array[RID] = [RID(), RID()]
# Velocity lives in its own ping-ponged texture: the cell is full, and
# unlike temperature or pressure a velocity needs two components. Packed
# as two int16 in one R32_UINT, in 1/64ths of a cell per tick.
var _vel: Array[RID] = [RID(), RID()]
var _cur := 0

# vx = vy = 0 encoded, as a signed int32 for PackedInt32Array.fill.
const VEL_ZERO := -2147450880 # 0x80008000

var _stamp_shader: RID
var _stamp_pipeline: RID
var _stamp_sets: Array[RID] = [RID(), RID()]

var _reaction_shader: RID
var _reaction_pipeline: RID
var _reaction_sets: Array[RID] = [RID(), RID()]

var _move_shader: RID
var _move_pipeline: RID
var _move_sets: Array[RID] = [RID(), RID()]

var _scramble_shader: RID
var _scramble_pipeline: RID
var _scramble_sets: Array[RID] = [RID(), RID()]

var _display_tex: RID
var _colorize_shader: RID
var _colorize_pipeline: RID
var _colorize_sets: Array[RID] = [RID(), RID()]

var _cmd_buffer: RID
var _event_buffer: RID

# Saved canvas lives in its own GPU texture, so save/load never needs a
# CPU round trip and survives a resize (it is re-anchored on load).
var _save_tex: RID
var _saved_w := 0
var _saved_h := 0

var _gpu_ready := false
var _tick := 0

# Render-thread copy of the grid dimensions.
var _gpu_w := 1280
var _gpu_h := 720

# Main-thread staging for stamp commands.
var _staged_cmds := PackedInt32Array()
var _staged_count := 0

# Events handed back from the render thread.
var _mutex := Mutex.new()
var _pending_events: Array[Vector4i] = []

var _has_saved_state := false

# Boundary behaviour. Off, material that falls off the bottom (or gas
# that rises off the top) is discarded, as in the original. On, the edge
# acts as a solid surface and material collects against it.
var solid_floor := false
var solid_ceiling := false

var _rng := RandomNumberGenerator.new()

# Display textures replaced by a resize. Texture2DRD does not take
# ownership of the RID it is handed, so we free them ourselves - but not
# until the main thread has pointed Texture2DRD at the replacement and
# the canvas renderer has rebuilt any batch that still referenced the
# old one. Each entry is [rid, frames_remaining].
var _retired_displays: Array = []
const DISPLAY_RETIRE_FRAMES := 8


func _ready() -> void:
	_rng.randomize()
	_gpu_w = width
	_gpu_h = height
	RenderingServer.call_on_render_thread(_init_gpu.bind(width, height))


func _exit_tree() -> void:
	# Unbind before teardown so the canvas renderer stops referencing the
	# display texture we are about to free.
	texture_rd.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_free_gpu)


# ------------------------------------------------------------------
# Main-thread API
# ------------------------------------------------------------------

func stamp_circle(elem: int, x: int, y: int, radius: int, overwrite := true,
		skip_wall := false, pressure := false) -> void:
	var f := _flags(overwrite, skip_wall) | (FLAG_PRESSURE if pressure else 0)
	_push_cmd(CMD_CIRCLE, elem, f, x, y, 0, 0, radius)


func stamp_segment(elem: int, x0: int, y0: int, x1: int, y1: int, radius: int,
		overwrite := true, skip_wall := false, pressure := false) -> void:
	var f := _flags(overwrite, skip_wall) | (FLAG_PRESSURE if pressure else 0)
	_push_cmd(CMD_SEGMENT, elem, f, x0, y0, x1, y1, radius)


# Rect covers [x0, x1) x [y0, y1); density is a 0-99 per-cell chance.
func stamp_rect(elem: int, x0: int, y0: int, x1: int, y1: int, density: int, overwrite := true) -> void:
	_push_cmd(CMD_RECT, elem, _flags(overwrite, false), x0, y0, x1, y1, density)


func stamp_cell(elem: int, x: int, y: int, overwrite := true) -> void:
	stamp_rect(elem, x, y, x + 1, y + 1, 100, overwrite)


# A stroke with a selectable profile: CMD_SEGMENT (round), CMD_SQUARE or
# CMD_SPRAY. With `emitter` the stroke lays down fixed sources of the
# material rather than loose material.
func stamp_stroke(elem: int, kind: int, x0: int, y0: int, x1: int, y1: int,
		radius: int, overwrite := true, emitter := false) -> void:
	var f := _flags(overwrite, false) | (FLAG_EMITTER if emitter else 0)
	_push_cmd(kind, elem, f, x0, y0, x1, y1, radius)


# Like stamp_circle, but also drives a pressure spike into the area, so
# an explosion shoves material outward instead of just recolouring it.
func stamp_blast(elem: int, x: int, y: int, radius: int) -> void:
	_push_cmd(CMD_CIRCLE, elem, _flags(true, false) | FLAG_PRESSURE,
		x, y, 0, 0, radius)


# Bucket fill: replaces the connected region of whatever element sits at
# (x, y) with `elem`. Runs on the render thread against a snapshot of the
# grid, so it lands on the next frame.
func flood_fill(x: int, y: int, elem: int) -> void:
	if not _gpu_ready:
		return
	RenderingServer.call_on_render_thread(_gpu_flood_fill.bind(x, y, elem))


# Runs `ticks` simulation steps this frame (0 = just apply stamps).
# `magic_active` mirrors the original's "mystery evaporates while magic
# particles are on screen" check. Returns nothing; events appear via
# take_events() next frame.
func step(ticks: int, magic_active: bool, do_scramble: bool) -> void:
	if not _gpu_ready:
		return
	var cmds := _staged_cmds.duplicate()
	var count := _staged_count
	_staged_cmds.clear()
	_staged_count = 0
	# Snapshot the flags here so the render thread sees a consistent set.
	var flags := (1 if magic_active else 0) \
		| (2 if solid_floor else 0) \
		| (4 if solid_ceiling else 0)
	RenderingServer.call_on_render_thread(
		_gpu_frame.bind(cmds, count, ticks, flags, do_scramble))


func take_events() -> Array[Vector4i]:
	_mutex.lock()
	var ev := _pending_events
	_pending_events = []
	_mutex.unlock()
	return ev


# Binds the display texture once the GPU side is initialized.
func update_display_texture() -> void:
	if not _gpu_ready:
		return
	if texture_rd.texture_rd_rid != _display_tex:
		texture_rd.texture_rd_rid = _display_tex


# Grows or shrinks the grid, keeping the existing contents anchored to
# the bottom-left so that whatever was resting on the floor stays on the
# floor. Growing reveals empty space above and to the right; shrinking
# crops from the top and right.
func resize(new_w: int, new_h: int) -> void:
	new_w = maxi(new_w, MIN_DIM)
	new_h = maxi(new_h, MIN_DIM)
	if new_w == width and new_h == height:
		return
	# Update the main-thread view immediately: brush, particles and
	# spigots all clamp against these before the render thread catches up.
	width = new_w
	height = new_h
	if _gpu_ready:
		RenderingServer.call_on_render_thread(_gpu_resize.bind(new_w, new_h))


func clear_canvas() -> void:
	RenderingServer.call_on_render_thread(_gpu_clear)


func save_canvas() -> void:
	RenderingServer.call_on_render_thread(_gpu_save)


func load_canvas() -> void:
	if _has_saved_state:
		RenderingServer.call_on_render_thread(_gpu_load)


# ------------------------------------------------------------------
# Internals (main thread)
# ------------------------------------------------------------------

func _flags(overwrite: bool, skip_wall: bool) -> int:
	return (FLAG_OVERWRITE if overwrite else 0) | (FLAG_SKIP_WALL if skip_wall else 0)


func _push_cmd(kind: int, elem: int, flags: int, a: int, b: int, c: int, d: int, r: int) -> void:
	if _staged_count >= MAX_COMMANDS:
		return
	_staged_cmds.append_array(PackedInt32Array([kind, elem, flags, a, b, c, d, r]))
	_staged_count += 1


# ------------------------------------------------------------------
# Render-thread side
# ------------------------------------------------------------------

func _init_gpu(w: int, h: int) -> void:
	_rd = RenderingServer.get_rendering_device()

	_stamp_shader = _load_shader("res://src/shaders/stamp.glsl")
	_reaction_shader = _load_shader("res://src/shaders/reaction.glsl")
	_move_shader = _load_shader("res://src/shaders/movement.glsl")
	_scramble_shader = _load_shader("res://src/shaders/scramble.glsl")
	_colorize_shader = _load_shader("res://src/shaders/colorize.glsl")
	_stamp_pipeline = _rd.compute_pipeline_create(_stamp_shader)
	_reaction_pipeline = _rd.compute_pipeline_create(_reaction_shader)
	_move_pipeline = _rd.compute_pipeline_create(_move_shader)
	_scramble_pipeline = _rd.compute_pipeline_create(_scramble_shader)
	_colorize_pipeline = _rd.compute_pipeline_create(_colorize_shader)

	var cmd_bytes := PackedByteArray()
	cmd_bytes.resize(MAX_COMMANDS * CMD_INTS * 4)
	_cmd_buffer = _rd.storage_buffer_create(cmd_bytes.size(), cmd_bytes)

	var ev_bytes := PackedByteArray()
	ev_bytes.resize(16 + MAX_EVENTS * 16)
	ev_bytes.encode_u32(4, MAX_EVENTS) # capacity field
	_event_buffer = _rd.storage_buffer_create(ev_bytes.size(), ev_bytes)

	_create_textures(w, h)
	_create_uniform_sets()
	_gpu_w = w
	_gpu_h = h
	_gpu_ready = true


# Allocates the two ping-pong grid textures plus the RGBA8 display
# texture at the given size. Does not touch uniform sets.
func _create_textures(w: int, h: int) -> void:
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32_UINT
	fmt.width = w
	fmt.height = h
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)
	# Grids start empty but at room temperature, not at zero, which the
	# temperature field would read as -500 C.
	var blank := _blank_grid(w, h)
	for i in 2:
		_tex[i] = _rd.texture_create(fmt, RDTextureView.new(), [blank])

	# Velocity starts at rest. It is transient, so a resize simply
	# clears it rather than blitting the old field across.
	var still := _blank_vel(w, h)
	for i in 2:
		_vel[i] = _rd.texture_create(fmt, RDTextureView.new(), [still])

	# Texture2DRD cannot expose uint formats to the canvas renderer, so
	# the colorize pass writes this RGBA8 copy for display.
	var disp_fmt := RDTextureFormat.new()
	disp_fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	disp_fmt.width = w
	disp_fmt.height = h
	disp_fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	var disp_zeros := PackedByteArray()
	disp_zeros.resize(w * h * 4)
	_display_tex = _rd.texture_create(disp_fmt, RDTextureView.new(), [disp_zeros])


# An empty grid: every cell background at ambient temperature.
func _blank_grid(w: int, h: int) -> PackedByteArray:
	var cells := PackedInt32Array()
	cells.resize(w * h)
	cells.fill(ambient_cell())
	return cells.to_byte_array()


func _blank_vel(w: int, h: int) -> PackedByteArray:
	var cells := PackedInt32Array()
	cells.resize(w * h)
	cells.fill(VEL_ZERO)
	return cells.to_byte_array()


func _create_uniform_sets() -> void:
	for i in 2:
		var img := RDUniform.new()
		img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		img.binding = 0
		img.add_id(_tex[i])

		var cmd_u := RDUniform.new()
		cmd_u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		cmd_u.binding = 1
		cmd_u.add_id(_cmd_buffer)
		_stamp_sets[i] = _rd.uniform_set_create([img, cmd_u], _stamp_shader, 0)

		var vel_img := RDUniform.new()
		vel_img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		vel_img.binding = 1
		vel_img.add_id(_vel[i])
		_move_sets[i] = _rd.uniform_set_create([img, vel_img], _move_shader, 0)
		_scramble_sets[i] = _rd.uniform_set_create([img], _scramble_shader, 0)

		var col_src := RDUniform.new()
		col_src.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		col_src.binding = 0
		col_src.add_id(_tex[i])
		var col_dst := RDUniform.new()
		col_dst.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		col_dst.binding = 1
		col_dst.add_id(_display_tex)
		var col_vel := RDUniform.new()
		col_vel.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		col_vel.binding = 2
		col_vel.add_id(_vel[i])
		_colorize_sets[i] = _rd.uniform_set_create(
			[col_src, col_dst, col_vel], _colorize_shader, 0)

		var src_u := RDUniform.new()
		src_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		src_u.binding = 0
		src_u.add_id(_tex[i])
		var dst_u := RDUniform.new()
		dst_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		dst_u.binding = 1
		dst_u.add_id(_tex[1 - i])
		var ev_u := RDUniform.new()
		ev_u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		ev_u.binding = 2
		ev_u.add_id(_event_buffer)
		var vsrc_u := RDUniform.new()
		vsrc_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		vsrc_u.binding = 3
		vsrc_u.add_id(_vel[i])
		var vdst_u := RDUniform.new()
		vdst_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		vdst_u.binding = 4
		vdst_u.add_id(_vel[1 - i])
		_reaction_sets[i] = _rd.uniform_set_create(
			[src_u, dst_u, ev_u, vsrc_u, vdst_u], _reaction_shader, 0)


func _free_uniform_sets() -> void:
	for sets in [_stamp_sets, _move_sets, _scramble_sets, _colorize_sets, _reaction_sets]:
		for i in 2:
			if sets[i].is_valid():
				_rd.free_rid(sets[i])
			sets[i] = RID()


# Rebuilds the grid at a new size, blitting the old contents across on
# the GPU. Contents are anchored bottom-left: the floor stays the floor.
func _gpu_resize(w: int, h: int) -> void:
	if not _gpu_ready or (w == _gpu_w and h == _gpu_h):
		return

	var old_tex := _tex.duplicate()
	var old_vel := _vel.duplicate()
	var old_cur := _cur
	_retired_displays.append([_display_tex, DISPLAY_RETIRE_FRAMES])

	# Uniform sets reference the old textures, so they must go first.
	_free_uniform_sets()
	_create_textures(w, h)

	var copy_w := mini(_gpu_w, w)
	var copy_h := mini(_gpu_h, h)
	_rd.texture_copy(
		old_tex[old_cur], _tex[0],
		Vector3(0, _gpu_h - copy_h, 0),
		Vector3(0, h - copy_h, 0),
		Vector3(copy_w, copy_h, 1),
		0, 0, 0, 0)
	_cur = 0

	# The grid textures go immediately; the old display texture is
	# retired on a delay (see _retired_displays).
	for rid in [old_tex[0], old_tex[1], old_vel[0], old_vel[1]]:
		if rid.is_valid():
			_rd.free_rid(rid)

	_create_uniform_sets()
	_gpu_w = w
	_gpu_h = h


func _reap_retired_displays() -> void:
	if _retired_displays.is_empty():
		return
	var still_waiting := []
	for entry in _retired_displays:
		entry[1] -= 1
		if entry[1] > 0:
			still_waiting.append(entry)
		elif entry[0].is_valid():
			_rd.free_rid(entry[0])
	_retired_displays = still_waiting


func _load_shader(path: String) -> RID:
	var sf: RDShaderFile = load(path)
	var spirv := sf.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("Compute shader compile error in %s: %s" % [path, spirv.compile_error_compute])
	return _rd.shader_create_from_spirv(spirv)


func _free_gpu() -> void:
	if _rd == null:
		return
	_gpu_ready = false
	_free_uniform_sets()
	var rids := [_stamp_shader, _reaction_shader, _move_shader, _scramble_shader,
		_colorize_shader, _cmd_buffer, _event_buffer, _tex[0], _tex[1],
		_vel[0], _vel[1], _display_tex, _save_tex]
	for entry in _retired_displays:
		rids.append(entry[0])
	_retired_displays.clear()
	for rid in rids:
		if rid.is_valid():
			_rd.free_rid(rid)


func _push_constant_ints(a: int, b: int, c: int, d: int) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(16)
	pc.encode_s32(0, a)
	pc.encode_s32(4, b)
	pc.encode_s32(8, c)
	pc.encode_s32(12, d)
	return pc


func _gpu_frame(cmds: PackedInt32Array, cmd_count: int, ticks: int, flags: int, do_scramble: bool) -> void:
	if not _gpu_ready:
		return

	var groups_x := (_gpu_w + 15) / 16
	var groups_y := (_gpu_h + 15) / 16
	var block_gx := (_gpu_w / 2 + 1 + 15) / 16
	var block_gy := (_gpu_h / 2 + 1 + 15) / 16

	# Upload this frame's stamp commands once (like the original's
	# once-per-animation-frame updateUserStroke()).
	if cmd_count > 0:
		_rd.buffer_update(_cmd_buffer, 0, cmds.size() * 4, cmds.to_byte_array())

	var collected: Array[Vector4i] = []

	if do_scramble:
		_run_scramble(groups_x, groups_y)

	if ticks == 0 and cmd_count > 0:
		# Paused: still apply the user's stroke.
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _stamp_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _stamp_sets[_cur], 0)
		var pc := _push_constant_ints(cmd_count, _tick, 0, 0)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		_rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
		_rd.compute_list_end()

	for t in ticks:
		_tick += 1

		# Zero the event counter.
		var zero := PackedByteArray()
		zero.resize(4)
		_rd.buffer_update(_event_buffer, 0, 4, zero)

		var cl := _rd.compute_list_begin()

		# 1. Stamp pass (first tick of the frame only).
		if t == 0 and cmd_count > 0:
			_rd.compute_list_bind_compute_pipeline(cl, _stamp_pipeline)
			_rd.compute_list_bind_uniform_set(cl, _stamp_sets[_cur], 0)
			var pc0 := _push_constant_ints(cmd_count, _tick, 0, 0)
			_rd.compute_list_set_push_constant(cl, pc0, pc0.size())
			_rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
			_rd.compute_list_add_barrier(cl)

		# 2. Reaction pass: src = _cur, dst = 1 - _cur.
		_rd.compute_list_bind_compute_pipeline(cl, _reaction_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _reaction_sets[_cur], 0)
		var pc1 := _push_constant_ints(_tick, flags, 0, 0)
		_rd.compute_list_set_push_constant(cl, pc1, pc1.size())
		_rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
		_rd.compute_list_add_barrier(cl)
		_cur = 1 - _cur

		# 3. Movement passes. Row parity strictly alternates so that a
		# vacancy opened in one pass can be filled from above in the
		# next, letting solid columns fall coherently (the moved-bit
		# still caps every cell at one move per tick). Column parity is
		# randomized to avoid diagonal bias.
		var base_oy := _rng.randi() & 1
		_rd.compute_list_bind_compute_pipeline(cl, _move_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _move_sets[_cur], 0)
		for pi in 6:
			var off := Vector2i(_rng.randi() & 1, (base_oy + pi) & 1)
			var pc2 := _push_constant_ints(off.x, off.y, _tick, pi)
			_rd.compute_list_set_push_constant(cl, pc2, pc2.size())
			_rd.compute_list_dispatch(cl, block_gx, block_gy, 1)
			_rd.compute_list_add_barrier(cl)

		_rd.compute_list_end()

		# 4. Collect events emitted by the reaction pass.
		var header := _rd.buffer_get_data(_event_buffer, 0, 16)
		var count := mini(header.decode_u32(0), MAX_EVENTS)
		if count > 0:
			var data := _rd.buffer_get_data(_event_buffer, 16, count * 16)
			for i in count:
				var base := i * 16
				collected.append(Vector4i(
					data.decode_u32(base),
					data.decode_u32(base + 4),
					data.decode_u32(base + 8),
					data.decode_u32(base + 12)))

	_reap_retired_displays()
	_run_colorize(groups_x, groups_y, view_mode())

	if collected.size() > 0:
		_mutex.lock()
		_pending_events.append_array(collected)
		_mutex.unlock()


func _run_colorize(groups_x: int, groups_y: int, mode: int) -> void:
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _colorize_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _colorize_sets[_cur], 0)
	var pc := _push_constant_ints(mode, 0, 0, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	_rd.compute_list_end()


func _run_scramble(groups_x: int, groups_y: int) -> void:
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _scramble_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _scramble_sets[_cur], 0)
	# Pre-pass clears fire/mystery, then butterfly swap passes mix the
	# canvas globally.
	var pc := _push_constant_ints(0, _tick, 0, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	_rd.compute_list_add_barrier(cl)
	var total := _gpu_w * _gpu_h
	for i in 14:
		var mask := (_rng.randi() % total)
		if mask == 0:
			mask = 1 << (i % 20)
		var pcs := _push_constant_ints(mask, _tick + i, 1, 0)
		_rd.compute_list_set_push_constant(cl, pcs, pcs.size())
		_rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
		_rd.compute_list_add_barrier(cl)
	_rd.compute_list_end()


# Scanline flood fill. A GPU flood would need one propagation pass per
# cell of travel, so this reads the grid back, fills on the CPU and
# uploads once - a one-off cost on click rather than per frame.
func _gpu_flood_fill(sx: int, sy: int, elem: int) -> void:
	if not _gpu_ready:
		return
	if sx < 0 or sy < 0 or sx >= _gpu_w or sy >= _gpu_h:
		return

	var w := _gpu_w
	var h := _gpu_h
	var cells := _rd.texture_get_data(_tex[_cur], 0).to_int32_array()
	var target := cells[sy * w + sx] & FILL_MASK
	if target == elem:
		return

	# Stack of linear indices; each entry seeds one horizontal run.
	var stack := PackedInt32Array([sy * w + sx])
	while not stack.is_empty():
		var seed := stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		var y := seed / w
		var row := y * w
		if (cells[seed] & 63) != target:
			continue

		# Expand the run to both ends of the contiguous target span.
		var left := seed - row
		while left > 0 and (cells[row + left - 1] & FILL_MASK) == target:
			left -= 1
		var right := seed - row
		while right < w - 1 and (cells[row + right + 1] & FILL_MASK) == target:
			right += 1

		for x in range(left, right + 1):
			cells[row + x] = elem

		# Seed one entry per contiguous run on the rows above and below.
		for ny: int in [y - 1, y + 1]:
			if ny < 0 or ny >= h:
				continue
			var nrow: int = ny * w
			var x := left
			while x <= right:
				if (cells[nrow + x] & FILL_MASK) == target:
					stack.append(nrow + x)
					while x <= right and (cells[nrow + x] & FILL_MASK) == target:
						x += 1
				else:
					x += 1

	_rd.texture_update(_tex[_cur], 0, cells.to_byte_array())


func _gpu_clear() -> void:
	if not _gpu_ready:
		return
	_rd.texture_update(_tex[_cur], 0, _blank_grid(_gpu_w, _gpu_h))
	_rd.texture_update(_vel[_cur], 0, _blank_vel(_gpu_w, _gpu_h))


func _gpu_save() -> void:
	if not _gpu_ready:
		return
	# Keep the snapshot on the GPU: no readback, and it survives a
	# resize because _gpu_load re-anchors it.
	if _save_tex.is_valid():
		_rd.free_rid(_save_tex)
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32_UINT
	fmt.width = _gpu_w
	fmt.height = _gpu_h
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	_save_tex = _rd.texture_create(fmt, RDTextureView.new(), [_blank_grid(_gpu_w, _gpu_h)])
	_rd.texture_copy(
		_tex[_cur], _save_tex,
		Vector3.ZERO, Vector3.ZERO,
		Vector3(_gpu_w, _gpu_h, 1),
		0, 0, 0, 0)
	_saved_w = _gpu_w
	_saved_h = _gpu_h
	_has_saved_state = true


func _gpu_load() -> void:
	if not _gpu_ready or not _save_tex.is_valid():
		return
	# Wipe first: if the snapshot is smaller than the current grid, the
	# uncovered region must not keep whatever is there now.
	_rd.texture_update(_tex[_cur], 0, _blank_grid(_gpu_w, _gpu_h))
	_rd.texture_update(_vel[_cur], 0, _blank_vel(_gpu_w, _gpu_h))

	# Same bottom-left anchoring as a resize.
	var copy_w := mini(_saved_w, _gpu_w)
	var copy_h := mini(_saved_h, _gpu_h)
	_rd.texture_copy(
		_save_tex, _tex[_cur],
		Vector3(0, _saved_h - copy_h, 0),
		Vector3(0, _gpu_h - copy_h, 0),
		Vector3(copy_w, copy_h, 1),
		0, 0, 0, 0)
