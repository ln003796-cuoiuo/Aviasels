extends RefCounted
## Семьи и поколения: пары, беременность, рождение, наследование, уход за детьми,
## взросление, старение, болезни, традиции рода. Работает поверх общего состояния мира.

const Mind = preload("res://scripts/residents/mind.gd")

const MAX_POP := 30               # предел одновременно живущих (производительность телефона)
const PREGNANCY_YEARS := 0.75
const MIN_BIRTH_GAP_YEARS := 1.5
const CONCEPTION_PER_H := 0.045
const NEWCOMER_CHANCE := 0.1     # в день, если взрослому не с кем создать семью

const TRADITIONS := {
	"hut_sleep": {"name": "Ночевать в хижине", "desc": "род предпочитает спать под крышей; ночь под открытым небом портит настроение"},
	"evening_fire": {"name": "Вечера у костра", "desc": "по вечерам род собирается у костра"},
	"share_finds": {"name": "Делиться находками", "desc": "о найденной еде и воде сразу рассказывают другим"},
}
const TRADITION_THRESHOLD := {"hut_sleep": ["hut_nights", 5], "evening_fire": ["fire_evenings", 4], "share_finds": ["shared", 5]}

const NAMES_M := ["Арт", "Илан", "Тар", "Нико", "Бор", "Ром", "Ден", "Лев", "Кай", "Мир", "Ян", "Олег", "Тим", "Гор", "Сав",
	"Эрик", "Влас", "Демид", "Зар", "Лука", "Марк", "Остап", "Пётр", "Рэм", "Степан", "Устин", "Федот", "Юрий"]
const NAMES_F := ["Лия", "Мира", "Ая", "Сана", "Вера", "Нея", "Рая", "Тая", "Ида", "Ника", "Яра", "Злата", "Кира", "Лада",
	"Майя", "Ольга", "Полина", "Роза", "Софья", "Ульяна", "Фрея", "Хельга", "Эля", "Юна", "Алина", "Дана", "Есения", "Жанна"]

const ILLNESSES := ["лихорадка", "простуда", "отравление", "кашель"]

# ---------------------------------------------------------------- родство

static func parents_of(m) -> Array:
	var out: Array = []
	if m.mother_id >= 0: out.append(m.mother_id)
	if m.father_id >= 0: out.append(m.father_id)
	return out

static func is_close_relative(w, a, b) -> bool:
	if a.id == b.id:
		return true
	var pa := parents_of(a)
	var pb := parents_of(b)
	if b.id in pa or a.id in pb:
		return true                      # родитель и ребёнок
	for p in pa:
		if p in pb:
			return true                  # братья и сёстры (в т.ч. сводные)
	for p in pa:
		var pm = w.mind_by_id(p)
		if pm != null and b.id in parents_of(pm):
			return true                  # бабушка/дедушка
	for p in pb:
		var pm2 = w.mind_by_id(p)
		if pm2 != null and a.id in parents_of(pm2):
			return true
	return false

static func can_pair(w, a, b) -> bool:
	return a.alive and b.alive and a.is_adult() and b.is_adult() and a.sex != b.sex \
		and a.partner_id < 0 and b.partner_id < 0 and absf(a.age_years - b.age_years) < 18.0 \
		and not is_close_relative(w, a, b)

static func relation_to(w, me, other_id: int) -> String:
	var o = w.mind_by_id(other_id)
	if o == null:
		return ""
	var f: bool = o.sex == "f"
	if me.partner_id == other_id: return "жена" if f else "муж"
	if other_id == me.mother_id: return "мать"
	if other_id == me.father_id: return "отец"
	if other_id in me.children: return "дочь" if f else "сын"
	for p in parents_of(me):
		if p in parents_of(o): return "сестра" if f else "брат"
		var pm = w.mind_by_id(p)
		if pm != null and other_id in parents_of(pm): return "бабушка" if f else "дедушка"
	for c in me.children:
		var cm = w.mind_by_id(c)
		if cm != null and other_id in cm.children: return "внучка" if f else "внук"
	return ""

# ---------------------------------------------------------------- пары

