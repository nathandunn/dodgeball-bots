class_name Personality
extends RefCounted
## How a player plays (as opposed to what they are, which is PlayerBuild). 0..1 traits that
## shape the utility scores; nothing here changes speed, arm or hands.

const TRAITS: Array[String] = ["aggression", "caution", "catching", "teamwork", "patience", "bully"]

const TRAIT_HELP := {
	"aggression": "Walk up to the line and throw early",
	"caution": "Hang back, dodge early, block rather than catch",
	"catching": "Go for the catch instead of the dodge",
	"teamwork": "Volley with mates, pile on one target, feed the unarmed",
	"patience": "Hold the ball for a clean shot (up to the 10-second clock)",
	"bully": "Pick on the weakest and the unarmed",
}

const PRESETS := {
	"Gunner":    {"aggression": 0.95, "caution": 0.10, "catching": 0.20, "teamwork": 0.35, "patience": 0.15, "bully": 0.50},
	"Catcher":   {"aggression": 0.40, "caution": 0.40, "catching": 0.95, "teamwork": 0.50, "patience": 0.55, "bully": 0.30},
	"Dodger":    {"aggression": 0.25, "caution": 0.95, "catching": 0.15, "teamwork": 0.40, "patience": 0.70, "bully": 0.40},
	"Wall":      {"aggression": 0.35, "caution": 0.70, "catching": 0.35, "teamwork": 0.55, "patience": 0.90, "bully": 0.20},
	"Tactician": {"aggression": 0.55, "caution": 0.50, "catching": 0.45, "teamwork": 0.95, "patience": 0.65, "bully": 0.75},
	"Balanced":  {"aggression": 0.50, "caution": 0.50, "catching": 0.50, "teamwork": 0.50, "patience": 0.50, "bully": 0.50},
}

var traits: Dictionary = {}


func _init(from: Dictionary = {}) -> void:
	for t in TRAITS:
		traits[t] = clampf(float(from.get(t, 0.5)), 0.0, 1.0)


static func preset(preset_name: String) -> Personality:
	if preset_name == "Random":
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var d := {}
		for t in TRAITS:
			d[t] = rng.randf()
		return Personality.new(d)
	return Personality.new(PRESETS.get(preset_name, PRESETS["Balanced"]))


func get_trait(t: String) -> float:
	return float(traits.get(t, 0.5))


func set_trait(t: String, v: float) -> void:
	traits[t] = clampf(v, 0.0, 1.0)


func copy() -> Personality:
	return Personality.new(traits)


func jittered(rng: RandomNumberGenerator, spread: float = 0.08) -> Personality:
	var d := {}
	for t in TRAITS:
		d[t] = clampf(get_trait(t) + rng.randf_range(-spread, spread), 0.0, 1.0)
	return Personality.new(d)


func label() -> String:
	var best := "Custom"
	var best_d := 0.3
	for n in PRESETS:
		var d := 0.0
		for t in TRAITS:
			d += absf(get_trait(t) - float(PRESETS[n][t]))
		d /= TRAITS.size()
		if d < best_d:
			best_d = d
			best = n
	return best


func to_dict() -> Dictionary:
	return traits.duplicate()
