# CPU particle pool, ported from Project Sand's particles.js.
# Particles are pure kinematics here: instead of drawing strokes on an
# offscreen canvas, each active particle emits stamp commands into the
# GPU grid every simulation frame. Spawning is driven by events emitted
# by the reaction compute pass.
class_name SandParticles
extends RefCounted

const MAX_PARTICLES := 1000

const P_NITRO := 1
const P_NAPALM := 2
const P_C4 := 3
const P_LAVA := 4
const P_MAGIC1 := 5
const P_MAGIC2 := 6
const P_METHANE := 7
const P_TREE := 8
const P_ROCKET := 9
const P_NUKE := 10

const MAGIC_COLORS: Array[int] = [
	Elements.WALL, Elements.PLANT, Elements.SPOUT,
	Elements.WELL, Elements.WAX, Elements.ICE,
]


class Particle:
	var active := false
	var type := 0
	var x := 0.0
	var y := 0.0
	var init_x := 0.0
	var init_y := 0.0
	var vx := 0.0
	var vy := 0.0
	var init_vy := 0.0
	var y_accel := 0.0
	var size := 0.0
	var iters := 0
	var max_iters := 0
	var color := Elements.FIRE
	var angle := 0.0
	var velocity := 0.0
	# Tree state
	var generation := 1
	var branch_spacing := 0.0
	var max_branches := 0
	var next_branch := 0.0
	var branches := 0
	var tree_type := 0
	# Magic2 state
	var m2_theta := 0.0
	var m2_radius := 0.0
	var m2_spacing := 0.0
	var m2_max_radius := 0.0
	# Rocket state
	var min_y := -1.0

	func set_velocity(vel: float, ang: float) -> void:
		velocity = vel
		angle = ang
		vx = vel * cos(ang)
		vy = vel * sin(ang)


var _pool: Array[Particle] = []
var _counts := {}
var _rng := RandomNumberGenerator.new()
var _w: int
var _h: int


func _init(w: int, h: int) -> void:
	_w = w
	_h = h
	_rng.randomize()
	for i in MAX_PARTICLES:
		_pool.append(Particle.new())


# Bounds follow the window; in-flight particles simply expire against
# the new edges.
func set_size(w: int, h: int) -> void:
	_w = w
	_h = h


func active_count(type: int) -> int:
	return _counts.get(type, 0)


func magic_active() -> bool:
	return active_count(P_MAGIC1) > 0 or active_count(P_MAGIC2) > 0


func inactivate_all() -> void:
	for p in _pool:
		p.active = false
	_counts.clear()


func _alloc(type: int, x: float, y: float) -> Particle:
	for p in _pool:
		if not p.active:
			p.active = true
			p.type = type
			p.x = x
			p.y = y
			p.init_x = x
			p.init_y = y
			p.iters = 0
			_counts[type] = _counts.get(type, 0) + 1
			return p
	return null


func _free_particle(p: Particle) -> void:
	p.active = false
	_counts[p.type] = _counts.get(p.type, 1) - 1


func _off_canvas(p: Particle) -> bool:
	return p.x < 0.0 or p.x > float(_w - 1) or p.y < 0.0 or p.y > float(_h - 1)


func _stroke_radius(size: float) -> int:
	return maxi(1, int(round(size * 0.5)))


# ------------------------------------------------------------------
# Event handling (spawning). Returns true if a canvas scramble was
# requested this frame.
# ------------------------------------------------------------------

func handle_events(events: Array[Vector4i], sim: FallingSand) -> bool:
	var scramble := false
	for ev in events:
		var type := ev.x
		var x := float(ev.y)
		var y := float(ev.z)
		match type:
			FallingSand.EV_NITRO:
				_spawn_nitro(x, y)
			FallingSand.EV_NAPALM:
				if _spawn_napalm(x, y) == null:
					sim.stamp_cell(Elements.FIRE, int(x), int(y))
			FallingSand.EV_C4:
				if _spawn_c4(x, y) == null:
					sim.stamp_cell(Elements.FIRE, int(x), int(y))
			FallingSand.EV_LAVA_SPURT:
				_spawn_lava(x, y)
			FallingSand.EV_METHANE:
				if _spawn_methane(x, y) == null:
					sim.stamp_cell(Elements.FIRE, int(x), int(y))
			FallingSand.EV_TREE:
				_spawn_tree(x, y)
			FallingSand.EV_ROCKET:
				_spawn_rocket(x, y, ev.w)
			FallingSand.EV_GUNPOWDER:
				_handle_gunpowder(x, y, sim)
			FallingSand.EV_MAGIC1:
				_spawn_magic1(x, y, -1)
			FallingSand.EV_MAGIC2:
				_spawn_magic2()
			FallingSand.EV_NUKE:
				_spawn_nuke(x, y)
			FallingSand.EV_SCRAMBLE:
				scramble = true
	return scramble


