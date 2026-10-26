extends Node3D
## Житель: связывает разум (Mind + Brain) с 3D-моделью и выполняет план действий в мире.

const Mind = preload("res://scripts/residents/mind.gd")
const Brain = preload("res://scripts/residents/brain.gd")
const CharacterModel = preload("res://scripts/residents/character_model.gd")
const M = preload("res://scripts/core/meshes.gd")
const Defs = preload("res://scripts/core/object_defs.gd")
const Family = preload("res://scripts/residents/family.gd")

const WALK_SPEED := 0.5   # единиц мира за игровую минуту
const RUN_SPEED := 0.95

var mind = Mind.new()
var world                 # GameWorld
var sim_pos := Vector3.ZERO
var rng := RandomNumberGenerator.new()
var is_moving := false
var talk_partner_id := -1
var unreachable := {}     # obj_id -> до какого времени не пытаться
var talk_cooldown_until := 0.0

var _path := PackedVector3Array()
var _pathed := false
var _repath_t := 0.0
var _step_t := 0.0
var _percept_t := 0.0
var _think_t := 0.0
var _plan_urgency := 0.0
var _exchange_t := 0.0
var _shared_this_talk := false
var _stage := ""
var env_t := 0.0
var env_fire := false
var env_campfire := false
var _was_dependent := false
var _model_pregnant := false

var model
var _label: Label3D
var _bubble: Label3D
var _bubble_time := 0.0
var _ring: MeshInstance3D
var selected := false:
	set(v):
		selected = v
		if _ring: _ring.visible = v

func setup(w, data: Dictionary) -> void:
	world = w
	mind.from_dict(data)
	sim_pos = Vector3(float(data.get("x", 0.0)), 0, float(data.get("z", 0.0)))
	sim_pos.y = world.terrain.height_at(sim_pos.x, sim_pos.z)
	position = sim_pos
	rng.seed = hash(str(world.seed_value) + mind.name + str(mind.id))
	name = "Resident_%d" % mind.id
	_stage = mind.stage()
	_was_dependent = mind.is_dependent()
	_build_visual()
	if not mind.alive:
		model.set_dead_look()
		_label.text = mind.name + " †"

func to_dict() -> Dictionary:
	var d: Dictionary = mind.to_dict()
	d["x"] = sim_pos.x
	d["z"] = sim_pos.z
	return d

## Имя в дательном падеже («Адаму», «Еве»).
func dative() -> String:
	var n: String = mind.name
	if n.ends_with("а") or n.ends_with("я"):
		return n.substr(0, n.length() - 1) + "е"
	if mind.sex == "m":
		return n + "у"
	return n

## Склонение по полу: g("пошёл", "пошла")
func g(male: String, female: String) -> String:
	return female if mind.sex == "f" else male

func current_step() -> Dictionary:
	return mind.plan[0] if not mind.plan.is_empty() else {}

func set_plan(plan: Array, urgency: float) -> void:
	mind.plan = plan
	_plan_urgency = urgency
	_path = PackedVector3Array()
	_pathed = false
	_step_t = 0.0
	_think_t = 15.0
	if mind.sleeping and (plan.is_empty() or plan[0]["a"] != "sleep"):
		mind.sleeping = false
	_update_action_text()

# ---------------------------------------------------------------- симуляция

func sim_step(dt: float) -> void:
	if not mind.alive:
		return
	mind.age_years += dt / Mind.YEAR_MIN
	var st: String = mind.stage()
	if st != _stage:
		var old := _stage
		_stage = st
		Family.on_stage_change(world, self, old, st)
	if _was_dependent and not mind.is_dependent():
		_was_dependent = false
		Family.on_independent(world, self)
	Brain.update_needs(self, dt / 60.0)
	if mind.health <= 0.0:
		_die()
		return
	_percept_t -= dt
	if _percept_t <= 0.0:
		_percept_t = 5.0
		Brain.perceive(self)
		mind.cleanup(world.time_min)
		var step := current_step()
		# найден искомый ресурс — перестроить план
		if step.get("seek", "") != "" and not mind.places_of(step["seek"]).is_empty():
			Brain.decide(self)
		elif mind.goal != "flee" and world.nearest_danger(sim_pos, 6.0 + 4.0 * mind.traits["caution"]) != null:
			_end_talk(false)
			Brain.decide(self)
	if mind.plan.is_empty():
		Brain.decide(self)
	_think_t -= dt
	if _think_t <= 0.0:
		_think_t = 15.0
		_reconsider()
	_execute(dt)

