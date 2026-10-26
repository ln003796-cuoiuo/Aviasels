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
	for i in 40: main.world.step(1.0)
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
