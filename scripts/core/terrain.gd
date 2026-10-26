extends Node3D
## Процедурный рельеф: карта высот по seed, 3D-меш, коллизия для касаний и изменение кистью.

const SIZE := 96          # клеток по стороне
const WATER_LEVEL := 0.0

var heights := PackedFloat32Array()   # (SIZE+1)^2 вершин
var _mesh_inst: MeshInstance3D
var _body: StaticBody3D
var _shape: HeightMapShape3D
var _water: MeshInstance3D

func _ready() -> void:
	_mesh_inst = MeshInstance3D.new()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.95
	_mesh_inst.material_override = m
	add_child(_mesh_inst)
	_body = StaticBody3D.new()
	_body.collision_layer = 1
	var cs := CollisionShape3D.new()
	_shape = HeightMapShape3D.new()
	_shape.map_width = SIZE + 1
	_shape.map_depth = SIZE + 1
	cs.shape = _shape
	_body.add_child(cs)
	add_child(_body)
	_water = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(SIZE * 3, SIZE * 3)
	_water.mesh = pm
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.08, 0.28, 0.5, 0.82)
	wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wm.roughness = 0.15
	wm.metallic = 0.1
	_water.material_override = wm
	_water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_water.position.y = WATER_LEVEL
	add_child(_water)

static func vcount() -> int:
	return SIZE + 1

func generate(seed_value: int) -> void:
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.022
	n.fractal_octaves = 4
	var ridge := FastNoiseLite.new()
	ridge.seed = seed_value + 101
	ridge.frequency = 0.03
	ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridge.fractal_octaves = 3
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var mountain_dir := Vector2.from_angle(rng.randf() * TAU) * SIZE * 0.32
	heights.resize(vcount() * vcount())
	var half := SIZE / 2.0
	for z in vcount():
		for x in vcount():
			var p := Vector2(x - half, z - half)
			var d := p.length() / half
			var h := 1.6 + n.get_noise_2d(p.x, p.y) * 3.2
			# горный массив в одной стороне острова
			var md := (p - mountain_dir).length() / (SIZE * 0.3)
			if md < 1.0:
				h += (1.0 - md) * (1.0 - md) * (6.0 + ridge.get_noise_2d(p.x, p.y) * 5.0)
			# озеро
			var ld := (p + mountain_dir * 0.7).length() / 9.0
			if ld < 1.0:
				h -= (1.0 - ld) * 3.5
			# берег и океан по краям
			h -= pow(maxf(0.0, d - 0.55), 2.0) * 22.0
			# ровная стартовая поляна в центре
			var cd := p.length() / 10.0
			if cd < 1.0:
				h = lerpf(1.3, h, smoothstep(0.0, 1.0, cd))
			heights[z * vcount() + x] = h
	rebuild()

func rebuild() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := SIZE / 2.0
	var vc := vcount()
	for z in vc:
		for x in vc:
			var h := heights[z * vc + x]
			st.set_color(_color_for(h, _slope_at_vertex(x, z)))
			st.add_vertex(Vector3(x - half, h, z - half))
	for z in SIZE:
		for x in SIZE:
			var i := z * vc + x
			st.add_index(i)
			st.add_index(i + 1)
			st.add_index(i + vc)
			st.add_index(i + 1)
			st.add_index(i + vc + 1)
			st.add_index(i + vc)
	st.generate_normals()
	_mesh_inst.mesh = st.commit()
	_shape.map_data = heights

func _slope_at_vertex(x: int, z: int) -> float:
	var vc := vcount()
	var h := heights[z * vc + x]
	var m := 0.0
	if x > 0: m = maxf(m, absf(h - heights[z * vc + x - 1]))
	if x < SIZE: m = maxf(m, absf(h - heights[z * vc + x + 1]))
	if z > 0: m = maxf(m, absf(h - heights[(z - 1) * vc + x]))
	if z < SIZE: m = maxf(m, absf(h - heights[(z + 1) * vc + x]))
	return m

func _color_for(h: float, slope: float) -> Color:
	var c: Color
	if h < -0.3:
		c = Color(0.55, 0.5, 0.38)
	elif h < 0.35:
		c = Color(0.86, 0.78, 0.55)
	elif h < 4.5:
		c = Color(0.3, 0.55, 0.22).lerp(Color(0.38, 0.5, 0.25), clampf((h - 0.35) / 4.0, 0.0, 1.0))
	elif h < 8.0:
		c = Color(0.45, 0.42, 0.36)
	else:
		c = Color(0.92, 0.93, 0.96)
	if slope > 1.1 and h >= 0.35 and h < 8.0:
		c = c.lerp(Color(0.48, 0.45, 0.4), clampf((slope - 1.1) * 1.5, 0.0, 0.8))
	return c

## Высота в мировой точке (билинейная интерполяция).
func height_at(x: float, z: float) -> float:
	var half := SIZE / 2.0
	var fx := clampf(x + half, 0.0, SIZE - 0.001)
	var fz := clampf(z + half, 0.0, SIZE - 0.001)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	var vc := vcount()
	var h00 := heights[iz * vc + ix]
	var h10 := heights[iz * vc + ix + 1]
	var h01 := heights[(iz + 1) * vc + ix]
	var h11 := heights[(iz + 1) * vc + ix + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

## Максимальный перепад высот внутри клетки.
func cell_slope(cx: int, cz: int) -> float:
	var vc := vcount()
	var a := heights[cz * vc + cx]
	var b := heights[cz * vc + cx + 1]
	var c := heights[(cz + 1) * vc + cx]
	var d := heights[(cz + 1) * vc + cx + 1]
	return maxf(maxf(a, b), maxf(c, d)) - minf(minf(a, b), minf(c, d))

func cell_height(cx: int, cz: int) -> float:
	var vc := vcount()
	return (heights[cz * vc + cx] + heights[cz * vc + cx + 1] + heights[(cz + 1) * vc + cx] + heights[(cz + 1) * vc + cx + 1]) * 0.25

## Кисть рельефа. Возвращает {indices, before, after} для отмены.
func brush(center: Vector3, radius: float, strength: float) -> Dictionary:
	var half := SIZE / 2.0
	var vc := vcount()
	var idx := PackedInt32Array()
	var before := PackedFloat32Array()
	var after := PackedFloat32Array()
	var cx := int(round(center.x + half))
	var cz := int(round(center.z + half))
	var r := int(ceil(radius))
	for z in range(maxi(1, cz - r), mini(SIZE - 1, cz + r) + 1):
		for x in range(maxi(1, cx - r), mini(SIZE - 1, cx + r) + 1):
			var d := Vector2(x - cx, z - cz).length() / radius
			if d >= 1.0:
				continue
			var i := z * vc + x
			var k := (1.0 - d * d)
			idx.append(i)
			before.append(heights[i])
			heights[i] = clampf(heights[i] + strength * k, -4.0, 16.0)
			after.append(heights[i])
	rebuild()
	return {"indices": idx, "before": before, "after": after}

func apply_values(indices: PackedInt32Array, values: PackedFloat32Array) -> void:
	for k in indices.size():
		heights[indices[k]] = values[k]
	rebuild()
