class_name Player
extends CharacterBody3D
## One dodgeball player: a build (what they are), a personality (how they play) and a small
## utility brain. Everything physical - how fast they run, how hard and straight they throw,
## whether they catch, block or dodge in time - comes from the build through PlayerBuild.stat().

signal threw(player: Player, ball: Ball, target: Player)
signal eliminated(player: Player, by: Player, how: String)
signal caught(player: Player, thrower: Player)
signal blocked(player: Player, thrower: Player)
signal dodged(player: Player, thrower: Player)
signal picked_up(player: Player, ball: Ball)

const DECISION_INTERVAL := 0.12
const PICKUP_RANGE := 0.9
const HOLD_LIMIT := 10.0        # the throw clock
const FOV_COS := -0.09          # ~95 degrees each side of the nose
const HAND_POS := Vector3(0.42, 1.45, -0.3)
const WINDUP := 0.28            # a throw is telegraphed for this long
const THROW_COOLDOWN := 0.6
const VOLLEY_WINDOW := 0.7      # a mate's throw at the same target inside this is a volley
const LAYER_WORLD := 1
const LAYER_PLAYERS := 2

var team := 0
var team_color := Color.RED
var player_name := "p"
var index := 0
var personality: Personality
var build: PlayerBuild
var manager = null
var rng: RandomNumberGenerator

# --- derived from the build (set in apply_build)
var run_speed := 4.8
var throw_speed := 15.0
var aim_err := 4.0        # degrees, one sigma
var lead_skill := 0.5
var catch_skill := 0.5
var block_skill := 0.6
var react_time := 0.28
var dodge_burst := 1.3
var notice_skill := 0.75

# --- state
var on_court := true        # standing in play (not out, not walking in)
var out := false
var inbound := false
var held: Ball = null
var hold_timer := 0.0
var action := "wait"
var target: Player = null
var claim: Ball = null
var rush_ball: Ball = null
var move_dir := Vector3.ZERO
var face_point := Vector3.ZERO
var has_face_point := false
var decide_timer := 0.0
var throw_timer := 0.0
var _windup := 0.0
var _windup_target: Player = null
var _dodge_dir := Vector3.ZERO
var _dodge_timer := 0.0
var _dodge_speed := 0.0         # a sidestep starts from standing and builds
var _noticed: Dictionary = {}   # Ball -> {"t": reaction left, "mode": "catch"/"block"/"dodge", "armed": bool}
var _walk_to := Vector3.ZERO
var _stagger := 0.0
var _wait_z := 0.0
var last_throw_time := -10.0
var last_target: Player = null
var speed_scale := 1.0
var avg_vel := Vector3.ZERO     # smoothed, for throwers leading this player
var dummy := false
# --- flattened: a hit sends the body flying as a ragdoll for a moment before the walk of shame
var ragdoll: Ragdoll = null
var _down_timer := 0.0
const DOWN_TIME := 2.4
# --- celebration (winners): "gather" -> "dance" -> "moon" -> "done"
var celebrating := false
var celeb_spot := Vector3.ZERO
var _celeb_t := 0.0
var _dark_mat: StandardMaterial3D
var _skin_mat: StandardMaterial3D          # aim test: stands still, only reacts to incoming balls

# --- body
var body_root: Node3D
var arm_r: MeshInstance3D
var arm_l: MeshInstance3D
var leg_l: Node3D
var leg_r: Node3D
var label: Label3D
var _mat: StandardMaterial3D
var _gait := 0.0
var _flash_tween: Tween


func _ready() -> void:
	collision_layer = LAYER_PLAYERS
	# players do not body-block each other (a fetcher wedged behind a standing mate stalls the
	# game); the keep-off force in _physics_process spaces them out instead
	collision_mask = LAYER_WORLD
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	if personality == null:
		personality = Personality.preset("Balanced")
	if build == null:
		build = PlayerBuild.preset("Even")
	apply_build()
	decide_timer = rng.randf_range(0.0, DECISION_INTERVAL)
	_wait_z = lerpf(-Court.HALF_WID + 0.9, Court.HALF_WID - 0.9, float(index) / 5.0)
	_build_body()


