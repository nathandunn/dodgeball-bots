class_name Hud
extends CanvasLayer
## All UI built in code: scoreboard, controls, team setup (personality + build), results.

signal new_match_requested
signal batch_requested(n: int)
signal speed_changed(scale: float)
signal pause_toggled(paused: bool)

const PERSONA_LIST := ["Balanced", "Gunner", "Catcher", "Dodger", "Wall", "Tactician", "Random", "Custom"]
const BUILD_LIST := ["Even", "Sprinter", "Cannon", "Sniper", "Glue", "Ghost", "Thrower", "Keeper", "Random", "Custom"]

var manager: MatchManager
var timer_label: Label
var team_labels: Array[Label] = []
var live_label: Label
var status_label: Label
var teams_overlay: Control
var teams_scroll: ScrollContainer
var results_overlay: Control
var results_scroll: ScrollContainer
var results_box: VBoxContainer
var results_title: Label
var next_row: HFlowContainer
var persona_buttons: Array[OptionButton] = []
var build_buttons: Array[OptionButton] = []
var p_sliders := [{}, {}]
var p_vals := [{}, {}]
var b_sliders := [{}, {}]
var b_vals := [{}, {}]
var b_sum: Array[Label] = []
var speed_buttons: Array[Button] = []
var teams_btn: Button
var live_btn: Button
var results_btn: Button
var last_result := {}
var _updating := false
var _tick := 0.0
var _root: Control


func setup(m: MatchManager) -> void:
	manager = m
	var theme := Theme.new()
	theme.default_font_size = 16
	_root = Control.new()
	_root.theme = theme
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vbox)

	var row1 := HFlowContainer.new()
	row1.add_theme_constant_override("h_separation", 14)
	vbox.add_child(row1)
	var apps_gap := Control.new()  # room for the shell's "Apps" link, top left
	apps_gap.custom_minimum_size = Vector2(84, 1)
	row1.add_child(apps_gap)
	timer_label = Label.new()
	timer_label.add_theme_font_size_override("font_size", 26)
	timer_label.text = "0:00"
	row1.add_child(timer_label)
	for t in 2:
		var l := Label.new()
		l.add_theme_color_override("font_color", MatchManager.TEAM_COLORS[t].lightened(0.2))
		l.add_theme_font_size_override("font_size", 19)
		row1.add_child(l)
		team_labels.append(l)

	var row2 := HFlowContainer.new()
	row2.add_theme_constant_override("h_separation", 6)
	vbox.add_child(row2)
	var pause_btn := Button.new()
	pause_btn.text = "Pause"
	pause_btn.toggle_mode = true
	pause_btn.toggled.connect(func(on: bool): pause_btn.text = "Play" if on else "Pause"; pause_toggled.emit(on))
	row2.add_child(pause_btn)
	for s in [1, 2, 4, 8]:
		var b := Button.new()
		b.text = "%dx" % s
		b.toggle_mode = true
		b.button_pressed = (s == 1)
		b.pressed.connect(func(): _set_speed(float(s)))
		row2.add_child(b)
		speed_buttons.append(b)
	teams_btn = Button.new()
	teams_btn.text = "Teams / setup"
	teams_btn.toggle_mode = true
	teams_btn.toggled.connect(func(on: bool): teams_overlay.visible = on; if on: results_overlay.visible = false)
	row2.add_child(teams_btn)
	live_btn = Button.new()
	live_btn.text = "Live list"
	live_btn.toggle_mode = true
	live_btn.toggled.connect(func(on: bool): live_label.visible = on)
	row2.add_child(live_btn)
	results_btn = Button.new()
	results_btn.text = "Last results"
	results_btn.disabled = true
	results_btn.pressed.connect(func(): if not last_result.is_empty(): show_result(last_result))
	row2.add_child(results_btn)
	var new_btn := Button.new()
	new_btn.text = "New game"
	new_btn.pressed.connect(func(): _close_overlays(); new_match_requested.emit())
	row2.add_child(new_btn)
	var batch_btn := Button.new()
	batch_btn.text = "Batch x10"
	batch_btn.pressed.connect(func(): _close_overlays(); batch_requested.emit(10))
	row2.add_child(batch_btn)

	live_label = Label.new()
	live_label.add_theme_font_size_override("font_size", 13)
	live_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 0.95))
	live_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	live_label.visible = false
	vbox.add_child(live_label)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(spacer)
	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 14)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(status_label)

	_build_teams_overlay()
	_build_results_overlay()
	_refresh_sliders()
	get_tree().root.size_changed.connect(_relayout)
	_relayout()


# ---------------------------------------------------------------- overlays

