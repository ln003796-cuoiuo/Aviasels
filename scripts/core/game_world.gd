extends Node3D
## Единое состояние мира: время, рельеф, объекты, жители, журнал, команды создателя (с отменой).

signal event_logged(entry: Dictionary)
signal world_reset
signal object_removed(obj_id: int)

const Terrain = preload("res://scripts/core/terrain.gd")
const GridNav = preload("res://scripts/core/grid_nav.gd")
const WorldObject = preload("res://scripts/core/world_object.gd")
const Resident = preload("res://scripts/residents/resident.gd")
const Defs = preload("res://scripts/core/object_defs.gd")
const Mind = preload("res://scripts/residents/mind.gd")
const Family = preload("res://scripts/residents/family.gd")
const Settlement = preload("res://scripts/core/settlement.gd")

const SAVE_VERSION := 3
const MAX_TREES := 110
const MAX_BUSHES := 45
const BODY_REMOVE_H := 12.0
const MIN_PER_REAL_SEC := 6.0   # при скорости x1: 1 игровой час = 10 секунд
const MAX_STEPS_PER_FRAME := 240
const FRAME_BUDGET_US := 9000

var seed_value: int = 0
var time_min: float = 7 * 60.0
var speed: int = 1
var next_id: int = 1
var lagging := false      # симуляция не успевает за выбранной скоростью

var terrain
var nav = GridNav.new()
var objects := {}        # id -> WorldObject
var residents: Array = []
var events: Array = []   # [{t, text}]
var trace_log: Array = []
var next_resident_id: int = 1002
var stats := {"births": 0, "deaths": 0, "couples": 0, "feedings": 0, "deaths_by": {}}
var pop_history: Array = []  # [{d, pop, births, deaths}]
var archive: Array = []      # Mind умерших, чьи тела уже убраны (для родословной)
var _last_day: int = 1
var settlement: Dictionary = Settlement.fresh()
var _plan_acc := 0.0
var _rng := RandomNumberGenerator.new()
const BUCKET := 8.0
var _buckets := {}         # Vector2i -> Array объектов (пространственный индекс)
var _dangers: Array = []   # кэш опасных объектов

var undo_stack: Array = []
var redo_stack: Array = []

var _acc := 0.0
var _hour_acc := 0.0
var _objects_node: Node3D
var _residents_node: Node3D

func _ready() -> void:
	terrain = Terrain.new()
	terrain.name = "Terrain"
	add_child(terrain)
	_objects_node = Node3D.new()
	_objects_node.name = "Objects"
	add_child(_objects_node)
	_residents_node = Node3D.new()
	_residents_node.name = "Residents"
	add_child(_residents_node)

# ---------------------------------------------------------------- время

func day() -> int:
	return int(time_min / 1440.0) + 1

func hour_f() -> float:
	return fmod(time_min / 60.0, 24.0)

func is_night() -> bool:
	var h := hour_f()
	return h < 6.0 or h >= 21.0

func time_string(t: float = -1.0) -> String:
	if t < 0.0:
		t = time_min
	var d := int(t / 1440.0) + 1
	var m := int(fmod(t, 1440.0))
	return "День %d, %02d:%02d" % [d, m / 60, m % 60]

func _process(delta: float) -> void:
	if speed <= 0:
		return
	_acc += delta * MIN_PER_REAL_SEC * speed
	var steps := 0
	var t0 := Time.get_ticks_usec()
	# бюджет времени на кадр: на слабом телефоне симуляция замедляется, а не «замерзает»
	while _acc >= 1.0 and steps < MAX_STEPS_PER_FRAME and Time.get_ticks_usec() - t0 < FRAME_BUDGET_US:
		step(1.0)
		_acc -= 1.0
		steps += 1
	lagging = _acc >= 2.0
	if _acc > 30.0:
		_acc = 0.0

## Один шаг симуляции (dt — игровые минуты).
func step(dt: float) -> void:
	time_min += dt
	_hour_acc += dt
	if _hour_acc >= 10.0:
		var h := _hour_acc / 60.0
		_hour_acc = 0.0
		_sim_objects(h)
		Family.hourly(self, h)
		_remove_bodies()
		_plan_acc += h
		if _plan_acc >= 2.0:
			_plan_acc = 0.0
			Settlement.plan(self)
	if day() != _last_day:
		_last_day = day()
		_daily()
	for r in residents.duplicate():
		r.sim_step(dt)

