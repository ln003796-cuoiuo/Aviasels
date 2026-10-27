extends RefCounted
## Принятие решений жителя: потребности -> оценка целей (utility) -> план действий.
## Работает только с общим состоянием мира, без случайного выбора анимаций.

const Defs = preload("res://scripts/core/object_defs.gd")
const Family = preload("res://scripts/residents/family.gd")
const Settlement = preload("res://scripts/core/settlement.gd")

const PERCEPTION := 11.0

# Изменение потребностей за игровой час
const FOOD_PER_H := 4.5
const WATER_PER_H := 7.0
const ENERGY_PER_H := 4.5
const SOCIAL_PER_H := 3.5

static func update_needs(r, hours: float) -> void:
	var m = r.mind
	var w = r.world
	# окружение пересчитывается раз в 3 игровые минуты (экономия на телефоне)
	r.env_t -= hours * 60.0
	if r.env_t <= 0.0:
		r.env_t = 3.0
		r.env_fire = false
		r.env_campfire = false
		for o in w.objects_near(r.sim_pos, 4.0):
			if o.is_dangerous() and o.position.distance_to(r.sim_pos) < 2.6:
				r.env_fire = true
			if o.obj_type == "campfire":
				r.env_campfire = true
	var near_fire: bool = r.env_fire
	var near_campfire: bool = r.env_campfire
	var sleep_mul: float = 0.55 if m.sleeping else 1.0
	var st: String = m.stage()
	var body_mul: float = {"baby": 0.7, "child": 0.85, "teen": 1.0, "adult": 1.0, "elder": 0.9}.get(st, 1.0)
	if m.pregnant: body_mul *= 1.2
	m.food = clampf(m.food - FOOD_PER_H * hours * sleep_mul * body_mul, 0.0, 100.0)
	m.water = clampf(m.water - WATER_PER_H * hours * sleep_mul * body_mul, 0.0, 100.0)
	if m.sleeping:
		var in_hut: bool = r.current_step().get("obj", -1) >= 0
		m.energy = clampf(m.energy + (22.0 if in_hut else 13.0) * hours, 0.0, 100.0)
	else:
		var walk_extra: float = 2.0 if r.is_moving else 0.0
		var tire: float = 1.3 if st in ["baby", "elder"] else 1.0
		if m.pregnant or m.is_sick(w.time_min): tire *= 1.25
		m.energy = clampf(m.energy - (ENERGY_PER_H + walk_extra) * tire * hours, 0.0, 100.0)
	if r.talk_partner_id < 0:
		m.social = clampf(m.social - SOCIAL_PER_H * hours * (0.5 + m.traits["sociability"]), 0.0, 100.0)
	# здоровье
	var dmg := 0.0
	if m.food <= 0.0: dmg += 6.0
	if m.water <= 0.0: dmg += 9.0
	if m.energy <= 0.0: dmg += 2.0
	if near_fire: dmg += 40.0
	var sick: bool = m.is_sick(w.time_min)
	if sick:
		dmg += 0.7 if m.sleeping else 1.4
	if m.age_years >= m.lifespan:
		dmg += 4.0 + (m.age_years - m.lifespan) * 4.0   # тело изнашивается
	if dmg > 0.0:
		m.health = clampf(m.health - dmg * hours, 0.0, 100.0)
	elif m.food > 30.0 and m.water > 30.0 and m.energy > 20.0:
		m.health = clampf(m.health + (1.0 if st == "elder" else 2.5) * hours, 0.0, 100.0)
	if not sick and m.illness != "":
		m.remember(w.time_min, "recover", r.g("Выздоровел", "Выздоровела") + " (" + m.illness + ")", 0.5)
		m.illness = ""
	# настроение тянется к общему благополучию
	var target: float = m.food * 0.22 + m.water * 0.22 + m.energy * 0.18 + m.social * 0.18 + m.health * 0.2
	if near_campfire: target += 12.0
	if near_fire: target -= 40.0
	if m.is_in_danger_zone(r.sim_pos, w.time_min): target -= 15.0
	if sick: target -= 10.0
	target += (m.traits["calm"] - 0.5) * 10.0
	m.mood = clampf(lerpf(m.mood, target, clampf(0.15 * hours, 0.0, 1.0)), 0.0, 100.0)