## Вызывается после успешного обмена репликами.
static func on_talk(w, ra_res, rb_res, rel_a: Dictionary, rel_b: Dictionary) -> void:
	var a = ra_res.mind
	var b = rb_res.mind
	# обучение: старший родственник передаёт опыт младшему
	for pair in [[a, b], [b, a]]:
		var elder = pair[0]
		var young = pair[1]
		if not young.is_adult() and (young.mother_id == elder.id or young.father_id == elder.id or elder.is_adult()):
			var k: float = 0.08 if (young.mother_id == elder.id or young.father_id == elder.id) else 0.04
			for s in elder.skills:
				var diff: float = float(elder.skills[s]) - float(young.skills.get(s, 0.0))
				if diff > 0.0:
					young.add_skill(s, diff * k)
	if not can_pair(w, a, b):
		return
	if float(rel_a["affinity"]) < 30.0 or float(rel_b["affinity"]) < 30.0:
		return
	var attraction: float = 0.6 + 0.4 * (1.0 - absf(a.traits["curiosity"] - b.traits["curiosity"]))
	attraction *= 0.6 + (a.mood + b.mood) / 250.0
	for r in [rel_a, rel_b]:
		r["romance"] = clampf(float(r.get("romance", 0.0)) + 3.0 * attraction, 0.0, 100.0)
	if float(rel_a["romance"]) >= 60.0 and float(rel_b["romance"]) >= 60.0 and float(rel_a["affinity"]) >= 50.0 and float(rel_b["affinity"]) >= 50.0:
		form_couple(w, ra_res, rb_res)

static func form_couple(w, ra, rb) -> void:
	var a = ra.mind
	var b = rb.mind
	a.partner_id = b.id
	b.partner_id = a.id
	a.mood = minf(100.0, a.mood + 15.0)
	b.mood = minf(100.0, b.mood + 15.0)
	a.remember(w.time_min, "couple", "Мы с %s стали парой" % b.name, 1.0)
	b.remember(w.time_min, "couple", "Мы с %s стали парой" % a.name, 1.0)
	ra.say("Давай всегда будем вместе.")
	rb.say("Да. Теперь мы семья.")
	w.stats["couples"] = int(w.stats.get("couples", 0)) + 1
	w.log_event("%s и %s создают семью" % [a.name, b.name])

static func on_death(w, dead) -> void:
	if dead.partner_id >= 0:
		var p = w.mind_by_id(dead.partner_id)
		if p != null and p.alive and p.partner_id == dead.id:
			p.partner_id = -1
			p.remember(w.time_min, "widow", "Не стало %s — %s" % [dead.name, "моего мужа" if dead.sex == "m" else "моей жены"], 1.0)
			p.mood = maxf(0.0, p.mood - 25.0)

# ---------------------------------------------------------------- рождение

## Ежечасная проверка зачатия и родов.
static func hourly(w, h: float) -> void:
	var alive: int = w.alive_count()
	for r in w.residents.duplicate():
		var m = r.mind
		if not m.alive or m.sex != "f":
			continue
		if m.pregnant:
			if w.time_min >= m.pregnancy_due:
				give_birth(w, r)
			continue
		if m.partner_id < 0 or alive >= MAX_POP:
			continue
		var p = w.resident_by_id(m.partner_id)
		if p == null or not p.mind.alive:
			continue
		if m.age_years < 17.0 or m.age_years > 42.0 or p.mind.age_years < 17.0:
			continue
		if w.time_min - m.last_birth < MIN_BIRTH_GAP_YEARS * Mind.YEAR_MIN:
			continue
		if m.health < 50.0 or m.food < 35.0 or p.mind.food < 35.0 or m.is_sick(w.time_min):
			continue
		if r.sim_pos.distance_to(p.sim_pos) > 6.0:
			continue
		var fert: float = 1.0 - clampf((m.age_years - 17.0) / 25.0, 0.0, 1.0) * 0.7
		var crowd: float = clampf(1.0 - float(alive) / MAX_POP, 0.0, 1.0)
		var food_supply: float = clampf(float(w.count_type("bush")) * 3.0 / maxf(1.0, alive * 6.0), 0.15, 1.0)
		var together: float = 1.6 if (m.sleeping and p.mind.sleeping) else 1.0
		if r.rng.randf() < CONCEPTION_PER_H * h * fert * crowd * food_supply * together:
			m.pregnant = true
			m.pregnancy_father = p.mind.id
			m.pregnancy_due = w.time_min + PREGNANCY_YEARS * Mind.YEAR_MIN
			m.remember(w.time_min, "pregnant", "Я жду ребёнка", 0.95)
			p.mind.remember(w.time_min, "pregnant", "%s ждёт нашего ребёнка" % m.name, 0.95)
			w.log_event("%s ждёт ребёнка от %s" % [m.name, p.mind.name])
			r.refresh_model()