func _daily() -> void:
	for r in residents.duplicate():
		if r.mind.alive:
			Family.daily(self, r)
	_spread_bushes()
	_regrow_forest()
	Settlement.daily(self)
	Family.maybe_newcomer(self, _rng)
	pop_history.append({"d": day(), "pop": alive_count(), "births": int(stats["births"]), "deaths": int(stats["deaths"])})
	if pop_history.size() > 400:
		pop_history.remove_at(0)

## Ягодники сами разрастаются — еды в мире становится больше, но не бесконечно.
func _spread_bushes() -> void:
	var bushes: Array = objects.values().filter(func(o): return o.obj_type == "bush" and o.burning <= 0.0)
	var n := bushes.size()
	var added := 0
	for b in bushes:
		if n + added >= MAX_BUSHES:
			break
		if randf() > 0.12:
			continue
		for attempt in 6:
			var a := randf() * TAU
			var p: Vector3 = b.position + Vector3(cos(a), 0, sin(a)) * randf_range(2.5, 7.0)
			var hgt: float = terrain.height_at(p.x, p.z)
			if hgt < 0.4 or hgt > 6.0 or can_place("bush", p) != "":
				continue
			add_object("bush", p, {"variant": randf(), "rot": randf() * TAU, "amount": 1.0})
			added += 1
			break
	if added > 0:
		log_event("Ягодники разрослись: новых кустов %d" % added)

## Лес понемногу восстанавливается рядом с живыми деревьями.
func _regrow_forest() -> void:
	var trees: Array = objects.values().filter(func(o): return o.obj_type == "tree" and o.burning <= 0.0)
	var n := trees.size()
	if n == 0:
		return
	var cpos := Settlement.center(self)
	for t in trees:
		if n >= MAX_TREES:
			break
		if randf() > 0.03:
			continue
		var a := randf() * TAU
		var p: Vector3 = t.position + Vector3(cos(a), 0, sin(a)) * randf_range(2.0, 6.0)
		if settlement["has_center"] and p.distance_to(cpos) < 12.0:
			continue   # в самом поселении лес не растёт
		var hgt: float = terrain.height_at(p.x, p.z)
		if hgt < 0.5 or hgt > 6.0 or can_place("tree", p) != "":
			continue
		add_object("tree", p, {"variant": randf(), "rot": randf() * TAU})
		n += 1

## Тела умерших через полдня заменяются могилой; данные остаются в родословной.
func _remove_bodies() -> void:
	for r in residents.duplicate():
		if r.mind.alive or time_min - r.mind.died_at < BODY_REMOVE_H * 60.0:
			continue
		var m = r.mind
		var born_y: int = int(floor(m.born_at / Mind.YEAR_MIN))
		var died_y: int = int(floor(m.died_at / Mind.YEAR_MIN))
		var lbl := "%s (%d–%d г., %d лет)" % [m.name, born_y, died_y, int(m.age_years)]
		for attempt in 8:
			var p: Vector3 = r.sim_pos + Vector3(randf_range(-1.5, 1.5), 0, randf_range(-1.5, 1.5)) * float(attempt) * 0.5
			if can_place("grave", p) == "":
				add_object("grave", p, {"label": lbl, "rot": randf() * TAU})
				break
		archive.append(m)
		residents.erase(r)
		r.queue_free()

func _sim_objects(h: float) -> void:
	var dangerous: Array = []
	for o in objects.values():
		if o.is_dangerous():
			dangerous.append(o)
	# распространение огня
	for f in dangerous:
		var p: float = (0.5 if f.obj_type == "fire" else 0.12) * h
		for o in objects_near(f.position, 3.0):
			if o != f and (o.obj_type == "tree" or o.obj_type == "bush") and o.burning <= 0.0 and randf() < p:
				o.ignite()
	var gone: Array = []
	for o in objects.values():
		if not o.sim_hours(h):
			gone.append(o)
	var burnt := 0
	for o in gone:
		if o.burning > 0.0:
			burnt += 1
		elif o.obj_type == "fire":
			log_event("Пожар догорел")
		remove_object(o.obj_id, false)
	if burnt > 0:
		log_event("Огонь уничтожил объектов: %d" % burnt)
	_refresh_dangers()