## Восприятие: обновить знания о ближайших объектах и людях, заметить исчезнувшее.
static func perceive(r) -> void:
	var m = r.mind
	var w = r.world
	var radius: float = PERCEPTION + m.traits["curiosity"] * 4.0
	if w.is_night():
		radius *= 0.6
	var seen := {}
	for o in w.objects_near(r.sim_pos, radius):
		seen[str(o.obj_id)] = true
		if o.is_dangerous():
			var until: float = w.time_min + 60.0 * (6.0 + 6.0 * m.traits["caution"])
			if not m.is_in_danger_zone(o.position, w.time_min):
				m.remember(w.time_min, "danger", r.g("Увидел", "Увидела") + " огонь — опасное место", 0.8)
				w.log_event("%s замечает пожар и запоминает опасное место" % m.name)
			m.add_danger(o.position, 5.0 + 3.0 * m.traits["caution"], until)
		if o.obj_type in ["bush", "spring", "hut", "campfire", "storage", "well"]:
			var is_new: bool = m.know_place(o.obj_id, o.obj_type, o.position, o.amount, w.time_min)
			if is_new:
				m.add_skill("исследование", 1.5)
				if o.obj_type != "bush" or m.places_of("bush").size() <= 3:
					m.remember(w.time_min, "discover", r.g("Нашёл", "Нашла") + ": " + Defs.display_name(o.obj_type).to_lower(), 0.45 if o.obj_type == "bush" else 0.6)
				if o.obj_type in ["spring"] or (o.obj_type == "hut" and o.ext.get("built_by", []).is_empty()):
					w.log_event("%s находит %s" % [m.name, "родник" if o.obj_type == "spring" else "хижину"])
	# известные места в поле зрения, которых больше нет
	for key in m.known_places.keys():
		var p: Dictionary = m.known_places[key]
		var pos := Vector3(p["x"], 0, p["z"])
		var flat := Vector2(r.sim_pos.x - pos.x, r.sim_pos.z - pos.z).length()
		if flat < radius * 0.8 and not seen.has(key):
			m.forget_place(int(key))
			var what: String = Defs.display_name(p["type"]).to_lower()
			m.remember(w.time_min, "loss", "Знакомое место исчезло: " + what, 0.8 if p["type"] == "spring" else 0.55)
			m.mood = maxf(0.0, m.mood - (12.0 if p["type"] == "spring" else 5.0))
			w.log_event("%s обнаруживает, что пропало знакомое место: %s" % [m.name, what])
	# другие жители
	for other in w.residents:
		if other == r or not other.mind.alive:
			continue
		if other.sim_pos.distance_to(r.sim_pos) < radius:
			var rel: Dictionary = m.rel(other.mind.id, other.mind.name)
			if float(rel["familiarity"]) <= 0.0:
				rel["familiarity"] = 1.0
				rel["last"] = w.time_min
				m.remember(w.time_min, "meet", r.g("Впервые встретил ", "Впервые встретила ") + other.mind.name, 0.9)

# ---------------------------------------------------------------- выбор цели