func _reconsider() -> void:
	var cands: Array = Brain.evaluate(self)
	var top = null
	for c in cands:
		if top == null or c["u"] > top["u"]:
			top = c
	if top == null or top["goal"] == mind.goal:
		return
	var margin := 0.35 if mind.goal != "talk" else 0.55
	if mind.sleeping:
		margin = 0.6
	if float(top["u"]) > _plan_urgency + margin:
		_end_talk(false)
		mind.sleeping = false
		Brain.decide(self)

func _execute(dt: float) -> void:
	is_moving = false
	if mind.plan.is_empty():
		return
	var step: Dictionary = mind.plan[0]
	match step["a"]:
		"go":
			_do_go(step, dt)
		"eat", "drink":
			_do_consume(step, dt)
		"sleep":
			_do_sleep(step, dt)
		"talk_request":
			_do_talk_request(step)
		"talk":
			_do_talk(step, dt)
		"rest":
			var o = world.get_object(int(step["obj"]))
			if o == null:
				_fail_place(int(step["obj"]), "campfire")
				return
			mind.mood = minf(100.0, mind.mood + 8.0 * dt / 60.0)
			_step_t += dt
			if _step_t >= float(step["dur"]):
				mind.add_skill("выживание", 0.5)
				if world.hour_f() >= 17.0 or world.hour_f() < 1.0:
					mind.habit["fire_evenings"] = int(mind.habit.get("fire_evenings", 0)) + 1
				_advance()
		"look":
			_step_t += dt
			if _step_t >= float(step["dur"]):
				_advance()
		"gather":
			_do_gather(step, dt)
		"feed":
			_do_feed(step)
		_:
			_advance()

func _advance() -> void:
	if not mind.plan.is_empty():
		mind.plan.remove_at(0)
	_path = PackedVector3Array()
	_pathed = false
	_step_t = 0.0
	_update_action_text()

func _fail(reason: String) -> void:
	world.trace("%s: план сорван — %s" % [mind.name, reason])
	mind.plan = []
	mind.sleeping = false
	_path = PackedVector3Array()
	_pathed = false

func _fail_place(obj_id: int, t: String) -> void:
	if mind.known_places.has(str(obj_id)):
		mind.forget_place(obj_id)
		mind.remember(world.time_min, "loss", g("Пришёл", "Пришла") + ", а там больше нет: " + Defs.display_name(t).to_lower(), 0.7)
		mind.mood = maxf(0.0, mind.mood - 8.0)
		world.log_event("%s не находит на месте: %s" % [mind.name, Defs.display_name(t).to_lower()])
	_fail("объект исчез")

func _target_of(step: Dictionary):
	if step.has("rid"):
		var other = world.resident_by_id(int(step["rid"]))
		if other == null or not other.mind.alive:
			return null
		return other.sim_pos
	return Vector3(float(step["x"]), 0.0, float(step["z"]))