func _handle_gunpowder(x: float, y: float, sim: FallingSand) -> void:
	# GUNPOWDER_ACTION: rare star-shaped explosion, else 3x3 blast.
	if _rng.randi() % 100 < 1 and _rng.randi() % 100 < 25 \
			and active_count(P_MAGIC1) < 30:
		_spawn_magic1(x, y, Elements.FIRE)
		return
	var burn := _rng.randi() % 100 < 60
	var xi := int(x)
	var yi := int(y)
	if burn:
		# One impulse per explosion, applied here rather than by every
		# detonating cell every tick.
		sim.stamp_rect(Elements.FIRE, xi - 1, yi - 1, xi + 2, yi + 2, 100, true, true)
	else:
		# The grain failed to go off, so put that one grain back. The
		# original paints a 3x3 of fresh powder here, which works when
		# cells detonate one at a time but not when every grain touching
		# the fire goes on the same tick: nine cells created for each one
		# consumed multiplies without bound, and the cloud hangs in the
		# air re-detonating forever instead of falling.
		sim.stamp_cell(Elements.GUNPOWDER, xi, yi)
	if burn and _rng.randi() % 100 < 40:
		# Weaker burn at 2-pixel distance.
		for off in [Vector2i(0, -2), Vector2i(0, 2), Vector2i(-2, 0), Vector2i(2, 0)]:
			if _rng.randi() % 100 < 50:
				sim.stamp_cell(Elements.FIRE, xi + off.x, yi + off.y)


# ------------------------------------------------------------------
# Spawners (ported *_PARTICLE_INIT functions)
# ------------------------------------------------------------------

func _spawn_nitro(x: float, y: float) -> Particle:
	var p := _alloc(P_NITRO, x, y)
	if p == null: return null
	p.color = Elements.FIRE
	p.set_velocity(5.0 + _rng.randf() * 10.0, _rng.randf() * TAU)
	p.size = 2.0 + _rng.randf() * 7.0
	return p


func _spawn_napalm(x: float, y: float) -> Particle:
	var p := _alloc(P_NAPALM, x, y)
	if p == null: return null
	p.color = Elements.FIRE
	p.size = _rng.randf() * 8.0 + 6.0
	p.vx = _rng.randf() * 8.0 - 4.0
	p.vy = -1.0 * (_rng.randf() * 4.0 + 4.0)
	p.max_iters = _rng.randi_range(5, 14)
	return p


func _spawn_c4(x: float, y: float) -> Particle:
	var p := _alloc(P_C4, x, y)
	if p == null: return null
	p.color = Elements.FIRE
	var rand := _rng.randf() * 10000.0
	if rand < 9000.0:
		p.size = _rng.randf() * 10.0 + 3.0
	elif rand < 9500.0:
		p.size = _rng.randf() * 32.0 + 3.0
	elif rand < 9800.0:
		p.size = _rng.randf() * 64.0 + 3.0
	else:
		p.size = _rng.randf() * 128.0 + 3.0
	return p


func _spawn_lava(x: float, y: float) -> Particle:
	var p := _alloc(P_LAVA, x, y)
	if p == null: return null
	p.color = Elements.FIRE
	# Make it harder for the launch angle to be steep.
	var ang := PI / 4.0 + _rng.randf() * PI / 2.0
	if _rng.randi() % 100 < 75 and absf(PI / 2.0 - ang) < PI / 18.0:
		ang += (PI / 18.0) * (1.0 if ang > PI / 2.0 else -1.0)
	p.vx = (1.0 + _rng.randf() * 3.0) * cos(ang)
	p.init_vy = (-4.0 * _rng.randf() - 3.0) * sin(ang)
	p.vy = p.init_vy
	p.y_accel = 0.06
	p.size = 4.0 + _rng.randf() * 3.0
	p.y -= p.size
	p.init_y = p.y
	return p


func _spawn_magic1(x: float, y: float, forced_color: int) -> void:
	# Multi-pronged star: 5-18 spokes sharing one origin and color.
	var color := forced_color
	if color < 0:
		color = MAGIC_COLORS[_rng.randi() % MAGIC_COLORS.size()]
	var num_spokes := 5 + int(round(_rng.randf() * 13.0))
	var velocity := 7.0 + _rng.randf() * 3.0
	var spoke_size := 4.0 + _rng.randf() * 4.0
	var angle_step := TAU / float(num_spokes)
	for i in num_spokes:
		var p := _alloc(P_MAGIC1, x, y)
		if p == null: break
		p.color = color
		p.size = spoke_size
		p.set_velocity(velocity, angle_step * float(i))