## Возвращает массив кандидатов {goal, u, reason}.
static func evaluate(r) -> Array:
	var m = r.mind
	var w = r.world
	var out: Array = []
	# 1. опасность рядом — бежать
	var danger = w.nearest_danger(r.sim_pos, 6.0 + 4.0 * m.traits["caution"])
	if danger != null:
		out.append({"goal": "flee", "u": 10.0, "reason": "Рядом огонь — нужно уйти в безопасное место"})
	var water_need: float = (100.0 - m.water) / 100.0
	var food_need: float = (100.0 - m.food) / 100.0
	var energy_need: float = (100.0 - m.energy) / 100.0
	if m.is_dependent():
		_evaluate_child(r, out, energy_need)
		return out
	out.append({"goal": "drink", "u": water_need * water_need * 1.6 + (0.6 if m.water < 25.0 else 0.0),
		"reason": "Хочется пить (вода %d%%)" % int(m.water)})
	out.append({"goal": "eat", "u": food_need * food_need * 1.5 + (0.5 if m.food < 25.0 else 0.0),
		"reason": "Голод (сытость %d%%)" % int(m.food)})
	var night_bonus := 0.0
	if (w.is_night() or ("hut_sleep" in m.traditions and w.hour_f() >= 20.0)) and m.energy < 85.0:
		night_bonus = 0.55
	if m.is_sick(w.time_min):
		night_bonus += 0.35
	out.append({"goal": "sleep", "u": energy_need * energy_need * 1.4 + night_bonus + (0.6 if m.energy < 15.0 else 0.0),
		"reason": ("Ночь, пора спать" if night_bonus > 0.0 else "Усталость") + " (энергия %d%%)" % int(m.energy)})
	var partner = _best_partner(r) if w.time_min >= r.talk_cooldown_until else null
	if partner != null:
		var soc: float = (100.0 - m.social) / 100.0 * (0.35 + 0.8 * m.traits["sociability"])
		var rel: Dictionary = m.rel(partner.mind.id, partner.mind.name)
		soc += clampf(float(rel["affinity"]) / 200.0, -0.2, 0.25)
		if w.is_night(): soc *= 0.3
		out.append({"goal": "socialize", "u": soc, "reason": "Хочется пообщаться с %s" % partner.mind.name, "target": partner.mind.id})
	if not m.places_of("campfire").is_empty():
		if m.mood < 55.0:
			out.append({"goal": "rest", "u": (55.0 - m.mood) / 55.0 * 0.8 + 0.1, "reason": "Плохое настроение — отдохнуть у костра"})
		elif "evening_fire" in m.traditions and w.hour_f() >= 18.0 and w.hour_f() < 21.0:
			out.append({"goal": "rest", "u": 0.5, "reason": "Традиция рода — вечер у костра"})
	# стройка и запасы — общее дело поселения
	if m.age_years >= 14.0 and not m.is_sick(w.time_min):
		var dil: float = float(m.traits.get("diligence", 0.5))
		var work_mul: float = 0.25 if w.is_night() else 1.0
		if m.pregnant or m.stage() == "elder": work_mul *= 0.6
		var site = Settlement.pick_site(r)
		if site != null:
			var own: bool = int(site.ext.get("owner", -1)) == Settlement.household_of(w, m)
			out.append({"goal": "build", "u": (0.3 + dil * 0.3 + (0.15 if own else 0.0)) * work_mul, "target": site.obj_id,
				"reason": ("Строим свой дом" if own else "Поселению нужен %s" % Settlement.target_name(site.ext.get("target", "")).replace("хижину", "дом").replace("грядку", "огород"))})
		var stores: Array = m.places_of("storage")
		if not stores.is_empty() and m.food > 55.0:
			var stv: Dictionary = stores[0]
			var so = w.get_object(int(stv["id"]))
			if so != null and so.amount < minf(Settlement.STORAGE_CAP, w.alive_count() * 4.0):
				out.append({"goal": "stock", "u": (0.22 + dil * 0.25) * work_mul, "target": so.obj_id, "reason": "Запасти еду в амбар"})
	# забота о детях
	var kids: Array = Family.care_targets(r)
	if not kids.is_empty():
		var kid = kids[0]
		for k in kids:
			if minf(k.mind.food, k.mind.water) < minf(kid.mind.food, kid.mind.water):
				kid = k
		var low: float = minf(kid.mind.food, kid.mind.water)
		var cu: float = pow((100.0 - low) / 100.0, 2.0) * 1.6 + 0.35 + (0.6 if low < 25.0 else 0.0)
		var who: String = Family.relation_to(w, m, kid.mind.id)
		out.append({"goal": "care", "u": cu, "target": kid.mind.id,
			"reason": "%s %s хочет %s" % [who.capitalize() if who != "" else "Ребёнок", kid.mind.name, "есть" if kid.mind.food <= kid.mind.water else "пить"]})
	var explore: float = 0.12 + m.traits["curiosity"] * 0.3
	if m.places_of("spring").is_empty() or m.places_of("bush").is_empty():
		explore += 0.25
	if w.is_night(): explore *= 0.3
	out.append({"goal": "explore", "u": explore, "reason": "Любопытно, что вокруг" if m.traits["curiosity"] > 0.5 else "Нужно лучше знать окрестности"})
	return out

