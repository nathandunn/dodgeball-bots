extends Node3D
## Entry point. Builds the court, wires the HUD, runs games; headless batch sim:
##   godot --headless --path . -- --sim=20 [--red=Gunner --blue=Tactician]
##        [--redbuild=Sprinter --bluebuild=0.2,0.2,0.2,0.2,0.2] [--seed=1] [--cap=180]
##        [--gains=speed:1,arm:1,aim:1,hands:1,dodge:1]

var manager: MatchManager
var court: Court
var cam: CameraRig
var hud: Hud
var headless := false
var batch_left := 0
var batch_results: Array[Dictionary] = []
var _restart_timer := -1.0
var _base_seed := -1
var _last_result: Dictionary = {}


func _ready() -> void:
	court = Court.new()
	add_child(court)
	_build_lighting()

	manager = MatchManager.new()
	manager.world = self
	manager.court = court
	manager.match_ended.connect(_on_match_ended)
	manager.dance_started.connect(_on_dance_started)
	manager.celebration_finished.connect(_on_celebration_finished)
	add_child(manager)

	var args := _parse_args(OS.get_cmdline_user_args())
	headless = (DisplayServer.get_name() == "headless" or args.has("sim")) and not args.has("ui")
	if args.has("gains"):
		var g := PlayerBuild.GAINS.duplicate()
		var curve := PlayerBuild.CURVE
		for kv in String(args["gains"]).split(","):
			var pair := kv.split(":")
			if pair.size() == 2:
				if pair[0] == "curve":
					curve = float(pair[1])
				else:
					g[pair[0]] = float(pair[1])
		for t in 2:
			manager.team_builds[t].gains = g.duplicate()
			manager.team_builds[t].curve = curve
	if args.has("red"):
		manager.team_personalities[0] = Personality.preset(args["red"])
		manager.team_preset_names[0] = args["red"]
	if args.has("blue"):
		manager.team_personalities[1] = Personality.preset(args["blue"])
		manager.team_preset_names[1] = args["blue"]
	for t in 2:
		var key := "redbuild" if t == 0 else "bluebuild"
		if args.has(key):
			var gains: Dictionary = manager.team_builds[t].gains
			var curve: float = manager.team_builds[t].curve
			manager.team_builds[t] = PlayerBuild.parse(args[key])
			manager.team_builds[t].gains = gains
			manager.team_builds[t].curve = curve
			manager.team_build_names[t] = manager.team_builds[t].label()
	if args.has("seed"):
		_base_seed = int(args["seed"])

	if args.has("aimtest"):
		_aim_test(args)
		return
	if headless:
		manager.time_limit = float(args.get("cap", "180"))
		set_sim_speed(20.0)
		batch_left = maxi(int(args.get("sim", "5")), 1)
		print("Dodgeball Bots headless sim: %d games, %s/%s vs %s/%s gains=%s" % [batch_left,
			manager.team_preset_names[0], manager.team_builds[0].short(), manager.team_preset_names[1], manager.team_builds[1].short(),
			JSON.stringify(manager.team_builds[0].gains) + " curve=%.2f" % manager.team_builds[0].curve])
		_start_next()
		return

	_setup_ui_scale()
	cam = CameraRig.new()
	add_child(cam)
	_frame_court()
	get_tree().root.size_changed.connect(_frame_court)
	hud = Hud.new()
	add_child(hud)
	hud.setup(manager)
	hud.new_match_requested.connect(func(): batch_left = 0; batch_results.clear(); _start_next())
	hud.batch_requested.connect(_run_batch)
	hud.speed_changed.connect(set_sim_speed)
	hud.pause_toggled.connect(func(p: bool): get_tree().paused = p)
	hud.process_mode = Node.PROCESS_MODE_ALWAYS
	cam.process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.has_feature("web"):
		# ?speed=0.25 for slow motion (screenshots, gifs)
		var q: String = str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('speed') || ''", true))
		if q.is_valid_float() and float(q) > 0.0:
			set_sim_speed(clampf(float(q), 0.05, 8.0))
	_start_next()


