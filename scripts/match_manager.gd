class_name MatchManager
extends Node
## Runs one game of 6-a-side elimination dodgeball: spawns the teams and the six balls on the
## centre line, hands out the opening rush, keeps the out-queues (a catch brings the first one
## back), enforces the possession rule, and keeps the stats.

signal match_started(match_index: int)
signal match_ended(result: Dictionary)

const TEAM_SIZE := 6
const BALLS := 6
const TEAM_NAMES := ["Red", "Blue"]
const TEAM_COLORS := [Color(0.9, 0.3, 0.25), Color(0.25, 0.5, 0.95)]
const RUSHERS := 3               # the fastest three go for the balls, the rest hang back
const BURDEN_BALLS := 4          # holding four of six...
const BURDEN_TIME := 5.0         # ...for this long means you must throw one

var world: Node3D
var court: Court
var team_personalities: Array[Personality] = [Personality.preset("Gunner"), Personality.preset("Tactician")]
var team_preset_names: Array[String] = ["Gunner", "Tactician"]
var team_builds: Array[PlayerBuild] = [PlayerBuild.preset("Even"), PlayerBuild.preset("Even")]
var team_build_names: Array[String] = ["Even", "Even"]
var players: Array[Player] = []
var balls: Array[Ball] = []
var queues: Array = [[], []]     # eliminated players, in order
var time_limit := -1.0           # <= 0: no limit (headless sims are capped)
var elapsed := 0.0
var running := false
var match_index := 0
var stats := {}
var player_stats := {}
var rng := RandomNumberGenerator.new()
var _burden := [0.0, 0.0]


func start_match(seed_value: int = -1) -> void:
	clear()
	if seed_value < 0:
		rng.randomize()
	else:
		rng.seed = seed_value
	match_index += 1
	elapsed = 0.0
	stats = _fresh_stats()
	player_stats = {}
	queues = [[], []]
	_burden = [0.0, 0.0]

	for t in 2:
		for i in TEAM_SIZE:
			var p := Player.new()
			p.team = t
			p.index = i
			p.team_color = TEAM_COLORS[t]
			p.player_name = "%s%d" % [TEAM_NAMES[t][0], i + 1]
			p.personality = team_personalities[t].jittered(rng, 0.08)
			p.build = team_builds[t].jittered(rng, 0.015)
			p.manager = self
			p.rng = RandomNumberGenerator.new()
			p.rng.seed = rng.randi()
			var x := -Court.HALF_LEN + 0.6 if t == 0 else Court.HALF_LEN - 0.6
			var z := lerpf(-Court.HALF_WID + 0.8, Court.HALF_WID - 0.8, float(i) / float(TEAM_SIZE - 1))
			p.position = Vector3(x, 0.0, z)
			p.rotation.y = -PI * 0.5 if t == 0 else PI * 0.5
			p.threw.connect(_on_threw)
			p.eliminated.connect(_on_eliminated)
			p.caught.connect(_on_caught)
			p.blocked.connect(_on_blocked)
			p.dodged.connect(_on_dodged)
			p.picked_up.connect(_on_picked)
			world.add_child(p)
			players.append(p)
			player_stats[p.player_name] = {"name": p.player_name, "team": t, "persona": p.personality.label(),
				"build": p.build.label(), "throws": 0, "hits": 0, "catches": 0, "drops": 0, "blocks": 0,
				"dodges": 0, "outs": 0, "times_out": 0, "pickups": 0, "alive": true}

	# six balls along the centre line; each side rushes the three on its own right
	for k in BALLS:
		var b := Ball.new()
		b.manager = self
		var z := lerpf(-Court.HALF_WID + 0.8, Court.HALF_WID - 0.8, float(k) / float(BALLS - 1))
		b.position = Vector3(0.0, Ball.RADIUS, z)
		world.add_child(b)
		balls.append(b)
	_assign_rush()

	running = true
	match_started.emit(match_index)