## Turn the five properties into game numbers. The spans here are the "designed" ranges;
## PlayerBuild.GAINS (calibrated) scales how far a build moves from the middle of each.
func apply_build() -> void:
	run_speed = build.stat("speed", 3.4, 6.6, 2.4, 8.5)
	throw_speed = build.stat("arm", 10.0, 22.0, 7.0, 27.0)
	aim_err = build.stat("aim", 5.0, 0.8, 0.2, 9.0)
	lead_skill = build.stat("aim", 0.35, 1.0, 0.1, 1.0)
	catch_skill = build.stat("hands", 0.15, 0.8, 0.03, 0.97)
	block_skill = build.stat("hands", 0.35, 0.95, 0.1, 0.99)
	react_time = build.stat("dodge", 0.42, 0.13, 0.06, 0.7)
	dodge_burst = build.stat("dodge", 1.0, 1.7, 0.7, 2.3)
	notice_skill = build.stat("dodge", 0.6, 0.95, 0.3, 1.0)


# ---------------------------------------------------------------- body

func _build_body() -> void:
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.32
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0, 0.9, 0)
	add_child(cs)

	body_root = Node3D.new()
	add_child(body_root)
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = team_color
	_mat.roughness = 0.6
	var dark := StandardMaterial3D.new()
	dark.albedo_color = team_color.darkened(0.45)
	dark.roughness = 0.8
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.9, 0.75, 0.6)
	_dark_mat = dark
	_skin_mat = skin

	_mesh_part(_box(Vector3(0.5, 0.62, 0.3)), Vector3(0, 1.12, 0), _mat)
	_mesh_part(_box(Vector3(0.3, 0.3, 0.3)), Vector3(0, 1.66, 0), skin)
	arm_l = _mesh_part(_capsule(0.08, 0.56), Vector3(-0.35, 1.2, 0), dark)
	arm_r = _mesh_part(_capsule(0.08, 0.56), Vector3(0.35, 1.2, 0), dark)
	leg_l = _leg(-0.14, dark)
	leg_r = _leg(0.14, dark)
	# number on the back, eye on the front
	var eye := MeshInstance3D.new()
	eye.mesh = _box(Vector3(0.18, 0.05, 0.03))
	var em := StandardMaterial3D.new()
	em.albedo_color = Color(0.1, 0.1, 0.12)
	eye.material_override = em
	eye.position = Vector3(0, 1.7, -0.16)
	body_root.add_child(eye)

	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 30
	label.pixel_size = 0.008
	label.outline_size = 8
	label.position = Vector3(0, 2.15, 0)
	add_child(label)
	_update_label()


