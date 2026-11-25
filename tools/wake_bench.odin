package main

import "unified:cli"

// `uni bench`'s wake row (this repo): how late the Godot host's session thread wakes from its sleeps on this machine
// (tests/godot_driver/bench: godot.measure_wakes at 32, 64 and 128 Hz together), idle and under load, no target: what
// says whether a platform's session thread needs a stronger thread class.
Wake_Report :: struct {
	seconds: f64,
	cores:   int,
	idle:    []Wake_Rate,
	loaded:  []Wake_Rate,
}

Wake_Rate :: struct {
	hz:       int,
	lateness: Wake_Lateness,
}

// godot.Wake_Summary
Wake_Lateness :: struct {
	wakes:     int,
	p50_us:    f64,
	p99_us:    f64,
	max_us:    f64,
	over_ms:   int,
	over_tick: int,
}

wake_bench :: proc(work, binary: string) -> (data: any, ok: bool) {
	report := new(Wake_Report)
	if !cli.run_report(binary, {}, cli.join(work, "wake"), 60, report) {
		return nil, false
	}
	for phase, i in ([][]Wake_Rate{report.idle, report.loaded}) {
		for rate, j in phase {
			late := rate.lateness
			cli.log(
				"%-12s %-6s %3d Hz: %4d sleeps woke late by p50 %4.0f us, p99 %5.0f us, max %6.0f us; %d over 1 ms, %d over a tick",
				"wake" if i == 0 && j == 0 else "",
				("" if j > 0 else "idle" if i == 0 else "loaded"),
				rate.hz,
				late.wakes,
				late.p50_us,
				late.p99_us,
				late.max_us,
				late.over_ms,
				late.over_tick,
			)
		}
	}
	return report^, true
}
