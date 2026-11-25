package main

import "unified:cli"

// `uni bench`'s nav row (this repo): unified:nav on the yard Godot baked (tests/nav/bench), no target: the mesh's
// build, a field's build (a new goal: a miss of the memo), and a horde steering and moving every tick.
Nav_Report :: struct {
	polygons:   int,
	vertices:   int,
	build_us:   cli.Bench_Stat, // nav.build, once per world_create
	field_us:   cli.Bench_Stat, // one field_compute
	walkers:    int,
	walkers_us: cli.Bench_Stat, // every walker's field (a memo hit), steer and move in one tick
	arrivals:   int,
}

nav_bench :: proc(work, binary: string) -> (data: any, ok: bool) {
	report := new(Nav_Report)
	if !cli.run_report(binary, {}, cli.join(work, "nav"), 60, report) {
		return nil, false
	}
	cli.log(
		"%-12s %d polygons (a baked yard): build %.0f us, a field %.1f us (p99 %.1f); %d walkers %.1f us a tick (p99 %.1f)",
		"nav",
		report.polygons,
		report.build_us.mean,
		report.field_us.mean,
		report.field_us.p99,
		report.walkers,
		report.walkers_us.mean,
		report.walkers_us.p99,
	)
	return report^, true
}