func _overlay(title_text: String) -> Array:
	var ov := Control.new()
	ov.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ov.visible = false
	_root.add_child(ov)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ov.add_child(center)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.12, 0.92)
	sb.border_color = Color(0.35, 0.38, 0.45)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	panel.add_child(outer)
	var head := HBoxContainer.new()
	outer.add_child(head)
	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 20)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(title)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(func(): ov.visible = false; teams_btn.set_pressed_no_signal(false))
	head.add_child(close)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	outer.add_child(scroll)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	return [ov, scroll, content, title]


func _build_teams_overlay() -> void:
	var parts := _overlay("Teams")
	teams_overlay = parts[0]
	teams_scroll = parts[1]
	var content: VBoxContainer = parts[2]
	var hint := Label.new()
	hint.text = "Personality is how they play; the build is what they are. The five build properties always add up to 1 - push one up and the others give way. Each player gets the team settings with a little jitter."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 13)
	content.add_child(hint)
	var teams_row := HFlowContainer.new()
	teams_row.add_theme_constant_override("h_separation", 24)
	content.add_child(teams_row)
	for t in 2:
		teams_row.add_child(_build_team_panel(t))
	var start := Button.new()
	start.text = "Start game with these teams"
	start.add_theme_font_size_override("font_size", 18)
	start.pressed.connect(func(): _close_overlays(); new_match_requested.emit())
	content.add_child(start)


func _slider_row(box: VBoxContainer, name_text: String, help: String, on_change: Callable) -> Array:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = name_text
	l.custom_minimum_size.x = 84
	l.tooltip_text = help
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.01
	s.custom_minimum_size = Vector2(150, 28)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.value_changed.connect(on_change)
	row.add_child(s)
	var vl := Label.new()
	vl.custom_minimum_size.x = 36
	row.add_child(vl)
	box.add_child(row)
	return [s, vl]


func _build_team_panel(t: int) -> Control:
	var box := VBoxContainer.new()
	var title := Label.new()
	title.text = MatchManager.TEAM_NAMES[t]
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", MatchManager.TEAM_COLORS[t].lightened(0.2))
	box.add_child(title)

	var pl := Label.new()
	pl.text = "Personality"
	pl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	box.add_child(pl)
	var ob := OptionButton.new()
	for p in PERSONA_LIST:
		ob.add_item(p)
	ob.select(0)
	ob.item_selected.connect(func(idx: int): _on_persona(t, PERSONA_LIST[idx]))
	box.add_child(ob)
	persona_buttons.append(ob)
	for trait_name in Personality.TRAITS:
		var sv := _slider_row(box, trait_name, Personality.TRAIT_HELP[trait_name], func(v: float): _on_p_slider(t, trait_name, v))
		p_sliders[t][trait_name] = sv[0]
		p_vals[t][trait_name] = sv[1]

	var bl := Label.new()
	bl.text = "Build (adds up to 1)"
	bl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	box.add_child(bl)
	var bb := OptionButton.new()
	for p in BUILD_LIST:
		bb.add_item(p)
	bb.select(0)
	bb.item_selected.connect(func(idx: int): _on_build(t, BUILD_LIST[idx]))
	box.add_child(bb)
	build_buttons.append(bb)
	for prop in PlayerBuild.PROPS:
		var sv := _slider_row(box, prop, PlayerBuild.PROP_HELP[prop], func(v: float): _on_b_slider(t, prop, v))
		b_sliders[t][prop] = sv[0]
		b_vals[t][prop] = sv[1]
	var sum := Label.new()
	sum.add_theme_font_size_override("font_size", 13)
	sum.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	box.add_child(sum)
	b_sum.append(sum)
	return box


func _build_results_overlay() -> void:
	var parts := _overlay("Results")
	results_overlay = parts[0]
	results_scroll = parts[1]
	results_box = parts[2]
	results_title = parts[3]
	next_row = HFlowContainer.new()
	next_row.add_theme_constant_override("h_separation", 10)
	next_row.add_theme_constant_override("v_separation", 6)
	var q := _cell("Start the next game?", true, Color.WHITE, 16)
	q.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	next_row.add_child(q)
	var same := Button.new()
	same.text = "Yes - same teams"
	same.pressed.connect(func(): _close_overlays(); new_match_requested.emit())
	next_row.add_child(same)
	var change := Button.new()
	change.text = "Change teams first"
	change.pressed.connect(func(): results_overlay.visible = false; teams_btn.button_pressed = true)
	next_row.add_child(change)
	var later := Button.new()
	later.text = "Not yet"
	later.pressed.connect(func(): results_overlay.visible = false; teams_btn.set_pressed_no_signal(false))
	next_row.add_child(later)


func on_match_started() -> void:
	results_overlay.visible = false