static func _best_partner(r):
	var best = null
	var best_score := -INF
	for o in r.world.residents:
		if o == r or not o.mind.alive or o.mind.sleeping or o.mind.goal == "flee":
			continue
		if o.talk_partner_id >= 0 and o.talk_partner_id != r.mind.id:
			continue
		var rel: Dictionary = r.mind.rel(o.mind.id, o.mind.name)
		if float(rel["affinity"]) < -60.0:
			continue
		var score: float = float(rel["affinity"]) - o.sim_pos.distance_to(r.sim_pos)
		if o.mind.id == r.mind.partner_id:
			score += 25.0
		elif float(rel.get("romance", 0.0)) > 0.0 and Family.can_pair(r.world, r.mind, o.mind):
			score += 10.0 + float(rel["romance"]) * 0.3
		if score > best_score:
			best_score = score
			best = o
	return best

## Цели маленьких детей: держаться рядом со взрослыми, спать, играть; кормят их родители.
static func _evaluate_child(r, out: Array, energy_need: float) -> void:
	var m = r.mind
	var w = r.world
	var night_bonus: float = 0.6 if (w.is_night() and m.energy < 90.0) else 0.0
	out.append({"goal": "sleep", "u": energy_need * energy_need * 1.6 + night_bonus + (0.6 if m.energy < 15.0 else 0.0),
		"reason": "Малыш устал" if m.stage() == "baby" else "Пора спать"})
	var cg = caregiver_of(r)
	if cg != null:
		var d: float = cg.sim_pos.distance_to(r.sim_pos)
		out.append({"goal": "follow", "u": 0.15 + clampf((d - 2.5) / 6.0, 0.0, 1.2), "target": cg.mind.id,
			"reason": "Держаться рядом: %s" % cg.mind.name})
		if m.stage() != "baby" and not w.is_night():
			out.append({"goal": "play", "u": 0.2 + m.traits["curiosity"] * 0.25, "target": cg.mind.id, "reason": "Хочется поиграть"})
	if m.age_years >= 4.0:
		# подросший ребёнок уже может сам сорвать ягоды или попить рядом
		for pair in [["drink", "spring", m.water], ["eat", "bush", m.food]]:
			var near: Array = _sorted_places(r, pair[1]).filter(func(p): return Vector2(p["x"] - r.sim_pos.x, p["z"] - r.sim_pos.z).length() < 8.0)
			if not near.is_empty() and float(pair[2]) < 60.0:
				out.append({"goal": pair[0], "u": pow((100.0 - float(pair[2])) / 100.0, 2.0) * 1.4, "reason": "Рядом есть " + ("вода" if pair[0] == "drink" else "ягоды")})
	if m.stage() != "baby" and w.time_min >= r.talk_cooldown_until:
		var partner = _best_partner(r)
		if partner != null and partner.sim_pos.distance_to(r.sim_pos) < 8.0 and not w.is_night():
			out.append({"goal": "socialize", "u": (100.0 - m.social) / 100.0 * 0.6, "reason": "Поговорить с %s" % partner.mind.name, "target": partner.mind.id})