static func give_birth(w, mother_res) -> void:
	var mo = mother_res.mind
	var fa = w.mind_by_id(mo.pregnancy_father)
	mo.pregnant = false
	mo.last_birth = w.time_min
	mo.health = maxf(10.0, mo.health - 15.0)
	mo.energy = maxf(0.0, mo.energy - 30.0)
	var child = create_child(w, mother_res, fa)
	mother_res.refresh_model()
	var c = child.mind
	var word := "дочь" if c.sex == "f" else "сын"
	w.log_event("У %s и %s родился %s %s (поколение %d)" % [_gen(mo.name), _gen(fa.name) if fa else "?", "дочь" if c.sex == "f" else "сын", c.name, c.generation] if c.sex == "m" else
		"У %s и %s родилась дочь %s (поколение %d)" % [_gen(mo.name), _gen(fa.name) if fa else "?", c.name, c.generation])
	mo.remember(w.time_min, "birth_child", "У меня родился ребёнок: %s — %s" % [word, c.name], 1.0)
	if fa:
		fa.remember(w.time_min, "birth_child", "У меня родился ребёнок: %s — %s" % [word, c.name], 1.0)
	for sid in mo.children:
		var s = w.mind_by_id(sid)
		if s != null and s.alive and s.id != c.id:
			s.remember(w.time_min, "sibling", "У меня появил%s %s %s" % ["ась" if c.sex == "f" else "ся", "сестра" if c.sex == "f" else "брат", c.name], 0.7)

## Родительный падеж для журнала («у Евы», «у Адама»).
static func _gen(n: String) -> String:
	if n.ends_with("а"): return n.substr(0, n.length() - 1) + "ы"
	if n.ends_with("я"): return n.substr(0, n.length() - 1) + "и"
	if n.ends_with("й") or n.ends_with("ь"): return n.substr(0, n.length() - 1) + "я"
	return n + "а"

static func create_child(w, mother_res, fa):
	var mo = mother_res.mind
	var rng: RandomNumberGenerator = mother_res.rng
	var sex := "f" if rng.randf() < 0.5 else "m"
	var traits := {}
	for t in mo.traits:
		var a: float = float(mo.traits[t])
		var b: float = float(fa.traits.get(t, a)) if fa else a
		traits[t] = clampf(lerpf(a, b, rng.randf()) + rng.randfn(0.0, 0.07), 0.05, 0.95)
	var ap: Dictionary = mo.appearance
	var fap: Dictionary = fa.appearance if fa else ap
	var appearance := {
		"skin": Color(ap.get("skin", "#e0b48c")).lerp(Color(fap.get("skin", "#e0b48c")), rng.randf()).to_html(false),
		"hair": (ap if rng.randf() < 0.5 else fap).get("hair", "#3b2414"),
		"shirt": Color.from_hsv(rng.randf(), 0.5, 0.75).to_html(false),
		"pants": Color.from_hsv(rng.randf(), 0.35, 0.4).to_html(false),
		"height": clampf((float(ap.get("height", 0.95)) + float(fap.get("height", 1.0))) / 2.0 + rng.randfn(0.0, 0.025) + (0.04 if sex == "m" else -0.02), 0.86, 1.1),
	}
	var gen: int = maxi(mo.generation, fa.generation if fa else 0) + 1
	var data := {
		"id": w.next_resident_id, "name": unique_name(w, sex, rng), "sex": sex, "age_years": 0.0,
		"x": mother_res.sim_pos.x + 0.6, "z": mother_res.sim_pos.z + 0.4,
		"food": 90.0, "water": 90.0, "energy": 90.0, "social": 80.0, "mood": 80.0, "health": 100.0,
		"traits": traits, "appearance": appearance,
		"mother_id": mo.id, "father_id": fa.id if fa else -1, "generation": gen,
		"family_name": fa.family_name if fa and fa.family_name != "" else mo.family_name,
		"born_at": w.time_min, "lifespan": 52.0 + traits["vitality"] * 28.0 + rng.randf_range(-5.0, 5.0),
		"long_goal": ["Вырасти сильным" if sex == "m" else "Вырасти сильной", "Узнать весь мир", "Создать свою семью", "Заботиться о родных"][rng.randi() % 4],
	}
	w.next_resident_id += 1
	var child = w.add_resident(data)
	var c = child.mind
	c.remember(w.time_min, "born", "Родил%s. Мама — %s%s" % [child.g("ся", "ась"), mo.name, (", папа — " + fa.name) if fa else ""], 1.0)
	mo.children.append(c.id)
	if fa:
		fa.children.append(c.id)
	for pm in [mo, fa]:
		if pm == null:
			continue
		var r1: Dictionary = c.rel(pm.id, pm.name)
		r1["affinity"] = 60.0
		r1["familiarity"] = 40.0
		var r2: Dictionary = pm.rel(c.id, c.name)
		r2["affinity"] = 70.0
		r2["familiarity"] = 40.0
		pm.mood = minf(100.0, pm.mood + 20.0)
	w.stats["births"] = int(w.stats.get("births", 0)) + 1
	return child

