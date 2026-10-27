extends RefCounted
## Описание типов объектов мира. Единый источник правды для симуляции, редактора и интерфейса.

const DEFS := {
	"tree": {"name": "Дерево", "blocks": true, "max": 4},
	"bush": {"name": "Ягодный куст", "blocks": false, "food": true, "max": 6, "regen_h": 8.0},
	"spring": {"name": "Родник", "blocks": false, "water": true, "max": 0},
	"rock": {"name": "Камень", "blocks": true, "max": 8},
	"hut": {"name": "Хижина", "blocks": true, "shelter": true, "max": 0},
	"campfire": {"name": "Костёр", "blocks": false, "warmth": true, "max": 0},
	"fire": {"name": "Пожар", "blocks": true, "danger": true, "max": 0, "life_h": 10.0},
	"grave": {"name": "Могила", "blocks": false, "max": 0},
	"site": {"name": "Стройка", "blocks": false, "max": 0},
	"storage": {"name": "Амбар", "blocks": true, "food": true, "max": 0},
	"well": {"name": "Колодец", "blocks": false, "water": true, "max": 0},
}

## Инструменты, доступные создателю (порядок = порядок кнопок).
const PLACEABLE := ["tree", "bush", "spring", "rock", "hut", "campfire", "storage", "well", "fire"]

static func display_name(t: String) -> String:
	return DEFS.get(t, {}).get("name", t)

static func has_flag(t: String, flag: String) -> bool:
	return bool(DEFS.get(t, {}).get(flag, false))

static func max_amount(t: String) -> int:
	return int(DEFS.get(t, {}).get("max", 0))
