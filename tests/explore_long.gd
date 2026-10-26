extends SceneTree
const GameWorld = preload("res://scripts/core/game_world.gd")
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var seeds := [2024, 77, 31337]
	for sd in seeds:
		var w = GameWorld.new()
		root.add_child(w)
		w.speed = 0
		w.new_world(sd)
		var t0 := Time.get_ticks_msec()
		for d in 160:
			for i in 1440:
				w.step(1.0)
			if d % 20 == 19:
				var gens := {}
				for m in w.all_minds():
					gens[m.generation] = true
				print("seed %d day %d: alive %d births %d deaths %s newc %d couples %d gens %s bushes %d  %.0fs" % [sd, d + 1, w.alive_count(), w.stats["births"], str(w.stats["deaths_by"]), int(w.stats.get("newcomers", 0)), int(w.stats["couples"]), str(gens.keys()), w.count_type("bush"), (Time.get_ticks_msec() - t0) / 1000.0])
		w.queue_free()
	quit()
