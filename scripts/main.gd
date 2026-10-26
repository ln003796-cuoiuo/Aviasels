extends Node3D
## Точка входа: свет и небо, смена дня и ночи, камера, мир, интерфейс, касания, автосохранение.

const GameWorld = preload("res://scripts/core/game_world.gd")
const OrbitCamera = preload("res://scripts/camera/orbit_camera.gd")
const Hud = preload("res://scripts/ui/hud.gd")
const SaveSystem = preload("res://scripts/core/save_system.gd")

const AUTOSAVE_EVERY_MIN := 6 * 60.0

var world
var camera
var hud
var sun: DirectionalLight3D
var env: Environment
var sky_mat: ProceduralSkyMaterial
var selected = null
var _last_autosave := 0.0

func _ready() -> void:
	get_tree().set_auto_accept_quit(false)
	get_tree().set_quit_on_go_back(false)
	_setup_environment()
	world = GameWorld.new()
	world.name = "World"
	add_child(world)
	camera = OrbitCamera.new()
	add_child(camera)
	camera.current = true
	hud = Hud.new()
	add_child(hud)
	hud.setup(self, world)
	camera.ui_blocker = hud.is_over_ui
	camera.tapped.connect(_on_tap)
	world.world_reset.connect(_on_world_reset)
	world.object_removed.connect(func(id): if selected != null and is_instance_valid(selected) and selected.get("obj_id") == id: select(null))
	var err := SaveSystem.load_into(world, SaveSystem.AUTO)
	if err != "":
		if SaveSystem.exists(SaveSystem.AUTO):
			push_warning("Автосохранение не загружено: " + err)
			hud.toast("Автосохранение не загружено: " + err + ". Создан новый мир")
		world.new_world(randi() % 1000000)
	else:
		hud.toast("Мир продолжается с автосохранения")
	set_speed(1)

func _setup_environment() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky_mat = ProceduralSkyMaterial.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.4
	env.ambient_light_sky_contribution = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.9
	env.fog_enabled = true
	env.fog_density = 0.0025
	env.fog_sky_affect = 0.2
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 70.0
	sun.shadow_bias = 0.05
	add_child(sun)

func _process(_delta: float) -> void:
	_update_daylight()
	if world.time_min - _last_autosave >= AUTOSAVE_EVERY_MIN:
		_last_autosave = world.time_min
		var err := SaveSystem.save(world, SaveSystem.AUTO)
		if err != "":
			hud.toast("Ошибка автосохранения: " + err)

func _update_daylight() -> void:
	var h: float = world.hour_f()
	# солнце: восход 6:00, закат 20:00
	var t := (h - 6.0) / 14.0
	var elev := sin(clampf(t, 0.0, 1.0) * PI)
	var day_k := clampf(elev * 3.0, 0.0, 1.0)
	if t < 0.0 or t > 1.0:
		day_k = 0.0
	var az := lerpf(-1.2, 1.2, clampf(t, 0.0, 1.0))
	sun.rotation = Vector3(-maxf(0.15, elev * 1.25), az, 0)
	var warm := 1.0 - clampf(elev * 2.5, 0.0, 1.0)
	sun.light_color = Color(1.0, 0.95, 0.88).lerp(Color(1.0, 0.6, 0.35), warm).lerp(Color(0.5, 0.6, 0.9), 1.0 - day_k)
	sun.light_energy = lerpf(0.12, 1.0, day_k)
	sky_mat.sky_top_color = Color(0.02, 0.03, 0.09).lerp(Color(0.18, 0.4, 0.78), day_k)
	sky_mat.sky_horizon_color = Color(0.06, 0.08, 0.15).lerp(Color(0.6, 0.72, 0.85), day_k).lerp(Color(0.95, 0.6, 0.4), warm * day_k * 0.6)
	sky_mat.ground_horizon_color = sky_mat.sky_horizon_color
	sky_mat.ground_bottom_color = Color(0.05, 0.05, 0.07).lerp(Color(0.3, 0.32, 0.3), day_k)
	env.ambient_light_energy = lerpf(0.2, 0.45, day_k)
	env.fog_light_color = sky_mat.sky_horizon_color

# ---------------------------------------------------------------- касания

func _pick(screen_pos: Vector2, mask: int) -> Dictionary:
	var from: Vector3 = camera.project_ray_origin(screen_pos)
	var to: Vector3 = from + camera.project_ray_normal(screen_pos) * 400.0
	var q := PhysicsRayQueryParameters3D.create(from, to, mask)
	q.collide_with_areas = true
	q.collide_with_bodies = mask & 1 != 0
	return get_world_3d().direct_space_state.intersect_ray(q)

func _on_tap(screen_pos: Vector2) -> void:
	var tool: String = hud.tool
	match tool:
		"select", "delete":
			var hit := _pick(screen_pos, 2)
			var target = hit["collider"].get_meta("pick") if not hit.is_empty() and hit["collider"].has_meta("pick") else null
			if tool == "delete":
				if target != null and target.has_method("describe"):
					hud.toast("Удалено: " + target.display_name().to_lower())
					world.cmd_remove(target.obj_id)
				elif target != null:
					hud.toast("Жителей удалять нельзя")
				return
			select(target)
		"raise", "lower":
			var hit2 := _pick(screen_pos, 1)
			if not hit2.is_empty():
				world.cmd_terrain(hit2["position"], 0.7 if tool == "raise" else -0.7)
		_:
			var hit3 := _pick(screen_pos, 1)
			if hit3.is_empty():
				return
			var err: String = world.cmd_place(tool, hit3["position"])
			if err != "":
				hud.toast(err)

func select(obj) -> void:
	if selected != null and is_instance_valid(selected) and selected.has_method("sim_step"):
		selected.selected = false
	selected = obj
	if obj != null and obj.has_method("sim_step"):
		obj.selected = true
	else:
		camera.follow = null
		hud.set_follow_display(false)
	hud.show_selection(obj)

func toggle_follow() -> void:
	if selected != null and selected.has_method("sim_step"):
		camera.follow = null if camera.follow == selected else selected
		if camera.follow:
			camera.distance = minf(camera.distance, 16.0)
	hud.set_follow_display(camera.follow != null)

func set_speed(s: int) -> void:
	world.speed = s
	hud.set_speed_display(s)

func set_shadows(on: bool) -> void:
	sun.shadow_enabled = on

func new_world(s: int) -> void:
	select(null)
	world.new_world(s)
	_last_autosave = world.time_min
	SaveSystem.save(world, SaveSystem.AUTO)
	hud.toast("Создан новый мир, seed %d" % s)

func save_to(slot: String) -> void:
	var err := SaveSystem.save(world, slot)
	hud.toast("Сохранено" if err == "" else "Ошибка: " + err)
	hud.show_menu(true)

func load_from(slot: String) -> void:
	select(null)
	var err := SaveSystem.load_into(world, slot)
	if err == "":
		_last_autosave = world.time_min
		hud.toast("Мир загружен")
		hud.show_menu(false)
	else:
		hud.toast("Не удалось загрузить: " + err)

func _on_world_reset() -> void:
	camera.follow = null
	camera.focus_on(Vector3(0, world.terrain.height_at(0, 0), 0), 24.0)

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT:
			if world:
				SaveSystem.save(world, SaveSystem.AUTO)
		NOTIFICATION_WM_CLOSE_REQUEST:
			if world:
				SaveSystem.save(world, SaveSystem.AUTO)
			get_tree().quit()
		NOTIFICATION_WM_GO_BACK_REQUEST:
			if hud and not hud.close_panels():
				hud.show_menu(true)