## The three fastest on each side sprint for "their" three balls (the right-hand half of the
## line from where they stand); everyone else waits at the attack line for a pass of fortune.
func _assign_rush() -> void:
	for t in 2:
		var side: Array[Player] = []
		for p in players:
			if p.team == t:
				side.append(p)
		side.sort_custom(func(a: Player, b: Player): return a.run_speed > b.run_speed)
		# team 0 faces +x: its right is -z. team 1 faces -x: its right is +z.
		var mine: Array[Ball] = []
		for b in balls:
			if (b.position.z < 0.0) == (t == 0):
				mine.append(b)
		mine.sort_custom(func(a: Ball, b: Ball): return absf(a.position.z) > absf(b.position.z))
		for i in mini(RUSHERS, mine.size()):
			var runner: Player = side[i]
			# hand each runner the ball nearest its lane
			var best: Ball = null
			var best_d := INF
			for b in mine:
				var d := absf(b.position.z - runner.position.z)
				if d < best_d:
					best_d = d
					best = b
			runner.rush_ball = best
			mine.erase(best)


func clear() -> void:
	running = false
	for p in players:
		p.cleanup()
		p.queue_free()
	players.clear()
	for b in balls:
		b.queue_free()
	balls.clear()


func _physics_process(delta: float) -> void:
	if not running:
		return
	elapsed += delta
	# every live enemy ball is something each player might notice
	for b in balls:
		if b.live and b.thrower != null:
			for p in players:
				if p.team != b.thrower.team:
					p.consider(b)
	# possession: a side sitting on four balls must let one go
	for t in 2:
		var n := 0
		var holders: Array[Player] = []
		for p in players:
			if p.team == t and p.held != null and not p.held.hot:
				n += 1
				holders.append(p)
		if n >= BURDEN_BALLS:
			_burden[t] += delta
			if _burden[t] > BURDEN_TIME:
				holders.sort_custom(func(a: Player, b: Player): return a.hold_timer > b.hold_timer)
				holders[0].hold_timer = Player.HOLD_LIMIT  # the clock runs out for the longest holder
				_burden[t] = 0.0
		else:
			_burden[t] = 0.0
	# win?
	var alive := [count_on_court(0), count_on_court(1)]
	var winner := -1
	var reason := ""
	if alive[0] == 0 and alive[1] == 0:
		winner = -1
		reason = "double elimination"
	elif alive[0] == 0:
		winner = 1
		reason = "elimination"
	elif alive[1] == 0:
		winner = 0
		reason = "elimination"
	elif time_limit > 0.0 and elapsed >= time_limit:
		reason = "time"
		if alive[0] != alive[1]:
			winner = 0 if alive[0] > alive[1] else 1
	else:
		return
	_finish(winner, reason)


func count_on_court(t: int) -> int:
	var n := 0
	for p in players:
		if p.team == t and not p.out:
			n += 1
	return n


func balls_held(t: int) -> int:
	var n := 0
	for p in players:
		if p.team == t and p.held != null:
			n += 1
	return n


func balls_on_side(t: int) -> int:
	var n := 0
	for b in balls:
		if b.idle() and ((b.global_position.x < 0.0) == (t == 0)):
			n += 1
	return n


## A ball that rolled out of bounds is put back on the sideline of the side it left from.
func return_ball(b: Ball) -> void:
	var t := 0 if b.global_position.x < 0.0 else 1
	var x := clampf(b.global_position.x, -Court.HALF_LEN + 1.0, Court.HALF_LEN - 1.0)
	if absf(x) < Court.ATTACK:
		x = -Court.ATTACK - 0.5 if t == 0 else Court.ATTACK + 0.5
	var z := signf(b.global_position.z) * (Court.HALF_WID - 0.4) if absf(b.global_position.z) > Court.HALF_WID else b.global_position.z
	b.global_position = Vector3(x, Ball.RADIUS + 0.02, z)
	b.linear_velocity = Vector3.ZERO
	b.angular_velocity = Vector3.ZERO
	b.hot = false