# ---------------------------------------------------------------- запросы

func _bkey(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / BUCKET), floori(z / BUCKET))

func objects_near(pos: Vector3, r: float) -> Array:
	var out: Array = []
	var r2 := r * r
	var a := _bkey(pos.x - r, pos.z - r)
	var b := _bkey(pos.x + r, pos.z + r)
	for bx in range(a.x, b.x + 1):
		for bz in range(a.y, b.y + 1):
			var arr = _buckets.get(Vector2i(bx, bz))
			if arr == null:
				continue
			for o in arr:
				var dx: float = o.position.x - pos.x
				var dz: float = o.position.z - pos.z
				if dx * dx + dz * dz <= r2:
					out.append(o)
	return out

func _refresh_dangers() -> void:
	_dangers = objects.values().filter(func(o): return o.is_dangerous())

func nearest_danger(pos: Vector3, r: float):
	var best = null
	var bd := r
	for o in _dangers:
		if is_instance_valid(o) and o.is_dangerous():
			var d := Vector2(o.position.x - pos.x, o.position.z - pos.z).length()
			if d < bd:
				bd = d
				best = o
	return best

func get_object(id: int):
	return objects.get(id, null)

func resident_by_id(id: int):
	for r in residents:
		if r.mind.id == id:
			return r
	return null

## Разум жителя по id — живого, недавно умершего или из архива родословной.
func mind_by_id(id: int):
	if id < 0:
		return null
	for r in residents:
		if r.mind.id == id:
			return r.mind
	for m in archive:
		if m.id == id:
			return m
	return null

## Все люди, когда-либо жившие в мире.
func all_minds() -> Array:
	var out: Array = []
	for r in residents:
		out.append(r.mind)
	out.append_array(archive)
	return out

func current_year() -> int:
	return int(floor(time_min / Mind.YEAR_MIN))

func alive_count() -> int:
	var n := 0
	for r in residents:
		if r.mind.alive:
			n += 1
	return n

func count_type(t: String) -> int:
	var n := 0
	for o in objects.values():
		if o.obj_type == t:
			n += 1
	return n

func log_event(text: String) -> void:
	var e := {"t": time_min, "text": text}
	events.append(e)
	if events.size() > 300:
		events.remove_at(0)
	event_logged.emit(e)

func trace(text: String) -> void:
	trace_log.append("[%s] %s" % [time_string(), text])
	if trace_log.size() > 400:
		trace_log.remove_at(0)

# ---------------------------------------------------------------- объекты

func _obstacle_radius(t: String) -> int:
	return 1 if t in ["hut", "fire", "storage"] else 0

## Проверка, можно ли поставить объект. Пустая строка — можно.
func can_place(t: String, pos: Vector3) -> String:
	if absf(pos.x) > 47.0 or absf(pos.z) > 47.0:
		return "Слишком близко к краю мира"
	var h: float = terrain.height_at(pos.x, pos.z)
	if h < 0.2 and t != "spring":
		return "Здесь вода"
	var min_d := 1.3 if t not in ["hut", "storage"] else 2.4
	for o in objects_near(pos, 3.0):
		if Vector2(o.position.x - pos.x, o.position.z - pos.z).length() < min_d:
			return "Слишком близко к другому объекту"
	if t in ["hut", "storage", "well"]:
		var c: Vector2i = nav.world_to_cell(pos)
		if terrain.cell_slope(c.x, c.y) > 0.9:
			return "Слишком крутой склон для хижины"
	return ""

func add_object(t: String, pos: Vector3, data: Dictionary = {}) -> Node3D:
	var id: int = int(data.get("id", next_id))
	next_id = maxi(next_id, id + 1)
	pos.y = terrain.height_at(pos.x, pos.z)
	if t == "spring":
		pos.y = maxf(pos.y, 0.02)
	var o = WorldObject.new()
	_objects_node.add_child(o)
	o.world = self
	o.setup(id, t, pos, data)
	objects[id] = o
	var bk := _bkey(pos.x, pos.z)
	if not _buckets.has(bk):
		_buckets[bk] = []
	_buckets[bk].append(o)
	if Defs.has_flag(t, "blocks"):
		nav.add_obstacle(pos, _obstacle_radius(t))
	if t == "fire":
		for n in objects_near(pos, 2.5):
			n.ignite()
	if o.is_dangerous() or t == "fire":
		_refresh_dangers()
	return o

