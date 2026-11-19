package cli

import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// --- doc --------------------------------------------------------------------------------------------------------

@(private)
Doc_Opts :: struct {
	overflow: [dynamic]string `hint:"[package...]" usage:"unified packages (sim, unified:sim, headless/modes), a game (its sim package) or a directory; none: list them"`,
}

// The API of a package: `odin doc` (each file's header comment, then every public declaration with its doc comment),
// each declaration followed by where it is (file:line, from the project root). With no package, every package of
// the collection and each game's sim package, with its README's title.
@(private)
cmd_doc :: proc(args: []string) -> Result {
	opts: Doc_Opts
	parse(&opts, args)
	if len(opts.overflow) == 0 {
		return doc_list()
	}
	ensure_bindings()
	ensure_deps_for_headless() // physics' imports: the Box3D bindings
	dirs := make([]string, len(opts.overflow))
	runs := make([]Run, len(opts.overflow))
	for name, i in opts.overflow {
		dirs[i] = doc_package_dir(name)
		cmd: [dynamic]string
		append(&cmd, odin(), "doc", dirs[i])
		append(&cmd, ..collection())
		runs[i] = {
			cmd     = cmd[:],
			capture = true,
			quiet   = true,
		}
	}
	out := strings.builder_make()
	for ran, i in run_all(runs) {
		if !ran.ok {
			fatal("odin doc %s failed:\n%s%s", rel(dirs[i]), ran.stdout, ran.stderr)
		}
		strings.write_string(&out, doc_with_locations(doc_with_file_headers(ran.stdout, dirs[i]), dirs[i]))
	}
	return {ok = true, summary = strings.trim_right_space(strings.to_string(out)), data = box(dirs)}
}

// A package name or a path, as the directory of its package: `sim` and `unified:sim` are the collection's, a game's
// name its sim package (games/<game>/simulation/<game>), anything else a directory.
@(private)
doc_package_dir :: proc(name: string) -> string {
	pkg := strings.trim_prefix(name, "unified:")
	if dir := join(state.project.unified, "src", pkg); os.is_directory(dir) {
		return dir
	}
	for game in state.project.games {
		if game.name == name {
			return join(game.dir, "simulation", game.name)
		}
	}
	if os.is_directory(name) {
		abs, _ := os.get_absolute_path(name, context.allocator)
		return abs
	}
	fatal("no package %q: `uni doc` lists them", name)
}

// `odin doc` runs the files' header comments together as the package's doc, in file name order: this puts each
// under its file's name instead, the package's main file (<package>.odin, its overview) first.
@(private)
doc_with_file_headers :: proc(text: string, dir: string) -> string {
	first_newline := strings.index_byte(text, '\n')
	if first_newline < 0 {
		return text
	}
	body_start := len(text)
	for section in ([]string{"constants", "variables", "procedures", "proc_group", "types", "fullpath"}) {
		if at := strings.index(text, aprintf("\n\t%s\n", section)); at >= 0 && at + 1 < body_start {
			body_start = at + 1
		}
	}
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return text
	}
	names: [dynamic]string
	for info in infos {
		if info.type == .Regular &&
		   strings.has_suffix(info.name, ".odin") &&
		   !strings.has_suffix(info.name, ".gen.odin") {
			append(&names, info.name)
		}
	}
	main_file := aprintf("%s.odin", os.base(dir))
	slice.sort_by(names[:], proc(a, b: string) -> bool {return a < b})
	if index, found := slice.linear_search(names[:], main_file); found {
		ordered_remove(&names, index)
		inject_at(&names, 0, main_file)
	}
	out := strings.builder_make()
	strings.write_string(&out, text[:first_newline + 1])
	for name in names {
		source, read_err := os.read_entire_file(join(dir, name), context.allocator)
		if read_err != nil {
			continue
		}
		header: [dynamic]string
		for line in strings.split_lines(string(source)) {
			if strings.has_prefix(line, "package ") {
				break
			}
			if strings.has_prefix(line, "//") {
				append(&header, strings.trim_prefix(strings.trim_prefix(line, "//"), " "))
			}
		}
		if len(header) == 0 {
			continue
		}
		strings.write_string(&out, aprintf("\t%s\n", name))
		for line in header {
			strings.write_string(&out, line == "" ? "\n" : aprintf("\t\t%s\n", line))
		}
		strings.write_byte(&out, '\n')
	}
	strings.write_string(&out, text[body_start:])
	return strings.to_string(out)
}

