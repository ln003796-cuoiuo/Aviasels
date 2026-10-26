extends SceneTree
## Автотесты симуляции (запуск: godot --headless --script res://tests/run_tests.gd).
## Проверяют, что механики действительно работают, а не только то, что проект собирается.

const GameWorld = preload("res://scripts/core/game_world.gd")

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

	print("== Итог: %d пройдено, %d с ошибкой ==" % [passed, failures])
	quit(1 if failures > 0 else 0)