static func unique_name(w, sex: String, rng: RandomNumberGenerator) -> String:
	var pool: Array = NAMES_F if sex == "f" else NAMES_M
	var used := {}
	for r in w.residents:
		if r.mind.alive:
			used[r.mind.name] = true
	var start := rng.randi() % pool.size()
	for i in pool.size():
		var n: String = pool[(start + i) % pool.size()]
		if not used.has(n):
			return n
	var base: String = pool[start]
	var k := 2
	while used.has("%s %d" % [base, k]):
		k += 1
	return "%s %d" % [base, k]

# ---------------------------------------------------------------- приток людей извне

## Если взрослому одинокому жителю не с кем создать семью (все вокруг — родня),
## иногда из-за пределов карты приходит чужак противоположного пола.
## Возвращает пришедшего жителя или null.
static func maybe_newcomer(w, rng: RandomNumberGenerator, force: bool = false):
	if w.alive_count() >= MAX_POP:
		return null
	var lonely = null
	for r in w.residents:
		var m = r.mind
		if not m.alive or not m.is_adult() or m.partner_id >= 0 or m.age_years > 45.0:
			continue
		var has_option := false
		for o in w.residents:
			if o != r and can_pair(w, m, o.mind):
				has_option = true
				break
		if not has_option:
			lonely = r
			break
	if lonely == null:
		return null
	if not force and rng.randf() > NEWCOMER_CHANCE:
		return null
	var sex: String = "f" if lonely.mind.sex == "m" else "m"
	var pos := Vector3.ZERO
	for attempt in 30:
		var a := rng.randf() * TAU
		var p := Vector3(cos(a), 0, sin(a)) * rng.randf_range(26.0, 38.0)
		if w.nav.is_walkable(p) and w.terrain.height_at(p.x, p.z) > 0.3:
			pos = p
			break
	var age: float = rng.randf_range(17.0, 26.0)
	var vit: float = rng.randf_range(0.35, 0.85)
	var skins := ["#f1c9a5", "#e0b48c", "#c68e63", "#8d5a3b", "#5c3a24"]
	var hairs := ["#2b1a10", "#4a2c17", "#8a5a2b", "#c9a36a", "#1a1a1a"]
	var nm: String = unique_name(w, sex, rng)
	var data := {
		"id": w.next_resident_id, "name": nm, "sex": sex, "age_years": age, "x": pos.x, "z": pos.z,
		"food": 85.0, "water": 90.0, "energy": 80.0, "social": 30.0, "mood": 60.0, "health": 100.0,
		"family_name": nm, "generation": 1, "born_at": w.time_min - age * Mind.YEAR_MIN,
		"lifespan": 52.0 + vit * 28.0 + rng.randf_range(-4.0, 4.0),
		"traits": {"curiosity": rng.randf_range(0.2, 0.9), "caution": rng.randf_range(0.2, 0.9),
			"sociability": rng.randf_range(0.3, 0.95), "calm": rng.randf_range(0.25, 0.9), "vitality": vit},
		"appearance": {"skin": skins[rng.randi() % 5], "hair": hairs[rng.randi() % 5],
			"shirt": Color.from_hsv(rng.randf(), 0.5, 0.75).to_html(false),
			"pants": Color.from_hsv(rng.randf(), 0.35, 0.4).to_html(false),
			"height": rng.randf_range(0.95, 1.05) if sex == "m" else rng.randf_range(0.9, 0.98)},
		"long_goal": ["Найти новый дом", "Создать свою семью", "Узнать здешние места"][rng.randi() % 3],
	}
	w.next_resident_id += 1
	var nr = w.add_resident(data)
	nr.mind.remember(w.time_min, "arrive", "Приш%s издалека в эти земли" % nr.g("ёл", "ла"), 1.0)
	# путник шёл вдоль воды — знает ближайший родник
	var best = null
	for o in w.objects.values():
		if o.obj_type == "spring" and (best == null or o.position.distance_to(pos) < best.position.distance_to(pos)):
			best = o
	if best != null:
		nr.mind.know_place(best.obj_id, "spring", best.position, 0.0, w.time_min)
	w.stats["newcomers"] = int(w.stats.get("newcomers", 0)) + 1
	w.log_event("Издалека пришл%s %s — %s" % [nr.g("", "а"), "новый человек" if sex == "m" else "новая женщина", nm])
	return nr

# ---------------------------------------------------------------- возраст, болезни, традиции

