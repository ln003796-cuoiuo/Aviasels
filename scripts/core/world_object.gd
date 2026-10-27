extends Node3D
## Объект мира: дерево, куст, родник, камень, хижина, костёр, пожар.
## Хранит игровое состояние (тип, запас, возраст) и строит свою 3D-модель.

const Defs = preload("res://scripts/core/object_defs.gd")
const M = preload("res://scripts/core/meshes.gd")
const Settlement = preload("res://scripts/core/settlement.gd")

var obj_id: int = 0
var obj_type: String = ""
var amount: float = 0.0
var age_h: float = 0.0
var variant: float = 0.5  # детерминированный разброс внешнего вида
var burning: float = 0.0  # для деревьев/кустов, задетых пожаром (часы горения)
var label: String = ""    # подпись (для могил: имя и годы жизни)
var ext: Dictionary = {}  # данные построек: стройка, владелец дома, кто строил
var world = null

var _visual: Node3D
var _berries: Array = []
var _flames: Array = []
var _light: OmniLight3D
var _t: float = 0.0

func setup(id: int, t: String, pos: Vector3, data: Dictionary = {}) -> void:
	obj_id = id
	obj_type = t
	position = pos
	variant = float(data.get("variant", randf()))
	amount = float(data.get("amount", Defs.max_amount(t)))
	age_h = float(data.get("age_h", 0.0))
	burning = float(data.get("burning", 0.0))
	label = str(data.get("label", ""))
	var e = data.get("ext", {})
	ext = e.duplicate(true) if e is Dictionary else {}
	rotation.y = float(data.get("rot", variant * TAU))
	name = "%s_%d" % [t, id]
	_build()

func to_dict() -> Dictionary:
	return {"id": obj_id, "type": obj_type, "x": position.x, "y": position.y, "z": position.z,
		"amount": amount, "age_h": age_h, "variant": variant, "rot": rotation.y, "burning": burning, "label": label, "ext": ext.duplicate(true)}

func display_name() -> String:
	return Defs.display_name(obj_type)

func describe() -> String:
	var s := display_name()
	match obj_type:
		"bush":
			s += " — ягод: %d из %d" % [int(amount), Defs.max_amount(obj_type)]
		"fire":
			s += " — догорит через %.0f ч" % maxf(0.0, Defs.DEFS["fire"]["life_h"] - age_h)
		"spring":
			s += " — чистая вода"
		"hut":
			var ow: int = int(ext.get("owner", -1))
			if ow >= 0 and world != null:
				s += " — дом семьи «%s»" % Settlement.household_label(world, ow)
			else:
				s += " — свободное укрытие для сна"
			if not ext.get("built_by", []).is_empty():
				s += ", построена жителями"
		"site":
			var tn: String = Settlement.target_name(ext.get("target", "")) if world != null else ""
			s += ": %s — дерево %d/%d, камень %d/%d, работа %d%%" % [tn, int(ext.get("wood", 0)), int(ext.get("need_wood", 0)),
				int(ext.get("stone", 0)), int(ext.get("need_stone", 0)), int(100.0 * float(ext.get("work", 0.0)) / maxf(1.0, float(ext.get("work_need", 1.0))))]
		"storage":
			s += " — ягод в запасе: %d из %d" % [int(amount), 60]
		"well":
			s += " — вода для поселения"
		"tree":
			s += " — древесины: %d" % int(amount)
		"rock":
			s += " — камня: %d" % int(amount)
		"campfire":
			s += " — тепло и отдых"
		"grave":
			s += ": " + label
	if obj_type == "bush" and ext.get("planted", false):
		s += " (посажен жителями)"
	if burning > 0.0:
		s += " (горит)"
	return s

## Игровые часы прошли — обновить состояние. Возвращает false, если объект должен исчезнуть.
func sim_hours(h: float) -> bool:
	age_h += h
	if obj_type == "bush" and amount < Defs.max_amount("bush"):
		amount = minf(Defs.max_amount("bush"), amount + h / Defs.DEFS["bush"]["regen_h"])
		_update_berries()
	if burning > 0.0:
		burning += h
		if burning > 3.0:
			return false
	if obj_type == "fire" and age_h >= Defs.DEFS["fire"]["life_h"]:
		return false
	return true

