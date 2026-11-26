package main

import "unified:cli"

// `uni bench`'s physics row (this repo): unified:physics through its plug-in on a fixed pile apart from any game
// (tests/physics/bench), no target: what a Box3D or physics change compares (the upgrade-dependency skill).
Physics_Report :: struct {
	bodies:          int,
	step_us:         cli.Bench_Stat,
	save_us:         cli.Bench_Stat,
	restore_us:      cli.Bench_Stat,
	hash_deep_us:    cli.Bench_Stat, // the whole world (the ticks peers compare)
	hash_us:         cli.Bench_Stat, // the awake bodies (every other tick)
	rays:            int,
	rays_us:         cli.Bench_Stat,
	rays_rewound_us: cli.Bench_Stat, // the same rays rewound 2 ticks (world_cast_ray_closest_rewound) over the awake pile
	image_us:        cli.Bench_Stat, // a portable image of a past tick's slot (the world swapped out and back)
	image_live_us:   cli.Bench_Stat, // ... and of the live tick's (no swap: a snapshot of the tick the sim is at)
	load_us:         cli.Bench_Stat, // its load into another world
	characters:      int,
	characters_us:   cli.Bench_Stat, // that many character_updates in one tick
	// That many characters standing: a tick (their updates and the step) driven, dormant (character_set_dormant), and the
	// slab's step with none.
	dormant:         struct {
		standing_us: cli.Bench_Stat,
		dormant_us:  cli.Bench_Stat,
		empty_us:    cli.Bench_Stat,
	},
	snapshot_bytes:  int,
	image_bytes:     int,
	// The capacity against the frame budget: a smaller pile's forward step and its rollback at the prediction cap
	// (restore, `cap` steps saving every 2nd tick, a deep hash), on 1 and 4 workers.
	rollback:        struct {
		bodies:    int,
		cap:       int,
		workers_1: Physics_Rollback,
		workers_4: Physics_Rollback,
	},
	// A generated level of 10k static shapes built as a game's is (compounds by cell), with 100 and 500 dynamic
	// bodies: what the level costs each operation a session repeats.
	large_level:     []Physics_Large_Level,
}

Physics_Large_Level :: struct {
	shapes:          int,
	statics:         int, // the level's static bodies (compounds, and shapes alone in their cell)
	dynamic_bodies:  int,
	world_create_ms: f64, // create_with_levels: the level parsed, built and baked
	level_change_us: cli.Bench_Stat, // entering the level (its static bodies destroyed and made)
	step_us:         cli.Bench_Stat,
	save_us:         cli.Bench_Stat,
	restore_us:      cli.Bench_Stat,
	hash_deep_us:    cli.Bench_Stat,
	rollback_us:     cli.Bench_Stat, // a restore `rollback_depth` ticks back, then as many steps, each saved
	rollback_depth:  int,
	snapshot_bytes:  int, // a ring slot
	image_bytes:     int, // a late joiner's image (the level's compounds ride in it)
	load_us:         cli.Bench_Stat, // its load into another world
}

Physics_Rollback :: struct {
	step_us:                   cli.Bench_Stat,
	rollback_us:               cli.Bench_Stat,
	step_plus_rollback_p99_us: f64,
	step_plus_rollback_p90_us: f64, // of each tick's step plus its rollback: two preempted samples don't move it
	// The awake bodies in dense contact a step and a rollback at the cap fit in the frame budget at p90, scaled from
	// the pile (the cost per body is about flat): what physics bounds a tick to (src/physics/README.md, Capacity).
	bodies_fit:                int,
}

physics_bench :: proc(work, binary: string) -> (data: any, ok: bool) {
	report := new(Physics_Report)
	if !cli.run_report(binary, {}, cli.join(work, "physics"), 120, report) {
		return nil, false
	}
	cli.log(
		"%-12s %d boxes in a pile: step %.0f us (p99 %.0f), save %.0f us (%d bytes), restore %.0f us, hash %.0f us (deep %.0f), %d rays %.0f us (rewound %.0f us); image %.0f us (live %.0f us, %d bytes), load %.0f us; %d characters %.0f us, standing tick %.0f us (dormant %.1f us, none %.1f us)",
		"physics",
		report.bodies,
		report.step_us.mean,
		report.step_us.p99,
		report.save_us.mean,
		report.snapshot_bytes,
		report.restore_us.mean,
		report.hash_us.mean,
		report.hash_deep_us.mean,
		report.rays,
		report.rays_us.mean,
		report.rays_rewound_us.mean,
		report.image_us.mean,
		report.image_live_us.mean,
		report.image_bytes,
		report.load_us.mean,
		report.characters,
		report.characters_us.mean,
		report.dormant.standing_us.mean,
		report.dormant.dormant_us.mean,
		report.dormant.empty_us.mean,
	)
	for &row in ([]^Physics_Rollback{&report.rollback.workers_1, &report.rollback.workers_4}) {
		row.bodies_fit = int(f64(report.rollback.bodies) * cli.BENCH_TARGET_US / max(row.step_plus_rollback_p90_us, 1))
	}
	one, four := report.rollback.workers_1, report.rollback.workers_4
	cli.log(
		"%-12s %d boxes: step + %d-tick rollback %.2f ms at p90 (%.2f at p99) on 1 worker (means %.0f + %.0f us), %.2f ms at p90 (%.2f) on 4 (means %.0f + %.0f us): about %d awake bodies fit the %.0f ms target on 1 worker, %d on 4",
		"",
		report.rollback.bodies,
		report.rollback.cap,
		one.step_plus_rollback_p90_us / 1000,
		one.step_plus_rollback_p99_us / 1000,
		one.step_us.mean,
		one.rollback_us.mean,
		four.step_plus_rollback_p90_us / 1000,
		four.step_plus_rollback_p99_us / 1000,
		four.step_us.mean,
		four.rollback_us.mean,
		one.bodies_fit,
		cli.BENCH_TARGET_US / 1000,
		four.bodies_fit,
	)
	for row in report.large_level {
		cli.log(
			"%-12s %d static shapes (%d bodies), %d dynamic: change %.0f us, step %.0f us, save %.0f us (%d bytes), restore %.0f us, deep hash %.0f us, %d-tick rollback %.2f ms; image %d bytes, load %.0f us; built in %.0f ms",
			"",
			row.shapes,
			row.statics,
			row.dynamic_bodies,
			row.level_change_us.mean,
			row.step_us.mean,
			row.save_us.mean,
			row.snapshot_bytes,
			row.restore_us.mean,
			row.hash_deep_us.mean,
			row.rollback_depth,
			row.rollback_us.mean / 1000,
			row.image_bytes,
			row.load_us.mean,
			row.world_create_ms,
		)
	}
	return report^, true
}