## Sideline view in landscape; in portrait the court is turned end-on so its length runs down
## the screen instead of across a sliver of it.
func _frame_court() -> void:
	var vs := get_viewport().get_visible_rect().size
	var portrait := vs.y > vs.x
	cam.yaw = PI * 0.5 if portrait else 0.0
	cam.pitch = 1.15 if portrait else 0.95
	cam.dist = 25.0 if portrait else 23.0
	cam._rest_dist = cam.dist
	if cam._cam != null:
		cam._cam.keep_aspect = Camera3D.KEEP_HEIGHT if portrait else Camera3D.KEEP_WIDTH


func _setup_ui_scale() -> void:
	var root := get_tree().root
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	var dpi := DisplayServer.screen_get_dpi()
	root.content_scale_factor = clampf(float(dpi) / 96.0, 1.0, 3.0)


func set_sim_speed(s: float) -> void:
	Engine.time_scale = s
	Engine.physics_ticks_per_second = maxi(int(round(60.0 * s)), 12)
	Engine.max_physics_steps_per_frame = maxi(8, int(s * 4.0))


func _build_lighting() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, 30, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = not headless
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.12, 0.13, 0.17)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.72, 0.8)
	e.ambient_light_energy = 0.75
	env.environment = e
	add_child(env)


func _parse_args(list: PackedStringArray) -> Dictionary:
	var d := {}
	for a in list:
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			d[kv[0]] = kv[1] if kv.size() > 1 else "1"
	return d


func _start_next() -> void:
	_restart_timer = -1.0
	if hud != null:
		hud.on_match_started()
	var s := -1
	if _base_seed >= 0:
		s = _base_seed + manager.match_index
	manager.start_match(s)


func _run_batch(n: int) -> void:
	batch_left = n
	batch_results.clear()
	set_sim_speed(8.0)
	if hud != null:
		hud._set_speed(8.0)
	_start_next()


var _dbg_t := 0.0
func _process(delta: float) -> void:
	if headless and OS.has_environment("DBDEBUG") and manager.running:
		_dbg_t += delta
		if _dbg_t > 2.0:
			_dbg_t = 0.0
			var parts := PackedStringArray()
			for p in manager.players:
				parts.append("%s %s (%.1f,%.1f) %s%s%s%s%s" % [p.player_name, p.action, p.global_position.x, p.global_position.z, "B" if p.held != null else "-", "!" if p.out else "", "~" if p.inbound else "", "R" if p.ragdoll != null else "", "" if p.on_court else "^"])
			var bp := PackedStringArray()
			for b in manager.balls:
				bp.append("(%.1f,%.1f %s)" % [b.global_position.x, b.global_position.z, "live" if b.live else ("held" if b.holder != null else "idle")])
			print("t=%d " % int(manager.elapsed) + " | ".join(parts) + "  balls " + " ".join(bp))
	if cam != null and manager != null and manager.celebrating:
		var c := Vector3.ZERO
		var n := 0
		for p in manager.players:
			if p.celebrating:
				c += p.global_position
				n += 1
		if n > 0:
			# the results panel covers the right half (landscape) or the bottom (portrait):
			# put the winners in the part of the screen that is still visible
			var f := c / n
			var b := cam.camera_basis()
			var vs := get_viewport().get_visible_rect().size
			if hud != null and hud.results_overlay.visible:
				if vs.x > vs.y:
					f += Vector3(b.x.x, 0, b.x.z).normalized() * 4.5   # subject to screen-left
				else:
					f += Vector3(b.z.x, 0, b.z.z).normalized() * 3.5   # subject to screen-top
			cam.set_focus(f, 14.0)
	elif cam != null:
		cam.clear_focus()
	if _restart_timer > 0.0:
		_restart_timer -= delta
		if _restart_timer <= 0.0:
			_start_next()


