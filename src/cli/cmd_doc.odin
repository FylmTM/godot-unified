package cli

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// --- doc --------------------------------------------------------------------------------------------------------

@(private)
Doc_Opts :: struct {
	brief:    bool `usage:"one line per declaration: its name and its doc's first sentence (a proc group stands for its procs)"`,
	overflow: [dynamic]string `hint:"[package [name...]...]" usage:"unified packages (sim, unified:sim, headless/modes), a game (its sim package) or a directory, each followed by names of its declarations to show alone (or package.name; a name no declaration has shows every one containing it); none: list the packages"`,
}

// The API of a package: `odin doc` (each file's header comment, then every public declaration with its doc comment),
// each declaration followed by where it is (file:line, from the project root); a struct, enum or union with comments
// in its body is printed as its source (its fields' doc comments, which `odin doc` drops). Names after a package show
// only those declarations; --brief, one line each. With no package, every package of the collection and each game's
// sim package, with its README's title.
@(private)
cmd_doc :: proc(args: []string) -> Result {
	opts: Doc_Opts
	parse(&opts, args)
	if len(opts.overflow) == 0 {
		return doc_list()
	}
	Doc_Target :: struct {
		dir:   string,
		typed: string, // as given (a package's own name may differ: headless/modes is `modes`)
		names: [dynamic]string,
	}
	targets: [dynamic]Doc_Target
	for arg in opts.overflow {
		dot := strings.last_index_byte(arg, '.')
		// a directory by a bare name only first: after a package, a bare word is one of its names (`Game`, beside a
		// game repo's game/ on a case-blind file system)
		bare_dir := len(targets) == 0 || strings.contains_any(arg, "/\\")
		if dir, found := doc_package_dir(arg, bare_dir); found {
			append(&targets, Doc_Target{dir = dir, typed = arg})
		} else if dir_of_prefix, prefix_found := doc_package_dir(arg[:max(dot, 0)], bare_dir);
		   dot > 0 && prefix_found {
			append(&targets, Doc_Target{dir = dir_of_prefix, typed = arg[:dot]})
			append(&targets[len(targets) - 1].names, arg[dot + 1:])
		} else if len(targets) > 0 {
			append(&targets[len(targets) - 1].names, arg)
		} else {
			fatal("no package %q: `uni doc` lists them", arg)
		}
	}
	ensure_bindings()
	ensure_deps_for_headless() // physics' imports: the Box3D bindings
	dirs := make([]string, len(targets))
	runs := make([]Run, len(targets))
	for target, i in targets {
		dirs[i] = target.dir
		cmd: [dynamic]string
		append(&cmd, odin(), "doc", target.dir)
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
		doc := doc_parse(doc_with_locations(doc_with_file_headers(ran.stdout, dirs[i]), dirs[i]))
		doc_with_sources(&doc, dirs[i])
		names := targets[i].names[:]
		if len(names) > 0 {
			chosen, missing := doc_select(doc, names)
			if len(missing) > 0 {
				fatal("no declaration in %s named or containing: %s", rel(dirs[i]), strings.join(missing, ", "))
			}
			doc.entries = chosen
			doc.header = doc.package_line
		}
		strings.write_string(
			&out,
			opts.brief ? doc_brief(doc, targets[i].typed) : doc_text(doc, full = len(names) == 0),
		)
		strings.write_byte(&out, '\n')
	}
	return {ok = true, summary = strings.trim_right_space(strings.to_string(out)), data = box(dirs)}
}

// One package's `odin doc` text, read: the part before the declarations (the package line and the file headers),
// then each declaration with its section ("procedures", "types", ...) and doc comment.
Doc :: struct {
	package_line: string, // "package sim"
	header:       string, // the package line and the file headers, as printed
	entries:      []Doc_Entry,
	trailer:      string, // the `fullpath` section
}

// One public declaration in a Doc.
Doc_Entry :: struct {
	section: string,
	name:    string,
	lines:   []string, // the declaration as printed (one line, or a type's source), without indentation
	doc:     []string, // its doc comment's lines, without indentation
}

// The sections `odin doc` prints the declarations under.
@(private)
DOC_SECTIONS :: []string{"constants", "variables", "procedures", "proc_group", "types"}

