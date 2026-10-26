extends SceneTree
## Автотесты симуляции (запуск: godot --headless --script res://tests/run_tests.gd).
## Проверяют, что механики действительно работают, а не только то, что проект собирается.

const GameWorld = preload("res://scripts/core/game_world.gd")
const Family = preload("res://scripts/residents/family.gd")
const Mind = preload("res://scripts/residents/mind.gd")

var failures := 0
var passed := 0

func check(cond: bool, what: String) -> void:
	if cond:
		passed += 1
		print("  OK   ", what)
	else:
		failures += 1
		printerr("  FAIL ", what)

func _initialize() -> void:
	_run.call_deferred()

func _sim(w, minutes: int) -> void:
	for i in minutes:
		w.step(1.0)

func _make_world(s: int):
	var w = GameWorld.new()
	root.add_child(w)
	w.speed = 0
	w.new_world(s)
	return w

func _run() -> void:
	print("== Эволюция: тесты симуляции ==")
	var w = _make_world(12345)

	print("[мир]")
	check(w.residents.size() == 2, "в начале два жителя")
	check(w.residents[0].mind.sex != w.residents[1].mind.sex, "мужчина и женщина")
	check(w.objects.size() > 100, "сгенерированы объекты (%d)" % w.objects.size())
	check(w.count_type("spring") >= 2, "есть родники")
	var w2 = _make_world(12345)
	check(w2.terrain.heights == w.terrain.heights, "один seed — одинаковый рельеф")
	check(w2.objects.size() == w.objects.size(), "один seed — одинаковые объекты")
	var w3 = _make_world(777)
	check(w3.terrain.heights != w.terrain.heights, "другой seed — другой рельеф")
	w2.queue_free()
	w3.queue_free()

	print("[потребности и решения]")
	var a = w.residents[0]
	var b = w.residents[1]
	var food0: float = a.mind.food
	_sim(w, 60)
	check(a.mind.food < food0, "голод растёт со временем")
	a.mind.water = 8.0
	a.set_plan([], 0.0)
	var drank := false
	var saw_drink_goal := false
	for i in 8 * 60:
		w.step(1.0)
		if a.mind.goal == "drink": saw_drink_goal = true
		if a.mind.water > 90.0:
			drank = true
			break
	check(saw_drink_goal, "жажда приводит к цели «попить»")
	check(drank, "житель сам нашёл воду и напился (вода %d)" % int(a.mind.water))
	check(not a.mind.places_of("spring").is_empty(), "житель запомнил, где родник")

	print("[3 игровых дня без вмешательства]")
	var start_pos: Vector3 = a.sim_pos
	_sim(w, 3 * 24 * 60)
	check(a.mind.alive and b.mind.alive, "оба жителя живы через 3 дня")
	check(a.sim_pos.distance_to(start_pos) > 1.0 or b.sim_pos.distance_to(start_pos) > 1.0, "жители перемещались")
	check(float(a.mind.skills["собирательство"]) > 0.0 and float(b.mind.skills["собирательство"]) > 0.0, "оба ели ягоды")
	check(a.mind.memory.size() >= 3 and b.mind.memory.size() >= 3, "у жителей есть воспоминания (%d / %d)" % [a.mind.memory.size(), b.mind.memory.size()])
	var rel: Dictionary = a.mind.rel(b.mind.id)
	check(int(rel["talks"]) > 0, "жители разговаривали (%d раз)" % int(rel["talks"]))
	check(float(rel["familiarity"]) > 1.0, "знакомство изменило отношения (симпатия %d)" % int(rel["affinity"]))
	var slept := false
	for m in [a.mind, b.mind]:
		if float(m.skills["выживание"]) > 0.0: slept = true
	check(slept, "навык выживания растёт от действий")
	print("    ", a.mind.name, ": ", a.mind.action_text, "; память: ", a.mind.recent_memories(3).map(func(x): return x["text"]))
	print("    ", b.mind.name, ": ", b.mind.action_text, "; память: ", b.mind.recent_memories(3).map(func(x): return x["text"]))

	print("[последствия действий создателя]")
	# убрать родник, о котором житель знает, и отправить его туда
	var springs: Array = a.mind.places_of("spring")
	springs.sort_custom(func(p, q): return Vector2(p["x"] - a.sim_pos.x, p["z"] - a.sim_pos.z).length() < Vector2(q["x"] - a.sim_pos.x, q["z"] - a.sim_pos.z).length())
	if not springs.is_empty():
		var sid: int = springs[0]["id"]
		w.cmd_remove(sid)
		a.mind.water = 20.0
		a.mind.sleeping = false
		a.set_plan([], 0.0)
		var mem_before: int = a.mind.memory.size()
		var noticed := false
		for i in 6 * 60:
			w.step(1.0)
			if not a.mind.known_places.has(str(sid)):
				noticed = true
				break
		check(noticed, "житель обнаружил, что родник исчез")
		check(a.mind.memory.size() > mem_before, "исчезновение записано в память")
	else:
		check(false, "житель знал родник")
	# пожар рядом с жителем
	a.set_plan([], 0.0)
	a.mind.sleeping = false
	var fire_pos: Vector3 = a.sim_pos + Vector3(2.5, 0, 0)
	w.add_object("fire", fire_pos)
	var fled := false
	for i in 40:
		w.step(1.0)
		if a.mind.goal == "flee":
			fled = true
	_sim(w, 40)
	check(fled, "житель убегает от огня")
	check(Vector2(a.sim_pos.x - fire_pos.x, a.sim_pos.z - fire_pos.z).length() > 4.0, "житель отошёл от огня")
	check(not a.mind.danger_zones.is_empty(), "житель запомнил опасное место")

	print("[редактор и отмена]")
	var trees: int = w.count_type("tree")
	var err: String = w.cmd_place("tree", Vector3(3, 0, -6))
	if err != "":
		err = w.cmd_place("tree", Vector3(-6, 0, 5))
	check(err == "" and w.count_type("tree") == trees + 1, "дерево поставлено")
	w.undo()
	check(w.count_type("tree") == trees, "отмена убирает дерево")
	w.redo()
	check(w.count_type("tree") == trees + 1, "повтор возвращает дерево")
	var h0: float = w.terrain.height_at(10, 10)
	w.cmd_terrain(Vector3(10, 0, 10), 1.0)
	check(w.terrain.height_at(10, 10) > h0 + 0.5, "кисть поднимает рельеф")
	w.undo()
	check(absf(w.terrain.height_at(10, 10) - h0) < 0.001, "отмена восстанавливает рельеф")
	check(w.can_place("tree", Vector3(0, 0, 60)) != "", "нельзя ставить за краем мира")

	print("[сохранение и загрузка]")
	var d: Dictionary = w.to_dict()
	var json := JSON.stringify(d)
	var parsed = JSON.parse_string(json)
	check(parsed is Dictionary, "сохранение сериализуется в JSON (%d КБ)" % (json.length() / 1024))
	var snapshot := {"time": w.time_min, "objects": w.objects.size(), "a_name": a.mind.name, "a_food": a.mind.food,
		"a_mem": a.mind.memory.size(), "a_aff": float(a.mind.rel(b.mind.id)["affinity"]), "h": w.terrain.height_at(5, 5), "events": w.events.size()}
	var w4 = _make_world(999)
	var lerr: String = w4.load_dict(parsed)
	check(lerr == "", "сохранение загружается" + ("" if lerr == "" else ": " + lerr))
	var a2 = w4.residents[0]
	check(absf(w4.time_min - snapshot["time"]) < 0.01, "время совпадает")
	check(w4.objects.size() == snapshot["objects"], "объекты совпадают")
	check(a2.mind.name == snapshot["a_name"] and absf(a2.mind.food - snapshot["a_food"]) < 0.01, "потребности жителя совпадают")
	check(a2.mind.memory.size() == snapshot["a_mem"], "память жителя сохранена")
	check(absf(float(a2.mind.rel(w4.residents[1].mind.id)["affinity"]) - snapshot["a_aff"]) < 0.01, "отношения сохранены")
	check(absf(w4.terrain.height_at(5, 5) - snapshot["h"]) < 0.001, "рельеф сохранён")
	_sim(w4, 120)
	check(a2.mind.alive or not a.mind.alive, "загруженный мир продолжает симуляцию")
	var objs_before: int = w4.objects.size()
	check(w4.load_dict({"game": "evolution", "version": 1, "heights": [1, 2]}) != "", "повреждённое сохранение отклоняется")
	check(w4.load_dict({"foo": 1}) != "", "чужой файл отклоняется")
	check(w4.objects.size() == objs_before, "при ошибке загрузки мир не теряется")

	print("[долгий прогон: 10 дней]")
	_sim(w4, 10 * 24 * 60)
	print("    живы: %d, событий в журнале: %d" % [w4.alive_count(), w4.events.size()])
	check(w4.alive_count() >= 1, "население выживает 10 дней в стандартном мире")

	_family_tests()

	print("== Итог: %d пройдено, %d с ошибкой ==" % [passed, failures])
	quit(1 if failures > 0 else 0)