## Вызывается раз в игровой день для каждого живого жителя.
static func daily(w, r) -> void:
	var m = r.mind
	# болезни
	if not m.is_sick(w.time_min):
		var p: float = 0.015
		if m.stage() == "elder": p += 0.05
		if m.stage() == "baby": p += 0.02
		if m.food < 30.0 or m.water < 30.0: p += 0.05
		p *= 1.2 - float(m.traits.get("vitality", 0.5)) * 0.8
		if r.rng.randf() < p:
			m.illness = ILLNESSES[r.rng.randi() % ILLNESSES.size()]
			m.sick_until = w.time_min + r.rng.randf_range(16.0, 40.0) * 60.0
			m.remember(w.time_min, "sick", "Заболел%s: %s" % [r.g("", "а"), m.illness], 0.75)
			w.log_event("%s заболевает (%s)" % [m.name, m.illness])
	# традиции из привычек
	if m.age_years >= 12.0:
		for t in TRADITION_THRESHOLD:
			var th: Array = TRADITION_THRESHOLD[t]
			if t not in m.traditions and int(m.habit.get(th[0], 0)) >= int(th[1]):
				m.traditions.append(t)
				m.remember(w.time_min, "tradition", "Появилась привычка: %s" % TRADITIONS[t]["name"].to_lower(), 0.8)
				w.log_event("У %s складывается традиция «%s»" % [_gen(m.name), TRADITIONS[t]["name"]])

## Переход между возрастными этапами.
static func on_stage_change(w, r, old_stage: String, new_stage: String) -> void:
	var m = r.mind
	match new_stage:
		"child":
			m.remember(w.time_min, "grow", "Научил%s ходить и говорить" % r.g("ся", "ась"), 0.7)
		"teen":
			# перенять традиции родителей
			for pid in parents_of(m):
				var pm = w.mind_by_id(pid)
				if pm == null:
					continue
				for t in pm.traditions:
					if t not in m.traditions:
						m.traditions.append(t)
						m.remember(w.time_min, "tradition", "Перенял%s традицию рода: %s" % [r.g("", "а"), TRADITIONS[t]["name"].to_lower()], 0.85)
						w.log_event("%s перенимает традицию «%s» от %s" % [m.name, TRADITIONS[t]["name"], _gen(pm.name)])
			m.remember(w.time_min, "grow", "Стал%s подростком" % r.g("", "а"), 0.75)
		"adult":
			m.remember(w.time_min, "grow", "Стал%s взросл%s" % [r.g("", "а"), r.g("ым", "ой")], 0.9)
			w.log_event("%s взрослеет (%d лет)" % [m.name, int(m.age_years)])
		"elder":
			m.remember(w.time_min, "grow", "Пришла старость", 0.85)
			w.log_event("%s %s" % [m.name, r.g("становится стариком", "становится старушкой")])
	r.refresh_model()

## Ребёнок становится самостоятельным — родители показывают ему окрестности.
static func on_independent(w, r) -> void:
	var m = r.mind
	var n := 0
	for pid in parents_of(m):
		var pm = w.mind_by_id(pid)
		if pm == null or not pm.alive:
			continue
		for k in pm.known_places:
			if not m.known_places.has(k):
				m.known_places[k] = pm.known_places[k].duplicate()
				n += 1
	if n > 0:
		m.remember(w.time_min, "learn", "Родители показали мне окрестности (мест: %d)" % n, 0.8)

# ---------------------------------------------------------------- уход за детьми

## Дети, о которых этот житель должен позаботиться прямо сейчас.
static func care_targets(r) -> Array:
	var m = r.mind
	var w = r.world
	if m.age_years < 13.0 or m.is_sick(w.time_min):
		return []
	var out: Array = []
	for c in w.residents:
		var cm = c.mind
		if c == r or not cm.alive or not cm.is_dependent():
			continue
		if cm.food >= 55.0 and cm.water >= 55.0:
			continue
		var is_parent: bool = cm.mother_id == m.id or cm.father_id == m.id
		if not is_parent:
			# чужих детей кормят, только если родителей рядом нет
			var parent_alive := false
			for pid in parents_of(cm):
				var pr = w.resident_by_id(pid)
				if pr != null and pr.mind.alive and not pr.mind.is_sick(w.time_min):
					parent_alive = true
			if parent_alive and not is_close_relative(w, m, cm):
				continue
			if parent_alive and "share_finds" not in m.traditions:
				continue
		var busy_by: int = int(c.get_meta("care_by", -1))
		var busy_until: float = float(c.get_meta("care_until", 0.0))
		if busy_by >= 0 and busy_by != m.id and busy_until > w.time_min:
			continue
		out.append(c)
	return out
