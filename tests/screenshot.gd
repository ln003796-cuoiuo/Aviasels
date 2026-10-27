extends SceneTree
## Снимок экрана для визуальной проверки: godot --script res://tests/screenshot.gd -- out.png [select]
func _initialize(): _run.call_deferred()
func _run():
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://shot.png"
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.world.time_min = float(args[2]) * 60.0 if args.size() > 2 else 9.5 * 60.0
	var mode: String = args[1] if args.size() > 1 else ""
	if mode in ["family", "demo", "kid", "settle", "town"]:
		main.world.new_world(2024)
		for i in 44 * 1440: main.world.step(1.0)
		main.world.time_min = floor(main.world.time_min / 1440.0) * 1440.0 + (float(args[2]) if args.size() > 2 else 10.0) * 60.0
	for i in 40: main.world.step(1.0)
	if mode == "family":
		main.hud._toggle_side("family")
	elif mode == "settle" or mode == "town":
		var Settlement = load("res://scripts/core/settlement.gd")
		main.camera.focus_on(Settlement.center(main.world), 26.0 if mode == "town" else 16.0)
		if mode == "settle":
			main.hud._toggle_side("settlement")
	elif mode == "demo":
		main.hud._toggle_side("world")
	elif mode == "kid":
		var kid = null
		for r in main.world.residents:
			if r.mind.alive and (kid == null or r.mind.age_years < kid.mind.age_years):
				kid = r
		if kid == null:
			kid = main.world.residents[-1]
		main.select(kid)
		main.camera.focus_on(kid.sim_pos, 7.0)
		main.toggle_follow()
	if args.size() > 1 and args[1] == "select":
		main.select(main.world.residents[0])
		main.camera.focus_on(main.world.residents[0].sim_pos, 9.0)
	elif args.size() > 1 and args[1] == "menu":
		main.hud.show_menu(true)
	elif args.size() > 1 and args[1] == "log":
		main.hud._toggle_side("log")
	for i in 60: await process_frame
	root.get_viewport().get_texture().get_image().save_png(out)
	print("saved ", out)
	quit()