func player_entered(p: Player) -> void:
	pass


func _finish(winner: int, reason: String) -> void:
	running = false
	var res := {
		"match": match_index, "winner": winner, "reason": reason, "duration": elapsed,
		"winner_name": TEAM_NAMES[winner] if winner >= 0 else "Nobody",
		"alive": [count_on_court(0), count_on_court(1)],
		"presets": team_preset_names.duplicate(), "builds": team_build_names.duplicate(),
		"stats": stats.duplicate(true), "players": player_stats.values(),
	}
	match_ended.emit(res)


func _fresh_stats() -> Dictionary:
	return {"throws": [0, 0], "hits": [0, 0], "catches": [0, 0], "drops": [0, 0], "blocks": [0, 0],
		"dodges": [0, 0], "outs": [0, 0], "returns": [0, 0], "pickups": [0, 0], "how": {}, "dist": {}}


# ---------------------------------------------------------------- events

func note_hit_distance(d: float) -> void:
	var k := str(int(d / 3.0) * 3)
	stats["dist"][k][1] = int(stats["dist"][k][1]) + 1


func _on_threw(p: Player, b: Ball, t: Player) -> void:
	var k := str(int(p.global_position.distance_to(t.global_position) / 3.0) * 3)
	if not stats["dist"].has(k):
		stats["dist"][k] = [0, 0]
	stats["dist"][k][0] = int(stats["dist"][k][0]) + 1
	stats["throws"][p.team] += 1
	player_stats[p.player_name]["throws"] += 1


func _on_eliminated(p: Player, by: Player, how: String) -> void:
	stats["outs"][p.team] += 1
	stats["how"][how] = int(stats["how"].get(how, 0)) + 1
	player_stats[p.player_name]["times_out"] += 1
	player_stats[p.player_name]["alive"] = false
	if how == "dropped catch":
		stats["drops"][p.team] += 1
		player_stats[p.player_name]["drops"] += 1
	if by != null:
		stats["hits"][by.team] += 1
		player_stats[by.player_name]["hits"] += 1
		player_stats[by.player_name]["outs"] += 1
	queues[p.team].append(p)
	p.send_to_queue(Court.queue_spot(p.team, queues[p.team].size() - 1))


func _on_caught(p: Player, thrower: Player) -> void:
	stats["catches"][p.team] += 1
	player_stats[p.player_name]["catches"] += 1
	# the thrower is out...
	if thrower != null and thrower.on_court:
		thrower._eliminate(p, "caught", _dummy_ball())
	# ...and the first of ours in the queue comes back
	if queues[p.team].size() > 0:
		var back: Player = queues[p.team].pop_front()
		stats["returns"][p.team] += 1
		player_stats[back.player_name]["alive"] = true
		back.bring_back(Court.inbound_spot(p.team, back.index))
		for i in queues[p.team].size():
			queues[p.team][i].send_to_queue(Court.queue_spot(p.team, i))


var _dummy: Ball = null
func _dummy_ball() -> Ball:
	# Player._eliminate wants a ball to kill; a caught ball is already dead and held, so give it
	# a stand-in that is never on the court
	if _dummy == null:
		_dummy = Ball.new()
		_dummy.live = false
	return _dummy


func _on_blocked(p: Player, _thrower: Player) -> void:
	stats["blocks"][p.team] += 1
	player_stats[p.player_name]["blocks"] += 1


func _on_dodged(p: Player, _thrower: Player) -> void:
	stats["dodges"][p.team] += 1
	player_stats[p.player_name]["dodges"] += 1


func _on_picked(p: Player, _b: Ball) -> void:
	stats["pickups"][p.team] += 1
	player_stats[p.player_name]["pickups"] += 1
