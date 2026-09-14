class_name Ball
extends RigidBody3D
## An 8.5-inch rubber dodgeball. Bounces off the floor and walls (physics), passes through
## players physically - hits are resolved by the players when the ball's sensor reaches them.
## Live from the hand until it touches the floor, a wall, or a player; a blocked ball stays live.

signal went_dead(ball: Ball)

const RADIUS := 0.11
const LAYER_WORLD := 1
const LAYER_PLAYERS := 2
const LAYER_BALLS := 4

var live := false
var thrower = null          # Player who threw the live ball
var holder = null           # Player carrying it
var hot := false            # taken from the centre line: must go behind the attack line first
var last_touch_team := -1   # for returning a ball that leaves the court
var throw_dist := 0.0       # how far the target was at release (stats)
var dbg_target_speed := 0.0
var dbg_resolved := false
var manager = null
var _sensor: Area3D
var _mesh: MeshInstance3D
var _mat: StandardMaterial3D
var _touched: Dictionary = {}   # players this flight has already been resolved against
var _launch_grace := 0.0        # ignore the thrower's own body right after release
var _rest_timer := 0.0


func _ready() -> void:
	mass = 0.4
	collision_layer = LAYER_BALLS
	collision_mask = LAYER_WORLD | LAYER_BALLS
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 4
	linear_damp = 0.0
	angular_damp = 0.6
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.55
	pm.friction = 0.7
	physics_material_override = pm
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = RADIUS
	cs.shape = sh
	add_child(cs)

	_mesh = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = RADIUS
	sm.height = RADIUS * 2
	sm.radial_segments = 14
	sm.rings = 7
	_mesh.mesh = sm
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.85, 0.2, 0.55)
	_mat.roughness = 0.75
	_mesh.material_override = _mat
	add_child(_mesh)

	_sensor = Area3D.new()
	_sensor.collision_layer = 0
	_sensor.collision_mask = LAYER_PLAYERS
	_sensor.monitoring = true
	_sensor.monitorable = false
	var scs := CollisionShape3D.new()
	var ssh := SphereShape3D.new()
	ssh.radius = RADIUS + 0.06
	scs.shape = ssh
	_sensor.add_child(scs)
	add_child(_sensor)
	_sensor.body_entered.connect(_on_body_entered)
	body_entered.connect(_on_world_contact)
	_paint()


func _physics_process(delta: float) -> void:
	if _launch_grace > 0.0:
		_launch_grace -= delta
	if holder != null:
		return
	if not live and not freeze and global_position.y < RADIUS + 0.2:
		linear_damp = 0.6  # a dead ball rolls to a stop
	if live and (linear_velocity.length() < 1.5 or global_position.y < RADIUS + 0.05):
		# rolled to a stop / grazing the floor without a contact report: dead
		_rest_timer += delta
		if _rest_timer > 0.05:
			set_dead()
	# a ball that leaves the court (over a sideline or end line) belongs to the side it left from
	if not live and holder == null and manager != null:
		if absf(global_position.z) > Court.HALF_WID + 0.9 or absf(global_position.x) > Court.HALF_LEN + 0.9:
			if linear_velocity.length() < 1.0:
				manager.return_ball(self)


func _on_world_contact(body: Node) -> void:
	if live and body is StaticBody3D:
		set_dead()


func _on_body_entered(body: Node3D) -> void:
	if not live or holder != null:
		return
	if not (body is Player):
		return
	var p: Player = body
	if p == thrower and _launch_grace > 0.0:
		return
	if _touched.has(p):
		return
	if not p.on_court:
		return
	_touched[p] = true
	dbg_resolved = true
	p.ball_arrives(self)


## Thrown: `vel` is the launch velocity. The ball is live until it touches something.
func launch(by, vel: Vector3) -> void:
	holder = null
	thrower = by
	freeze = false
	live = true
	hot = false
	_touched.clear()
	dbg_resolved = false
	_rest_timer = 0.0
	_launch_grace = 0.12
	last_touch_team = by.team
	linear_damp = 0.0
	linear_velocity = vel
	angular_velocity = Vector3(vel.z, 0, -vel.x) * 2.0
	_paint()


## Blocked by a held ball: keeps flying, slower, off to the side, still live (NDL rule).
func deflect(by) -> void:
	var v := linear_velocity
	var away: Vector3 = (global_position - by.global_position)
	away.y = 0.0
	away = away.normalized() if away.length() > 0.01 else -v.normalized()
	linear_velocity = (away * 0.6 + Vector3(0, 0.35, 0) + v.normalized() * -0.2).normalized() * v.length() * 0.45
	_touched.clear()
	_touched[by] = true


func set_dead() -> void:
	if not live:
		return
	if OS.has_environment("DBDEBUG") and thrower != null and not dbg_resolved:
		var tp = thrower.last_target.global_position if thrower.last_target != null else Vector3.ZERO
		print("  miss dist=%.1f tspeed=%.1f ball %s target now %s (%s, %s)" % [throw_dist, dbg_target_speed, global_position, tp, thrower.last_target.action if thrower.last_target != null else "", "out" if thrower.last_target != null and thrower.last_target.out else "in"])
	live = false
	thrower = null
	_paint()
	went_dead.emit(self)


func take(by) -> void:
	holder = by
	live = false
	thrower = null
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_rest_timer = 0.0
	_paint()


func release(at: Vector3, vel: Vector3) -> void:
	holder = null
	freeze = false
	global_position = at
	linear_velocity = vel
	_paint()


func idle() -> bool:
	return holder == null and not live


## Where the ball will be after t seconds if nothing gets in the way.
func predict(t: float) -> Vector3:
	var g := Vector3(0, -9.8, 0)
	return global_position + linear_velocity * t + 0.5 * g * t * t


func _paint() -> void:
	if _mat == null:
		return
	if live:
		_mat.albedo_color = Color(1.0, 0.35, 0.2)
		_mat.emission_enabled = true
		_mat.emission = Color(0.6, 0.15, 0.05)
	elif holder != null:
		_mat.albedo_color = Color(0.85, 0.2, 0.55)
		_mat.emission_enabled = false
	else:
		_mat.albedo_color = Color(0.7, 0.2, 0.45)
		_mat.emission_enabled = false