func take_food(n: int) -> int:
	var got := mini(n, int(amount))
	amount -= got
	_update_berries()
	if obj_type == "storage" and got > 0 and int(amount) % 10 == 9:
		refresh_visual()
	return got

func ignite() -> void:
	if burning <= 0.0 and (obj_type == "tree" or obj_type == "bush"):
		burning = 0.01
		_add_flames(3 if obj_type == "tree" else 2, 1.0 if obj_type == "tree" else 0.4)

func is_dangerous() -> bool:
	return obj_type == "fire" or burning > 0.0

func _process(delta: float) -> void:
	if _flames.is_empty():
		return
	_t += delta
	for i in _flames.size():
		var f: Node3D = _flames[i]
		var k := 0.85 + 0.25 * sin(_t * 9.0 + i * 1.7)
		f.scale = Vector3(1.0, k, 1.0) * f.get_meta("base", 1.0)
	if _light:
		_light.light_energy = 1.6 + 0.4 * sin(_t * 13.0)

# ---------------------------------------------------------------- визуал

func refresh_visual() -> void:
	if _visual:
		_visual.queue_free()
		remove_child(_visual)
	_berries.clear()
	_flames.clear()
	_build_visual()

func _build() -> void:
	_build_visual()
	_build_pick()

func _build_visual() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	var v := variant
	match obj_type:
		"site":
			var tg: String = ext.get("target", "hut")
			var sz: float = {"hut": 2.2, "storage": 2.0, "well": 1.4, "campfire": 1.0, "bush": 0.9}.get(tg, 1.5)
			M.add(_visual, M.box(Vector3(sz + 0.3, 0.06, sz + 0.3)), M.mat(Color(0.5, 0.4, 0.28)), Vector3(0, 0.03, 0))
			var prog: float = clampf(float(ext.get("work", 0.0)) / maxf(1.0, float(ext.get("work_need", 1.0))), 0.0, 1.0)
			var h: float = 0.25 + prog * 1.3
			if tg in ["hut", "storage"]:
				for cx in [-1, 1]:
					for cz in [-1, 1]:
						M.add(_visual, M.cyl(0.07, 0.08, h, 6), M.mat(Color(0.45, 0.3, 0.17)), Vector3(cx * sz / 2.0, h / 2.0, cz * sz / 2.0))
				if prog > 0.5:
					M.add(_visual, M.box(Vector3(sz, 0.5 * (prog - 0.5) * 2.0, 0.08)), M.mat(Color(0.55, 0.4, 0.25)), Vector3(0, 0.3, -sz / 2.0))
			elif tg == "well":
				M.add(_visual, M.cyl(0.6, 0.65, 0.2 + prog * 0.5, 12), M.mat(Color(0.5, 0.5, 0.52)), Vector3(0, 0.1 + prog * 0.25, 0))
			# сложенные материалы
			for i in int(ext.get("wood", 0)):
				M.add(_visual, M.cyl(0.07, 0.07, 0.9, 6), M.mat(Color(0.48, 0.32, 0.18)), Vector3(sz / 2.0 + 0.5, 0.08 + (i / 3) * 0.14, -0.3 + (i % 3) * 0.16), Vector3.ONE, Vector3(PI / 2, 0, 0))
			for i in int(ext.get("stone", 0)):
				M.add(_visual, M.sphere(0.13, 0.2, 6), M.mat(Color(0.48, 0.47, 0.46)), Vector3(-sz / 2.0 - 0.5 + (i % 3) * 0.2, 0.08 + (i / 3) * 0.15, 0.2))
			# колышек с флажком — видно, что это стройка
			M.add(_visual, M.cyl(0.03, 0.03, 1.4, 5), M.mat(Color(0.4, 0.3, 0.2)), Vector3(-sz / 2.0, 0.7, -sz / 2.0))
			M.add(_visual, M.box(Vector3(0.35, 0.22, 0.02)), M.mat(Color(0.9, 0.75, 0.2)), Vector3(-sz / 2.0 + 0.18, 1.28, -sz / 2.0))
		"storage":
			for cx in [-1, 1]:
				for cz in [-1, 1]:
					M.add(_visual, M.cyl(0.08, 0.1, 0.5, 6), M.mat(Color(0.4, 0.28, 0.16)), Vector3(cx * 0.8, 0.25, cz * 0.8))
			M.add(_visual, M.box(Vector3(2.0, 1.1, 2.0)), M.mat(Color(0.62, 0.46, 0.28)), Vector3(0, 1.05, 0))
			M.add(_visual, M.prism(Vector3(2.4, 0.9, 2.3)), M.mat(Color(0.45, 0.32, 0.2)), Vector3(0, 2.05, 0))
			var baskets: int = mini(6, int(ceil(amount / 10.0)))
			for i in baskets:
				M.add(_visual, M.cyl(0.18, 0.14, 0.25, 8), M.mat(Color(0.7, 0.55, 0.3)), Vector3(-0.75 + i * 0.3, 0.12, 1.25))
				M.add(_visual, M.sphere(0.14, 0.12, 6), M.mat(Color(0.8, 0.12, 0.2)), Vector3(-0.75 + i * 0.3, 0.26, 1.25))
		"well":
			M.add(_visual, M.cyl(0.7, 0.75, 0.6, 14), M.mat(Color(0.5, 0.5, 0.52)), Vector3(0, 0.3, 0))
			M.add(_visual, M.cyl(0.55, 0.55, 0.02, 14), M.mat(Color(0.25, 0.55, 0.85)), Vector3(0, 0.55, 0))
			for sx in [-1, 1]:
				M.add(_visual, M.cyl(0.05, 0.05, 1.5, 6), M.mat(Color(0.42, 0.28, 0.16)), Vector3(sx * 0.75, 1.0, 0))
			M.add(_visual, M.prism(Vector3(1.8, 0.45, 1.0)), M.mat(Color(0.5, 0.35, 0.2)), Vector3(0, 1.85, 0))
		"tree":
			var s := 0.8 + v * 0.6
			_visual.scale = Vector3.ONE * s
			M.add(_visual, M.cyl(0.12, 0.2, 1.4, 8), M.mat(Color(0.42, 0.28, 0.16)), Vector3(0, 0.7, 0))
			var green := Color(0.16, 0.42 + v * 0.15, 0.18)
			if v < 0.35:
				# лиственное дерево — крона из сфер
				M.add(_visual, M.sphere(0.9, 1.5, 10), M.mat(green), Vector3(0, 2.0, 0))
				M.add(_visual, M.sphere(0.6, 1.0, 8), M.mat(green.lightened(0.1)), Vector3(0.35, 2.5, 0.1))
			else:
				M.add(_visual, M.cyl(0.0, 1.0, 1.6, 10), M.mat(green), Vector3(0, 1.8, 0))
				M.add(_visual, M.cyl(0.0, 0.75, 1.3, 10), M.mat(green.lightened(0.08)), Vector3(0, 2.6, 0))
		"bush":
			M.add(_visual, M.sphere(0.55, 0.8, 10), M.mat(Color(0.2, 0.45, 0.2)), Vector3(0, 0.35, 0))
			M.add(_visual, M.sphere(0.4, 0.6, 8), M.mat(Color(0.24, 0.5, 0.22)), Vector3(0.35, 0.3, 0.2))
			for i in Defs.max_amount("bush"):
				var a := i * TAU / 6.0 + v
				var b := M.add(_visual, M.sphere(0.08, -1, 6), M.mat(Color(0.85, 0.1, 0.2)),
					Vector3(cos(a) * 0.48, 0.35 + (i % 2) * 0.2, sin(a) * 0.48))
				_berries.append(b)
			_update_berries()
		"spring":
			M.add(_visual, M.cyl(1.1, 1.1, 0.06, 20), M.mat(Color(0.25, 0.6, 0.9, 0.85), 0.15, true), Vector3(0, 0.05, 0))
			for i in 9:
				var a := i * TAU / 9.0
				M.add(_visual, M.sphere(0.16, 0.2, 6), M.mat(Color(0.55, 0.55, 0.58)), Vector3(cos(a) * 1.2, 0.06, sin(a) * 1.2))
		"rock":
			var s2 := 0.7 + v * 0.8
			M.add(_visual, M.sphere(0.7, 0.9, 8), M.mat(Color(0.42, 0.41, 0.4)), Vector3(0, 0.3, 0), Vector3(1.2, 1.0, 0.9) * s2)
			M.add(_visual, M.sphere(0.4, 0.5, 6), M.mat(Color(0.36, 0.35, 0.34)), Vector3(0.6, 0.15, 0.3) * s2)
		"hut":
			M.add(_visual, M.box(Vector3(2.2, 1.4, 2.2)), M.mat(Color(0.55, 0.4, 0.25)), Vector3(0, 0.7, 0))
			M.add(_visual, M.prism(Vector3(2.7, 1.2, 2.6)), M.mat(Color(0.75, 0.62, 0.3)), Vector3(0, 2.0, 0))
			M.add(_visual, M.box(Vector3(0.6, 1.0, 0.05)), M.mat(Color(0.2, 0.12, 0.06)), Vector3(0, 0.5, 1.11))
		"grave":
			M.add(_visual, M.box(Vector3(0.7, 0.18, 1.3)), M.mat(Color(0.38, 0.3, 0.2)), Vector3(0, 0.09, 0))
			M.add(_visual, M.box(Vector3(0.5, 0.6, 0.12)), M.mat(Color(0.5, 0.5, 0.52)), Vector3(0, 0.4, -0.6))
		"campfire":
			for i in 4:
				M.add(_visual, M.cyl(0.07, 0.07, 0.8, 6), M.mat(Color(0.35, 0.22, 0.12)), Vector3(0, 0.08, 0), Vector3.ONE, Vector3(PI / 2, i * PI / 4, 0))
			for i in 8:
				var a := i * TAU / 8.0
				M.add(_visual, M.sphere(0.1, 0.12, 6), M.mat(Color(0.4, 0.4, 0.42)), Vector3(cos(a) * 0.5, 0.05, sin(a) * 0.5))
			_add_flames(2, 0.45)
		"fire":
			for i in 5:
				var a := i * TAU / 5.0 + v
				_add_flames(1, 0.8 + 0.5 * ((i * 37) % 10) / 10.0, Vector3(cos(a), 0, sin(a)) * 0.9)
			_add_flames(1, 1.4)
	if burning > 0.0:
		_add_flames(3, 0.8)

