// The navreport binary, which `uni bake --report` builds and runs:
//   navreport [--export=<max_lowered>,<inside_solids>] <file.level> ...
// An --export gives what the exporter changed in the next file's bake (Export). Prints the report of each level with
// a navigation mesh (or an error) as text (write_text), then one JSON line, {"levels": [Report, ...]}, a report for
// every file. Exits 1 when a file can't be read, 2 on a bad argument.
package navreport

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// Reports on every .level file named on the command line.
main :: proc() {
	reports := make([dynamic]Report)
	ok := true
	builder := strings.builder_make()
	pending: Maybe(Export)
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--export=") {
			export, parsed := parse_export(strings.trim_prefix(arg, "--export="))
			if !parsed {
				fmt.eprintfln("navreport: %s: want --export=<max_lowered>,<inside_solids>", arg)
				os.exit(2)
			}
			pending = export
			continue
		}
		data, err := os.read_entire_file(arg, context.allocator)
		if err != nil {
			fmt.eprintfln("navreport: cannot read %s: %v", arg, err)
			ok = false
			pending = nil
			continue
		}
		level_report := report(arg, data)
		level_report.export = pending
		pending = nil
		append(&reports, level_report)
		if level_report.polygons > 0 || level_report.error != "" {
			write_text(&builder, level_report)
			strings.write_string(&builder, "\n")
		}
	}
	fmt.print(strings.to_string(builder))
	Out :: struct {
		levels: []Report,
	}
	line, marshal_err := json.marshal(Out{reports[:]})
	if marshal_err != nil {
		fmt.eprintfln("navreport: cannot write the JSON: %v", marshal_err)
		os.exit(1)
	}
	fmt.println(string(line))
	if !ok do os.exit(1)
}

// An --export value: "<max_lowered>,<inside_solids>".
@(private)
parse_export :: proc(value: string) -> (export: Export, ok: bool) {
	comma := strings.index_byte(value, ',')
	if comma < 0 do return
	max_lowered, lowered_ok := strconv.parse_f32(value[:comma])
	inside_solids, solids_ok := strconv.parse_int(value[comma + 1:])
	return {max_lowered, inside_solids}, lowered_ok && solids_ok
}
