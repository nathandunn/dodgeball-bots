class_name Court
extends Node3D
## A regulation 60 x 30 ft court (18.3 x 9.1 m) built in code: centre line, a 4 ft neutral
## zone, attack lines 10 ft from centre, end lines, and a low wall a couple of metres outside
## the sidelines so balls stop. Red plays x < 0, Blue x > 0.

const HALF_LEN := 9.15      # centre line to end line (30 ft)
const HALF_WID := 4.57      # centre to sideline (15 ft)
const NEUTRAL := 0.61       # half the neutral zone (4 ft wide)
const ATTACK := 3.05        # attack line, from centre (10 ft)
const MARGIN := 2.2         # out-of-bounds strip inside the walls
const QUEUE_Z := HALF_WID + 1.3  # where the eliminated wait, along the far sideline
const WALL_H := 3.5

const LINE_COL := Color(0.92, 0.92, 0.88)


func _ready() -> void:
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.72, 0.52, 0.32)  # gym boards
	floor_mat.roughness = 0.9
	_static_box(Vector3(0, -0.5, 0), Vector3((HALF_LEN + MARGIN) * 2 + 1, 1.0, (HALF_WID + MARGIN) * 2 + 1), floor_mat)

	# the halves get a faint tint each so the sides read from any camera angle
	for t in 2:
		var tint := StandardMaterial3D.new()
		tint.albedo_color = Color(0.78, 0.5, 0.42) if t == 0 else Color(0.5, 0.58, 0.8)
		tint.albedo_color.a = 0.35
		tint.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var m := MeshInstance3D.new()
		m.mesh = _box_mesh(Vector3(HALF_LEN - NEUTRAL, 0.01, HALF_WID * 2))
		m.material_override = tint
		var cx := (NEUTRAL + HALF_LEN) * 0.5
		m.position = Vector3(-cx if t == 0 else cx, 0.004, 0)
		add_child(m)

	# lines
	_line(Vector3(0, 0.012, 0), Vector3(0.08, 0.01, HALF_WID * 2))                  # centre
	_line(Vector3(-NEUTRAL, 0.012, 0), Vector3(0.05, 0.01, HALF_WID * 2))           # neutral zone
	_line(Vector3(NEUTRAL, 0.012, 0), Vector3(0.05, 0.01, HALF_WID * 2))
	_line(Vector3(-ATTACK, 0.012, 0), Vector3(0.06, 0.01, HALF_WID * 2))            # attack lines
	_line(Vector3(ATTACK, 0.012, 0), Vector3(0.06, 0.01, HALF_WID * 2))
	_line(Vector3(-HALF_LEN, 0.012, 0), Vector3(0.08, 0.01, HALF_WID * 2))          # end lines
	_line(Vector3(HALF_LEN, 0.012, 0), Vector3(0.08, 0.01, HALF_WID * 2))
	_line(Vector3(0, 0.012, -HALF_WID), Vector3(HALF_LEN * 2, 0.01, 0.08))          # sidelines
	_line(Vector3(0, 0.012, HALF_WID), Vector3(HALF_LEN * 2, 0.01, 0.08))
	# queue boxes on the far sideline
	for t in 2:
		var qx := -HALF_LEN * 0.5 if t == 0 else HALF_LEN * 0.5
		var qm := StandardMaterial3D.new()
		qm.albedo_color = Color(0.4, 0.38, 0.36)
		var q := MeshInstance3D.new()
		q.mesh = _box_mesh(Vector3(HALF_LEN - 1.0, 0.008, 1.2))
		q.material_override = qm
		q.position = Vector3(qx, 0.003, QUEUE_Z)
		add_child(q)

	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.25, 0.27, 0.32)
	var t := 0.4
	var lx := HALF_LEN + MARGIN
	var lz := HALF_WID + MARGIN
	_static_box(Vector3(0, WALL_H * 0.5, -lz - t * 0.5), Vector3(lx * 2 + t * 2, WALL_H, t), wall_mat)
	_static_box(Vector3(0, WALL_H * 0.5, lz + t * 0.5), Vector3(lx * 2 + t * 2, WALL_H, t), wall_mat)
	_static_box(Vector3(-lx - t * 0.5, WALL_H * 0.5, 0), Vector3(t, WALL_H, lz * 2), wall_mat)
	_static_box(Vector3(lx + t * 0.5, WALL_H * 0.5, 0), Vector3(t, WALL_H, lz * 2), wall_mat)
	# an invisible ceiling keeps lobs in the gym
	var lid := _static_box(Vector3(0, WALL_H + 3.0, 0), Vector3(lx * 2 + 2, 0.2, lz * 2 + 2), wall_mat)
	lid.get_child(1).visible = false


## Which side of the centre line a point is on: 0 red (x<0), 1 blue.
static func side_of(p: Vector3) -> int:
	return 0 if p.x < 0.0 else 1


## Is this point on the court for team t (their half, inside the sidelines, outside the neutral zone)?
static func on_own_court(p: Vector3, t: int) -> bool:
	if absf(p.z) > HALF_WID:
		return false
	var x := -p.x if t == 0 else p.x
	return x > NEUTRAL and x <= HALF_LEN


## Clamp a point into team t's legal playing area, `pad` inside the lines.
static func clamp_to_half(p: Vector3, t: int, pad: float = 0.35) -> Vector3:
	var q := p
	q.z = clampf(q.z, -HALF_WID + pad, HALF_WID - pad)
	if t == 0:
		q.x = clampf(q.x, -HALF_LEN + pad, -NEUTRAL - pad)
	else:
		q.x = clampf(q.x, NEUTRAL + pad, HALF_LEN - pad)
	return q


## Depth into own half from the centre line (0 at the neutral zone edge).
static func depth(p: Vector3, t: int) -> float:
	return (-p.x if t == 0 else p.x) - NEUTRAL


static func queue_spot(t: int, index: int) -> Vector3:
	var x0 := -HALF_LEN + 1.0 if t == 0 else HALF_LEN - 1.0
	var dir := 1.0 if t == 0 else -1.0
	return Vector3(x0 + dir * index * 1.1, 0.0, QUEUE_Z)


static func inbound_spot(t: int, index: int) -> Vector3:
	var x := -HALF_LEN + 0.8 if t == 0 else HALF_LEN - 0.8
	return Vector3(x, 0.0, lerpf(-HALF_WID + 1.0, HALF_WID - 1.0, float(index % 6) / 5.0))


func _line(pos: Vector3, size: Vector3) -> void:
	var m := MeshInstance3D.new()
	m.mesh = _box_mesh(size)
	var lm := StandardMaterial3D.new()
	lm.albedo_color = LINE_COL
	m.material_override = lm
	m.position = pos
	add_child(m)


func _static_box(pos: Vector3, size: Vector3, mat: Material) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.collision_layer = 1
	sb.collision_mask = 0
	sb.position = pos
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	sb.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = _box_mesh(size)
	mi.material_override = mat
	sb.add_child(mi)
	add_child(sb)
	return sb


func _box_mesh(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m
