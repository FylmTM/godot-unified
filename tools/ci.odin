package main

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

import "unified:cli"

Ci_Opts :: struct {}

Ci_Cache_Key_Opts :: struct {
	dep: string `args:"pos=0,required" usage:"cache-key: odinfmt or godot"`,
}

// CI helpers (.github/workflows): the job summary, and a dependency's cache key.
cmd_ci :: proc(args: []string) -> cli.Result {
	if len(args) == 0 {
		cli.usage("ci summary | ci cache-key <dep>")
	}
	switch args[0] {
	case "summary":
		opts: Ci_Opts
		cli.parse(&opts, args[1:])
		return {ok = true, summary = ci_summary()}
	case "cache-key":
		opts: Ci_Cache_Key_Opts
		cli.parse(&opts, args[1:])
		return {ok = true, summary = cache_key(opts.dep)}
	case "-h", "--help":
		opts: Ci_Opts
		cli.parse(&opts, args)
	}
	cli.usage("ci summary | ci cache-key <dep>")
}

// A dependency's cache key: its pins, our recipe and, for odinfmt (built with Odin), the Odin it was built with.
// Only what CI caches: Odin's cache is keyed in the workflow (the key must exist before Odin does), and
// unified-box3d is fetched every run.
@(private)
cache_key :: proc(dep: string) -> string {
	section := dep
	if dep != "odinfmt" && dep != "godot" {
		cli.usage("no dependency %q (odinfmt, godot)", dep)
	}
	pins, ok := cli.state.pins.sections[section]
	if !ok {
		cli.fatal("pins.cfg has no [%s]", section)
	}
	keys: [dynamic]string
	for k in pins {
		append(&keys, k)
	}
	slice.sort(keys[:])
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s recipe %d\n", dep, cli.RECIPE_VERSION)
	for k in keys {
		fmt.sbprintf(&b, "%s=%s\n", k, pins[k])
	}
	if dep == "odinfmt" {
		fmt.sbprintf(&b, "odin %s\n", ODIN_VERSION_HASH)
	}
	return cli.aprintf("%s-%s-%s", dep, cli.PLATFORM, cli.sha256_hex(transmute([]byte)strings.to_string(b))[:16])
}

// Markdown for $GITHUB_STEP_SUMMARY from .out/: the commands' times against their budgets, the net suite and the
// benchmarks.
@(private)
ci_summary :: proc() -> string {
	out := strings.builder_make()
	fmt.sbprintf(&out, "## uni: %s\n\n", cli.PLATFORM)
	read :: proc(name: string) -> (json.Value, bool) {
		text, ok := cli.read_text(cli.join(cli.state.project.out, name))
		if !ok {
			return nil, false
		}
		v, err := json.parse_string(text)
		return v, err == nil
	}
	if v, ok := read("timings.json"); ok {
		fmt.sbprintf(&out, "| step | seconds | budget |\n|---|---:|---|\n")
		obj, _ := v.(json.Object)
		keys: [dynamic]string
		for k in obj {
			append(&keys, k)
		}
		slice.sort(keys[:])
		for k in keys {
			e, _ := obj[k].(json.Object)
			budget := cli.json_f64(e["budget"])
			over, _ := e["over"].(json.Boolean)
			cold, _ := e["cold"].(json.Array)
			flag := ""
			if budget > 0 {
				flag =
					over ? cli.aprintf("**OVER** %.0fs", budget) : len(cold) > 0 ? cli.aprintf("%.0fs (cold)", budget) : cli.aprintf("%.0fs", budget)
			}
			fmt.sbprintf(&out, "| `uni %s` | %.1f | %s |\n", k, cli.json_f64(e["seconds"]), flag)
		}
		strings.write_byte(&out, '\n')
	}
	if v, ok := read("net.json"); ok {
		obj, _ := v.(json.Object)
		pass, _ := obj["ok"].(json.Boolean)
		fmt.sbprintf(
			&out,
			"### `uni test --suite net`: %s\n\n| test | result | seconds | detail |\n|---|---|---:|---|\n",
			pass ? "PASS" : "**FAIL**",
		)
		tests, _ := obj["tests"].(json.Object)
		for name, t in tests {
			tt, _ := t.(json.Object)
			detail, _ := strings.replace_all(cli.json_string(tt["detail"]), "|", "\\|")
			fmt.sbprintf(
				&out,
				"| %s | %s | %.1f | %s |\n",
				name,
				strings.to_upper(cli.json_string(tt["status"])),
				cli.json_f64(tt["seconds"]),
				detail,
			)
		}
	} else {
		strings.write_string(&out, "No .out/net.json: the net suite did not run.\n")
	}
	if v, ok := read("bench.json"); ok {
		obj, _ := v.(json.Object)
		fmt.sbprintf(
			&out,
			"\n### Benchmarks (`uni bench`, release; target: step + re-sim <= %.0f ms)\n\n| benchmark | step µs (p99) | save µs | restore µs | re-sim µs (p99) | step + re-sim | snapshot bytes |\n|---|---:|---:|---:|---:|---:|---:|\n",
			cli.json_f64(obj["target_us"]) / 1000,
		)
		benches, _ := obj["benchmarks"].(json.Object)
		for name, bv in benches {
			d, _ := bv.(json.Object)
			within, _ := d["within_target"].(json.Boolean)
			fmt.sbprintf(
				&out,
				"| %s | %.0f (%.0f) | %.0f | %.0f | %.0f (%.0f) | **%.2f ms**%s | %d |\n",
				name,
				cli.json_f64(d["step_mean_us"]),
				cli.json_f64(d["step_p99_us"]),
				cli.json_f64(d["save_mean_us"]),
				cli.json_f64(d["restore_mean_us"]),
				cli.json_f64(d["resim_mean_us"]),
				cli.json_f64(d["resim_p99_us"]),
				cli.json_f64(d["step_plus_resim_us"]) / 1000,
				within ? "" : " **OVER**",
				cli.json_int(d["snapshot_bytes"]),
			)
		}
	} else {
		strings.write_string(&out, "\nNo .out/bench.json: `uni bench` did not run.\n")
	}
	return strings.to_string(out)
}