## Кто присматривает за ребёнком: мать, отец, родственник или ближайший взрослый.
static func caregiver_of(r):
	var m = r.mind
	var w = r.world
	for pid in [m.mother_id, m.father_id]:
		var p = w.resident_by_id(pid)
		if p != null and p.mind.alive:
			return p
	var best = null
	var bd := INF
	for o in w.residents:
		if o == r or not o.mind.alive or o.mind.age_years < 13.0:
			continue
		var d: float = o.sim_pos.distance_to(r.sim_pos) - (30.0 if Family.is_close_relative(w, m, o.mind) else 0.0)
		if d < bd:
			bd = d
			best = o
	return best

static func decide(r) -> void:
	var m = r.mind
	var cands := evaluate(r)
	cands.sort_custom(func(a, b): return a["u"] > b["u"])
	for c in cands:
		var plan := build_plan(r, c)
		if not plan.is_empty():
			if m.goal != c["goal"]:
				r.world.trace("%s: цель «%s» (%s)" % [m.name, goal_name(c["goal"]), c["reason"]])
			m.goal = c["goal"]
			m.goal_reason = c["reason"]
			r.set_plan(plan, float(c["u"]))
			return
	m.goal = "idle"
	m.goal_reason = "Не видит, чем заняться"
	r.set_plan([{"a": "look", "dur": 20.0}], 0.0)

static func goal_name(g: String) -> String:
	return {"flee": "спастись от огня", "drink": "попить", "eat": "поесть", "sleep": "поспать",
		"socialize": "пообщаться", "rest": "отдохнуть у костра", "explore": "исследовать",
		"idle": "осмотреться", "talk": "разговор", "care": "позаботиться о ребёнке", "follow": "держаться рядом",
		"play": "поиграть", "build": "строить", "stock": "запасти еду"}.get(g, g)

