extends RefCounted
## Внутреннее состояние жителя: личность, потребности, память, знания о местах, отношения, навыки.
## Чистые данные + сериализация; решения принимает brain.gd.

const MAX_MEMORY := 80

var id: int = 0
var name: String = ""
var sex: String = "m"            # "m" / "f"
var age_years: float = 20.0
var alive: bool = true
var appearance := {}             # skin, hair, shirt, pants, height

# Потребности 0..100 (100 — полностью удовлетворена)
var food: float = 80.0
var water: float = 80.0
var energy: float = 85.0
var social: float = 60.0
var health: float = 100.0
var mood: float = 70.0

# Черты характера 0..1
var traits := {"curiosity": 0.5, "caution": 0.5, "sociability": 0.5, "calm": 0.5}
var preferences := {}            # например {"favorite_place": "spring"}
var long_goal: String = ""

var skills := {"собирательство": 0.0, "общение": 0.0, "исследование": 0.0, "выживание": 0.0}

var memory: Array = []           # [{t, kind, text, imp}]
var known_places := {}           # obj_id(str) -> {type, x, z, amount, seen}
var danger_zones: Array = []     # [{x, z, r, until}]
var relationships := {}          # other_id(str) -> {name, affinity, familiarity, talks, last}

# Текущее решение
var goal: String = "idle"
var goal_reason: String = ""
var plan: Array = []             # [{a: "move"/"eat"/..., ...}]
var action_text: String = "Осматривается"
var sleeping: bool = false

# ---------------------------------------------------------------- память

func remember(t: float, kind: String, text: String, imp: float = 0.5) -> void:
	memory.append({"t": t, "kind": kind, "text": text, "imp": imp})
	if memory.size() > MAX_MEMORY:
		# забываем наименее важное из старых воспоминаний
		var worst := 0
		for i in range(memory.size() - 20):
			if float(memory[i]["imp"]) < float(memory[worst]["imp"]):
				worst = i
		memory.remove_at(worst)

func recent_memories(n: int) -> Array:
	var out: Array = []
	for i in range(memory.size() - 1, maxi(-1, memory.size() - 1 - n), -1):
		out.append(memory[i])
	return out

func life_story() -> Array:
	var out: Array = []
	for m in memory:
		if float(m["imp"]) >= 0.75:
			out.append(m)
	return out

func know_place(obj_id: int, t: String, pos: Vector3, amount: float, now: float) -> bool:
	var key := str(obj_id)
	var is_new := not known_places.has(key)
	known_places[key] = {"type": t, "x": pos.x, "z": pos.z, "amount": amount, "seen": now}
	return is_new

func forget_place(obj_id: int) -> void:
	known_places.erase(str(obj_id))

func places_of(t: String) -> Array:
	var out: Array = []
	for k in known_places:
		var p: Dictionary = known_places[k]
		if p["type"] == t:
			var e := p.duplicate()
			e["id"] = int(k)
			out.append(e)
	return out

func add_danger(pos: Vector3, r: float, until: float) -> void:
	for d in danger_zones:
		if Vector2(d["x"] - pos.x, d["z"] - pos.z).length() < 2.0:
			d["until"] = maxf(float(d["until"]), until)
			return
	danger_zones.append({"x": pos.x, "z": pos.z, "r": r, "until": until})

func is_in_danger_zone(pos: Vector3, now: float) -> bool:
	for d in danger_zones:
		if float(d["until"]) > now and Vector2(d["x"] - pos.x, d["z"] - pos.z).length() < float(d["r"]):
			return true
	return false

func cleanup(now: float) -> void:
	danger_zones = danger_zones.filter(func(d): return float(d["until"]) > now)

# ---------------------------------------------------------------- отношения

func rel(other_id: int, other_name: String = "") -> Dictionary:
	var key := str(other_id)
	if not relationships.has(key):
		relationships[key] = {"name": other_name, "affinity": 0.0, "familiarity": 0.0, "talks": 0, "last": -1.0}
	return relationships[key]

static func relation_label(affinity: float, familiarity: float) -> String:
	if familiarity < 5.0:
		return "Незнакомы"
	if affinity >= 75.0:
		return "Близкие люди"
	if affinity >= 40.0:
		return "Друзья"
	if affinity >= 10.0:
		return "Приятели"
	if affinity > -20.0:
		return "Знакомые"
	if affinity > -50.0:
		return "Неприязнь"
	return "Конфликт"

func add_skill(s: String, v: float) -> void:
	skills[s] = minf(100.0, float(skills.get(s, 0.0)) + v)

func trait_text() -> String:
	var parts: Array = []
	if traits["curiosity"] > 0.65: parts.append("любознательный" if sex == "m" else "любознательная")
	if traits["caution"] > 0.65: parts.append("осторожный" if sex == "m" else "осторожная")
	if traits["sociability"] > 0.65: parts.append("общительный" if sex == "m" else "общительная")
	if traits["sociability"] < 0.35: parts.append("замкнутый" if sex == "m" else "замкнутая")
	if traits["calm"] > 0.65: parts.append("спокойный" if sex == "m" else "спокойная")
	if traits["calm"] < 0.35: parts.append("вспыльчивый" if sex == "m" else "вспыльчивая")
	if parts.is_empty():
		parts.append("уравновешенный" if sex == "m" else "уравновешенная")
	return ", ".join(parts)

# ---------------------------------------------------------------- сериализация

const FIELDS := ["id", "name", "sex", "age_years", "alive", "appearance", "food", "water", "energy",
	"social", "health", "mood", "traits", "preferences", "long_goal", "skills", "memory",
	"known_places", "danger_zones", "relationships", "goal", "goal_reason", "action_text", "sleeping"]

func to_dict() -> Dictionary:
	var d := {}
	for f in FIELDS:
		var v = get(f)
		d[f] = v.duplicate(true) if (v is Dictionary or v is Array) else v
	return d

func from_dict(d: Dictionary) -> void:
	for f in FIELDS:
		if d.has(f):
			var cur = get(f)
			var v = d[f]
			if cur is float:
				v = float(v)
			elif cur is int:
				v = int(v)
			elif cur is bool:
				v = bool(v)
			set(f, v)
	plan = []