// Reads `odin doc` text (after doc_with_file_headers and doc_with_locations). A doc line that is a formatter
// directive (`odinfmt: disable`) is no documentation and is left out.
doc_parse :: proc(text: string) -> Doc {
	doc: Doc
	lines := strings.split_lines(text)
	if len(lines) > 0 do doc.package_line = strings.trim_space(lines[0])
	entries: [dynamic]Doc_Entry
	docs: [dynamic][dynamic]string // each entry's doc lines, as they come
	header := strings.builder_make()
	trailer := strings.builder_make()
	section := ""
	in_trailer := false
	for line in lines {
		if strings.has_prefix(line, "\t") && !strings.has_prefix(line, "\t\t") {
			word := strings.trim_space(line)
			if slice.contains(DOC_SECTIONS, word) {
				section = word
				continue
			}
			in_trailer ||= word == "fullpath:" // then files:
		}
		switch {
		case in_trailer:
			fmt.sbprintln(&trailer, line)
		case section == "":
			fmt.sbprintln(&header, line)
		case strings.has_prefix(line, "\t\t\t"):
			if len(docs) > 0 && !strings.has_prefix(strings.trim_space(line), "odinfmt:") {
				append(&docs[len(docs) - 1], line[3:])
			}
		case strings.has_prefix(line, "\t\t"):
			declaration := line[2:]
			name_end := strings.index_any(declaration, " :") // `name :: ...`, a variable's `name: type`
			name := name_end < 0 ? declaration : declaration[:name_end]
			append(&entries, Doc_Entry{section = section, name = name, lines = strs(declaration)})
			append(&docs, [dynamic]string{})
		}
	}
	for &entry, i in entries do entry.doc = docs[i][:]
	doc.header = strings.trim_right_space(strings.to_string(header))
	doc.entries = entries[:]
	doc.trailer = strings.trim_right_space(strings.to_string(trailer))
	return doc
}

// Each type with where it is (`odin doc` gives a type none), and a struct, enum, union or bit_field whose body holds
// comments (its fields' doc comments, which `odin doc` drops) as its source; any other entry stays as it is.
doc_with_sources :: proc(doc: ^Doc, dir: string) {
	Source :: struct {
		path:  string, // from the project root, with slashes
		lines: []string,
	}
	sources: [dynamic]Source
	infos, _ := os.read_all_directory_by_path(dir, context.allocator)
	for info in infos {
		if info.type != .Regular ||
		   !strings.has_suffix(info.name, ".odin") ||
		   strings.has_suffix(info.name, ".gen.odin") {
			continue
		}
		text, found := read_text(info.fullpath)
		if !found do continue
		path, _ := strings.replace_all(rel(info.fullpath), "\\", "/")
		append(&sources, Source{path, strings.split_lines(text)})
	}
	for &entry in doc.entries {
		if entry.section != "types" || len(entry.lines) != 1 do continue
		declared := aprintf("%s :: ", entry.name)
		find: for source in sources {
			for line, index in source.lines {
				if !strings.has_prefix(line, declared) do continue
				location := aprintf("%s:%d", source.path, index + 1)
				_, _, rest := strings.partition(entry.lines[0], " :: ")
				with_body := false
				for keyword in ([]string{"struct", "enum", "union", "bit_field"}) {
					with_body ||= strings.has_prefix(rest, keyword)
				}
				block := with_body ? doc_source_block(source.lines[index:]) : nil
				if len(block) == 0 do block = strs(entry.lines[0])
				block[0] = aprintf("%s  // %s", block[0], location)
				entry.lines = block
				break find
			}
		}
	}
}

// The lines of the declaration that starts `lines`, through the brace that closes its body; nil when that body holds
// no comment (odin doc's one line says it all) or its braces don't close.
doc_source_block :: proc(lines: []string) -> []string {
	text := strings.join(lines, "\n")
	depth := 0
	commented := false
	for i := 0; i < len(text); i += 1 {
		switch {
		case strings.has_prefix(text[i:], "//"):
			commented ||= depth > 0
			for i + 1 < len(text) && text[i + 1] != '\n' do i += 1
		case strings.has_prefix(text[i:], "/*"):
			commented ||= depth > 0
			end := strings.index(text[i + 2:], "*/")
			i = end < 0 ? len(text) : i + 2 + end + 1
		case text[i] == '"' || text[i] == '`' || text[i] == '\'':
			quote := text[i]
			for i + 1 < len(text) && text[i + 1] != quote && text[i + 1] != '\n' {
				i += text[i + 1] == '\\' && quote != '`' ? 2 : 1
			}
			i += 1
		case text[i] == '{':
			depth += 1
		case text[i] == '}':
			depth -= 1
			if depth > 0 do continue
			if !commented do return nil
			block := strings.split_lines(text[:i + 1])
			for &block_line in block do block_line = strings.trim_right_space(block_line)
			return block
		}
	}
	return nil
}