func _build_pick() -> void:
	# Зона выбора касанием
	var area := Area3D.new()
	area.collision_layer = 2
	area.collision_mask = 0
	area.set_meta("pick", self)
	var cs := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 1.4 if obj_type in ["hut", "storage", "site"] else 1.0
	shape.height = 3.0 if obj_type in ["tree", "hut", "storage"] else 1.4
	cs.shape = shape
	cs.position.y = shape.height / 2.0
	area.add_child(cs)
	add_child(area)

func _add_flames(n: int, size: float, offset: Vector3 = Vector3.ZERO) -> void:
	for i in n:
		var f := M.add(_visual, M.cyl(0.0, 0.25 * size, 0.9 * size, 8), M.mat(Color(1.0, 0.45 + 0.2 * (i % 2), 0.1), 3.0),
			offset + Vector3((i - n / 2.0) * 0.18 * size, 0.45 * size + (0.6 if obj_type == "tree" else 0.0), 0))
		f.set_meta("base", 1.0)
		f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_flames.append(f)
	if _light == null:
		_light = OmniLight3D.new()
		_light.light_color = Color(1.0, 0.6, 0.3)
		_light.omni_range = 6.0
		_light.light_energy = 1.6
		_light.position = Vector3(0, 1.0, 0)
		add_child(_light)

func _update_berries() -> void:
	for i in _berries.size():
		_berries[i].visible = i < int(amount)
