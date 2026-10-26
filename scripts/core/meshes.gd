extends RefCounted
## Общие меши и материалы (кэшируются, чтобы не создавать дубликаты на каждом объекте).

static var _mats: Dictionary = {}
static var _meshes: Dictionary = {}

static func mat(color: Color, emission: float = 0.0, alpha: bool = false) -> StandardMaterial3D:
	var key := "%s|%s|%s" % [color.to_html(), emission, alpha]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.85
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emission
	if alpha:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mats[key] = m
	return m

static func sphere(r: float, h: float = -1.0, segs: int = 12) -> SphereMesh:
	var key := "s%s_%s_%s" % [r, h, segs]
	if not _meshes.has(key):
		var s := SphereMesh.new()
		s.radius = r
		s.height = r * 2.0 if h < 0.0 else h
		s.radial_segments = segs
		s.rings = maxi(4, segs / 2)
		_meshes[key] = s
	return _meshes[key]

static func cyl(top: float, bottom: float, h: float, segs: int = 10) -> CylinderMesh:
	var key := "c%s_%s_%s_%s" % [top, bottom, h, segs]
	if not _meshes.has(key):
		var c := CylinderMesh.new()
		c.top_radius = top
		c.bottom_radius = bottom
		c.height = h
		c.radial_segments = segs
		c.rings = 1
		_meshes[key] = c
	return _meshes[key]

static func capsule(r: float, h: float) -> CapsuleMesh:
	var key := "k%s_%s" % [r, h]
	if not _meshes.has(key):
		var c := CapsuleMesh.new()
		c.radius = r
		c.height = h
		c.radial_segments = 10
		c.rings = 4
		_meshes[key] = c
	return _meshes[key]

static func box(size: Vector3) -> BoxMesh:
	var key := "b%s" % [size]
	if not _meshes.has(key):
		var b := BoxMesh.new()
		b.size = size
		_meshes[key] = b
	return _meshes[key]

static func prism(size: Vector3) -> PrismMesh:
	var key := "p%s" % [size]
	if not _meshes.has(key):
		var p := PrismMesh.new()
		p.size = size
		_meshes[key] = p
	return _meshes[key]

static func torus(inner: float, outer: float) -> TorusMesh:
	var key := "t%s_%s" % [inner, outer]
	if not _meshes.has(key):
		var t := TorusMesh.new()
		t.inner_radius = inner
		t.outer_radius = outer
		t.rings = 24
		t.ring_segments = 6
		_meshes[key] = t
	return _meshes[key]

## Создаёт MeshInstance3D и добавляет к родителю.
static func add(parent: Node3D, mesh: Mesh, material: Material, pos: Vector3 = Vector3.ZERO, scl: Vector3 = Vector3.ONE, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.scale = scl
	mi.rotation = rot
	parent.add_child(mi)
	return mi