func _do_go(step: Dictionary, dt: float) -> void:
	var target = _target_of(step)
	if target == null:
		_fail("цель недоступна")
		return
	if step.has("obj") and world.get_object(int(step["obj"])) == null and _flat_dist(target) < 9.0:
		_fail_place(int(step["obj"]), mind.known_places.get(str(step["obj"]), {}).get("type", "bush"))
		return
	var near := float(step.get("near", 1.2))
	if _flat_dist(target) <= near:
		_advance()
		return
	_repath_t -= dt
	if not _pathed or (step.has("rid") and _repath_t <= 0.0):
		_path = world.nav.find_path(sim_pos, target)
		_pathed = true
		_repath_t = 5.0
		if _path.is_empty():
			if step.has("obj"):
				unreachable[int(step["obj"])] = world.time_min + 180.0
				mind.remember(world.time_min, "blocked", "Не смог%s пройти к цели — путь перекрыт" % g("", "ла"), 0.4)
			_fail("нет пути")
			return
	var speed := (RUN_SPEED if step.get("run", false) else WALK_SPEED) * dt * speed_factor()
	if mind.energy < 15.0:
		speed *= 0.7
	while speed > 0.0 and not _path.is_empty():
		var p: Vector3 = _path[0]
		var to := Vector3(p.x - sim_pos.x, 0, p.z - sim_pos.z)
		var d := to.length()
		if d <= speed:
			sim_pos.x = p.x
			sim_pos.z = p.z
			speed -= d
			_path.remove_at(0)
		else:
			sim_pos += to / d * speed
			speed = 0.0
		is_moving = true
	sim_pos.y = world.terrain.height_at(sim_pos.x, sim_pos.z)
	if _path.is_empty():
		if _flat_dist(target) <= near + 1.2 or step.has("explore"):
			_advance()
		elif step.has("rid"):
			_pathed = false
		else:
			_advance()

## Скорость зависит от возраста, беременности и болезни.
func speed_factor() -> float:
	var f: float = {"baby": 0.6, "child": 0.85, "teen": 1.0, "adult": 1.0, "elder": 0.75}.get(mind.stage(), 1.0)
	if mind.pregnant: f *= 0.85
	if mind.is_sick(world.time_min): f *= 0.8
	return f

## Набрать еду/воду, чтобы отнести ребёнку.
func _do_gather(step: Dictionary, dt: float) -> void:
	var o = world.get_object(int(step["obj"]))
	var need: String = step["need"]
	if o == null:
		_fail_place(int(step["obj"]), "bush" if need == "food" else "spring")
		return
	_step_t += dt
	if _step_t < 8.0:
		return
	if need == "food":
		var got: int = o.take_food(2)
		mind.know_place(o.obj_id, o.obj_type, o.position, o.amount, world.time_min)
		if got <= 0:
			_fail("ягод нет")
			return
		mind.carry["food"] = int(mind.carry.get("food", 0)) + got
		mind.add_skill("собирательство", 0.6)
	else:
		mind.carry["water"] = 2
	_advance()

## Накормить/напоить ребёнка.
func _do_feed(step: Dictionary) -> void:
	var c = world.resident_by_id(int(step["rid"]))
	var need: String = step["need"]
	if c == null or not c.mind.alive:
		mind.carry[need] = 0
		_fail("ребёнка нет рядом")
		return
	var n: int = int(mind.carry.get(need, 0))
	if n <= 0:
		_fail("нечего дать")
		return
	if need == "food":
		c.mind.food = minf(100.0, c.mind.food + n * 22.0)
	else:
		c.mind.water = minf(100.0, c.mind.water + n * 30.0)
	mind.carry[need] = 0
	mind.add_skill("забота", 1.0)
	c.remove_meta("care_by")
	var rc: Dictionary = c.mind.rel(mind.id, mind.name)
	rc["affinity"] = minf(100.0, float(rc["affinity"]) + 2.0)
	rc["familiarity"] = minf(100.0, float(rc["familiarity"]) + 1.0)
	var who: String = Family.relation_to(world, c.mind, mind.id)
	c.mind.remember(world.time_min, "cared", "%s %s меня" % [(who.capitalize() + " " if who != "" else "") + mind.name, ("накормил" if need == "food" else "напоил") + g("", "а")], 0.3)
	say("Держи, %s." % c.mind.name if need == "food" else "Попей, %s." % c.mind.name)
	world.stats["feedings"] = int(world.stats.get("feedings", 0)) + 1
	_advance()

func _flat_dist(p: Vector3) -> float:
	return Vector2(p.x - sim_pos.x, p.z - sim_pos.z).length()

