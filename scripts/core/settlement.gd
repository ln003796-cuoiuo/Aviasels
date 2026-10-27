extends RefCounted
## Поселение: жители сами решают, что построить, выбирают место, добывают дерево и камень,
## носят материалы на стройку и строят. Состояние хранится в world.settlement и в объектах-стройках.

const Defs = preload("res://scripts/core/object_defs.gd")

## Что умеют строить жители. unlock — навык и порог, после которого постройка «открыта».
const BUILD := {
	"hut": {"wood": 8, "stone": 0, "work": 300.0},
	"campfire": {"wood": 3, "stone": 2, "work": 40.0},
	"storage": {"wood": 10, "stone": 4, "work": 360.0, "unlock": ["строительство", 6.0]},
	"bush": {"wood": 0, "stone": 0, "work": 60.0, "unlock": ["собирательство", 25.0]},
	"well": {"wood": 2, "stone": 8, "work": 420.0, "unlock": ["строительство", 15.0]},
}
const DISCOVERY_TEXT := {
	"storage": "жители научились строить амбары для запасов",
	"bush": "жители научились сажать ягодные кусты — первые грядки",
	"well": "жители научились копать колодцы и обкладывать их камнем",
}
const NAMES := ["Родники", "Ясная Поляна", "Берёзовка", "Каменка", "Ольховка", "Тихий Лог", "Светлый Яр", "Ручейки"]
const LEVELS := ["Стоянка", "Посёлок", "Деревня", "Большая деревня"]
const STORAGE_CAP := 60

static func fresh() -> Dictionary:
	return {"name": "", "founded_at": -1.0, "cx": 0.0, "cz": 0.0, "has_center": false, "level": 0,
		"discoveries": [], "built": 0, "plan_note": ""}

static func target_name(t: String) -> String:
	return "грядку" if t == "bush" else {"hut": "хижину", "campfire": "костёр", "storage": "амбар", "well": "колодец"}.get(t, Defs.display_name(t).to_lower())

static func center(w) -> Vector3:
	return Vector3(float(w.settlement["cx"]), 0.0, float(w.settlement["cz"]))

# ---------------------------------------------------------------- семьи и дома

## Ключ домохозяйства: пара живёт вместе, дети и молодёжь до 20 лет без пары — с родителями.
static func household_of(w, m) -> int:
	if m.partner_id >= 0:
		return mini(m.id, m.partner_id)
	if m.age_years < 20.0:
		for pid in [m.mother_id, m.father_id]:
			var pm = w.mind_by_id(pid)
			if pm != null and pm.alive:
				return household_of(w, pm)
	return m.id

static func home_of(w, m):
	var key := household_of(w, m)
	for o in w.objects.values():
		if o.obj_type == "hut" and int(o.ext.get("owner", -1)) == key:
			return o
	return null

static func household_label(w, key: int) -> String:
	var m = w.mind_by_id(key)
	if m == null:
		return "?"
	if m.partner_id >= 0:
		var p = w.mind_by_id(m.partner_id)
		if p != null:
			return "%s и %s" % [m.name, p.name]
	return m.name

static func households(w) -> Array:
	var keys := {}
	for r in w.residents:
		if r.mind.alive and r.mind.age_years >= 16.0:
			keys[household_of(w, r.mind)] = true
	return keys.keys()

# ---------------------------------------------------------------- планирование

static func best_skill(w, s: String) -> Array:
	var best = null
	var v := -1.0
	for r in w.residents:
		if r.mind.alive and r.mind.is_adult() and float(r.mind.skills.get(s, 0.0)) > v:
			v = float(r.mind.skills.get(s, 0.0))
			best = r
	return [best, v]

static func sites(w) -> Array:
	return w.objects.values().filter(func(o): return o.obj_type == "site")

static func unlocked(w, t: String) -> bool:
	return not BUILD[t].has("unlock") or t in w.settlement["discoveries"]