func remove_object(id: int, record: bool = true) -> bool:
	var o = objects.get(id, null)
	if o == null:
		return false
	if record:
		_push_undo({"op": "remove", "data": o.to_dict()})
	if Defs.has_flag(o.obj_type, "blocks"):
		nav.remove_obstacle(o.position, _obstacle_radius(o.obj_type))
	objects.erase(id)
	var bk := _bkey(o.position.x, o.position.z)
	if _buckets.has(bk):
		_buckets[bk].erase(o)
	_dangers.erase(o)
	o.queue_free()
	object_removed.emit(id)
	return true

# ---------------------------------------------------------------- команды создателя

func cmd_place(t: String, pos: Vector3) -> String:
	var err := can_place(t, pos)
	if err != "":
		return err
	var o = add_object(t, pos)
	_push_undo({"op": "place", "data": o.to_dict()})
	log_event("Создатель: %s" % Defs.display_name(t).to_lower())
	return ""

func cmd_remove(id: int) -> String:
	var o = objects.get(id, null)
	if o == null:
		return "Объект не найден"
	var n: String = o.display_name()
	remove_object(id, true)
	log_event("Создатель убрал: %s" % n.to_lower())
	return ""

func cmd_terrain(pos: Vector3, strength: float) -> void:
	var res: Dictionary = terrain.brush(pos, 4.5, strength)
	if res["indices"].is_empty():
		return
	_after_terrain_change()
	_push_undo({"op": "terrain", "indices": res["indices"], "before": res["before"], "after": res["after"]})
	log_event("Создатель %s рельеф" % ("поднял" if strength > 0 else "опустил"))

func _after_terrain_change() -> void:
	nav.rebuild_terrain()
	for o in objects.values():
		o.position.y = maxf(terrain.height_at(o.position.x, o.position.z), 0.02 if o.obj_type == "spring" else -10.0)
	for r in residents:
		r.sim_pos.y = terrain.height_at(r.sim_pos.x, r.sim_pos.z)

func _push_undo(cmd: Dictionary) -> void:
	undo_stack.append(cmd)
	if undo_stack.size() > 60:
		undo_stack.remove_at(0)
	redo_stack.clear()

func undo() -> String:
	if undo_stack.is_empty():
		return "Нечего отменять"
	var c: Dictionary = undo_stack.pop_back()
	_apply(c, true)
	redo_stack.append(c)
	return "Отменено"

func redo() -> String:
	if redo_stack.is_empty():
		return "Нечего повторять"
	var c: Dictionary = redo_stack.pop_back()
	_apply(c, false)
	undo_stack.append(c)
	return "Повторено"

func _apply(c: Dictionary, inverse: bool) -> void:
	match c["op"]:
		"place", "remove":
			var create: bool = (c["op"] == "place") != inverse
			var d: Dictionary = c["data"]
			if create:
				if not objects.has(int(d["id"])):
					add_object(d["type"], Vector3(d["x"], d["y"], d["z"]), d)
			else:
				remove_object(int(d["id"]), false)
		"terrain":
			terrain.apply_values(c["indices"], c["before"] if inverse else c["after"])
			_after_terrain_change()
	log_event("Создатель: %s" % ("отмена действия" if inverse else "повтор действия"))

# ---------------------------------------------------------------- мир

func clear_world() -> void:
	for o in objects.values():
		o.queue_free()
	objects.clear()
	_buckets.clear()
	_dangers.clear()
	for r in residents:
		r.queue_free()
	residents.clear()
	archive.clear()
	pop_history.clear()
	stats = {"births": 0, "deaths": 0, "couples": 0, "feedings": 0, "deaths_by": {}}
	next_resident_id = 1002
	settlement = Settlement.fresh()
	_plan_acc = 0.0
	events.clear()
	trace_log.clear()
	undo_stack.clear()
	redo_stack.clear()
	next_id = 1
	_acc = 0.0
	_hour_acc = 0.0
	_last_day = 1

