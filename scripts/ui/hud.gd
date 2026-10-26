extends CanvasLayer
## Интерфейс: время и скорость, инструменты создателя, карточка жителя, журнал, список жителей, меню.

const Defs = preload("res://scripts/core/object_defs.gd")
const Mind = preload("res://scripts/residents/mind.gd")
const Brain = preload("res://scripts/residents/brain.gd")
const SaveSystem = preload("res://scripts/core/save_system.gd")
const Family = preload("res://scripts/residents/family.gd")

var main      # main.gd
var world

var tool := "select"
var _tool_buttons := {}
var _speed_buttons := {}
var _time_label: Label
var _stats_label: Label
var _blockers: Array = []

var _card: PanelContainer
var _card_title: Label
var _card_info: Label
var _card_bars := {}
var _card_text: RichTextLabel
var _follow_btn: Button

var _obj_panel: PanelContainer
var _obj_label: Label
var _selected_obj_id := -1

var _side: PanelContainer
var _side_title: Label
var _side_text: RichTextLabel
var _side_mode := ""
var _chart: Control

var _menu: PanelContainer
var _slot_labels := {}
var _seed_edit: LineEdit
var _shadow_check: CheckButton

var _toast: Label
var _toast_t := 0.0
var _refresh_t := 0.0

func setup(m, w) -> void:
	main = m
	world = w
	layer = 10
	_build()
	world.event_logged.connect(func(_e): if _side_mode == "log": _refresh_side())

# ---------------------------------------------------------------- построение

func _theme() -> Theme:
	var th := Theme.new()
	th.default_font = load("res://fonts/NotoSans-Regular.ttf")
	th.default_font_size = 20
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.06, 0.09, 0.14, 0.86)
	panel.set_corner_radius_all(14)
	panel.set_content_margin_all(10)
	th.set_stylebox("panel", "PanelContainer", panel)
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		var b := StyleBoxFlat.new()
		b.set_corner_radius_all(10)
		b.set_content_margin_all(8)
		match st:
			"normal": b.bg_color = Color(0.17, 0.24, 0.33)
			"hover": b.bg_color = Color(0.22, 0.31, 0.42)
			"pressed": b.bg_color = Color(0.9, 0.62, 0.15)
			"focus":
				b.bg_color = Color(0, 0, 0, 0)
				b.draw_center = false
			"disabled": b.bg_color = Color(0.12, 0.14, 0.18)
		th.set_stylebox(st, "Button", b)
	th.set_color("font_pressed_color", "Button", Color(0.08, 0.06, 0.02))
	th.set_color("font_color", "Label", Color(0.93, 0.95, 0.98))
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.15, 0.17, 0.22)
	bar_bg.set_corner_radius_all(6)
	th.set_stylebox("background", "ProgressBar", bar_bg)
	th.set_font_size("font_size", "ProgressBar", 14)
	return th