func _close_overlays() -> void:
	teams_overlay.visible = false
	results_overlay.visible = false
	teams_btn.set_pressed_no_signal(false)


func _relayout() -> void:
	var vs := get_viewport().get_visible_rect().size
	var w := vs.x
	var h := vs.y
	teams_scroll.custom_minimum_size = Vector2(minf(820.0, w - 40.0), minf(560.0, h - 110.0))
	var rc: Control = results_overlay.get_child(0)
	if w > h:
		rc.anchor_left = 0.5
		rc.anchor_top = 0.0
		rc.offset_left = 0.0
		rc.offset_top = 96.0
		results_scroll.custom_minimum_size = Vector2(minf(640.0, w * 0.5 - 40.0), minf(560.0, h - 210.0))
	else:
		rc.anchor_left = 0.0
		rc.anchor_top = 0.42
		rc.offset_left = 0.0
		rc.offset_top = 0.0
		results_scroll.custom_minimum_size = Vector2(minf(900.0, w - 40.0), minf(600.0, h * 0.58 - 90.0))


# ---------------------------------------------------------------- team setup

func _on_persona(t: int, preset_name: String) -> void:
	if preset_name == "Custom":
		manager.team_preset_names[t] = "Custom"
		return
	manager.team_personalities[t] = Personality.preset(preset_name)
	manager.team_preset_names[t] = preset_name
	_refresh_sliders()


func _on_build(t: int, preset_name: String) -> void:
	if preset_name == "Custom":
		manager.team_build_names[t] = "Custom"
		return
	var gains: Dictionary = manager.team_builds[t].gains
	var curve: float = manager.team_builds[t].curve
	manager.team_builds[t] = PlayerBuild.preset(preset_name)
	manager.team_builds[t].gains = gains
	manager.team_builds[t].curve = curve
	manager.team_build_names[t] = preset_name
	_refresh_sliders()


func _on_p_slider(t: int, trait_name: String, v: float) -> void:
	if _updating:
		return
	manager.team_personalities[t].set_trait(trait_name, v)
	p_vals[t][trait_name].text = "%.2f" % v
	var lbl := manager.team_personalities[t].label()
	manager.team_preset_names[t] = lbl
	var idx := PERSONA_LIST.find(lbl)
	persona_buttons[t].select(idx if idx >= 0 else PERSONA_LIST.size() - 1)


func _on_b_slider(t: int, prop: String, v: float) -> void:
	if _updating:
		return
	manager.team_builds[t].set_prop(prop, v)
	var lbl := manager.team_builds[t].label()
	manager.team_build_names[t] = lbl
	_refresh_sliders()


func _refresh_sliders() -> void:
	_updating = true
	for t in 2:
		var p := manager.team_personalities[t]
		for trait_name in Personality.TRAITS:
			p_sliders[t][trait_name].value = p.get_trait(trait_name)
			p_vals[t][trait_name].text = "%.2f" % p.get_trait(trait_name)
		var idx := PERSONA_LIST.find(manager.team_preset_names[t])
		persona_buttons[t].select(idx if idx >= 0 else PERSONA_LIST.size() - 1)
		var b := manager.team_builds[t]
		var total := 0.0
		for prop in PlayerBuild.PROPS:
			b_sliders[t][prop].value = b.get_prop(prop)
			b_vals[t][prop].text = "%.2f" % b.get_prop(prop)
			total += b.get_prop(prop)
		b_sum[t].text = "total %.2f   run %.1f m/s, throw %.0f m/s, aim +-%.1f deg, catch %d%%, react %.2f s" % [total,
			b.stat("speed", 3.4, 6.6, 2.4, 8.5), b.stat("arm", 10.0, 22.0, 7.0, 27.0), b.stat("aim", 5.0, 0.8, 0.2, 9.0), int(b.stat("hands", 0.15, 0.8, 0.03, 0.97) * 100), b.stat("dodge", 0.42, 0.13, 0.06, 0.7)]
		var bidx := BUILD_LIST.find(manager.team_build_names[t])
		build_buttons[t].select(bidx if bidx >= 0 else BUILD_LIST.size() - 1)
	_updating = false


func _set_speed(s: float) -> void:
	for b in speed_buttons:
		b.button_pressed = (b.text == "%dx" % int(s))
	speed_changed.emit(s)


# ---------------------------------------------------------------- live

func _process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0 or manager == null:
		return
	_tick = 0.2
	var tl := manager.elapsed
	timer_label.text = "%d:%02d" % [int(tl) / 60, int(tl) % 60]
	for t in 2:
		team_labels[t].text = "%s %d/%d in, %d balls" % [MatchManager.TEAM_NAMES[t], manager.count_on_court(t), MatchManager.TEAM_SIZE,
			manager.balls_held(t) + manager.balls_on_side(t)]
	if live_label.visible:
		var lines := PackedStringArray()
		for p in manager.players:
			var st := "OUT" if p.out else ("in " + p.action)
			var bl := " [ball %ds]" % int(p.hold_timer) if p.held != null else ""
			lines.append("%s %s %s%s" % [p.player_name, p.build.label(), st, bl])
		live_label.text = "\n".join(lines)