// `odin doc` ends each declaration with `{...} /* pkg:file.odin!offset */` (a byte offset): this writes
// `// path/file.odin:line` instead, a location an editor opens.
@(private)
doc_with_locations :: proc(text: string, dir: string) -> string {
	line_starts: map[string][]int // per file: the byte offset of each line
	out := strings.builder_make()
	rest := text
	for {
		start := strings.index(rest, " /* ")
		if start < 0 {
			break
		}
		end := strings.index(rest[start:], " */")
		bang := strings.index_byte(rest[start:], '!')
		colon := strings.index_byte(rest[start:], ':')
		if end < 0 || bang < 0 || colon < 0 || bang > end || colon > bang {
			strings.write_string(&out, rest[:start + 4])
			rest = rest[start + 4:]
			continue
		}
		file := rest[start + colon + 1:start + bang]
		offset, _ := strconv.parse_int(rest[start + bang + 1:start + end])
		head := strings.trim_suffix(rest[:start], " {...}")
		strings.write_string(&out, head)
		path := join(dir, file)
		if path not_in line_starts {
			starts: [dynamic]int
			append(&starts, 0)
			if bytes, err := os.read_entire_file(path, context.allocator); err == nil {
				for character, i in bytes {
					if character == '\n' {
						append(&starts, i + 1)
					}
				}
			}
			line_starts[path] = starts[:]
		}
		line, _ := slice.binary_search(line_starts[path], offset)
		if line < len(line_starts[path]) && line_starts[path][line] == offset do line += 1
		slashed, _ := strings.replace_all(rel(path), "\\", "/")
		strings.write_string(&out, aprintf("  // %s:%d", slashed, line))
		rest = rest[start + end + 3:]
	}
	strings.write_string(&out, rest)
	return strings.to_string(out)
}

// Every package of the collection (src/, sub-packages included) and each game's sim package, with its README's
// title.
@(private)
doc_list :: proc() -> Result {
	Row :: struct {
		name:  string,
		title: string,
	}
	rows: [dynamic]Row
	src := join(state.project.unified, "src")
	pkgs: [dynamic]string
	doc_collect_packages(src, &pkgs)
	slice.sort(pkgs[:])
	for dir in pkgs {
		name, _ := strings.replace_all(dir[len(src) + 1:], "\\", "/")
		append(&rows, Row{aprintf("unified:%s", name), readme_title(dir)})
	}
	for game in state.project.games {
		append(&rows, Row{game.name, readme_title(game.dir)})
	}
	width := 0
	for row in rows {
		width = max(width, len(row.name))
	}
	out := strings.builder_make()
	for row in rows {
		strings.write_string(&out, aprintf("%-*s  %s\n", width, row.name, row.title))
	}
	return {ok = true, summary = strings.trim_right_space(strings.to_string(out)), data = box(rows[:])}
}

// The directories under `dir` holding Odin code that isn't all generated.
@(private)
doc_collect_packages :: proc(dir: string, out: ^[dynamic]string) {
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return
	}
	has_code := false
	for info in infos {
		if info.type == .Directory {
			doc_collect_packages(info.fullpath, out)
		} else if strings.has_suffix(info.name, ".odin") && !strings.has_suffix(info.name, ".gen.odin") {
			has_code = true
		}
	}
	if has_code {
		append(out, strings.clone(dir))
	}
}

// The text of a README's first heading, without its `#` ("" without a README).
@(private)
readme_title :: proc(dir: string) -> string {
	bytes, err := os.read_entire_file(join(dir, "README.md"), context.allocator)
	if err != nil {
		return ""
	}
	first, _, _ := strings.partition(string(bytes), "\n")
	return strings.trim_space(strings.trim_left(first, "#"))
}
