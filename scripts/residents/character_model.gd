extends Node3D
## Стилизованная объёмная модель человека из примитивов с процедурной анимацией
## (ходьба, бег, сон, еда/питьё, разговор, смерть).

const M = preload("res://scripts/core/meshes.gd")

var _body: Node3D
var _leg_l: Node3D
var _leg_r: Node3D
var _arm_l: Node3D
var _arm_r: Node3D
var _head: Node3D
var _phase := 0.0
var _t := 0.0
var _parts: Array = []

func build(appearance: Dictionary, sex: String) -> void:
	var skin: Color = Color(appearance.get("skin", "#e0b48c"))
	var hair: Color = Color(appearance.get("hair", "#3b2414"))
	var shirt: Color = Color(appearance.get("shirt", "#3f7fbf"))
	var pants: Color = Color(appearance.get("pants", "#4a3b2a"))
	var hscale: float = float(appearance.get("height", 1.0))
	scale = Vector3.ONE * hscale
	_body = Node3D.new()
	add_child(_body)
	var female := sex == "f"
	# ноги (поворотная точка в бедре)
	_leg_l = _limb(_body, Vector3(-0.11, 0.82, 0), M.capsule(0.075, 0.8), pants, Vector3(0, -0.4, 0))
	_leg_r = _limb(_body, Vector3(0.11, 0.82, 0), M.capsule(0.075, 0.8), pants, Vector3(0, -0.4, 0))
	for leg in [_leg_l, _leg_r]:
		_parts.append(M.add(leg, M.box(Vector3(0.12, 0.07, 0.22)), M.mat(Color(0.25, 0.17, 0.1)), Vector3(0, -0.79, 0.04)))
	# торс
	_parts.append(M.add(_body, M.capsule(0.19 if not female else 0.17, 0.62), M.mat(shirt), Vector3(0, 1.12, 0), Vector3(1.0, 1.0, 0.75)))
	if female:
		_parts.append(M.add(_body, M.cyl(0.17, 0.3, 0.35, 12), M.mat(shirt.darkened(0.15)), Vector3(0, 0.82, 0)))
	# руки (поворот в плече)
	_arm_l = _limb(_body, Vector3(-0.25, 1.36, 0), M.capsule(0.06, 0.62), shirt, Vector3(0, -0.28, 0))
	_arm_r = _limb(_body, Vector3(0.25, 1.36, 0), M.capsule(0.06, 0.62), shirt, Vector3(0, -0.28, 0))
	for arm in [_arm_l, _arm_r]:
		_parts.append(M.add(arm, M.sphere(0.065, -1, 8), M.mat(skin), Vector3(0, -0.6, 0)))
	# голова
	_head = Node3D.new()
	_head.position = Vector3(0, 1.58, 0)
	_body.add_child(_head)
	_parts.append(M.add(_head, M.cyl(0.06, 0.07, 0.12, 8), M.mat(skin), Vector3(0, -0.08, 0)))
	_parts.append(M.add(_head, M.sphere(0.15, 0.32, 14), M.mat(skin), Vector3(0, 0.1, 0)))
	_parts.append(M.add(_head, M.sphere(0.155, 0.2, 14), M.mat(hair), Vector3(0, 0.2, -0.015)))
	if female:
		_parts.append(M.add(_head, M.capsule(0.12, 0.45), M.mat(hair), Vector3(0, 0.0, -0.1), Vector3(1.1, 1.0, 0.6)))
	for sx in [-1, 1]:
		M.add(_head, M.sphere(0.022, -1, 6), M.mat(Color(0.08, 0.08, 0.1)), Vector3(0.055 * sx, 0.13, 0.135))
	for p in _parts:
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func _limb(parent: Node3D, pivot: Vector3, mesh: Mesh, color: Color, offset: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pivot
	parent.add_child(n)
	_parts.append(M.add(n, mesh, M.mat(color), offset))
	return n

## state: "idle", "walk", "run", "sleep", "eat", "drink", "talk", "dead", "rest"
func animate(delta: float, state: String, speed: float) -> void:
	_t += delta
	var lying := state == "sleep" or state == "dead"
	_body.rotation.z = lerp_angle(_body.rotation.z, PI / 2.0 if lying else 0.0, clampf(delta * 5.0, 0.0, 1.0))
	_body.position.y = lerpf(_body.position.y, 0.18 if lying else 0.0, clampf(delta * 5.0, 0.0, 1.0))
	_body.position.x = lerpf(_body.position.x, 0.8 if lying else 0.0, clampf(delta * 5.0, 0.0, 1.0))
	if state == "walk" or state == "run":
		_phase += delta * speed * (7.0 if state == "walk" else 10.0)
		var amp := 0.55 if state == "walk" else 0.9
		var s := sin(_phase)
		_leg_l.rotation.x = s * amp
		_leg_r.rotation.x = -s * amp
		_arm_l.rotation.x = -s * amp * 0.8
		_arm_r.rotation.x = s * amp * 0.8
		_body.position.y = absf(cos(_phase)) * 0.04
		_head.rotation = Vector3.ZERO
	else:
		var k := clampf(delta * 6.0, 0.0, 1.0)
		_leg_l.rotation.x = lerpf(_leg_l.rotation.x, 0.0, k)
		_leg_r.rotation.x = lerpf(_leg_r.rotation.x, 0.0, k)
		var arm_target := 0.0
		var arm_l_target := 0.0
		match state:
			"eat", "drink":
				arm_target = -1.9 + sin(_t * 5.0) * 0.25
				_head.rotation.x = 0.3 if state == "drink" else 0.1
			"talk":
				arm_target = -0.4 + sin(_t * 3.0) * 0.35
				arm_l_target = -0.2 + sin(_t * 2.3 + 1.0) * 0.2
				_head.rotation.y = sin(_t * 1.7) * 0.2
				_head.rotation.x = sin(_t * 4.0) * 0.06
			"rest":
				_leg_l.rotation.x = lerpf(_leg_l.rotation.x, -1.4, k)
				_leg_r.rotation.x = lerpf(_leg_r.rotation.x, -1.4, k)
				_body.position.y = lerpf(_body.position.y, -0.45, k)
			_:
				_head.rotation.y = sin(_t * 0.6) * 0.35
				_head.rotation.x = 0.0
		_arm_r.rotation.x = lerpf(_arm_r.rotation.x, arm_target, k)
		_arm_l.rotation.x = lerpf(_arm_l.rotation.x, arm_l_target, k)

func set_dead_look() -> void:
	for p in _parts:
		var mi := p as MeshInstance3D
		if mi and mi.material_override is StandardMaterial3D:
			var c: Color = (mi.material_override as StandardMaterial3D).albedo_color
			mi.material_override = M.mat(Color(c.get_luminance(), c.get_luminance(), c.get_luminance()).darkened(0.2))