func _spawn_magic2() -> Particle:
	var p := _alloc(P_MAGIC2, float(_w) / 2.0, float(_h) / 2.0)
	if p == null: return null
	p.color = MAGIC_COLORS[_rng.randi() % MAGIC_COLORS.size()]
	p.size = 4.0 + _rng.randf() * 8.0
	p.m2_theta = 0.0
	p.m2_spacing = 25.0 + _rng.randf() * 55.0
	p.m2_radius = p.m2_spacing
	p.m2_max_radius = sqrt(float(_w * _w + _h * _h)) / 2.0 + p.size
	return p


func _spawn_methane(x: float, y: float) -> Particle:
	var p := _alloc(P_METHANE, x, y)
	if p == null: return null
	p.color = Elements.FIRE
	p.size = 10.0 + _rng.randf() * 10.0
	return p


func _spawn_tree(x: float, y: float) -> Particle:
	var p := _alloc(P_TREE, x, y)
	if p == null: return null
	p.color = Elements.BRANCH
	p.size = 3.0 if _rng.randi() % 100 < 50 else 4.0
	var velocity := 1.0 + _rng.randf() * 0.5
	var ang := -1.0 * (PI / 2.0 + PI / 8.0 - _rng.randf() * PI / 4.0)
	p.set_velocity(velocity, ang)
	p.generation = 1
	p.branch_spacing = 15.0 + round(_rng.randf() * 45.0)
	p.max_branches = 1 + int(round(_rng.randf() * 2.0))
	p.next_branch = p.branch_spacing
	p.branches = 0
	p.tree_type = 0 if _rng.randi() % 100 < 62 else 1
	return p


func _spawn_rocket(x: float, y: float, aux: int) -> Particle:
	var p := _alloc(P_ROCKET, x, y)
	if p == null: return null
	p.color = Elements.FIRE
	p.size = 4.0
	p.vx = 0.0
	p.vy = -100.0
	p.min_y = float(aux - 1) if aux > 0 else -1.0
	return p


func _spawn_nuke(x: float, y: float) -> Particle:
	var p := _alloc(P_NUKE, x, y)
	if p == null: return null
	p.color = Elements.FIRE
	var max_dim := float(maxi(_w, _h))
	p.size = max_dim / 4.0 + _rng.randf() * max_dim / 8.0
	return p


# ------------------------------------------------------------------
# Per-frame update (ported *_PARTICLE_ACTION functions)
# ------------------------------------------------------------------

func update(sim: FallingSand) -> void:
	for p in _pool:
		if not p.active:
			continue
		p.iters += 1
		match p.type:
			P_NITRO: _act_nitro(p, sim)
			P_NAPALM: _act_napalm(p, sim)
			P_C4: _act_c4(p, sim)
			P_LAVA: _act_lava(p, sim)
			P_MAGIC1: _act_magic1(p, sim)
			P_MAGIC2: _act_magic2(p, sim)
			P_METHANE: _act_methane(p, sim)
			P_TREE: _act_tree(p, sim)
			P_ROCKET: _act_rocket(p, sim)
			P_NUKE: _act_nuke(p, sim)


func _act_nitro(p: Particle, sim: FallingSand) -> void:
	var x0 := p.x
	var y0 := p.y
	p.x += p.vx
	p.y += p.vy
	# Nitro streaks carry the blast front with them.
	sim.stamp_segment(p.color, int(x0), int(y0), int(p.x), int(p.y),
		_stroke_radius(p.size), true, false, true)
	if p.iters % 5 == 0:
		p.size /= 1.3
	if p.iters % 15 == 0:
		p.vy += 10.0 * float(p.iters) / 5.0
	if p.size < 1.75 or _off_canvas(p):
		_free_particle(p)


func _act_napalm(p: Particle, sim: FallingSand) -> void:
	sim.stamp_circle(p.color, int(p.x), int(p.y), int(p.size), true, false, true)
	p.x += p.vx
	p.y += p.vy
	p.size *= 1.0 + _rng.randf() * 0.1
	if p.iters > p.max_iters:
		_free_particle(p)


func _act_c4(p: Particle, sim: FallingSand) -> void:
	sim.stamp_blast(p.color, int(p.x), int(p.y), int(p.size))
	if p.iters % 3 == 0:
		p.size /= 3.0
		if p.size <= 1.0:
			_free_particle(p)


