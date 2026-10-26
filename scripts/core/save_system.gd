extends RefCounted
## Сохранения: 3 ручных слота + автосохранение. Запись атомарная (временный файл -> переименование).

const DIR := "user://saves"
const SLOTS := ["slot_1", "slot_2", "slot_3"]
const AUTO := "autosave"

static func _path(slot: String) -> String:
	return "%s/%s.json" % [DIR, slot]

static func save(world, slot: String) -> String:
	DirAccess.make_dir_recursive_absolute(DIR)
	var data: Dictionary = world.to_dict()
	data["saved_at"] = Time.get_datetime_string_from_system()
	data["summary"] = "%s · жителей: %d" % [world.time_string(), world.alive_count()]
	var tmp := _path(slot) + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "Не удалось записать файл (%s)" % error_string(FileAccess.get_open_error())
	f.store_string(JSON.stringify(data))
	f.close()
	var dir := DirAccess.open(DIR)
	if dir == null:
		return "Нет доступа к папке сохранений"
	if dir.file_exists(slot + ".json"):
		dir.remove(slot + ".json")
	var err := dir.rename(slot + ".json.tmp", slot + ".json")
	if err != OK:
		return "Не удалось завершить сохранение (%s)" % error_string(err)
	return ""

static func read(slot: String):
	var p := _path(slot)
	if not FileAccess.file_exists(p):
		return null
	var txt := FileAccess.get_file_as_string(p)
	var j := JSON.new()
	if j.parse(txt) != OK or not (j.data is Dictionary):
		return "corrupt"
	return j.data

static func load_into(world, slot: String) -> String:
	var d = read(slot)
	if d == null:
		return "Слот пуст"
	if d is String:
		return "Сохранение повреждено и не может быть загружено"
	return world.load_dict(d)

static func exists(slot: String) -> bool:
	return FileAccess.file_exists(_path(slot))

static func summary(slot: String) -> String:
	var d = read(slot)
	if d == null:
		return "пусто"
	if d is String:
		return "повреждено"
	return "%s (%s)" % [d.get("summary", "?"), str(d.get("saved_at", "")).replace("T", " ")]

static func delete(slot: String) -> void:
	if exists(slot):
		DirAccess.remove_absolute(_path(slot))