## Вызывается каждые 2 игровых часа: открытия, распределение домов, новая стройка.
static func plan(w) -> void:
	var st: Dictionary = w.settlement
	for t in BUILD:
		if BUILD[t].has("unlock") and t not in st["discoveries"]:
			var u: Array = BUILD[t]["unlock"]
			var bs: Array = best_skill(w, u[0])
			if bs[0] != null and float(bs[1]) >= float(u[1]):
				st["discoveries"].append(t)
				bs[0].mind.remember(w.time_min, "discovery", "Я понял%s, как сделать %s" % [bs[0].g("", "а"), target_name(t)], 1.0)
				w.log_event("Открытие: %s (первым — %s)" % [DISCOVERY_TEXT[t], bs[0].mind.name])
	var adults: Array = w.residents.filter(func(r): return r.mind.alive and r.mind.age_years >= 14.0)
	if adults.is_empty():
		return
	# центр — рядом с ближайшим к людям родником
	if not st["has_center"]:
		var mean := Vector3.ZERO
		for r in adults:
			mean += r.sim_pos
		mean /= adults.size()
		var spring = null
		for o in w.objects.values():
			if o.obj_type == "spring" and (spring == null or o.position.distance_to(mean) < spring.position.distance_to(mean)):
				spring = o
		var c: Vector3 = mean
		if spring != null:
			var dir: Vector3 = (mean - spring.position)
			dir.y = 0.0
			dir = dir.normalized() if dir.length() > 0.5 else Vector3(1, 0, 0)
			c = spring.position + dir * 5.0
		st["cx"] = c.x
		st["cz"] = c.z
		st["has_center"] = true
	_assign_homes(w)
	var active: Array = sites(w)
	if active.size() >= 1 + int(adults.size() / 4):
		return
	var cpos := center(w)
	var pop: int = w.alive_count()
	var choice := ""
	var owner := -1
	var reason := ""
	# 1. дом каждой семье
	for key in households(w):
		var has := false
		for o in w.objects.values():
			if (o.obj_type == "hut" or (o.obj_type == "site" and o.ext.get("target", "") == "hut")) and int(o.ext.get("owner", -1)) == key:
				has = true
				break
		if not has:
			choice = "hut"
			owner = key
			reason = "семье «%s» негде жить" % household_label(w, key)
			break
	# 2. общий костёр
	if choice == "" and not _exists_near(w, "campfire", cpos, 14.0):
		choice = "campfire"
		reason = "нужен общий костёр"
	# 3. амбар
	if choice == "" and unlocked(w, "storage") and pop >= 4 and not _exists_near(w, "storage", cpos, 20.0):
		choice = "storage"
		reason = "нужно хранить запасы еды"
	# 4. грядки, когда ягод рядом мало
	if choice == "" and unlocked(w, "bush"):
		var near_b: int = w.objects_near(cpos, 16.0).filter(func(o): return o.obj_type == "bush").size()
		if near_b < int(pop * 0.8) + 2:
			choice = "bush"
			reason = "рядом мало ягод для %d человек" % pop
	# 5. колодец для большого поселения
	if choice == "" and unlocked(w, "well") and pop >= 8:
		var wells: int = w.objects.values().filter(func(o): return o.obj_type == "well" or (o.obj_type == "site" and o.ext.get("target", "") == "well")).size()
		if wells < int(pop / 10) + 1:
			choice = "well"
			reason = "одного родника мало для %d человек" % pop
	if choice == "":
		st["plan_note"] = "Всё необходимое построено"
		return
	# дублировать одну и ту же стройку не нужно
	for s in active:
		if s.ext.get("target", "") == choice and choice != "hut":
			return
	var pos = _find_spot(w, choice, cpos)
	if pos == null:
		st["plan_note"] = "Не нашли места для: %s" % target_name(choice)
		return
	var bs2: Array = best_skill(w, "строительство")
	var initiator = bs2[0] if bs2[0] != null else adults[0]
	var need: Dictionary = BUILD[choice]
	w.add_object("site", pos, {"ext": {"target": choice, "need_wood": need["wood"], "need_stone": need["stone"],
		"wood": 0, "stone": 0, "work": 0.0, "work_need": need["work"], "owner": owner, "by": initiator.mind.id,
		"builders": [], "started": w.time_min}})
	st["plan_note"] = "Строим %s: %s" % [target_name(choice), reason]
	initiator.mind.remember(w.time_min, "plan", "Предложил%s построить %s — %s" % [initiator.g("", "а"), target_name(choice), reason], 0.7)
	w.log_event("%s предлагает построить %s: %s" % [initiator.mind.name, target_name(choice), reason])