func _on_match_ended(result: Dictionary) -> void:
	if not headless:
		print("game %d: %s by %s in %ds (left %d-%d)" % [result["match"], result["winner_name"], result["reason"], int(result["duration"]), result["alive"][0], result["alive"][1]])
	if batch_left > 0:
		batch_left -= 1
		batch_results.append(result)
		if headless:
			print("  game %d: %s by %s in %ds (left %d-%d)" % [result["match"], result["winner_name"], result["reason"], int(result["duration"]), result["alive"][0], result["alive"][1]])
		if batch_left > 0:
			if hud != null:
				hud.set_status("Batch: %d done, %d to go..." % [batch_results.size(), batch_left])
			_restart_timer = 0.05
			return
		var summary := _summarize(batch_results)
		if headless:
			print(summary["text"])
			for pp in batch_results[-1]["players"]:
				print("  %s %s/%s throws=%d hits=%d catches=%d drops=%d blocks=%d dodges=%d out=%d" % [pp["name"], pp["persona"], pp["build"], pp["throws"], pp["hits"], pp["catches"], pp["drops"], pp["blocks"], pp["dodges"], pp["times_out"]])
			print("SUMMARY " + JSON.stringify(summary["data"]))
			if OS.has_environment("DBCELEB") and manager.celebrating:
				get_tree().create_timer(30.0).timeout.connect(func(): print("celebration: CAP HIT in phase %s" % manager.celebration_phase); get_tree().quit())
				return
			get_tree().quit()
			return
		hud.show_batch(summary)
		set_sim_speed(1.0)
		hud._set_speed(1.0)
		return
	if hud != null:
		_last_result = result
		_results_shown_for = -1
		hud.set_status("Game over - %s" % (result["winner_name"] + " win" if result["winner"] >= 0 else "a draw"))
		if result["winner"] < 0 or not manager.celebrating:
			get_tree().create_timer(1.2).timeout.connect(func(): _show_results(result["match"]))
		else:
			# the panel comes up as the dance starts; a safety timer in case the winners dawdle
			get_tree().create_timer(GATHER_SAFETY).timeout.connect(func(): _show_results(result["match"]))
	elif headless:
		print(JSON.stringify(result))


const GATHER_SAFETY := 9.0
var _results_shown_for := -1

func _show_results(idx: int) -> void:
	if hud == null or _last_result.is_empty() or _results_shown_for == idx or idx != manager.match_index or manager.running:
		return
	_results_shown_for = idx
	hud.show_result(_last_result)


func _on_dance_started(idx: int) -> void:
	if batch_left > 0:
		return
	_show_results(idx)


func _on_celebration_finished(idx: int) -> void:
	if headless and OS.has_environment("DBCELEB"):
		print("celebration finished for game %d" % idx)
		get_tree().quit()