func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _theme()
	add_child(root)

	# --- верхняя левая панель: время и скорость
	var top := PanelContainer.new()
	top.position = Vector2(10, 10)
	root.add_child(top)
	_blockers.append(top)
	var tv := VBoxContainer.new()
	top.add_child(tv)
	var th := HBoxContainer.new()
	th.add_theme_constant_override("separation", 6)
	tv.add_child(th)
	_time_label = Label.new()
	_time_label.custom_minimum_size = Vector2(190, 0)
	_time_label.add_theme_font_size_override("font_size", 22)
	th.add_child(_time_label)
	for sp in [[0, "II"], [1, "x1"], [3, "x3"], [10, "x10"], [30, "x30"]]:
		var b := _button(sp[1], func(): main.set_speed(sp[0]), Vector2(62, 52))
		b.toggle_mode = true
		th.add_child(b)
		_speed_buttons[sp[0]] = b
	_stats_label = Label.new()
	_stats_label.add_theme_font_size_override("font_size", 16)
	_stats_label.modulate = Color(0.8, 0.86, 0.95)
	tv.add_child(_stats_label)

	# --- верхняя правая панель
	var tr := PanelContainer.new()
	tr.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	tr.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	tr.position = Vector2(-10, 10)
	root.add_child(tr)
	_blockers.append(tr)
	var trh := HBoxContainer.new()
	trh.add_theme_constant_override("separation", 6)
	tr.add_child(trh)
	trh.add_child(_button("Жители", func(): _toggle_side("people")))
	trh.add_child(_button("Семьи", func(): _toggle_side("family")))
	trh.add_child(_button("Журнал", func(): _toggle_side("log")))
	trh.add_child(_button("Мир", func(): _toggle_side("world")))
	trh.add_child(_button("Меню", func(): show_menu(not _menu.visible)))

	# --- нижняя панель инструментов
	var bottom := PanelContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bottom.offset_left = 10
	bottom.offset_right = -10
	bottom.offset_bottom = -8
	root.add_child(bottom)
	_blockers.append(bottom)
	var scroll := ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 66)
	bottom.add_child(scroll)
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 6)
	scroll.add_child(tools)
	var tool_list: Array = [["select", "Выбор"]]
	for t in Defs.PLACEABLE:
		tool_list.append([t, Defs.display_name(t).replace("Ягодный куст", "Куст")])
	tool_list += [["raise", "Поднять"], ["lower", "Опустить"], ["delete", "Удалить"]]
	for tl in tool_list:
		var b := _button(tl[1], func(): set_tool(tl[0]), Vector2(96, 56))
		b.toggle_mode = true
		tools.add_child(b)
		_tool_buttons[tl[0]] = b
	var sep := VSeparator.new()
	tools.add_child(sep)
	tools.add_child(_button("Отмена", func(): toast(world.undo()), Vector2(96, 56)))
	tools.add_child(_button("Повтор", func(): toast(world.redo()), Vector2(96, 56)))

	# --- карточка жителя (справа)
	_card = PanelContainer.new()
	_card.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_card.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_card.offset_left = -420
	_card.offset_right = -10
	_card.offset_top = 80
	_card.offset_bottom = -96
	_card.visible = false
	root.add_child(_card)
	_blockers.append(_card)
	var cv := VBoxContainer.new()
	_card.add_child(cv)
	var ch := HBoxContainer.new()
	cv.add_child(ch)
	_card_title = Label.new()
	_card_title.add_theme_font_size_override("font_size", 26)
	_card_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ch.add_child(_card_title)
	_follow_btn = _button("Следить", func(): main.toggle_follow(), Vector2(100, 48))
	_follow_btn.toggle_mode = true
	ch.add_child(_follow_btn)
	ch.add_child(_button("X", func(): main.select(null), Vector2(48, 48)))
	var cscroll := ScrollContainer.new()
	cscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cv.add_child(cscroll)
	var cbody := VBoxContainer.new()
	cbody.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cscroll.add_child(cbody)
	_card_info = Label.new()
	_card_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_info.add_theme_font_size_override("font_size", 17)
	cbody.add_child(_card_info)
	var grid := GridContainer.new()
	grid.columns = 2
	cbody.add_child(grid)
	for need in [["health", "Здоровье"], ["food", "Сытость"], ["water", "Вода"], ["energy", "Энергия"], ["social", "Общение"], ["mood", "Настроение"]]:
		var l := Label.new()
		l.text = need[1]
		l.custom_minimum_size = Vector2(130, 0)
		l.add_theme_font_size_override("font_size", 17)
		grid.add_child(l)
		var pb := ProgressBar.new()
		pb.custom_minimum_size = Vector2(230, 22)
		pb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pb.max_value = 100
		grid.add_child(pb)
		_card_bars[need[0]] = pb
	_card_text = RichTextLabel.new()
	_card_text.bbcode_enabled = true
	_card_text.fit_content = true
	_card_text.scroll_active = false
	_card_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_text.add_theme_font_size_override("normal_font_size", 17)
	_card_text.add_theme_font_override("bold_font", load("res://fonts/NotoSans-Bold.ttf"))
	_card_text.add_theme_font_size_override("bold_font_size", 18)
	cbody.add_child(_card_text)

	# --- панель объекта
	_obj_panel = PanelContainer.new()
	_obj_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_obj_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_obj_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_obj_panel.position = Vector2(-10, -100)
	_obj_panel.visible = false
	root.add_child(_obj_panel)
	_blockers.append(_obj_panel)
	var oh := HBoxContainer.new()
	_obj_panel.add_child(oh)
	_obj_label = Label.new()
	_obj_label.custom_minimum_size = Vector2(260, 0)
	_obj_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	oh.add_child(_obj_label)
	oh.add_child(_button("Удалить", func(): _delete_selected_obj(), Vector2(100, 52)))
	oh.add_child(_button("X", func(): main.select(null), Vector2(48, 52)))

	# --- боковая панель (журнал / жители / мир)
	_side = PanelContainer.new()
	_side.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_side.offset_left = 10
	_side.offset_right = 430
	_side.offset_top = 112
	_side.offset_bottom = -96
	_side.visible = false
	root.add_child(_side)
	_blockers.append(_side)
	var sv := VBoxContainer.new()
	_side.add_child(sv)
	var sh := HBoxContainer.new()
	sv.add_child(sh)
	_side_title = Label.new()
	_side_title.add_theme_font_size_override("font_size", 24)
	_side_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sh.add_child(_side_title)
	sh.add_child(_button("X", func(): _toggle_side(""), Vector2(48, 48)))
	_side_text = RichTextLabel.new()
	_side_text.bbcode_enabled = true
	_side_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_side_text.add_theme_font_size_override("normal_font_size", 17)
	_side_text.add_theme_font_override("bold_font", load("res://fonts/NotoSans-Bold.ttf"))
	_side_text.meta_clicked.connect(_on_meta)
	_chart = Control.new()
	_chart.custom_minimum_size = Vector2(0, 150)
	_chart.visible = false
	_chart.draw.connect(_draw_chart)
	sv.add_child(_chart)
	sv.add_child(_side_text)

	# --- меню
	_menu = PanelContainer.new()
	_menu.set_anchors_preset(Control.PRESET_CENTER)
	_menu.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_menu.grow_vertical = Control.GROW_DIRECTION_BOTH
	_menu.custom_minimum_size = Vector2(640, 0)
	_menu.visible = false
	root.add_child(_menu)
	_blockers.append(_menu)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 10)
	_menu.add_child(mv)
	var mt := Label.new()
	mt.text = "Эволюция — меню"
	mt.add_theme_font_size_override("font_size", 28)
	mt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mv.add_child(mt)
	mv.add_child(_button("Продолжить", func(): show_menu(false), Vector2(0, 56)))
	for i in SaveSystem.SLOTS.size():
		var slot: String = SaveSystem.SLOTS[i]
		var row := HBoxContainer.new()
		mv.add_child(row)
		var l := Label.new()
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.add_theme_font_size_override("font_size", 16)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(l)
		_slot_labels[slot] = l
		row.add_child(_button("Сохранить", func(): main.save_to(slot), Vector2(130, 52)))
		row.add_child(_button("Загрузить", func(): main.load_from(slot), Vector2(130, 52)))
	var arow := HBoxContainer.new()
	mv.add_child(arow)
	var al := Label.new()
	al.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	al.add_theme_font_size_override("font_size", 16)
	al.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	arow.add_child(al)
	_slot_labels[SaveSystem.AUTO] = al
	arow.add_child(_button("Загрузить", func(): main.load_from(SaveSystem.AUTO), Vector2(130, 52)))
	mv.add_child(HSeparator.new())
	var nrow := HBoxContainer.new()
	mv.add_child(nrow)
	var nl := Label.new()
	nl.text = "Новый мир, seed:"
	nrow.add_child(nl)
	_seed_edit = LineEdit.new()
	_seed_edit.custom_minimum_size = Vector2(170, 52)
	_seed_edit.placeholder_text = "случайный"
	_seed_edit.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	nrow.add_child(_seed_edit)
	nrow.add_child(_button("Создать", func(): _confirm_new_world(), Vector2(130, 52)))
	_shadow_check = CheckButton.new()
	_shadow_check.text = "Тени (выключите на слабом телефоне)"
	_shadow_check.button_pressed = true
	_shadow_check.toggled.connect(func(on): main.set_shadows(on))
	mv.add_child(_shadow_check)
	var hint := Label.new()
	hint.text = "Управление: один палец — вращать камеру, два пальца — приблизить и сдвинуть, касание — выбрать или применить инструмент."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 15)
	hint.modulate = Color(0.75, 0.8, 0.9)
	mv.add_child(hint)

	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.position.y = 120
	_toast.add_theme_font_size_override("font_size", 22)
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_toast.add_theme_constant_override("outline_size", 8)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_toast)
	set_tool("select")