func _do_consume(step: Dictionary, dt: float) -> void:
	var o = world.get_object(int(step["obj"]))
	var t: String = "bush" if step["a"] == "eat" else "spring"
	if o == null:
		_fail_place(int(step["obj"]), t)
		return
	if step["a"] == "eat" and o.amount < 1.0:
		mind.know_place(o.obj_id, o.obj_type, o.position, 0.0, world.time_min)
		mind.remember(world.time_min, "empty", "Куст пуст — ягоды кончились", 0.35)
		_fail("ягод нет")
		return
	_step_t += dt
	if _step_t < float(step["dur"]):
		return
	if step["a"] == "eat":
		var got: int = o.take_food(2)
		mind.food = minf(100.0, mind.food + got * 19.0)
		mind.add_skill("собирательство", 1.0)
		mind.know_place(o.obj_id, o.obj_type, o.position, o.amount, world.time_min)
		if mind.food < 70.0 and o.amount >= 1.0:
			_step_t = 0.0  # ещё порцию
			return
	else:
		mind.water = 100.0
		mind.add_skill("выживание", 0.3)
	_advance()

func _do_sleep(step: Dictionary, dt: float) -> void:
	var obj_id := int(step.get("obj", -1))
	if obj_id >= 0 and world.get_object(obj_id) == null:
		mind.sleeping = false
		_fail_place(obj_id, "hut")
		return
	if not mind.sleeping:
		mind.sleeping = true
		if obj_id >= 0 and _step_t == 0.0:
			mind.add_skill("выживание", 0.2)
	_step_t += dt
	var wake: bool = mind.energy >= 99.0 or (mind.energy >= 75.0 and not world.is_night())
	if mind.water < 12.0 or mind.food < 10.0:
		wake = true
	if wake:
		mind.sleeping = false
		if _step_t > 120.0 and obj_id >= 0:
			mind.mood = minf(100.0, mind.mood + 6.0)
			mind.habit["hut_nights"] = int(mind.habit.get("hut_nights", 0)) + 1
		elif _step_t > 120.0 and "hut_sleep" in mind.traditions:
			mind.mood = maxf(0.0, mind.mood - 6.0)
		_advance()

func _do_talk_request(step: Dictionary) -> void:
	var other = world.resident_by_id(int(step["rid"]))
	if other == null or not other.mind.alive:
		_fail("собеседника нет")
		return
	var answer: String = other.request_talk(self)
	if answer == "":
		var dur := 30.0 + rng.randf() * 30.0
		start_talk(other, true, dur)
		other.start_talk(self, false, dur)
	else:
		var rel: Dictionary = mind.rel(other.mind.id, other.mind.name)
		if answer != "спать":
			rel["affinity"] = float(rel["affinity"]) - 1.0
		talk_cooldown_until = world.time_min + 90.0
		say(Brain.dialogue(self, other, "ask"))
		other.say(Brain.dialogue(other, self, "refuse", answer))
		mind.remember(world.time_min, "refused", "%s не захотел%s говорить: %s" % [other.mind.name, other.g("", "а"), answer], 0.3)
		mind.social = maxf(0.0, mind.social - 3.0)
		_fail("отказ")

## Пустая строка — согласие; иначе причина отказа.
func request_talk(from) -> String:
	if not mind.alive:
		return "нет"
	if mind.sleeping:
		return "спать"
	if mind.goal == "flee":
		return "уйти от огня"
	if talk_partner_id >= 0:
		return "закончить разговор"
	if _plan_urgency > 0.85 and mind.goal in ["drink", "eat"]:
		return "сначала " + ("попить" if mind.goal == "drink" else "поесть")
	var rel: Dictionary = mind.rel(from.mind.id, from.mind.name)
	if float(rel["affinity"]) < -40.0 and mind.traits["calm"] < 0.5:
		return "побыть одн" + g("ому", "ой")
	return ""

func start_talk(other, lead: bool, dur: float) -> void:
	talk_partner_id = other.mind.id
	mind.goal = "talk"
	mind.goal_reason = "Разговаривает с %s" % other.mind.name
	set_plan([{"a": "talk", "rid": other.mind.id, "dur": dur, "lead": lead}], 0.5)
	_exchange_t = 0.0
	_shared_this_talk = false
	_face(other.sim_pos)