## Построить план для цели. Пустой план — цель сейчас недостижима.
static func build_plan(r, c: Dictionary) -> Array:
	var m = r.mind
	var w = r.world
	match c["goal"]:
		"flee":
			var d = w.nearest_danger(r.sim_pos, 20.0)
			if d == null:
				return []
			var away: Vector3 = (r.sim_pos - d.position)
			away.y = 0
			if away.length() < 0.1:
				away = Vector3(1, 0, 0)
			var target: Vector3 = r.sim_pos + away.normalized() * 12.0
			return [{"a": "go", "x": target.x, "z": target.z, "run": true, "near": 2.0}]
		"drink":
			return _plan_resource(r, "spring", "drink", 10.0)
		"eat":
			return _plan_resource(r, "bush", "eat", 15.0)
		"care":
			var kid = w.resident_by_id(int(c.get("target", -1)))
			if kid == null:
				return []
			var need: String = "food" if kid.mind.food <= kid.mind.water else "water"
			var plan: Array = []
			if int(m.carry.get(need, 0)) <= 0:
				var src: Array = _sorted_places(r, "bush" if need == "food" else "spring")
				if src.is_empty():
					return []
				var sp: Dictionary = src[0]
				plan.append({"a": "go", "x": sp["x"], "z": sp["z"], "obj": sp["id"], "near": 1.6 if need == "food" else 1.9})
				plan.append({"a": "gather", "obj": sp["id"], "need": need})
			plan.append({"a": "go", "rid": kid.mind.id, "near": 1.3})
			plan.append({"a": "feed", "rid": kid.mind.id, "need": need})
			kid.set_meta("care_by", m.id)
			kid.set_meta("care_until", w.time_min + 150.0)
			return plan
		"follow":
			return [{"a": "go", "rid": c.get("target", -1), "near": 2.0}, {"a": "look", "dur": 15.0}]
		"build":
			var site = w.get_object(int(c.get("target", -1)))
			if site == null:
				return []
			return Settlement.plan_for(r, site)
		"stock":
			var so = w.get_object(int(c.get("target", -1)))
			if so == null:
				return []
			var bushes: Array = m.places_of("bush").filter(func(p): return p["type"] == "bush" and float(p["amount"]) >= 2.0 and not r.unreachable.has(int(p["id"])))
			if bushes.is_empty():
				return []
			var pos: Vector3 = r.sim_pos
			bushes.sort_custom(func(a, b): return Vector2(a["x"] - pos.x, a["z"] - pos.z).length() < Vector2(b["x"] - pos.x, b["z"] - pos.z).length())
			var bp: Dictionary = bushes[0]
			var plan2: Array = []
			if int(m.carry.get("food", 0)) <= 0:
				plan2.append({"a": "go", "x": bp["x"], "z": bp["z"], "obj": bp["id"], "near": 1.6})
				plan2.append({"a": "gather", "obj": bp["id"], "need": "food"})
			plan2.append({"a": "go", "x": so.position.x, "z": so.position.z, "obj": so.obj_id, "near": 2.0, "quiet": true})
			plan2.append({"a": "deposit", "obj": so.obj_id})
			return plan2
		"play":
			var cg = w.resident_by_id(int(c.get("target", -1)))
			if cg == null:
				return []
			var a: float = r.rng.randf() * TAU
			var pt: Vector3 = cg.sim_pos + Vector3(cos(a), 0, sin(a)) * r.rng.randf_range(2.0, 5.0)
			if not w.nav.is_walkable(pt):
				return []
			return [{"a": "go", "x": pt.x, "z": pt.z, "near": 1.0, "explore": true}, {"a": "look", "dur": 8.0}]
		"sleep":
			if m.is_dependent():
				var cg2 = caregiver_of(r)
				if cg2 != null and cg2.mind.sleeping and int(cg2.current_step().get("obj", -1)) >= 0:
					var hid: int = int(cg2.current_step()["obj"])
					var ho = w.get_object(hid)
					if ho != null:
						return [{"a": "go", "x": ho.position.x, "z": ho.position.z, "obj": hid, "near": 2.2}, {"a": "sleep", "obj": hid}]
				return [{"a": "sleep", "obj": -1}]
			var huts: Array = _sorted_places(r, "hut")
			var pr = w.resident_by_id(m.partner_id)
			if pr != null and pr.mind.alive and pr.mind.sleeping and int(pr.current_step().get("obj", -1)) >= 0:
				var phid: int = int(pr.current_step()["obj"])
				for i in huts.size():
					if int(huts[i]["id"]) == phid:
						var hh: Dictionary = huts[i]
						huts.remove_at(i)
						huts.push_front(hh)
						break
			var home = Settlement.home_of(w, m)
			if home != null and (pr == null or not pr.mind.sleeping):
				for i in huts.size():
					if int(huts[i]["id"]) == home.obj_id:
						var hm: Dictionary = huts[i]
						huts.remove_at(i)
						huts.push_front(hm)
						break
			if not huts.is_empty():
				var h: Dictionary = huts[0]
				return [{"a": "go", "x": h["x"], "z": h["z"], "obj": h["id"], "near": 2.2}, {"a": "sleep", "obj": h["id"]}]
			return [{"a": "sleep", "obj": -1}]
		"socialize":
			return [{"a": "go", "rid": c.get("target", -1), "near": 1.8}, {"a": "talk_request", "rid": c.get("target", -1)}]
		"rest":
			var fires: Array = _sorted_places(r, "campfire")
			if fires.is_empty():
				return []
			var f: Dictionary = fires[0]
			return [{"a": "go", "x": f["x"], "z": f["z"], "obj": f["id"], "near": 1.6}, {"a": "rest", "obj": f["id"], "dur": 60.0}]
		"explore":
			var t = _explore_target(r)
			if t == null:
				return []
			return [{"a": "go", "x": t.x, "z": t.z, "near": 1.5, "explore": true}, {"a": "look", "dur": 10.0}]
	return []