func _button(text: String, cb: Callable, min_size: Vector2 = Vector2(90, 52)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

# ---------------------------------------------------------------- API

func is_over_ui(p: Vector2) -> bool:
	for c in _blockers:
		if c.visible and c.get_global_rect().has_point(p):
			return true
	return false

func set_tool(t: String) -> void:
	tool = t
	for k in _tool_buttons:
		_tool_buttons[k].set_pressed_no_signal(k == t)
	if t != "select":
		var hints := {"raise": "Касайтесь земли, чтобы поднять рельеф", "lower": "Касайтесь земли, чтобы опустить рельеф",
			"delete": "Коснитесь объекта, чтобы удалить его"}
		toast(hints.get(t, "Коснитесь земли: " + Defs.display_name(t).to_lower()))

func set_speed_display(s: int) -> void:
	for k in _speed_buttons:
		_speed_buttons[k].set_pressed_no_signal(k == s)

func toast(text: String) -> void:
	_toast.text = text
	_toast.modulate.a = 1.0
	_toast_t = 2.5

func show_menu(on: bool) -> void:
	_menu.visible = on
	if on:
		for slot in _slot_labels:
			var nm: String = "Автосохранение" if slot == SaveSystem.AUTO else "Слот " + slot.substr(5)
			_slot_labels[slot].text = "%s: %s" % [nm, SaveSystem.summary(slot)]

func close_panels() -> bool:
	if _menu.visible:
		show_menu(false)
		return true
	if _side.visible:
		_toggle_side("")
		return true
	if _card.visible or _obj_panel.visible:
		main.select(null)
		return true
	return false

func show_selection(sel) -> void:
	_card.visible = false
	_obj_panel.visible = false
	_selected_obj_id = -1
	if sel == null:
		return
	if sel.has_method("sim_step"):
		_card.visible = true
		_refresh_card()
	else:
		_selected_obj_id = sel.obj_id
		_obj_panel.visible = true
		_obj_label.text = sel.describe()

func set_follow_display(on: bool) -> void:
	_follow_btn.set_pressed_no_signal(on)

var _pending_new := false
func _confirm_new_world() -> void:
	if not _pending_new:
		_pending_new = true
		toast("Текущий мир будет заменён. Нажмите «Создать» ещё раз для подтверждения")
		get_tree().create_timer(4.0).timeout.connect(func(): _pending_new = false)
		return
	_pending_new = false
	var txt := _seed_edit.text.strip_edges()
	var s: int = int(txt) if txt.is_valid_int() else randi() % 1000000
	main.new_world(s)
	show_menu(false)

func _delete_selected_obj() -> void:
	if _selected_obj_id >= 0:
		var err: String = world.cmd_remove(_selected_obj_id)
		toast(err if err != "" else "Удалено (можно отменить)")
		main.select(null)

func _on_meta(meta) -> void:
	var r = world.resident_by_id(int(str(meta)))
	if r:
		main.select(r)
		main.camera.focus_on(r.sim_pos, 14.0)
	else:
		var m = world.mind_by_id(int(str(meta)))
		if m != null:
			toast("%s — %s %s в %d лет" % [m.name, "умер" if m.sex == "m" else "умерла", m.cause_of_death, int(m.age_years)])

# ---------------------------------------------------------------- обновление

func _process(delta: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= delta
		_toast.modulate.a = clampf(_toast_t, 0.0, 1.0)
	_refresh_t -= delta
	if _refresh_t > 0.0:
		return
	_refresh_t = 0.35
	_time_label.text = world.time_string() + ("  ночь" if world.is_night() else "")
	_stats_label.text = "Жителей: %d · рождений: %d · смертей: %d · кустов: %d · родников: %d" % [world.alive_count(), int(world.stats["births"]), int(world.stats["deaths"]), world.count_type("bush"), world.count_type("spring")] + ("\nТелефон не успевает — симуляция идёт медленнее выбранной скорости" if world.lagging and world.speed > 1 else "")
	if _card.visible:
		_refresh_card()
	if _obj_panel.visible:
		var o = world.get_object(_selected_obj_id)
		if o == null:
			main.select(null)
		else:
			_obj_label.text = o.describe()
	if _side.visible and _side_mode != "log":
		_refresh_side()

func _bar_color(v: float) -> Color:
	if v < 25.0: return Color(0.9, 0.3, 0.25)
	if v < 50.0: return Color(0.95, 0.7, 0.2)
	return Color(0.35, 0.8, 0.45)

func _refresh_card() -> void:
	var r = main.selected
	if r == null or not is_instance_valid(r) or not r.has_method("sim_step") or r.is_queued_for_deletion():
		if _card.visible:
			main.select(null)
		return
	var m = r.mind
	_card_title.text = m.name + ("" if m.alive else " †")
	_card_info.text = "%s, %d %s · поколение %d · род %s\n%s\nЦель жизни: %s" % [m.stage_name().capitalize(), int(m.age_years), _years_word(int(m.age_years)), m.generation, m.family_name if m.family_name != "" else "—", m.trait_text(), m.long_goal]
	for k in _card_bars:
		var pb: ProgressBar = _card_bars[k]
		var v: float = m.get(k)
		pb.value = v
		var fill: StyleBoxFlat = pb.get_meta("fill") if pb.has_meta("fill") else null
		if fill == null:
			fill = StyleBoxFlat.new()
			fill.set_corner_radius_all(6)
			pb.set_meta("fill", fill)
			pb.add_theme_stylebox_override("fill", fill)
		fill.bg_color = _bar_color(v)
	var t := ""
	t += "[b]Сейчас:[/b] %s\n" % m.action_text
	t += "[b]Цель:[/b] %s\n[b]Почему:[/b] %s\n" % [Brain.goal_name(m.goal), m.goal_reason]
	if m.plan.size() > 0:
		var steps: Array = []
		for s in m.plan:
			steps.append({"go": "идти", "eat": "есть", "drink": "пить", "sleep": "спать", "talk": "говорить", "talk_request": "заговорить", "rest": "греться", "look": "осмотреться", "gather": "собрать", "feed": "накормить"}.get(s["a"], s["a"]))
		t += "[b]План:[/b] " + " → ".join(steps) + "\n"
	t += _family_block(m)
	t += "\n[b]Отношения[/b]\n"
	if m.relationships.is_empty():
		t += "Пока ни с кем не знаком%s\n" % ("" if m.sex == "m" else "а")
	for k in m.relationships:
		var rel: Dictionary = m.relationships[k]
		t += "%s — %s (симпатия %d, разговоров %d)\n" % [rel["name"], Mind.relation_label(float(rel["affinity"]), float(rel["familiarity"])), int(rel["affinity"]), int(rel["talks"])]
	t += "\n[b]Знает мест:[/b] "
	var counts := {}
	for k in m.known_places:
		var tp: String = m.known_places[k]["type"]
		counts[tp] = counts.get(tp, 0) + 1
	var parts: Array = []
	for tp in counts:
		parts.append("%s: %d" % [Defs.display_name(tp).to_lower(), counts[tp]])
	t += (", ".join(parts) if not parts.is_empty() else "пока ничего") + "\n"
	t += "\n[b]Навыки[/b]\n"
	for s in m.skills:
		t += "%s: %.1f\n" % [s.capitalize(), m.skills[s]]
	t += "\n[b]Память (последнее)[/b]\n"
	for mem in m.recent_memories(8):
		t += "[color=#9fb3c8]%s[/color]  %s\n" % [world.time_string(mem["t"]), mem["text"]]
	var story: Array = m.life_story()
	if not story.is_empty():
		t += "\n[b]История жизни[/b]\n"
		for mem in story.slice(maxi(0, story.size() - 8)):
			t += "[color=#9fb3c8]%s[/color]  %s\n" % [world.time_string(mem["t"]), mem["text"]]
	_card_text.text = t

func _years_word(n: int) -> String:
	var n10 := n % 10
	var n100 := n % 100
	if n10 == 1 and n100 != 11: return "год"
	if n10 >= 2 and n10 <= 4 and (n100 < 12 or n100 > 14): return "года"
	return "лет"

func _person_link(id: int) -> String:
	var o = world.mind_by_id(id)
	if o == null:
		return "?"
	return "[url=%d]%s[/url]%s" % [id, o.name, "" if o.alive else " †"]

func _family_block(m) -> String:
	var t := "\n[b]Семья[/b]\n"
	var parents: Array = []
	for pid in [m.mother_id, m.father_id]:
		if pid >= 0:
			parents.append(_person_link(pid))
	t += "Родители: %s\n" % (", ".join(parents) if not parents.is_empty() else "нет — первые люди мира")
	if m.partner_id >= 0:
		t += "%s: %s\n" % ["Муж" if m.sex == "f" else "Жена", _person_link(m.partner_id)]
	elif m.is_adult():
		t += "Пары нет\n"
	if not m.children.is_empty():
		t += "Дети: %s\n" % ", ".join(m.children.map(func(c): return _person_link(int(c))))
	var sibs: Array = []
	for o in world.all_minds():
		if o.id != m.id and ((m.mother_id >= 0 and o.mother_id == m.mother_id) or (m.father_id >= 0 and o.father_id == m.father_id)):
			sibs.append(_person_link(o.id))
	if not sibs.is_empty():
		t += "Братья и сёстры: %s\n" % ", ".join(sibs)
	if m.pregnant:
		t += "[color=#ffd27a]Ждёт ребёнка, роды примерно через %d ч[/color]\n" % int(maxf(0.0, m.pregnancy_due - world.time_min) / 60.0)
	if m.is_sick(world.time_min):
		t += "[color=#ff9a8a]Болеет: %s (ещё ~%d ч)[/color]\n" % [m.illness, int((m.sick_until - world.time_min) / 60.0)]
	if int(m.carry.get("food", 0)) > 0 or int(m.carry.get("water", 0)) > 0:
		t += "Несёт ребёнку: %s\n" % ("ягоды" if int(m.carry.get("food", 0)) > 0 else "воду")
	if m.is_dependent():
		t += "[color=#9fb3c8]Ещё мал%s: сам%s не добывает еду, о %s заботятся взрослые[/color]\n" % ["" if m.sex == "m" else "а", "" if m.sex == "m" else "а", "нём" if m.sex == "m" else "ней"]
	if not m.traditions.is_empty():
		t += "Традиции: %s\n" % ", ".join(m.traditions.map(func(x): return Family.TRADITIONS[x]["name"].to_lower()))
	return t

## Родословная: дети показываются под отцом (если он известен), иначе под матерью.
func _tree_lines(m, depth: int, out: Array, seen: Dictionary) -> void:
	if seen.has(m.id) or depth > 12:
		return
	seen[m.id] = true
	var pad := ""
	for i in depth:
		pad += "    "
	var line := "%s%s%s, %d %s" % [pad, "└ " if depth > 0 else "", _person_link(m.id), int(m.age_years), _years_word(int(m.age_years))]
	if m.partner_id >= 0 or m.children.size() > 0:
		var pid: int = m.partner_id
		if pid < 0:
			for c in m.children:
				var cm = world.mind_by_id(int(c))
				if cm != null:
					pid = cm.father_id if m.sex == "f" else cm.mother_id
					break
		if pid >= 0:
			line += "  +  " + _person_link(pid)
			var pm = world.mind_by_id(pid)
			if pm != null and pm.mother_id < 0 and pm.father_id < 0:
				seen[pid] = true
	out.append(line)
	for c in m.children:
		var cm2 = world.mind_by_id(int(c))
		if cm2 == null:
			continue
		var owner: int = cm2.father_id if cm2.father_id >= 0 else cm2.mother_id
		if owner == m.id or world.mind_by_id(owner) == null:
			_tree_lines(cm2, depth + 1, out, seen)
	# дети этой пары, записанные за супругом (если супруг — тоже корень)
	if m.partner_id >= 0:
		var p = world.mind_by_id(m.partner_id)
		if p != null:
			for c in p.children:
				var cm3 = world.mind_by_id(int(c))
				if cm3 != null and not seen.has(cm3.id) and cm3.father_id != p.id:
					_tree_lines(cm3, depth + 1, out, seen)

func _draw_chart() -> void:
	var h: Array = world.pop_history
	var sz := _chart.size
	var f := load("res://fonts/NotoSans-Regular.ttf") as Font
	_chart.draw_rect(Rect2(Vector2.ZERO, sz), Color(0.1, 0.13, 0.19))
	if h.size() < 2:
		_chart.draw_string(f, Vector2(10, sz.y / 2), "График появится через пару дней", HORIZONTAL_ALIGNMENT_LEFT, -1, 15)
		return
	var mx := 1
	for e in h:
		mx = maxi(mx, int(e["pop"]))
	var pts := PackedVector2Array()
	for i in h.size():
		var x: float = 8.0 + (sz.x - 16.0) * i / float(h.size() - 1)
		var y: float = sz.y - 20.0 - (sz.y - 40.0) * float(h[i]["pop"]) / mx
		pts.append(Vector2(x, y))
	_chart.draw_polyline(pts, Color(0.45, 0.85, 0.55), 3.0, true)
	_chart.draw_string(f, Vector2(8, 16), "Население по дням (макс. %d)" % mx, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.8, 0.86, 0.95))
	_chart.draw_string(f, Vector2(8, sz.y - 4), "день %d" % int(h[0]["d"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.6, 0.66, 0.75))
	_chart.draw_string(f, Vector2(sz.x - 80, sz.y - 4), "день %d" % int(h[-1]["d"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.6, 0.66, 0.75))

func _toggle_side(mode: String) -> void:
	if mode == "" or (_side.visible and _side_mode == mode):
		_side.visible = false
		_side_mode = ""
		return
	_side_mode = mode
	_side.visible = true
	_refresh_side()

func _refresh_side() -> void:
	var t := ""
	match _side_mode:
		"log":
			_side_title.text = "Журнал событий"
			for i in range(world.events.size() - 1, maxi(-1, world.events.size() - 80), -1):
				var e: Dictionary = world.events[i]
				t += "[color=#9fb3c8]%s[/color]  %s\n" % [world.time_string(float(e["t"])), e["text"]]
		"people":
			_side_title.text = "Жители"
			for r in world.residents:
				var m = r.mind
				t += "[url=%d][b]%s[/b][/url]%s, %s %d — %s\n" % [m.id, m.name, "" if m.alive else " †", m.stage_name(), int(m.age_years), m.action_text]
				t += "  здоровье %d · сытость %d · вода %d · энергия %d · настроение %d\n\n" % [int(m.health), int(m.food), int(m.water), int(m.energy), int(m.mood)]
			t += "[color=#9fb3c8]Коснитесь имени, чтобы открыть карточку.[/color]"
		"family":
			_side_title.text = "Семьи и родословная"
			var roots: Array = world.all_minds().filter(func(x): return x.mother_id < 0 and x.father_id < 0)
			roots.sort_custom(func(a, b): return a.sex == "m" and b.sex != "m")
			var lines: Array = []
			var seen := {}
			for rm in roots:
				_tree_lines(rm, 0, lines, seen)
			t += "\n".join(lines) + "\n\n"
			var couples := 0
			for r in world.residents:
				if r.mind.alive and r.mind.partner_id >= 0 and r.mind.sex == "f":
					couples += 1
			t += "Пар сейчас: %d · всего создано: %d\n" % [couples, int(world.stats.get("couples", 0))]
			var trad := {}
			for r in world.residents:
				for x in r.mind.traditions:
					if r.mind.alive:
						trad[x] = int(trad.get(x, 0)) + 1
			if not trad.is_empty():
				t += "\n[b]Традиции[/b]\n"
				for x in trad:
					t += "%s — %s (соблюдают: %d)\n" % [Family.TRADITIONS[x]["name"], Family.TRADITIONS[x]["desc"], trad[x]]
			t += "\n[color=#9fb3c8]† — умер. Коснитесь имени, чтобы открыть карточку. 1 год = 2 игровых дня.[/color]"
		"world":
			_side_title.text = "Мир и демография"
			t += "Seed: %d · %s · год %d\n\n" % [world.seed_value, world.time_string(), world.current_year()]
			var stages := {"baby": 0, "child": 0, "teen": 0, "adult": 0, "elder": 0}
			var gens := {}
			var age_sum := 0.0
			for r in world.residents:
				if r.mind.alive:
					stages[r.mind.stage()] += 1
					gens[r.mind.generation] = true
					age_sum += r.mind.age_years
			var alive: int = world.alive_count()
			t += "[b]Население: %d[/b] (предел %d)\n" % [alive, Family.MAX_POP]
			t += "Младенцы %d · дети %d · подростки %d · взрослые %d · старики %d\n" % [stages["baby"], stages["child"], stages["teen"], stages["adult"], stages["elder"]]
			t += "Средний возраст: %.1f · поколений среди живых: %d\n" % [age_sum / maxf(1.0, alive), gens.size()]
			t += "Рождений: %d · смертей: %d\n" % [int(world.stats["births"]), int(world.stats["deaths"])]
			var db: Dictionary = world.stats["deaths_by"]
			if not db.is_empty():
				var parts: Array = []
				for k in db:
					parts.append("%s: %d" % [k, int(db[k])])
				t += "Причины смерти: %s\n" % ", ".join(parts)
			t += "\n"
			for tp in Defs.PLACEABLE:
				t += "%s: %d\n" % [Defs.display_name(tp), world.count_type(tp)]
			t += "\n[b]Этап развития:[/b] первобытные семьи\n"
			t += "[color=#9fb3c8]Есть: пары, рождение, уход за детьми, наследование, взросление, старость, болезни, традиции. Поселения, ремёсла, технологии и космос — следующие этапы, в этой версии их нет.[/color]"
	_chart.visible = _side_mode == "world"
	if _chart.visible:
		_chart.queue_redraw()
	_side_text.text = t