func _do_talk(step: Dictionary, dt: float) -> void:
	var other = world.resident_by_id(int(step["rid"]))
	if other == null or not other.mind.alive or other.talk_partner_id != mind.id:
		_end_talk(false)
		return
	_face(other.sim_pos)
	mind.social = minf(100.0, mind.social + 25.0 * dt / 60.0)
	_step_t += dt
	if step.get("lead", false):
		_exchange_t -= dt
		if _exchange_t <= 0.0:
			_exchange_t = 10.0
			if not _exchange(other):
				return
	if _step_t >= float(step["dur"]):
		_end_talk(true)

## Один обмен репликами. Возвращает false, если разговор прервался ссорой.
func _exchange(other) -> bool:
	var a = mind
	var b = other.mind
	var ra: Dictionary = a.rel(b.id, b.name)
	var rb: Dictionary = b.rel(a.id, a.name)
	var first: bool = int(ra["talks"]) == 0
	var compat: float = 1.0 - absf(a.traits["sociability"] - b.traits["sociability"]) * 0.5 - absf(a.traits["calm"] - b.traits["calm"]) * 0.3
	var mood_f: float = (a.mood + b.mood) / 200.0
	var calm_avg: float = (a.traits["calm"] + b.traits["calm"]) / 2.0
	var aff_guard: float = 1.0 - clampf(float(ra["affinity"]) / 100.0, 0.0, 0.85)
	var quarrel_p: float = 0.22 * clampf(1.2 - mood_f * 1.4, 0.0, 1.0) * (1.0 - calm_avg) * aff_guard
	if a.food < 25.0 or a.water < 25.0 or a.energy < 20.0:
		quarrel_p += 0.08  # голодный и уставший легче срывается
	if not first and rng.randf() < quarrel_p:
		for pair in [[a, ra, b, other], [b, rb, a, self]]:
			pair[1]["affinity"] = float(pair[1]["affinity"]) - 7.0
			pair[0].mood = maxf(0.0, pair[0].mood - 8.0)
			pair[0].remember(world.time_min, "quarrel", "Поссорились с %s" % pair[2].name, 0.7)
		say(Brain.dialogue(self, other, "quarrel"))
		other.say(Brain.dialogue(other, self, "quarrel"))
		world.log_event("%s и %s поссорились" % [a.name, b.name])
		_end_talk(false)
		return false
	var before_a: String = Mind.relation_label(float(ra["affinity"]), float(ra["familiarity"]))
	var delta: float = 1.1 * compat * (0.5 + mood_f)
	for r in [ra, rb]:
		r["affinity"] = clampf(float(r["affinity"]) + delta, -100.0, 100.0)
		r["familiarity"] = minf(100.0, float(r["familiarity"]) + 3.0)
		r["talks"] = int(r["talks"]) + 1
		r["last"] = world.time_min
	a.add_skill("общение", 0.8)
	b.add_skill("общение", 0.8)
	if first:
		say(Brain.dialogue(self, other, "greet"))
		other.say(Brain.dialogue(other, self, "greet"))
		a.remember(world.time_min, "talk", "Познакомил%s с %s" % [g("ся", "ась"), b.name], 0.85)
		b.remember(world.time_min, "talk", "Познакомил%s с %s" % [other.g("ся", "ась"), a.name], 0.85)
		world.log_event("%s и %s знакомятся" % [a.name, b.name])
	else:
		# поделиться знанием о месте, которого собеседник не знает
		var shared := false
		for key in (a.known_places if not _shared_this_talk else {}):
			var p: Dictionary = a.known_places[key]
			if not b.known_places.has(key) and p["type"] in ["spring", "bush", "hut", "campfire"] and not world.get_object(int(key)) == null:
				b.known_places[key] = p.duplicate()
				var what: String = {"spring": "родник", "bush": "ягодный куст", "hut": "хижина", "campfire": "костёр"}[p["type"]]
				say(Brain.dialogue(self, other, "share", what))
				b.remember(world.time_min, "learn", "%s рассказал%s, где %s" % [a.name, g("", "а"), what], 0.5)
				world.log_event("%s рассказывает %s, где %s" % [a.name, other.dative(), what])
				a.habit["shared"] = int(a.habit.get("shared", 0)) + 1
				shared = true
				_shared_this_talk = true
				break
		if not shared:
			var topic := "happy"
			if a.water < 35.0: topic = "thirsty"
			elif a.food < 35.0: topic = "hungry"
			elif a.energy < 25.0: topic = "tired"
			elif not a.danger_zones.is_empty(): topic = "fire"
			say(Brain.dialogue(self, other, topic))
			other.say(Brain.dialogue(other, self, "happy"))
	var after_a: String = Mind.relation_label(float(ra["affinity"]), float(ra["familiarity"]))
	if after_a != before_a and after_a in ["Приятели", "Друзья", "Близкие люди"]:
		a.remember(world.time_min, "bond", "Мы с %s теперь: %s" % [b.name, after_a.to_lower()], 0.9)
		b.remember(world.time_min, "bond", "Мы с %s теперь: %s" % [a.name, after_a.to_lower()], 0.9)
		world.log_event("%s и %s теперь %s" % [a.name, b.name, after_a.to_lower()])
	Family.on_talk(world, self, other, ra, rb)
	return true