func _act_lava(p: Particle, sim: FallingSand) -> void:
	var x0 := p.x
	var y0 := p.y
	p.x += p.vx
	p.y = p.init_y + p.init_vy * float(p.iters) \
		+ p.y_accel * float(p.iters) * float(p.iters) / 2.0
	sim.stamp_segment(p.color, int(x0), int(y0), int(p.x), int(p.y), _stroke_radius(p.size))
	if p.x < 0.0 or p.x > float(_w - 1) or p.y > float(_h - 1):
		_free_particle(p)


func _act_magic1(p: Particle, sim: FallingSand) -> void:
	var x0 := p.x
	var y0 := p.y
	p.x += p.vx
	p.y += p.vy
	sim.stamp_segment(p.color, int(x0), int(y0), int(p.x), int(p.y), _stroke_radius(p.size))
	if _off_canvas(p):
		_free_particle(p)


func _act_magic2(p: Particle, sim: FallingSand) -> void:
	var x0 := p.x
	var y0 := p.y
	p.m2_theta += 20.0 / p.m2_radius
	p.m2_radius = (p.m2_theta / TAU) * p.m2_spacing
	p.x = p.m2_radius * cos(p.m2_theta) + p.init_x
	p.y = p.m2_radius * sin(p.m2_theta) + p.init_y
	sim.stamp_segment(p.color, int(x0), int(y0), int(p.x), int(p.y), _stroke_radius(p.size))
	if p.m2_radius > p.m2_max_radius:
		_free_particle(p)


func _act_methane(p: Particle, sim: FallingSand) -> void:
	sim.stamp_circle(p.color, int(p.x), int(p.y), int(p.size), true, false, true)
	if p.iters > 2:
		_free_particle(p)


func _act_tree(p: Particle, sim: FallingSand) -> void:
	var x0 := p.x
	var y0 := p.y
	p.x += p.vx
	p.y += p.vy
	# Trees never overwrite walls (approximation of the original's
	# stop-at-wall check).
	sim.stamp_segment(p.color, int(x0), int(y0), int(p.x), int(p.y),
		_stroke_radius(p.size), true, true)
	if _off_canvas(p):
		_free_particle(p)
		return

	if float(p.iters) >= p.next_branch:
		p.branches += 1
		if p.max_branches == 0:
			_free_particle(p)
			return
		var leaf_branch := p.color == Elements.LEAF or p.branches == p.max_branches
		var branch_angles := _tree_branch_angles(p)
		for ang in branch_angles:
			var b := _alloc(P_TREE, p.x, p.y)
			if b == null: break
			b.generation = p.generation + 1
			b.max_branches = maxi(0, p.max_branches - 1)
			b.branch_spacing = p.branch_spacing * _tree_spacing_factor(p)
			b.next_branch = b.branch_spacing
			b.branches = 0
			b.tree_type = p.tree_type
			b.size = maxf(p.size - 1.0, 2.0)
			b.color = Elements.LEAF if leaf_branch else Elements.BRANCH
			b.set_velocity(p.velocity, ang)
		if p.branches >= p.max_branches:
			_free_particle(p)
			return
		if p.branch_spacing > 45.0:
			p.branch_spacing *= 0.8
		p.next_branch = float(p.iters) + p.branch_spacing * (_rng.randf() * 0.35 + 0.65)


func _tree_branch_angles(p: Particle) -> Array[float]:
	if p.tree_type == 0:
		# Tree0: standard fork.
		var branch_angle := PI / 8.0 + _rng.randf() * PI / 4.0
		return [p.angle + branch_angle, p.angle - branch_angle]
	# Tree2: lots of shallow-angle branching.
	var ba := _rng.randf() * PI / 16.0 + PI / 8.0
	return [p.angle, p.angle + ba, p.angle - ba]


func _tree_spacing_factor(p: Particle) -> float:
	return 0.9 if p.tree_type == 0 else 0.6


func _act_rocket(p: Particle, sim: FallingSand) -> void:
	var y0 := p.y
	p.y = maxf(p.min_y, p.y + p.vy)
	sim.stamp_segment(p.color, int(p.x), int(y0), int(p.x), int(p.y), int(p.size / 2.0))
	if p.y <= p.min_y or _off_canvas(p):
		_free_particle(p)


func _act_nuke(p: Particle, sim: FallingSand) -> void:
	sim.stamp_blast(p.color, int(p.x), int(p.y), int(p.size))
	if p.iters > 4:
		_free_particle(p)
