extends Camera3D
## Орбитальная камера: один палец — вращение, два пальца — масштаб и сдвиг, касание — выбор.
## Мышь: ЛКМ — вращение, ПКМ — сдвиг, колесо — масштаб.

signal tapped(screen_pos: Vector2)

var target := Vector3(0, 1, 0)
var yaw := 0.6
var pitch := -0.75
var distance := 26.0
var follow: Node3D = null
var ui_blocker: Callable   # func(pos: Vector2) -> bool

var _touches := {}         # index -> позиция
var _press_pos := Vector2.ZERO
var _press_time := 0
var _moved := 0.0
var _pinch_dist := 0.0
var _pinch_mid := Vector2.ZERO
var _mouse_btn := 0

const MIN_DIST := 5.0
const MAX_DIST := 95.0

func _ready() -> void:
	fov = 55.0
	near = 0.1
	far = 400.0
	_apply()

func _over_ui(p: Vector2) -> bool:
	return ui_blocker.is_valid() and ui_blocker.call(p)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			if _over_ui(event.position):
				return
			_touches[event.index] = event.position
			if _touches.size() == 1:
				_press_pos = event.position
				_press_time = Time.get_ticks_msec()
				_moved = 0.0
			elif _touches.size() == 2:
				_init_pinch()
				_moved = 999.0
		else:
			if _touches.has(event.index):
				_touches.erase(event.index)
				if _touches.is_empty() and _moved < 18.0 and Time.get_ticks_msec() - _press_time < 600:
					tapped.emit(event.position)
				if _touches.size() == 1:
					_moved = 999.0
	elif event is InputEventScreenDrag:
		if not _touches.has(event.index):
			return
		_touches[event.index] = event.position
		if _touches.size() == 1:
			_moved += event.relative.length()
			if _moved > 10.0:
				_rotate(event.relative)
		elif _touches.size() == 2:
			var pts: Array = _touches.values()
			var d: float = (pts[0] as Vector2).distance_to(pts[1])
			var mid: Vector2 = ((pts[0] as Vector2) + (pts[1] as Vector2)) / 2.0
			if _pinch_dist > 0.0 and d > 0.0:
				distance = clampf(distance * _pinch_dist / d, MIN_DIST, MAX_DIST)
			_pan(mid - _pinch_mid)
			_pinch_dist = d
			_pinch_mid = mid
			_apply()
	elif event is InputEventMouseButton and event.device != InputEvent.DEVICE_ID_EMULATION:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			distance = clampf(distance * 0.9, MIN_DIST, MAX_DIST)
			_apply()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			distance = clampf(distance * 1.1, MIN_DIST, MAX_DIST)
			_apply()
		elif event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			if event.pressed:
				if _over_ui(event.position):
					return
				_mouse_btn = event.button_index
				_press_pos = event.position
				_press_time = Time.get_ticks_msec()
				_moved = 0.0
			elif _mouse_btn == event.button_index:
				if _mouse_btn == MOUSE_BUTTON_LEFT and _moved < 8.0:
					tapped.emit(event.position)
				_mouse_btn = 0
	elif event is InputEventMouseMotion and event.device != InputEvent.DEVICE_ID_EMULATION and _mouse_btn != 0:
		_moved += event.relative.length()
		if _mouse_btn == MOUSE_BUTTON_LEFT:
			if _moved > 6.0:
				_rotate(event.relative)
		else:
			_pan(event.relative)
			_apply()

func _init_pinch() -> void:
	var pts: Array = _touches.values()
	_pinch_dist = (pts[0] as Vector2).distance_to(pts[1])
	_pinch_mid = ((pts[0] as Vector2) + (pts[1] as Vector2)) / 2.0

func _rotate(rel: Vector2) -> void:
	yaw -= rel.x * 0.006
	pitch = clampf(pitch - rel.y * 0.005, -1.45, -0.18)
	_apply()

func _pan(rel: Vector2) -> void:
	follow = null
	var k := distance * 0.0022
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var fwd := Vector3(sin(yaw), 0, cos(yaw))
	target -= right * rel.x * k
	target -= fwd * rel.y * k
	target.x = clampf(target.x, -50.0, 50.0)
	target.z = clampf(target.z, -50.0, 50.0)

func focus_on(p: Vector3, dist: float = -1.0) -> void:
	target = p + Vector3(0, 1, 0)
	if dist > 0.0:
		distance = dist
	_apply()

func _process(delta: float) -> void:
	if follow != null and is_instance_valid(follow):
		target = target.lerp(follow.global_position + Vector3(0, 1.0, 0), clampf(delta * 4.0, 0.0, 1.0))
		_apply()

func _apply() -> void:
	var off := Vector3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch)) * distance
	global_position = target + off
	look_at(target, Vector3.UP)
