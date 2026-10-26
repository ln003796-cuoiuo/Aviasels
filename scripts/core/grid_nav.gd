extends RefCounted
## Навигация по сетке (A*): вода, крутые склоны и препятствия непроходимы.

var size: int
var astar := AStarGrid2D.new()
var _terrain_block := PackedByteArray()
var _obstacles := {}  # Vector2i -> количество объектов-препятствий
var terrain  # ссылка на Terrain

func setup(t) -> void:
	terrain = t
	_obstacles.clear()
	astar = AStarGrid2D.new()
	size = t.SIZE
	astar.region = Rect2i(0, 0, size, size)
	astar.cell_size = Vector2(1, 1)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	_terrain_block.resize(size * size)
	rebuild_terrain()

func rebuild_terrain() -> void:
	for z in size:
		for x in size:
			var h: float = terrain.cell_height(x, z)
			var s: float = terrain.cell_slope(x, z)
			var blocked := h < 0.2 or s > 1.6
			_terrain_block[z * size + x] = 1 if blocked else 0
			astar.set_point_weight_scale(Vector2i(x, z), 1.0 + s * 1.5)
			_refresh(Vector2i(x, z))

func _refresh(c: Vector2i) -> void:
	astar.set_point_solid(c, _terrain_block[c.y * size + c.x] == 1 or _obstacles.get(c, 0) > 0)

func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(clampi(int(floor(p.x + size / 2.0)), 0, size - 1), clampi(int(floor(p.z + size / 2.0)), 0, size - 1))

func cell_to_world(c: Vector2i) -> Vector3:
	var x := c.x - size / 2.0 + 0.5
	var z := c.y - size / 2.0 + 0.5
	return Vector3(x, terrain.height_at(x, z), z)

func add_obstacle(p: Vector3, radius: int = 0) -> void:
	_mod_obstacle(p, radius, 1)

func remove_obstacle(p: Vector3, radius: int = 0) -> void:
	_mod_obstacle(p, radius, -1)

func _mod_obstacle(p: Vector3, radius: int, delta: int) -> void:
	var c := world_to_cell(p)
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var cc := c + Vector2i(dx, dz)
			if not astar.is_in_boundsv(cc):
				continue
			var v: int = _obstacles.get(cc, 0) + delta
			if v <= 0:
				_obstacles.erase(cc)
			else:
				_obstacles[cc] = v
			_refresh(cc)

func is_walkable(p: Vector3) -> bool:
	var c := world_to_cell(p)
	return not astar.is_point_solid(c)

func nearest_walkable(c: Vector2i, max_r: int = 6) -> Vector2i:
	if astar.is_in_boundsv(c) and not astar.is_point_solid(c):
		return c
	for r in range(1, max_r + 1):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dz) != r:
					continue
				var cc := c + Vector2i(dx, dz)
				if astar.is_in_boundsv(cc) and not astar.is_point_solid(cc):
					return cc
	return Vector2i(-1, -1)

## Путь в мировых координатах. Пустой массив — пути нет.
func find_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	var a := nearest_walkable(world_to_cell(from), 4)
	var b := nearest_walkable(world_to_cell(to), 4)
	if a.x < 0 or b.x < 0:
		return out
	if a == b:
		out.append(cell_to_world(b))
		return out
	var ids := astar.get_id_path(a, b)
	if ids.is_empty():
		return out
	for i in range(1, ids.size()):
		out.append(cell_to_world(ids[i]))
	return out