static func _exists_near(w, t: String, p: Vector3, rad: float) -> bool:
	for o in w.objects_near(p, rad):
		if o.obj_type == t or (o.obj_type == "site" and o.ext.get("target", "") == t):
			return true
	return false

static func _find_spot(w, t: String, c: Vector3):
	var ring: Array = {"hut": [4.0, 12.0], "campfire": [0.0, 2.5], "storage": [3.0, 8.0], "bush": [5.0, 15.0], "well": [2.0, 7.0]}[t]
	var rng: RandomNumberGenerator = w._rng
	for attempt in 40:
		var a := rng.randf() * TAU
		var d := rng.randf_range(float(ring[0]), float(ring[1]) + attempt * 0.15)
		var p := c + Vector3(cos(a), 0, sin(a)) * d
		if w.can_place(t, p) != "" or not w.nav.is_walkable(p):
			continue
		var gap: float = 3.4 if t in ["hut", "storage"] else 2.0
		var ok := true
		for o in w.objects_near(p, gap):
			if o.obj_type in ["hut", "storage", "well", "site", "campfire"]:
				ok = false
				break
		if ok:
			return p
	return null

static func _assign_homes(w) -> void:
	var keys: Array = households(w)
	for o in w.objects.values():
		if o.obj_type == "hut" and int(o.ext.get("owner", -1)) >= 0 and int(o.ext["owner"]) not in keys:
			o.ext["owner"] = -1   # семья распалась или умерла — дом свободен
	for key in keys:
		var has := false
		for o in w.objects.values():
			if o.obj_type == "hut" and int(o.ext.get("owner", -1)) == key:
				has = true
				break
		if has:
			continue
		for o in w.objects_near(center(w), 30.0):
			if o.obj_type == "hut" and int(o.ext.get("owner", -1)) < 0:
				o.ext["owner"] = key
				w.log_event("Семья «%s» занимает свободную хижину" % household_label(w, key))
				break

# ---------------------------------------------------------------- работа жителя

## Стройка, на которую этому жителю стоит пойти (своя хижина — в первую очередь).
static func pick_site(r):
	var w = r.world
	var key := household_of(w, r.mind)
	var best = null
	var bd := INF
	for s in sites(w):
		if r.unreachable.has(s.obj_id):
			continue
		var d: float = s.position.distance_to(r.sim_pos)
		if int(s.ext.get("owner", -1)) == key:
			d -= 40.0
		if d < bd:
			bd = d
			best = s
	return best

static func remaining(s, mat: String) -> int:
	return maxi(0, int(s.ext.get("need_" + mat, 0)) - int(s.ext.get(mat, 0)))

## План стройки: добыть недостающий материал → принести → строить.
static func plan_for(r, s) -> Array:
	var m = r.mind
	var w = r.world
	var go_site := {"a": "go", "x": s.position.x, "z": s.position.z, "obj": s.obj_id, "near": 1.6, "quiet": true}
	for mat in ["wood", "stone"]:
		if remaining(s, mat) <= 0:
			continue
		if int(m.carry.get(mat, 0)) > 0:
			return [go_site, {"a": "deliver", "obj": s.obj_id, "mat": mat}]
		var src = nearest_source(r, "tree" if mat == "wood" else "rock")
		if src == null:
			continue
		return [{"a": "go", "x": src.position.x, "z": src.position.z, "obj": src.obj_id, "near": 1.9, "quiet": true},
			{"a": "chop", "obj": src.obj_id, "mat": mat}, go_site, {"a": "deliver", "obj": s.obj_id, "mat": mat}]
	if remaining(s, "wood") > 0 or remaining(s, "stone") > 0:
		return []
	return [go_site, {"a": "build", "obj": s.obj_id, "dur": 30.0}]