static func _sorted_places(r, t: String) -> Array:
	var m = r.mind
	var arr: Array = m.places_of(t)
	arr = arr.filter(func(p): return not m.is_in_danger_zone(Vector3(p["x"], 0, p["z"]), r.world.time_min) and not r.unreachable.has(int(p["id"])))
	if t == "bush":
		arr = arr.filter(func(p): return float(p["amount"]) >= 1.0 or r.world.time_min - float(p["seen"]) > 6.0 * 60.0)
	var pos: Vector3 = r.sim_pos
	arr.sort_custom(func(a, b): return Vector2(a["x"] - pos.x, a["z"] - pos.z).length() < Vector2(b["x"] - pos.x, b["z"] - pos.z).length())
	return arr

static func _plan_resource(r, t: String, act: String, dur: float) -> Array:
	var places := _sorted_places(r, t)
	if places.is_empty():
		# не знает источника — идти искать
		var target = _explore_target(r)
		if target == null:
			return []
		r.mind.action_text = "Ищет " + ("воду" if t == "spring" else "еду")
		return [{"a": "go", "x": target.x, "z": target.z, "near": 1.5, "explore": true, "seek": t}]
	var p: Dictionary = places[0]
	return [{"a": "go", "x": p["x"], "z": p["z"], "obj": p["id"], "near": 1.6 if t == "bush" else 1.9}, {"a": act, "obj": p["id"], "dur": dur}]

static func _explore_target(r):
	var w = r.world
	var m = r.mind
	var rng: RandomNumberGenerator = r.rng
	var best = null
	var best_score := -INF
	var max_dist: float = 10.0 + m.traits["curiosity"] * 14.0 - m.traits["caution"] * 4.0
	for i in 10:
		var a := rng.randf() * TAU
		var dist := rng.randf_range(5.0, max_dist)
		var p: Vector3 = r.sim_pos + Vector3(cos(a), 0, sin(a)) * dist
		if absf(p.x) > 46.0 or absf(p.z) > 46.0:
			continue
		if not w.nav.is_walkable(p) or m.is_in_danger_zone(p, w.time_min):
			continue
		# предпочитаем места дальше от уже известных объектов
		var novelty := 0.0
		for k in m.known_places:
			var kp: Dictionary = m.known_places[k]
			novelty += minf(20.0, Vector2(kp["x"] - p.x, kp["z"] - p.z).length())
		novelty /= maxf(1.0, m.known_places.size())
		var score := novelty + rng.randf() * 6.0
		if score > best_score:
			best_score = score
			best = p
	return best

# ---------------------------------------------------------------- диалоги

static func dialogue(r, other, topic: String, extra: String = "") -> String:
	var m = r.mind
	match topic:
		"ask":
			return ["Поговорим?", "Можно с тобой поговорить, %s?" % other.mind.name][r.rng.randi() % 2]
		"greet":
			return ["Привет! Я %s." % m.name, "Здравствуй, меня зовут %s." % m.name][r.rng.randi() % 2]
		"share":
			return "Я знаю, где %s. Пойдём покажу!" % extra
		"hungry":
			return r.g("Я так проголодался...", "Я так проголодалась...")
		"thirsty":
			return "Очень хочется пить."
		"tired":
			return "Я совсем без сил."
		"fire":
			return "Там огонь! Будь осторожн%s." % ("ой" if other.mind.sex == "f" else "ым")
		"happy":
			return ["Хороший сегодня день.", "Как здесь красиво!", "Рад%s тебя видеть, %s." % ["а" if m.sex == "f" else "", other.mind.name]][r.rng.randi() % 3]
		"quarrel":
			return ["Оставь меня в покое!", "Ты опять за своё?", "Не хочу сейчас говорить."][r.rng.randi() % 3]
		"refuse":
			return "Не сейчас, мне нужно %s." % extra
		"loss":
			return "Ты знаешь, пропало место: %s..." % extra
	return "..."