func _summarize(results: Array[Dictionary]) -> Dictionary:
	var wins := [0, 0]
	var draws := 0
	var dur := 0.0
	var agg := {}
	var how := {}
	var dist := {}
	for k in ["throws", "hits", "catches", "drops", "blocks", "dodges", "outs", "returns"]:
		agg[k] = [0, 0]
	for r in results:
		if r["winner"] >= 0:
			wins[r["winner"]] += 1
		else:
			draws += 1
		dur += r["duration"]
		for k in agg:
			for t in 2:
				agg[k][t] += r["stats"][k][t]
		for k in r["stats"]["how"]:
			how[k] = int(how.get(k, 0)) + int(r["stats"]["how"][k])
		for k in r["stats"]["dist"]:
			if not dist.has(k):
				dist[k] = [0, 0]
			dist[k][0] += int(r["stats"]["dist"][k][0])
			dist[k][1] += int(r["stats"]["dist"][k][1])
	var n := maxi(results.size(), 1)
	var txt := "Batch of %d: Red(%s/%s) %d wins, Blue(%s/%s) %d wins, %d draws, avg %ds.  " % [
		results.size(), manager.team_preset_names[0], manager.team_build_names[0], wins[0],
		manager.team_preset_names[1], manager.team_build_names[1], wins[1], draws, int(dur / n)]
	for t in 2:
		var acc := float(agg["hits"][t]) / maxf(agg["throws"][t], 1) * 100.0
		txt += "%s per game: %d throws (%d%% hit), %d catches, %d drops, %d blocks, %d dodges.  " % [
			MatchManager.TEAM_NAMES[t], agg["throws"][t] / n, int(acc), agg["catches"][t] / n, agg["drops"][t] / n, agg["blocks"][t] / n, agg["dodges"][t] / n]
	txt += "Outs by: %s  Throws/hits by distance: %s" % [JSON.stringify(how), JSON.stringify(dist)]
	return {"text": txt, "data": {"games": results.size(), "wins": wins, "draws": draws, "avg_duration": dur / n,
		"totals": agg, "how": how, "presets": manager.team_preset_names, "builds": manager.team_build_names}}


# ---------------------------------------------------------------- aim test
# godot --headless -- --aimtest=1 --redbuild=... [--dist=8] [--n=100]: one thrower, one target
# standing still, count how many throws touch the target.

var _at_throws := 0
var _at_hits := 0
var _at_catches := 0
var _at_n := 0
var _at_timer := 0.0
var _at_thrower: Player
var _at_target: Player
var _at_ball: Ball
var args_react := false

func _aim_test(args: Dictionary) -> void:
	set_sim_speed(20.0)
	_at_n = int(args.get("n", "100"))
	args_react = args.get("react", "0") == "1"
	var dist := float(args.get("dist", "8"))
	manager.running = true
	_at_thrower = Player.new()
	_at_thrower.team = 0
	_at_thrower.build = manager.team_builds[0]
	_at_thrower.manager = manager
	_at_thrower.position = Vector3(-dist * 0.5, 0, 0)
	_at_thrower.rotation.y = -PI * 0.5
	add_child(_at_thrower)
	_at_target = Player.new()
	_at_target.team = 1
	_at_target.build = manager.team_builds[1]
	_at_target.manager = manager
	_at_target.position = Vector3(dist * 0.5, 0, 0)
	_at_target.rotation.y = PI * 0.5
	add_child(_at_target)
	manager.players = [_at_thrower, _at_target]
	_at_ball = Ball.new()
	_at_ball.manager = manager
	_at_ball.position = Vector3(-dist * 0.5, 0.5, 0)
	add_child(_at_ball)
	manager.balls = [_at_ball]
	_at_target.dummy = true
	_at_target.set_physics_process(args.get("react", "0") == "1")
	_at_thrower.set_physics_process(false)
	_at_target.eliminated.connect(func(_p, _by, _how): _at_hits += 1; _at_target.out = false; _at_target.on_court = true)
	set_process(true)


func _physics_process(delta: float) -> void:
	if _at_thrower == null:
		return
	_at_timer -= delta
	if _at_timer > 0.0:
		return
	_at_timer = 1.6
	if _at_throws >= _at_n:
		print("AIMTEST throws=%d hits=%d catches=%d rate=%.1f%% build=%s speed=%.1f err=%.2f" % [_at_throws, _at_hits, _at_catches, 100.0 * _at_hits / _at_throws, _at_thrower.build.short(), _at_thrower.throw_speed, _at_thrower.aim_err])
		get_tree().quit()
		return
	if _at_target.held == _at_ball:
		_at_catches += 1
		_at_target.held = null
	_at_ball.set_dead()
	_at_ball.take(_at_thrower)
	_at_ball.global_position = _at_thrower.to_global(Player.HAND_POS)
	_at_thrower.held = _at_ball
	_at_thrower._windup_target = _at_target
	_at_thrower._release()
	_at_throws += 1