func new_world(s: int) -> void:
	clear_world()
	seed_value = s
	_rng.seed = s * 31 + 7
	time_min = 7 * 60.0
	terrain.generate(s)
	nav.setup(terrain)
	_populate(s)
	_last_day = day()
	pop_history.append({"d": day(), "pop": alive_count(), "births": 0, "deaths": 0})
	log_event("Мир создан (seed %d). Появились первые люди: %s и %s" % [s, residents[0].mind.name, residents[1].mind.name])
	world_reset.emit()

func _populate(s: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = s * 7919 + 13
	var half: float = terrain.SIZE / 2.0 - 3.0
	# родники: один недалеко от центра, остальные дальше
	_scatter(rng, "spring", 1, 9.0, 15.0, 0.4, 4.0)
	_scatter(rng, "spring", 2, 20.0, half, 0.4, 5.0)
	_scatter(rng, "bush", 4, 6.0, 16.0, 0.4, 4.5)
	_scatter(rng, "bush", 8, 16.0, half, 0.4, 5.0)
	_scatter(rng, "tree", 95, 9.0, half, 0.5, 6.0)
	_scatter(rng, "rock", 22, 8.0, half, 0.4, 12.0)
	var skins := ["#f1c9a5", "#e0b48c", "#c68e63", "#8d5a3b", "#5c3a24"]
	var hairs := ["#2b1a10", "#4a2c17", "#8a5a2b", "#c9a36a", "#1a1a1a"]
	for i in 2:
		var sex := "m" if i == 0 else "f"
		var nm: String = "Адам" if i == 0 else "Ева"
		var age: float = rng.randf_range(18.0, 24.0)
		var vit: float = rng.randf_range(0.45, 0.85)
		var data := {
			"id": 1000 + i, "name": nm, "sex": sex, "age_years": age,
			"family_name": nm, "generation": 1, "born_at": time_min - age * Mind.YEAR_MIN,
			"lifespan": 52.0 + vit * 28.0 + rng.randf_range(-4.0, 4.0),
			"x": -1.5 + i * 3.0, "z": rng.randf_range(-1.0, 1.0),
			"food": rng.randf_range(55.0, 75.0), "water": rng.randf_range(50.0, 70.0), "energy": rng.randf_range(70.0, 90.0),
			"social": rng.randf_range(35.0, 55.0), "mood": 65.0, "health": 100.0,
			"traits": {"curiosity": rng.randf_range(0.2, 0.9), "caution": rng.randf_range(0.2, 0.9),
				"sociability": rng.randf_range(0.3, 0.95), "calm": rng.randf_range(0.25, 0.9), "vitality": vit, "diligence": rng.randf_range(0.3, 0.9)},
			"appearance": {"skin": skins[rng.randi() % 5], "hair": hairs[rng.randi() % 5],
				"shirt": Color.from_hsv(rng.randf(), 0.5, 0.75).to_html(false),
				"pants": Color.from_hsv(rng.randf(), 0.35, 0.4).to_html(false),
				"height": rng.randf_range(0.95, 1.05) if sex == "m" else rng.randf_range(0.9, 0.98)},
			"long_goal": ["Узнать, что за горами", "Найти надёжное укрытие", "Обрести друга", "Никогда не голодать"][rng.randi() % 4],
		}
		var r = add_resident(data)
		r.mind.remember(time_min, "birth", "Очнул%s в новом мире" % r.g("ся", "ась"), 1.0)

func _scatter(rng: RandomNumberGenerator, t: String, n: int, rmin: float, rmax: float, hmin: float, hmax: float) -> void:
	var placed := 0
	var tries := 0
	while placed < n and tries < n * 60:
		tries += 1
		var a := rng.randf() * TAU
		var d := rng.randf_range(rmin, rmax)
		var p := Vector3(cos(a) * d, 0, sin(a) * d)
		var h: float = terrain.height_at(p.x, p.z)
		if h < hmin or h > hmax:
			continue
		var c: Vector2i = nav.world_to_cell(p)
		if terrain.cell_slope(c.x, c.y) > 1.3:
			continue
		if can_place(t, p) != "":
			continue
		add_object(t, p, {"variant": rng.randf(), "rot": rng.randf() * TAU})
		placed += 1

func add_resident(data: Dictionary):
	next_resident_id = maxi(next_resident_id, int(data.get("id", 0)) + 1)
	var r = Resident.new()
	_residents_node.add_child(r)
	r.setup(self, data)
	residents.append(r)
	return r

func on_resident_died(r, cause: String) -> void:
	log_event("%s %s %s в возрасте %d лет" % [r.mind.name, r.g("умер", "умерла"), cause, int(r.mind.age_years)])
	stats["deaths"] = int(stats["deaths"]) + 1
	var key: String = cause.split(" (")[0]
	stats["deaths_by"][key] = int(stats["deaths_by"].get(key, 0)) + 1
	Family.on_death(self, r.mind)
	for o in residents:
		if o != r and o.mind.alive and o.mind.relationships.has(str(r.mind.id)):
			o.mind.remember(time_min, "grief", "%s %s" % [r.mind.name, r.g("умер", "умерла")], 1.0)
			o.mind.mood = maxf(0.0, o.mind.mood - 30.0)

# ---------------------------------------------------------------- сохранение

func to_dict() -> Dictionary:
	var objs: Array = []
	for o in objects.values():
		objs.append(o.to_dict())
	var res: Array = []
	for r in residents:
		res.append(r.to_dict())
	return {"version": SAVE_VERSION, "game": "evolution", "seed": seed_value, "time_min": time_min,
		"next_id": next_id, "heights": Array(terrain.heights), "objects": objs, "residents": res,
		"events": events.duplicate(true), "next_resident_id": next_resident_id, "stats": stats.duplicate(true),
		"pop_history": pop_history.duplicate(true), "archive": archive.map(func(m): return m.to_dict()),
		"settlement": settlement.duplicate(true)}

## Загрузка. Пустая строка — успех, иначе текст ошибки (мир не меняется при ошибке).
func load_dict(d: Dictionary) -> String:
	if d.get("game", "") != "evolution":
		return "Файл не является сохранением «Эволюции»"
	if int(d.get("version", 0)) > SAVE_VERSION:
		return "Сохранение создано более новой версией игры"
	var vc: int = terrain.vcount()
	var hs = d.get("heights", [])
	if not (hs is Array) or hs.size() != vc * vc:
		return "Повреждены данные рельефа"
	if not (d.get("objects") is Array) or not (d.get("residents") is Array) or d["residents"].is_empty():
		return "Повреждены данные объектов или жителей"
	clear_world()
	seed_value = int(d.get("seed", 0))
	_rng.seed = seed_value * 31 + int(time_min)
	time_min = float(d.get("time_min", 420.0))
	terrain.heights = PackedFloat32Array(hs)
	terrain.rebuild()
	nav.setup(terrain)
	for od in d["objects"]:
		if od is Dictionary and Defs.DEFS.has(od.get("type", "")):
			add_object(od["type"], Vector3(float(od["x"]), float(od["y"]), float(od["z"])), od)
	for rd in d["residents"]:
		if rd is Dictionary:
			add_resident(rd)
	next_id = maxi(next_id, int(d.get("next_id", 1)))
	for ad in d.get("archive", []):
		if ad is Dictionary:
			var am = Mind.new()
			am.from_dict(ad)
			archive.append(am)
			next_resident_id = maxi(next_resident_id, am.id + 1)
	next_resident_id = maxi(next_resident_id, int(d.get("next_resident_id", 0)))
	var st = d.get("stats", {})
	if st is Dictionary:
		for k in st:
			stats[k] = st[k]
	if not (stats["deaths_by"] is Dictionary):
		stats["deaths_by"] = {}
	for ph in d.get("pop_history", []):
		if ph is Dictionary:
			pop_history.append(ph)
	_last_day = day()
	# сохранения версии 1: у первых людей нет родословных данных
	if int(d.get("version", 1)) < 2:
		for r in residents:
			if r.mind.family_name == "":
				r.mind.family_name = r.mind.name
				r.mind.born_at = time_min - r.mind.age_years * Mind.YEAR_MIN
	var sd = d.get("settlement", {})
	if sd is Dictionary:
		for k in sd:
			settlement[k] = sd[k]
	if not (settlement["discoveries"] is Array):
		settlement["discoveries"] = []
	# сохранения до версии 3: у деревьев и камней не было запаса материала
	if int(d.get("version", 1)) < 3:
		for o in objects.values():
			if o.obj_type in ["tree", "rock"] and o.amount <= 0.0:
				o.amount = float(Defs.max_amount(o.obj_type))
	for e in d.get("events", []):
		if e is Dictionary:
			events.append(e)
	world_reset.emit()
	return ""