func set_status(text: String) -> void:
	status_label.text = text


# ---------------------------------------------------------------- results

func _clear_results() -> void:
	for c in results_box.get_children():
		results_box.remove_child(c)
		if c != next_row:
			c.queue_free()


func _cell(text: String, bold := false, color := Color.WHITE, size := 14) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color.lightened(0.15) if bold else color)
	return l


static func _pct(hits: int, tries: int) -> String:
	return "%d%%" % int(round(100.0 * hits / tries)) if tries > 0 else "-"


func show_result(res: Dictionary) -> void:
	last_result = res
	results_btn.disabled = false
	_clear_results()
	teams_overlay.visible = false
	teams_btn.set_pressed_no_signal(false)
	var s: Dictionary = res["stats"]
	var wcol: Color = MatchManager.TEAM_COLORS[res["winner"]].lightened(0.25) if res["winner"] >= 0 else Color.WHITE
	results_title.text = "Game %d - %s in %d s" % [res["match"], (res["winner_name"] + " win by " + res["reason"]) if res["winner"] >= 0 else "a draw", int(res["duration"])]
	results_title.add_theme_color_override("font_color", wcol)
	results_box.add_child(next_row)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 3)
	results_box.add_child(grid)
	grid.add_child(_cell(""))
	for t in 2:
		grid.add_child(_cell("%s (%s / %s)" % [MatchManager.TEAM_NAMES[t], res["presets"][t], res["builds"][t]], true, MatchManager.TEAM_COLORS[t].lightened(0.2), 15))
	var rows := [
		["Still in", func(t): return "%d / %d" % [res["alive"][t], MatchManager.TEAM_SIZE]],
		["Throws / hits", func(t): return "%d / %d  (%s)" % [s["throws"][t], s["hits"][t], _pct(s["hits"][t], s["throws"][t])]],
		["Catches (mate returned)", func(t): return "%d (%d)" % [s["catches"][t], s["returns"][t]]],
		["Dropped catches", func(t): return "%d" % s["drops"][t]],
		["Blocks", func(t): return "%d" % s["blocks"][t]],
		["Dodges", func(t): return "%d" % s["dodges"][t]],
		["Times out", func(t): return "%d" % s["outs"][t]],
	]
	for row in rows:
		grid.add_child(_cell(row[0], false, Color(0.8, 0.8, 0.85)))
		for t in 2:
			grid.add_child(_cell(row[1].call(t)))

	results_box.add_child(_cell("Players", true, Color.WHITE, 16))
	var rg := GridContainer.new()
	rg.columns = 9
	rg.add_theme_constant_override("h_separation", 14)
	rg.add_theme_constant_override("v_separation", 2)
	results_box.add_child(rg)
	for hdr in ["Player", "Build", "Plays", "Throws / hits", "Outs made", "Catches", "Drops", "Blocks / dodges", "Out"]:
		rg.add_child(_cell(hdr, false, Color(0.75, 0.75, 0.8), 13))
	for r in res["players"]:
		var col: Color = MatchManager.TEAM_COLORS[r["team"]].lightened(0.25)
		rg.add_child(_cell(r["name"], true, col))
		rg.add_child(_cell(r["build"]))
		rg.add_child(_cell(r["persona"]))
		rg.add_child(_cell("%d / %d %s" % [r["throws"], r["hits"], _pct(r["hits"], r["throws"])]))
		rg.add_child(_cell("%d" % r["outs"]))
		rg.add_child(_cell("%d" % r["catches"]))
		rg.add_child(_cell("%d" % r["drops"]))
		rg.add_child(_cell("%d / %d" % [r["blocks"], r["dodges"]]))
		rg.add_child(_cell("%d" % r["times_out"] + ("" if r["alive"] else " (out)")))
	results_overlay.visible = true
	results_scroll.scroll_vertical = 0
	set_status("Game over. Close the panel to look around; New game (or Teams / setup) when ready.")


func show_batch(summary: Dictionary) -> void:
	_clear_results()
	results_title.text = "Batch results"
	results_title.add_theme_color_override("font_color", Color.WHITE)
	results_box.add_child(next_row)
	var l := _cell(summary["text"])
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = minf(820.0, get_viewport().get_visible_rect().size.x - 70.0)
	results_box.add_child(l)
	results_overlay.visible = true
