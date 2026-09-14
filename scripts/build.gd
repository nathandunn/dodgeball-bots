class_name PlayerBuild
extends RefCounted
## A player's physical make-up: five properties that ALWAYS sum to 1. Raising one lowers the
## others in proportion, so every player spends the same budget and the only question is where.
##
##   speed  - running speed
##   arm    - throw speed (a faster ball is harder to dodge, catch or block)
##   aim    - throw accuracy and lead on a moving target
##   hands  - catching, blocking and keeping hold of the ball
##   dodge  - reaction time and sidestep (how hard the player is to hit)
##
## Each property turns into game numbers through `skill()`, linear in the property: 0.2 (an
## even split) is the midpoint, 0.4 the designed top of the span, 0.6 half again beyond it, and
## 0 the floor. GAINS is what the calibration sweep tunes so that a point spent anywhere is
## worth about the same (tools/calibrate.py rewrites the line).

const PROPS: Array[String] = ["speed", "arm", "aim", "hands", "dodge"]

const PROP_HELP := {
	"speed": "Running speed",
	"arm": "Throw speed",
	"aim": "Throw accuracy and lead",
	"hands": "Catching, blocking, holding on",
	"dodge": "Reaction time and sidestep",
}

# calibration: how strongly each property's skill swings its game numbers (1.0 = the
# designed span). Tuned by tools/calibrate.py so that specialising in any one property beats
# an even split about half the time.
const GAINS := {"speed": 0.910, "arm": 0.580, "aim": 5.000, "hands": 0.740, "dodge": 0.450}
# calibration: how hard it hurts to starve a property (the exponent below the midpoint).
# 1 = linear; smaller = gentler, so specialists who dump the rest are not crippled by it.
const CURVE := 0.310

const PRESETS := {
	"Even":      {"speed": 0.20, "arm": 0.20, "aim": 0.20, "hands": 0.20, "dodge": 0.20},
	"Sprinter":  {"speed": 0.50, "arm": 0.15, "aim": 0.10, "hands": 0.10, "dodge": 0.15},
	"Cannon":    {"speed": 0.10, "arm": 0.50, "aim": 0.20, "hands": 0.10, "dodge": 0.10},
	"Sniper":    {"speed": 0.10, "arm": 0.20, "aim": 0.50, "hands": 0.10, "dodge": 0.10},
	"Glue":      {"speed": 0.10, "arm": 0.10, "aim": 0.10, "hands": 0.55, "dodge": 0.15},
	"Ghost":     {"speed": 0.20, "arm": 0.10, "aim": 0.10, "hands": 0.10, "dodge": 0.50},
	"Thrower":   {"speed": 0.15, "arm": 0.35, "aim": 0.35, "hands": 0.05, "dodge": 0.10},
	"Keeper":    {"speed": 0.15, "arm": 0.10, "aim": 0.10, "hands": 0.35, "dodge": 0.30},
}

const MID := 0.2   # an even split

var props: Dictionary = {}
var gains: Dictionary = GAINS.duplicate()
var curve: float = CURVE


func _init(from: Dictionary = {}) -> void:
	for p in PROPS:
		props[p] = maxf(float(from.get(p, MID)), 0.0)
	normalize()


static func preset(preset_name: String) -> PlayerBuild:
	if preset_name == "Random":
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var d := {}
		for p in PROPS:
			d[p] = rng.randf() + 0.05
		return PlayerBuild.new(d)
	return PlayerBuild.new(PRESETS.get(preset_name, PRESETS["Even"]))


## "0.3,0.2,0.2,0.2,0.1" in PROPS order, or a preset name.
static func parse(text: String) -> PlayerBuild:
	if text.find(",") < 0:
		return preset(text)
	var parts := text.split(",")
	var d := {}
	for i in mini(parts.size(), PROPS.size()):
		d[PROPS[i]] = float(parts[i])
	return PlayerBuild.new(d)


func normalize() -> void:
	var total := 0.0
	for p in PROPS:
		total += float(props[p])
	if total <= 0.0:
		for p in PROPS:
			props[p] = MID
		return
	for p in PROPS:
		props[p] = float(props[p]) / total


func get_prop(p: String) -> float:
	return float(props.get(p, MID))


## Set one property and rescale the rest so the total stays 1.
func set_prop(p: String, v: float) -> void:
	v = clampf(v, 0.0, 1.0)
	var others := 0.0
	for q in PROPS:
		if q != p:
			others += float(props[q])
	var rest := 1.0 - v
	for q in PROPS:
		if q == p:
			props[q] = v
		elif others > 0.0:
			props[q] = float(props[q]) / others * rest
		else:
			props[q] = rest / float(PROPS.size() - 1)


## 0..1 skill for a property: 0.5 at an even split, 1 at 0.4, 0 at nothing. GAINS widens or
## narrows the swing about the midpoint.
func skill(p: String) -> float:
	# linear in the property all the way, so a point moved from one property to another
	# is the same amount of skill either side: 0 -> 0, 0.2 -> 0.5, 0.4 -> 1, 0.6 -> 1.5.
	# Not clamped: the physical numbers are bounded in Player.apply_build.
	var v := get_prop(p)
	var s := 0.0
	if v >= MID:
		s = v / (2.0 * MID)
	else:
		s = 0.5 * pow(v / MID, float(curve))
	return 0.5 + (s - 0.5) * float(gains.get(p, 1.0))


## Linear game number from a property: `lo` at skill 0, `hi` at skill 1, extrapolated beyond
## when the gain pushes the skill outside 0..1 and then held inside [floor, ceiling].
func stat(p: String, lo: float, hi: float, floor_v: float = -INF, ceil_v: float = INF) -> float:
	var v := lo + (hi - lo) * skill(p)
	var a := minf(lo, hi)
	var b := maxf(lo, hi)
	# never past the physical bounds, whichever way the span runs
	return clampf(v, maxf(floor_v, a - (b - a)), minf(ceil_v, b + (b - a)))


func copy() -> PlayerBuild:
	var b := PlayerBuild.new(props)
	b.gains = gains.duplicate()
	b.curve = curve
	return b


## Same build with a little per-player noise, renormalised.
func jittered(rng: RandomNumberGenerator, spread: float = 0.02) -> PlayerBuild:
	var d := {}
	for p in PROPS:
		d[p] = maxf(get_prop(p) + rng.randf_range(-spread, spread), 0.0)
	var b := PlayerBuild.new(d)
	b.gains = gains.duplicate()
	b.curve = curve
	return b


func label() -> String:
	var best := "Custom"
	var best_d := 0.09
	for n in PRESETS:
		var d := 0.0
		for p in PROPS:
			d += absf(get_prop(p) - float(PRESETS[n][p]))
		d /= PROPS.size()
		if d < best_d:
			best_d = d
			best = n
	return best


func short() -> String:
	var parts := PackedStringArray()
	for p in PROPS:
		parts.append("%s %d" % [p.substr(0, 2), int(round(get_prop(p) * 100.0))])
	return " ".join(parts)


func to_dict() -> Dictionary:
	return props.duplicate()