func _end_talk(_normal: bool) -> void:
	if talk_partner_id < 0:
		return
	var other = world.resident_by_id(talk_partner_id)
	talk_partner_id = -1
	if mind.goal == "talk":
		mind.plan = []
		mind.goal = "idle"
	if other != null and other.talk_partner_id == mind.id:
		other._end_talk(_normal)

func _die() -> void:
	mind.alive = false
	mind.plan = []
	mind.sleeping = false
	mind.action_text = "Умер" if mind.sex == "m" else "Умерла"
	var cause := "от ран"
	if mind.age_years >= mind.lifespan:
		cause = "от старости"
	elif mind.water <= 0.0:
		cause = "от жажды"
	elif mind.food <= 0.0:
		cause = "от голода"
	elif mind.is_sick(world.time_min):
		cause = "от болезни (%s)" % mind.illness
	mind.cause_of_death = cause
	mind.died_at = world.time_min
	mind.pregnant = false
	mind.remember(world.time_min, "death", "Смерть " + cause, 1.0)
	world.on_resident_died(self, cause)
	_end_talk(false)
	if model:
		model.set_dead_look()
		_label.text = mind.name + " †"

func _face(p: Vector3) -> void:
	var d := Vector2(p.x - sim_pos.x, p.z - sim_pos.z)
	if d.length() > 0.05:
		rotation.y = atan2(d.x, d.y)

func _update_action_text() -> void:
	var step := current_step()
	var a: String = step.get("a", "")
	match a:
		"go":
			if step.get("run", false): mind.action_text = "Убегает от огня"
			elif step.has("seek"): mind.action_text = "Ищет " + ("воду" if step["seek"] == "spring" else "еду")
			elif step.has("rid"):
				var o = world.resident_by_id(int(step["rid"]))
				if mind.goal == "care":
					mind.action_text = "Несёт еду: " + (o.mind.name if o else "ребёнку")
				elif mind.goal == "follow":
					mind.action_text = "Идёт за: " + (o.mind.name if o else "родными")
				else:
					mind.action_text = "Идёт к " + (o.mind.name if o else "собеседнику")
			elif step.get("explore", false): mind.action_text = "Исследует местность"
			else: mind.action_text = "Идёт: " + Brain.goal_name(mind.goal)
		"eat": mind.action_text = "Ест ягоды"
		"drink": mind.action_text = "Пьёт воду"
		"sleep": mind.action_text = "Спит" + (" в хижине" if int(step.get("obj", -1)) >= 0 else " на земле")
		"talk":
			var o2 = world.resident_by_id(int(step["rid"]))
			mind.action_text = "Разговаривает с " + (o2.mind.name if o2 else "кем-то")
		"talk_request": mind.action_text = "Заговаривает"
		"rest": mind.action_text = "Греется у костра"
		"look": mind.action_text = "Осматривается" if mind.goal != "follow" else "Держится рядом с родными"
		"gather": mind.action_text = "Собирает " + ("ягоды" if step["need"] == "food" else "воду") + " для ребёнка"
		"feed": mind.action_text = "Кормит ребёнка" if step["need"] == "food" else "Поит ребёнка"
		_: mind.action_text = "Думает"