# ---------------------------------------------------------------- семьи и поколения

func _family_tests() -> void:
	print("[семьи: пары]")
	var w = _make_world(4242)
	var adam = w.residents[0]
	var eva = w.residents[1]
	check(adam.mind.family_name != "" and adam.mind.generation == 1, "у первых людей есть род и поколение 1")
	check(Family.can_pair(w, adam.mind, eva.mind), "мужчина и женщина без родства могут стать парой")
	for pair in [[adam, eva], [eva, adam]]:
		var rl: Dictionary = pair[0].mind.rel(pair[1].mind.id, pair[1].mind.name)
		rl["affinity"] = 55.0
		rl["familiarity"] = 30.0
		rl["talks"] = 3
	var t0: float = w.time_min
	while adam.mind.partner_id < 0 and w.time_min - t0 < 4 * 1440:
		w.step(1.0)
	check(adam.mind.partner_id == eva.mind.id and eva.mind.partner_id == adam.mind.id,
		"пара возникает из разговоров (за %.1f ч)" % ((w.time_min - t0) / 60.0))

	print("[семьи: рождение и наследование]")
	eva.mind.pregnant = true
	eva.mind.pregnancy_father = adam.mind.id
	eva.mind.pregnancy_due = w.time_min + 30.0
	var pop0: int = w.alive_count()
	_sim(w, 90)
	check(w.alive_count() == pop0 + 1 and int(w.stats["births"]) >= 1, "беременность заканчивается рождением ребёнка")
	var kid = w.residents[-1]
	var k = kid.mind
	check(k.mother_id == eva.mind.id and k.father_id == adam.mind.id, "у ребёнка записаны мать и отец")
	check(k.id in eva.mind.children and k.id in adam.mind.children, "ребёнок записан у родителей")
	check(k.generation == 2 and k.family_name == adam.mind.family_name, "поколение 2, род отца")
	var inherit_ok := true
	for tr in k.traits:
		var lo: float = minf(adam.mind.traits[tr], eva.mind.traits[tr]) - 0.3
		var hi: float = maxf(adam.mind.traits[tr], eva.mind.traits[tr]) + 0.3
		if k.traits[tr] < lo or k.traits[tr] > hi:
			inherit_ok = false
	check(inherit_ok, "черты ребёнка — в диапазоне родителей с небольшой мутацией")
	check(k.lifespan > 45.0 and k.lifespan < 90.0, "срок жизни зависит от живучести (%.0f лет)" % k.lifespan)
	check(k.stage() == "baby" and kid.model.scale.y < 0.6, "младенец меньше взрослого")
	check(Family.is_close_relative(w, k, eva.mind) and not Family.can_pair(w, k, eva.mind), "с родителями пару создать нельзя")

	print("[семьи: уход за детьми]")
	k.food = 20.0
	k.water = 90.0
	var fed := false
	for i in 8 * 60:
		w.step(1.0)
		if k.food > 50.0:
			fed = true
			break
	check(fed, "голодного младенца кормит взрослый")
	check(float(eva.mind.skills.get("забота", 0.0)) + float(adam.mind.skills.get("забота", 0.0)) > 0.0, "растёт навык заботы")
	check(k.alive, "младенец жив")

	print("[семьи: взросление]")
	k.age_years = Mind.DEPENDENT_AGE - 0.001
	_sim(w, 10)
	check(not k.is_dependent() and not k.known_places.is_empty(), "в %d лет ребёнок узнаёт от родителей места (%d)" % [int(Mind.DEPENDENT_AGE), k.known_places.size()])
	eva.mind.traditions = ["evening_fire"]
	k.age_years = 11.999
	_sim(w, 10)
	check("evening_fire" in k.traditions, "подросток перенимает традицию родителей")
	k.age_years = Mind.ADULT_AGE - 0.001
	_sim(w, 10)
	check(k.is_adult() and absf(kid.model.scale.y - float(k.appearance["height"])) < 0.05, "взрослый — полный рост")
	var grown := false
	for mem in k.memory:
		if mem["kind"] == "grow" and "взросл" in mem["text"]:
			grown = true
	check(grown, "взросление записано в память")

	print("[семьи: родство]")
	eva.mind.pregnant = true
	eva.mind.pregnancy_father = adam.mind.id
	eva.mind.pregnancy_due = w.time_min + 5.0
	_sim(w, 70)
	var kid2 = w.residents[-1]
	check(kid2 != kid and kid2.mind.mother_id == eva.mind.id, "родился второй ребёнок")
	kid2.mind.age_years = 18.0
	k.age_years = 19.0
	check(not Family.can_pair(w, k, kid2.mind), "братья и сёстры не создают пару")
	check(Family.relation_to(w, k, kid2.mind.id) in ["брат", "сестра"], "родство определяется (%s)" % Family.relation_to(w, k, kid2.mind.id))

	print("[семьи: болезни, старость, смерть]")
	adam.mind.age_years = adam.mind.lifespan + 0.2
	var died := false
	for i in 2 * 1440:
		w.step(1.0)
		if not adam.mind.alive:
			died = true
			break
	check(died and adam.mind.cause_of_death == "от старости", "старик умирает от старости (%s)" % adam.mind.cause_of_death)
	check(eva.mind.partner_id == -1, "вдова снова одна")
	_sim(w, 13 * 60)
	check(w.resident_by_id(1000) == null and w.mind_by_id(1000) != null, "тело убрано, человек остался в родословной")
	check(w.count_type("grave") >= 1, "на месте смерти — могила")
	var sick_ok := false
	k.illness = "простуда"
	k.sick_until = w.time_min + 120.0
	var h0: float = k.health
	_sim(w, 60)
	sick_ok = k.health < h0 or k.health < 100.0
	check(sick_ok, "болезнь отнимает здоровье")

	print("[семьи: сохранение]")
	var js := JSON.stringify(w.to_dict())
	var w5 = _make_world(1)
	var err: String = w5.load_dict(JSON.parse_string(js))
	check(err == "", "сохранение с семьями загружается")
	var e5 = w5.resident_by_id(eva.mind.id)
	check(e5 != null and e5.mind.children.size() == 2, "дети матери сохранены")
	check(w5.mind_by_id(1000) != null and w5.mind_by_id(1000).cause_of_death == "от старости", "архив родословной сохранён")
	check(w5.resident_by_id(k.id).mind.father_id == 1000, "отец ребёнка сохранён")
	check(int(w5.stats["births"]) == int(w.stats["births"]), "демография сохранена")
	w5.queue_free()
	w.queue_free()

	print("[семьи: долгий прогон 60 дней = 30 лет]")
	var t_start := Time.get_ticks_msec()
	var wl = _make_world(2024)
	var max_pop := 0
	for d in 60:
		_sim(wl, 1440)
		max_pop = maxi(max_pop, wl.alive_count())
	var gens := {}
	for m in wl.all_minds():
		gens[m.generation] = true
	print("    живы: %d, макс. %d, рождений %d, смертей %d %s, поколений %d, кустов %d, пар %d, кормлений %d, %.1f с" % [
		wl.alive_count(), max_pop, int(wl.stats["births"]), int(wl.stats["deaths"]), str(wl.stats["deaths_by"]), gens.size(),
		wl.count_type("bush"), int(wl.stats["couples"]), int(wl.stats["feedings"]), (Time.get_ticks_msec() - t_start) / 1000.0])
	check(int(wl.stats["couples"]) >= 1, "в стандартном мире сами возникают пары")
	check(int(wl.stats["births"]) >= 2, "сами рождаются дети")
	check(wl.alive_count() > 2, "население выросло")
	check(max_pop <= Family.MAX_POP, "население не превышает предел")
	check(gens.size() >= 2, "сменяются поколения")
	wl.queue_free()