func _mesh_part(mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	body_root.add_child(mi)
	return mi


func _leg(x: float, mat: Material) -> Node3D:
	var piv := Node3D.new()
	piv.position = Vector3(x, 0.8, 0)
	body_root.add_child(piv)
	var mi := MeshInstance3D.new()
	mi.mesh = _capsule(0.1, 0.72)
	mi.material_override = mat
	mi.position = Vector3(0, -0.4, 0)
	piv.add_child(mi)
	return piv


func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


func _capsule(r: float, h: float) -> CapsuleMesh:
	var m := CapsuleMesh.new()
	m.radius = r
	m.height = h
	m.radial_segments = 8
	m.rings = 3
	return m


func _update_label() -> void:
	if label == null:
		return
	label.text = "%s %s" % [player_name, build.label()]
	label.modulate = Color(0.6, 0.6, 0.6) if out else Color.WHITE


func flash(c: Color) -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_mat.albedo_color = c
	_flash_tween = create_tween()
	_flash_tween.tween_property(_mat, "albedo_color", team_color, 0.5)


# ---------------------------------------------------------------- loop

func _physics_process(delta: float) -> void:
	if manager == null or (not manager.running and not manager.celebrating):
		velocity = Vector3.ZERO
		if ragdoll != null:
			_follow_ragdoll()
		_animate(delta)
		return
	if ragdoll != null:
		# flat on the boards: ride the ragdoll until it settles, then get up where it lies
		_down_timer -= delta
		_follow_ragdoll()
		if _down_timer <= 0.0:
			_get_up()
		return
	if _stagger > 0.0:
		_stagger -= delta
	if celebrating:
		_celebrate(delta)
		return
	if out:
		_walk(delta, _walk_to, 0.75)
		_animate(delta)
		return
	if not manager.running:
		velocity = Vector3.ZERO
		_animate(delta)
		return
	if inbound:
		_walk(delta, _walk_to, 1.0)
		if global_position.distance_to(_walk_to) < 0.5:
			inbound = false
			on_court = true
			manager.player_entered(self)
		_animate(delta)
		return

	throw_timer = maxf(throw_timer - delta, 0.0)
	if held != null:
		hold_timer += delta
		held.global_position = to_global(HAND_POS)
	for b in _noticed.keys():
		var n: Dictionary = _noticed[b]
		if not is_instance_valid(b) or not b.live:
			if n.get("armed", false) and n.get("mode", "") == "dodge" and n.get("counted", false) == false:
				dodged.emit(self, n.get("thrower"))
			_noticed.erase(b)
			continue
		if not n.get("armed", false):
			n["t"] = float(n["t"]) - delta
			if float(n["t"]) <= 0.0:
				_react(b, n)

	decide_timer -= delta
	if decide_timer <= 0.0 and not dummy:
		decide_timer = DECISION_INTERVAL
		_decide()
	if dummy and _dodge_timer <= 0.0:
		move_dir = Vector3.ZERO
		if OS.has_environment("DBMOVE"):
			# pace across the court so throwers have to lead
			var z := 2.5 if fmod(manager.elapsed, 3.0) < 1.5 else -2.5
			_go_to(Vector3(_sign() * 4.0, 0, z))
		else:
			_go_to(Vector3(_sign() * 4.0, 0, float(OS.get_environment("DBSIDE")) if OS.has_environment("DBSIDE") else 0.0))

	if _windup > 0.0:
		_windup -= delta
		move_dir = Vector3.ZERO
		if _windup <= 0.0:
			_release()

	# movement
	var v := Vector3.ZERO
	if _dodge_timer > 0.0:
		_dodge_timer -= delta
		# a sidestep from standing: legs have to get going, so the quick-footed gain most
		_dodge_speed = minf(_dodge_speed + 9.0 * dodge_burst * delta, run_speed * 0.85 * dodge_burst)
		v = _dodge_dir * _dodge_speed
	else:
		_dodge_speed = 0.0
		v = move_dir * run_speed * speed_scale
	# keep off teammates
	for m in manager.players:
		if m == self or m.team != team or not m.on_court:
			continue
		var d: Vector3 = global_position - m.global_position
		d.y = 0.0
		var l: float = d.length()
		if l < 0.9 and l > 0.001:
			v += d / l * (0.9 - l) * 4.0
	velocity = v
	move_and_slide()
	avg_vel = avg_vel.lerp(velocity, clampf(delta * 6.0, 0.0, 1.0))
	# stay in your own half, inside the lines; the neutral zone is only for the rush
	var p := global_position
	var pad := 0.3
	p.z = clampf(p.z, -Court.HALF_WID + pad, Court.HALF_WID - pad)
	# the neutral zone may be entered to collect a loose ball (never the far half)
	var edge := Court.NEUTRAL + 0.1
	if rush_ball != null and is_instance_valid(rush_ball) and rush_ball.idle():
		edge = 0.05
	elif claim != null and is_instance_valid(claim) and claim.idle() and absf(claim.global_position.x) < Court.NEUTRAL + 0.3:
		edge = 0.05
	if team == 0:
		p.x = clampf(p.x, -Court.HALF_LEN + pad, -edge)
	else:
		p.x = clampf(p.x, edge, Court.HALF_LEN - pad)
	p.y = 0.0
	global_position = p

	# facing
	if has_face_point:
		_face(face_point, delta)
	elif v.length() > 0.5:
		_face(global_position + v, delta)
	_pickup()
	_animate(delta)


func _walk(delta: float, to: Vector3, scale: float) -> void:
	var d := to - global_position
	d.y = 0.0
	if d.length() > 0.3:
		velocity = d.normalized() * run_speed * scale
		_face(to, delta)
	else:
		velocity = Vector3.ZERO
		_face(Vector3(0, 0, global_position.z), delta)
	move_and_slide()
	global_position.y = 0.0


func _face(point: Vector3, delta: float) -> void:
	var d := point - global_position
	d.y = 0.0
	if d.length_squared() < 0.0001:
		return
	var want := atan2(-d.x, -d.z)
	rotation.y = lerp_angle(rotation.y, want, clampf(delta * 10.0, 0.0, 1.0))


func facing() -> Vector3:
	return -global_transform.basis.z


func can_see(point: Vector3) -> bool:
	var d := point - global_position
	d.y = 0.0
	if d.length_squared() < 0.04:
		return true
	return facing().dot(d.normalized()) > FOV_COS


func _animate(delta: float) -> void:
	var spd := velocity.length()
	if spd > 0.3:
		_gait += delta * spd * 1.8
		leg_l.rotation.x = sin(_gait) * 0.65
		leg_r.rotation.x = -sin(_gait) * 0.65
		arm_l.rotation.x = -sin(_gait) * 0.35
		if _windup <= 0.0:
			arm_r.rotation.x = sin(_gait) * 0.35
	else:
		leg_l.rotation.x = lerpf(leg_l.rotation.x, 0.0, delta * 8.0)
		leg_r.rotation.x = lerpf(leg_r.rotation.x, 0.0, delta * 8.0)
		arm_l.rotation.x = lerpf(arm_l.rotation.x, 0.0, delta * 8.0)
		if _windup <= 0.0:
			arm_r.rotation.x = lerpf(arm_r.rotation.x, (-1.1 if held != null else 0.0), delta * 8.0)
	if _windup > 0.0:
		arm_r.rotation.x = -2.6  # cocked back over the shoulder
	if _stagger > 0.0:
		body_root.rotation.x = -0.5 * clampf(_stagger / 0.4, 0.0, 1.0)
	else:
		body_root.rotation.x = lerpf(body_root.rotation.x, 0.0, delta * 6.0)


# ---------------------------------------------------------------- brain

func _decide() -> void:
	if _windup > 0.0:
		return
	has_face_point = false
	speed_scale = 1.0
	# the throw clock: at 9.5 s you throw whatever you have at whoever is there
	if held != null and hold_timer > HOLD_LIMIT - 0.5 and not held.hot:
		var t := _pick_target()
		if t != null:
			_start_throw(t)
			return
	# an incoming ball we have reacted to takes precedence (the reaction set _dodge_dir etc.)
	if _dodge_timer > 0.0:
		action = "dodge"
		return

	if held != null:
		if held.hot and absf(global_position.x) >= Court.ATTACK:
			held.hot = false  # behind the attack line: it may fly
		if held.hot:
			action = "carry back"
			_go_to(Court.clamp_to_half(Vector3(_sign() * (Court.ATTACK + 0.6), 0, global_position.z), team))
			_look_at_enemies()
			return
		var t := _pick_target()
		if t == null:
			action = "hold"
			_hold_position(_throw_depth())
			return
		target = t
		var q := _shot_quality(t)
		var threshold := 0.45 + 0.45 * personality.get_trait("patience") - 0.25 * personality.get_trait("aggression") \
			- 0.5 * clampf(hold_timer / HOLD_LIMIT, 0.0, 1.0)
		# the accurate throw from range and stay safe; the wild have to walk in close
		var reach := throw_speed * lerpf(0.65, 1.15, clampf(build.skill("aim"), 0.0, 1.0))
		var dist := global_position.distance_to(t.global_position)
		if q > threshold and dist < reach and throw_timer <= 0.0:
			_start_throw(t)
			return
		# not yet: walk to the throwing depth, keep eyes on the target
		action = "advance"
		_hold_position(_throw_depth())
		face_point = t.global_position
		has_face_point = true
		return

	# unarmed
	var b := _best_ball()
	if b != null:
		claim = b
		action = "fetch"
		_go_to(b.global_position)
		# the cautious fetch facing the enemy (slower); the rest turn their back on the game
		var ball_behind := (b.global_position - global_position).dot(_enemy_dir()) < 0.0
		if ball_behind and personality.get_trait("caution") > 0.55:
			_look_at_enemies()
			speed_scale = 0.8
		return
	action = "wait"
	_hold_position(lerpf(3.0, 7.0, personality.get_trait("caution")))
	_look_at_enemies()


func _sign() -> float:
	return -1.0 if team == 0 else 1.0


func _enemy_dir() -> Vector3:
	return Vector3(-_sign(), 0, 0)


func _look_at_enemies() -> void:
	var c := Vector3.ZERO
	var n := 0
	for e in manager.players:
		if e.team != team and e.on_court:
			c += e.global_position
			n += 1
	face_point = c / n if n > 0 else Vector3(-_sign() * 5.0, 0, global_position.z)
	has_face_point = true


## Preferred distance from the neutral zone when armed: the aggressive walk right up.
func _throw_depth() -> float:
	var a := personality.get_trait("aggression")
	var c := personality.get_trait("caution")
	var d := lerpf(0.5, 5.5, clampf((1.0 - a) * 0.65 + c * 0.35, 0.0, 1.0))
	# a poor arm-and-eye has to get closer to hit anything
	return d * lerpf(0.6, 1.1, clampf(build.skill("aim"), 0.0, 1.0))


func _hold_position(depth: float) -> void:
	var x := _sign() * (Court.NEUTRAL + depth)
	_go_to(Vector3(x, 0, _wait_z))


func _go_to(point: Vector3) -> void:
	var d := point - global_position
	d.y = 0.0
	if d.length() < 0.25:
		move_dir = Vector3.ZERO
	else:
		move_dir = d.normalized()


## Nearest idle ball on our side that no mate has claimed (or that we are nearer to).
func _best_ball() -> Ball:
	var best: Ball = null
	var best_cost := INF
	for b in manager.balls:
		if not b.idle():
			continue
		var bp: Vector3 = b.global_position
		var own_side := (bp.x < 0.05) if team == 0 else (bp.x > -0.05)  # the centre-line balls count for both
		if not own_side:
			continue
		if absf(bp.z) > Court.HALF_WID + 0.2 or absf(bp.x) > Court.HALF_LEN + 0.2:
			continue  # outside the lines: it comes back on its own, do not stand at the line waiting
		var cost := global_position.distance_to(bp)
		if b == rush_ball:
			cost -= 3.0
		for m in manager.players:
			if m != self and m.team == team and m.on_court and m.claim == b and m.held == null:
				if m.global_position.distance_to(bp) < cost:
					cost += 6.0
		if cost < best_cost:
			best_cost = cost
			best = b
	return best


func _pickup() -> void:
	if held != null or out or not on_court or dummy:
		return
	for b in manager.balls:
		if not b.idle():
			continue
		if global_position.distance_to(b.global_position) < PICKUP_RANGE * (0.7 + 0.6 * clampf(build.skill("hands"), 0.0, 1.5)):
			var was_rush: bool = (b == rush_ball)
			b.take(self)
			held = b
			hold_timer = 0.0
			# a ball off the centre line must go behind the attack line before it flies
			b.hot = was_rush or absf(b.global_position.x) < Court.ATTACK * 0.6
			claim = null
			if was_rush:
				rush_ball = null
			picked_up.emit(self, b)
			return


## Score every standing enemy and pick the best target.
func _pick_target() -> Player:
	var best: Player = null
	var best_q := -INF
	for e in manager.players:
		if e.team == team or not e.on_court:
			continue
		var q := _shot_quality(e)
		if q > best_q:
			best_q = q
			best = e
	return best


func _shot_quality(e: Player) -> float:
	var dist := global_position.distance_to(e.global_position)
	var q := 0.95 - dist / 10.0
	if e.held == null:
		q += 0.25
	elif e.can_see(global_position):
		q -= 0.15 * e.block_skill  # a ball in hand facing me: a block waiting to happen
	if not e.can_see(global_position):
		q += 0.35  # not looking
	if e.velocity.length() > 2.0:
		q += 0.05
	q += 0.25 * personality.get_trait("bully") * (1.0 - e.build.skill("dodge"))
	q += 0.15 * personality.get_trait("bully") * (1.0 - e.build.skill("hands"))
	# volley: a mate just threw at this one
	var now: float = manager.elapsed
	for m in manager.players:
		if m != self and m.team == team and m.last_target == e and now - m.last_throw_time < VOLLEY_WINDOW:
			q += 0.3 * personality.get_trait("teamwork")
			break
	if e.can_see(global_position) and e.held == null:
		q -= 0.2 * e.build.skill("hands") * e.personality.get_trait("catching")  # the catchers
	return q


func _start_throw(t: Player) -> void:
	action = "throw"
	_windup = WINDUP
	_windup_target = t
	target = t
	move_dir = Vector3.ZERO
	face_point = t.global_position
	has_face_point = true


func _release() -> void:
	var t := _windup_target
	_windup_target = null
	if held == null or t == null or not is_instance_valid(t):
		return
	if not t.on_court:
		t = _pick_target()
		if t == null:
			return
	var b := held
	held = null
	hold_timer = 0.0
	throw_timer = THROW_COOLDOWN
	last_throw_time = manager.elapsed
	last_target = t
	var from := to_global(HAND_POS)
	# aim at the chest, leading a moving target by however much the aim skill allows
	var flight := from.distance_to(t.global_position) / throw_speed
	# the accurate go for the knees: hard to catch, hard to step away from. The rest aim
	# for the chest, the biggest thing there is.
	var aim_y := lerpf(1.05, 0.5, clampf(build.skill("aim"), 0.0, 1.0))
	var aim := t.global_position + Vector3(0, aim_y, 0) + t.avg_vel * flight * lead_skill
	var vel := _ballistic(from, aim, throw_speed)
	# aiming error: a cone around the intended line
	var err := deg_to_rad(aim_err)
	var yaw := rng.randfn(0.0, err)
	var pitch := rng.randfn(0.0, err * 0.7)
	vel = vel.rotated(Vector3.UP, yaw)
	var side := vel.cross(Vector3.UP).normalized()
	if side.length() > 0.5:
		vel = vel.rotated(side, pitch)
	b.release(from, vel)
	b.launch(self, vel)
	b.throw_dist = from.distance_to(t.global_position)
	b.dbg_target_speed = t.avg_vel.length()
	if OS.has_environment("DBDEBUG"):
		print("  throw %s t=%.2f target %s %s avg_vel %s flight %.2f aim %s" % [player_name, manager.elapsed, t.player_name, t.action, t.avg_vel, flight, aim])
	threw.emit(self, b, t)


## Launch velocity of magnitude v from `from` to `to` on the low arc (45 degrees if out of reach).
func _ballistic(from: Vector3, to: Vector3, v: float) -> Vector3:
	var d := to - from
	var h := d.y
	var flat := Vector3(d.x, 0, d.z)
	var D := flat.length()
	var g := 9.8
	var dir := flat.normalized() if D > 0.01 else facing()
	var disc := v * v * v * v - g * (g * D * D + 2.0 * h * v * v)
	var ang := PI * 0.25
	if disc >= 0.0 and D > 0.01:
		ang = atan((v * v - sqrt(disc)) / (g * D))
	return dir * v * cos(ang) + Vector3.UP * v * sin(ang)


# ---------------------------------------------------------------- incoming balls

## Called by the manager each physics frame with every live enemy ball, so players can notice.
func consider(b: Ball) -> void:
	if out or not on_court or _noticed.has(b):
		return
	if b.thrower == null or b.thrower.team == team:
		return
	if not can_see(b.global_position):
		return
	# is it coming at me? time until it reaches my x, and how far it misses by
	var rel := b.global_position - global_position
	var vx := b.linear_velocity.x
	if absf(vx) < 0.5 or (rel.x > 0.0) == (vx > 0.0):
		return  # moving away
	var tti := -rel.x / vx
	if tti > 1.4:
		return
	var at := b.predict(tti)
	var me := global_position + velocity * tti
	var miss := Vector2(at.z - me.z, at.y - 1.0).length()
	if miss > 1.1:
		return
	# everyone who sees the ball tries to get out of its way; what differs is how soon they move.
	# A clean release (the thrower's aim) reads late; sharp eyes (dodge) and caution read it sooner.
	var disguise := 0.3 * clampf(b.thrower.build.skill("aim"), 0.0, 3.1)
	var eyes := clampf(0.6 + 0.4 * notice_skill + 0.15 * personality.get_trait("caution"), 0.6, 1.2)
	var t := react_time * rng.randf_range(0.85, 1.15) * (1.0 + 1.6 * disguise) / eyes
	_noticed[b] = {"t": t, "armed": false, "mode": "", "thrower": b.thrower, "tti": tti, "miss": miss}


func _react(b: Ball, n: Dictionary) -> void:
	n["armed"] = true
	if not b.live:
		return
	if OS.has_environment("DBDEBUG"):
		print("  react %s t=%.2f ball at %s v=%.1f me %s" % [player_name, manager.elapsed, b.global_position, b.linear_velocity.length(), global_position])
	var rel := b.global_position - global_position
	var vx := b.linear_velocity.x
	var tti := -rel.x / vx if absf(vx) > 0.5 else 0.5
	var catching := personality.get_trait("catching")
	var caution := personality.get_trait("caution")
	var ball_speed := b.linear_velocity.length()
	var aligned := facing().dot(-b.linear_velocity.normalized()) > 0.5
	var low := clampf((0.9 - b.predict(tti).y) / 0.5, 0.0, 1.0)  # 1 = at the knees
	if held == null and aligned:
		# go for the catch? the catchers do, and anyone with good hands facing a soft throw
		var want := catching * 0.5 + catch_skill * 0.25 - clampf((ball_speed - 13.0) / 14.0, 0.0, 0.5) - 0.35 * low
		if rng.randf() < want:
			n["mode"] = "catch"
			move_dir = Vector3.ZERO
			face_point = b.global_position
			has_face_point = true
			# square up under the ball
			var at := b.predict(tti)
			_dodge_dir = Vector3(0, 0, at.z - global_position.z).normalized() if absf(at.z - global_position.z) > 0.15 else Vector3.ZERO
			_dodge_timer = minf(tti, 0.35)
			return
	if held != null and aligned:
		var want := 0.35 + 0.45 * block_skill + 0.2 * caution
		if rng.randf() < want:
			n["mode"] = "block"
			move_dir = Vector3.ZERO
			face_point = b.global_position
			has_face_point = true
			_dodge_dir = Vector3.ZERO
			_dodge_timer = minf(tti, 0.3)
			return
	# dodge: step across the ball's line, away from where it is drifting
	n["mode"] = "dodge"
	var at := b.predict(tti)
	var lateral := at.z - global_position.z
	var s := -1.0 if lateral > 0.0 else 1.0
	if absf(lateral) < 0.1:
		s = 1.0 if rng.randf() < 0.5 else -1.0
	# don't dodge into the sideline
	if global_position.z * s > Court.HALF_WID - 1.0:
		s = -s
	_dodge_dir = Vector3(0, 0, s)
	# the cautious also give ground
	if caution > 0.5:
		_dodge_dir += Vector3(_sign() * 0.5 * caution, 0, 0)
		_dodge_dir = _dodge_dir.normalized()
	_dodge_timer = clampf(tti + 0.15, 0.25, 0.8)


## The ball's sensor reached this player. Resolve: catch, block, or out.
func ball_arrives(b: Ball) -> void:
	if out or not on_court:
		return
	var thrower: Player = b.thrower
	if thrower == null or thrower.team == team:
		return
	var n: Dictionary = _noticed.get(b, {})
	var mode: String = n.get("mode", "blind")
	if OS.has_environment("DBDEBUG"):
		print("  arrives %s t=%.2f mode=%s dist=%.1f tspeed=%.1f ball %s me %s" % [player_name, manager.elapsed, mode, b.throw_dist, b.dbg_target_speed, b.global_position, global_position])
	if n.is_empty():
		mode = "blind"
	n["counted"] = true
	var ball_speed := b.linear_velocity.length()
	if mode == "catch" and held == null:
		var low := clampf((0.9 - b.global_position.y) / 0.5, 0.0, 1.0)
		var p := catch_skill * clampf(1.1 - (ball_speed - 10.0) / 18.0, 0.3, 1.0) * (1.0 - 0.4 * low)
		if rng.randf() < p:
			b.take(self)
			held = b
			hold_timer = 0.0
			b.hot = false
			flash(Color(0.3, 1.0, 0.4))
			caught.emit(self, thrower)
			return
		_eliminate(thrower, "dropped catch", b)
		return
	if mode == "block" and held != null:
		var p := block_skill * clampf(1.1 - (ball_speed - 12.0) / 24.0, 0.4, 1.0)
		if rng.randf() < p:
			b.deflect(self)
			flash(Color(0.4, 0.7, 1.0))
			blocked.emit(self, thrower)
			return
		_eliminate(thrower, "dropped block", b)
		return
	if held != null and mode != "block":
		# the ball in hand gets in the way whether you meant it or not: good hands hang on
		if rng.randf() < block_skill * 0.45:
			b.deflect(self)
			flash(Color(0.4, 0.7, 1.0))
			blocked.emit(self, thrower)
			return
	_eliminate(thrower, "hit", b)


func _eliminate(by: Player, how: String, b: Ball) -> void:
	if manager != null and b.throw_dist > 0.0:
		manager.note_hit_distance(b.throw_dist)
	b.set_dead()
	out = true
	on_court = false
	_stagger = 0.4
	_dodge_timer = 0.0
	_windup = 0.0
	move_dir = Vector3.ZERO
	claim = null
	rush_ball = null
	if held != null:
		var hb := held
		held = null
		hb.release(to_global(Vector3(0.3, 0.2, 0.4)), Vector3(_sign() * -1.5, 0.5, 0.0))
		hb.hot = false
	flash(Color(1.0, 0.2, 0.2))
	_update_label()
	if how != "caught":
		_splat(b)
	eliminated.emit(self, by, how)


## The ball lands: a burst of colour where it struck and the body goes flying.
func _splat(b: Ball) -> void:
	var at := b.global_position if is_inside_tree() and b.is_inside_tree() else global_position + Vector3(0, 1.0, 0)
	var vel: Vector3 = b.linear_velocity
	if vel.length() < 1.0:
		vel = -_enemy_dir() * 12.0
	_spawn_ragdoll()
	if ragdoll != null:
		var dir := Vector3(vel.x, 0, vel.z).normalized()
		ragdoll.shove(dir * (28.0 + vel.length() * 1.2) + Vector3(0, 9.0 + rng.randf() * 5.0, 0))
	_down_timer = DOWN_TIME
	_burst(at)


func _burst(at: Vector3) -> void:
	if manager == null or manager.world == null:
		return
	var p := CPUParticles3D.new()
	p.emitting = false
	p.one_shot = true
	p.amount = 40
	p.lifetime = 0.7
	p.explosiveness = 1.0
	p.direction = Vector3(0, 1, 0)
	p.spread = 180.0
	p.initial_velocity_min = 2.5
	p.initial_velocity_max = 7.0
	p.gravity = Vector3(0, -9.8, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	var m := SphereMesh.new()
	m.radius = 0.06
	m.height = 0.12
	m.radial_segments = 6
	m.rings = 3
	p.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.35, 0.2)
	mat.emission_enabled = true
	mat.emission = Color(0.9, 0.25, 0.1)
	p.material_override = mat
	manager.world.add_child(p)
	p.global_position = at
	p.emitting = true
	get_tree().create_timer(1.2).timeout.connect(p.queue_free)


func _spawn_ragdoll() -> void:
	if ragdoll != null or manager == null or manager.world == null:
		return
	ragdoll = Ragdoll.new()
	manager.world.add_child(ragdoll)
	var pose := global_transform
	pose.origin.y = 0.0
	ragdoll.build(pose, _mat, _dark_mat, _skin_mat)
	body_root.visible = false
	label.visible = false


func _follow_ragdoll() -> void:
	if ragdoll == null:
		return
	var p := ragdoll.torso_position()
	global_position = Vector3(clampf(p.x, -Court.HALF_LEN - 1.5, Court.HALF_LEN + 1.5), 0.0, clampf(p.z, -Court.HALF_WID - 1.5, Court.HALF_WID + 1.5))


func _get_up() -> void:
	if ragdoll != null:
		_follow_ragdoll()
		ragdoll.queue_free()
		ragdoll = null
	body_root.visible = true
	body_root.rotation = Vector3.ZERO
	body_root.position = Vector3.ZERO
	label.visible = true
	_stagger = 0.0


# ---------------------------------------------------------------- celebration

## Manager: the game is won; go here and do as the phase says.
func cheer(spot: Vector3) -> void:
	celebrating = true
	celeb_spot = spot
	_celeb_t = rng.randf() * 2.0
	_dodge_timer = 0.0
	_windup = 0.0
	if ragdoll != null:
		_get_up()


func _celebrate(delta: float) -> void:
	var phase: String = manager.celebration_phase
	_celeb_t += delta
	action = phase
	if phase == "gather":
		_walk(delta, celeb_spot, 1.0)
		body_root.rotation = Vector3.ZERO
		body_root.position = Vector3.ZERO
		_animate(delta)
	elif phase == "dance":
		velocity = Vector3.ZERO
		_face(Vector3(-_sign() * 6.0, 0, global_position.z), delta)  # face the losers
		var beat: float = manager.dance_clock
		body_root.rotation.y = sin(beat * 6.0) * 0.55
		body_root.rotation.z = sin(beat * 3.0) * 0.18
		body_root.position.y = absf(sin(beat * 6.0)) * 0.18
		arm_l.rotation.x = -2.6 + sin(beat * 6.0) * 0.5
		arm_r.rotation.x = -2.6 - sin(beat * 6.0) * 0.5
		leg_l.rotation.x = sin(beat * 6.0) * 0.3
		leg_r.rotation.x = -sin(beat * 6.0) * 0.3
	elif phase == "moon":
		# up to the line, backs to the beaten, bend over
		var d := celeb_spot - global_position
		d.y = 0.0
		if d.length() > 0.3:
			_walk(delta, celeb_spot, 1.0)
			body_root.rotation = Vector3.ZERO
			body_root.position = Vector3.ZERO
			_animate(delta)
		else:
			velocity = Vector3.ZERO
			_face(Vector3(_sign() * 20.0, 0, global_position.z), delta)  # back to the enemy half
			body_root.rotation.x = lerpf(body_root.rotation.x, 1.25, delta * 5.0)  # bent double
			body_root.rotation.z = sin(_celeb_t * 9.0) * 0.12                       # a waggle
			body_root.position.y = -0.15
			body_root.position.z = 0.25
			arm_l.rotation.x = 0.4
			arm_r.rotation.x = 0.4
			leg_l.rotation.x = 0.0
			leg_r.rotation.x = 0.0
	else:
		velocity = Vector3.ZERO
		body_root.rotation = Vector3.ZERO
		body_root.position = Vector3.ZERO
		_animate(delta)


## Manager: this player is out, wait here.
func send_to_queue(spot: Vector3) -> void:
	_walk_to = spot


## Manager: a catch brought this player back; walk in from the end line.
func bring_back(spot: Vector3) -> void:
	out = false
	inbound = true
	on_court = false
	hold_timer = 0.0
	held = null
	_noticed.clear()
	_walk_to = spot
	_update_label()


func cleanup() -> void:
	if held != null:
		held.holder = null
		held = null
	if ragdoll != null and is_instance_valid(ragdoll):
		ragdoll.queue_free()
		ragdoll = null