// The entries `names` pick: each name's declaration (a proc group's with its procs), or, for a name no declaration
// has, every one whose name contains it (any case). `missing`: the names that matched nothing.
doc_select :: proc(doc: Doc, names: []string) -> (chosen: []Doc_Entry, missing: []string) {
	picked := make([]bool, len(doc.entries))
	missing_names: [dynamic]string
	for name in names {
		exact := false
		for entry, i in doc.entries {
			if entry.name != name do continue
			exact = true
			picked[i] = true
			if entry.section != "proc_group" do continue
			for member in doc_group_members(entry) {
				for other, j in doc.entries do if other.name == member do picked[j] = true
			}
		}
		if exact do continue
		lower := strings.to_lower(name)
		found := false
		for entry, i in doc.entries {
			if strings.contains(strings.to_lower(entry.name), lower) {
				picked[i] = true
				found = true
			}
		}
		if !found do append(&missing_names, name)
	}
	out: [dynamic]Doc_Entry
	for entry, i in doc.entries do if picked[i] do append(&out, entry)
	return out[:], missing_names[:]
}

// A proc group's procs, by name, from its declaration (`name :: proc{a, b}`).
doc_group_members :: proc(entry: Doc_Entry) -> []string {
	if len(entry.lines) == 0 do return nil
	_, _, rest := strings.partition(entry.lines[0], "proc{")
	list, _, _ := strings.partition(rest, "}")
	members: [dynamic]string
	for member in strings.split(list, ",") do append(&members, strings.trim_space(member))
	return members[:]
}

// A Doc as `uni doc` prints it: the header, then each section's declarations with their docs (`full`: and the
// fullpath section after them).
doc_text :: proc(doc: Doc, full: bool) -> string {
	out := strings.builder_make()
	fmt.sbprintf(&out, "%s\n\n", doc.header)
	section := ""
	for entry in doc.entries {
		if entry.section != section {
			section = entry.section
			fmt.sbprintf(&out, "\t%s\n", section)
		}
		for line in entry.lines do strings.write_string(&out, line == "" ? "\n" : aprintf("\t\t%s\n", line))
		for line in entry.doc do fmt.sbprintf(&out, "\t\t\t%s\n", line)
		if len(entry.doc) > 0 || len(entry.lines) > 1 do strings.write_byte(&out, '\n')
	}
	if full && doc.trailer != "" do fmt.sbprintf(&out, "\n%s\n", doc.trailer)
	return strings.to_string(out)
}

// A Doc in one line per declaration: its name and its doc's first sentence, a proc group's procs left out (the
// group stands for them), then how to see one whole (`typed`: the package as the command line named it).
doc_brief :: proc(doc: Doc, typed: string) -> string {
	grouped: map[string]bool
	for entry in doc.entries {
		if entry.section != "proc_group" do continue
		for member in doc_group_members(entry) do grouped[member] = true
	}
	width := 0
	for entry in doc.entries do if entry.name not_in grouped do width = max(width, len(entry.name))
	width = min(width, 32)
	out := strings.builder_make()
	fmt.sbprintf(&out, "%s\n", doc.package_line)
	section := ""
	for entry in doc.entries {
		if entry.name in grouped do continue
		if entry.section != section {
			section = entry.section
			fmt.sbprintf(&out, "\t%s\n", section)
		}
		if first := doc_first_sentence(entry.doc); first != "" {
			fmt.sbprintf(&out, "\t\t%-*s  %s\n", width, entry.name, first)
		} else {
			fmt.sbprintf(&out, "\t\t%s\n", entry.name)
		}
	}
	fmt.sbprintf(&out, "(uni doc %s <name>: one declaration whole)\n", typed)
	return strings.to_string(out)
}

// A doc comment's first sentence, on one line (through its first ". ", else all of it), cut at 140 characters.
doc_first_sentence :: proc(doc: []string) -> string {
	text := strings.join(doc, " ")
	if end := strings.index(text, ". "); end >= 0 do text = text[:end + 1]
	if len(text) > 140 do text = aprintf("%s...", strings.trim_right_space(text[:137]))
	return text
}

// A package name or a path, as the directory of its package: `sim` and `unified:sim` are the collection's, a game's
// name its sim package (examples/<game>/simulation/<game>), anything else a directory (`any_dir`; found false: none of
// them).
@(private)
doc_package_dir :: proc(name: string, any_dir: bool) -> (dir: string, found: bool) {
	pkg := strings.trim_prefix(name, "unified:")
	if collection_dir := join(state.project.unified, "src", pkg); os.is_directory(collection_dir) {
		return collection_dir, true
	}
	for game in state.project.games {
		if game.name == name {
			return join(game.dir, "simulation", game.name), true
		}
	}
	if any_dir && os.is_directory(name) {
		abs, _ := os.get_absolute_path(name, context.allocator)
		return abs, true
	}
	return "", false
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