# ---------------------------------------------------------------- визуал

## Перестроить модель (смена возраста, беременность).
func refresh_model() -> void:
	if model == null:
		return
	model.queue_free()
	remove_child(model)
	_make_model()
	if not mind.alive:
		model.set_dead_look()

func _make_model() -> void:
	model = CharacterModel.new()
	_model_pregnant = mind.pregnant
	model.build(mind.appearance, mind.sex, mind.stage(), mind.pregnant)
	add_child(model)
	if _label:
		_label.position.y = 2.15 * model.scale.y + 0.15

func _build_visual() -> void:
	_make_model()
	_ring = M.add(self, M.torus(0.45, 0.6), M.mat(Color(1.0, 0.85, 0.2), 1.5), Vector3(0, 0.05, 0))
	_ring.visible = false
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var font: Font = load("res://fonts/NotoSans-Bold.ttf")
	_label = Label3D.new()
	_label.font = font
	_label.text = mind.name
	_label.font_size = 40
	_label.outline_size = 10
	_label.pixel_size = 0.006
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.position = Vector3(0, 2.15 * model.scale.y + 0.15, 0)
	_label.modulate = Color(1, 1, 1)
	add_child(_label)
	_bubble = Label3D.new()
	_bubble.font = font
	_bubble.font_size = 34
	_bubble.outline_size = 12
	_bubble.outline_modulate = Color(0.05, 0.08, 0.15)
	_bubble.modulate = Color(1.0, 0.95, 0.7)
	_bubble.pixel_size = 0.006
	_bubble.width = 600
	_bubble.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_bubble.position = Vector3(0, 2.6, 0)
	_bubble.visible = false
	add_child(_bubble)
	var area := Area3D.new()
	area.collision_layer = 2
	area.collision_mask = 0
	area.set_meta("pick", self)
	var cs := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.6
	shape.height = 2.0
	cs.shape = shape
	cs.position.y = 1.0
	area.add_child(cs)
	add_child(area)

func say(text: String) -> void:
	if _bubble == null:
		return
	_bubble.text = text
	_bubble.visible = true
	_bubble_time = 4.0
	world.trace("%s: «%s»" % [mind.name, text])

func _process(delta: float) -> void:
	var prev := position
	if position.distance_to(sim_pos) > 4.0:
		position = sim_pos
	else:
		position = position.lerp(sim_pos, clampf(delta * 8.0, 0.0, 1.0))
	var moved := Vector2(position.x - prev.x, position.z - prev.z)
	var vis_speed := moved.length() / maxf(delta, 0.0001)
	if moved.length() > 0.002 and mind.alive:
		rotation.y = lerp_angle(rotation.y, atan2(moved.x, moved.y), clampf(delta * 10.0, 0.0, 1.0))
	var st := "idle"
	if not mind.alive:
		st = "dead"
	elif mind.sleeping:
		st = "sleep"
	elif is_moving and vis_speed > 0.05:
		st = "run" if current_step().get("run", false) else "walk"
	else:
		match current_step().get("a", ""):
			"eat": st = "eat"
			"drink": st = "drink"
			"talk": st = "talk"
			"rest": st = "rest"
	var sp: float = 1.0 if world.speed == 0 else clampf(float(world.speed), 1.0, 3.0)
	model.animate(delta * (0.0 if world.speed == 0 else 1.0), st, sp)
	if _bubble_time > 0.0:
		_bubble_time -= delta
		if _bubble_time <= 0.0:
			_bubble.visible = false