static func nearest_source(r, t: String):
	var w = r.world
	var best = null
	var bd := INF
	for o in w.objects_near(r.sim_pos, 30.0):
		if o.obj_type != t or o.burning > 0.0 or o.amount < 1.0 or r.unreachable.has(o.obj_id):
			continue
		if r.mind.is_in_danger_zone(o.position, w.time_min):
			continue
		var d: float = o.position.distance_to(r.sim_pos)
		if d < bd:
			bd = d
			best = o
	return best

static func complete(w, s) -> void:
	var t: String = s.ext["target"]
	var pos: Vector3 = s.position
	var owner: int = int(s.ext.get("owner", -1))
	var builders: Array = s.ext.get("builders", [])
	w.remove_object(s.obj_id, false)
	var data := {"ext": {"built_by": builders.duplicate(), "owner": owner, "built_at": w.time_min}}
	if t == "bush":
		data["amount"] = 1.0
		data["ext"]["planted"] = true
	if t == "storage":
		data["amount"] = 0.0
	var o = w.add_object(t, pos, data)
	var names: Array = []
	for id in builders:
		var bm = w.mind_by_id(int(id))
		if bm != null:
			names.append(bm.name)
			bm.remember(w.time_min, "built", "Мы построили %s" % target_name(t), 0.8 if t != "bush" else 0.4)
			bm.mood = minf(100.0, bm.mood + 8.0)
	w.settlement["built"] = int(w.settlement["built"]) + 1
	w.stats["built"] = int(w.stats.get("built", 0)) + 1
	var tail := (" для семьи «%s»" % household_label(w, owner)) if owner >= 0 else ""
	w.log_event("%s: %s %s%s" % [", ".join(names) if not names.is_empty() else "Жители", "сажают" if t == "bush" else "достроили", target_name(t), tail])
	for r in w.residents:
		if r.mind.alive and r.sim_pos.distance_to(pos) < 14.0:
			r.mind.know_place(o.obj_id, t, pos, o.amount, w.time_min)
	_update_level(w)

static func built_count(w, t: String) -> int:
	var n := 0
	for o in w.objects.values():
		if o.obj_type == t and not o.ext.get("built_by", []).is_empty():
			n += 1
	return n

static func _update_level(w) -> void:
	var st: Dictionary = w.settlement
	var huts := built_count(w, "hut")
	var lvl := 0
	if int(st["built"]) >= 3: lvl = 1
	if huts >= 3 and built_count(w, "storage") >= 1: lvl = 2
	if huts >= 6 and built_count(w, "well") >= 1: lvl = 3
	if lvl > int(st["level"]):
		if st["name"] == "":
			st["name"] = NAMES[w._rng.randi() % NAMES.size()]
			st["founded_at"] = w.time_min
			for r in w.residents:
				if r.mind.alive:
					r.mind.remember(w.time_min, "founded", "Мы основали поселение «%s»" % st["name"], 1.0)
			w.log_event("Основано поселение «%s»" % st["name"])
		else:
			w.log_event("«%s» растёт: теперь это %s" % [st["name"], LEVELS[lvl].to_lower()])
		st["level"] = lvl

## Раз в день: часть запасов в амбаре портится.
static func daily(w) -> void:
	for o in w.objects.values():
		if o.obj_type == "storage" and o.amount > 0.0:
			o.amount = maxf(0.0, o.amount - maxf(1.0, o.amount * 0.05))
			o.refresh_visual()

static func level_name(w) -> String:
	return LEVELS[int(w.settlement["level"])]
