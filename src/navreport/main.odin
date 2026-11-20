// The navreport binary, which `uni bake --report` builds and runs: `navreport <file.level>...` prints each level's
// report as text (write_text), a blank line after each, then one JSON line, {"levels": [Report, ...]}. Exits 1 when a
// file can't be read.
package navreport

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// Reports on every .level file named on the command line.
main :: proc() {
	reports := make([dynamic]Report)
	ok := true
	builder := strings.builder_make()
	for file in os.args[1:] {
		data, err := os.read_entire_file(file, context.allocator)
		if err != nil {
			fmt.eprintfln("navreport: cannot read %s: %v", file, err)
			ok = false
			continue
		}
		level_report := report(file, data)
		append(&reports, level_report)
		write_text(&builder, level_report)
		strings.write_string(&builder, "\n")
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
