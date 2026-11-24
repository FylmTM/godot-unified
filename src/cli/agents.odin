// The guidance unified ships for coding agents in a game repo (docs/agent-guide.md, How the integration works): a short
// section of the repo's AGENTS.md between markers, and unified's skills (every SKILL_PREFIX directory of its
// .claude/skills/) copied into the repo's. Both come from the unified submodule, so they match the library the game
// builds against; `init` writes them, `refresh` rewrites them after a submodule bump (refresh.odin), and `vet` fails
// while they differ.
package cli

import "core:os"
import "core:slice"
import "core:strings"

// Where a project keeps its Claude Code skills, from its root.
SKILLS_DIR :: ".claude/skills"

// How the names of unified's shipped skills start. The prefix marks a game repo's copies as unified's: `refresh`
// rewrites and removes only those, and never touches the game's own skills beside them.
SKILL_PREFIX :: "unified-"

// The AGENTS.md section's text, in unified's checkout. It lives once, there; a game repo's AGENTS.md holds it between
// AGENTS_BEGIN and AGENTS_END.
AGENTS_SECTION :: "src/cli/template/agents-section.md"

// The line before the section in a game repo's AGENTS.md. A line starting with AGENTS_BEGIN_MARK is the marker, so its
// wording can change.
AGENTS_BEGIN :: AGENTS_BEGIN_MARK + ": managed by `./uni refresh`, edit outside it -->"

// How the section's first line starts.
AGENTS_BEGIN_MARK :: "<!-- unified: begin"

// The line after the section.
AGENTS_END :: "<!-- unified: end -->"

// The SKILL_PREFIX skills in the SKILLS_DIR of the project at `root`, sorted by name (none without the directory).
unified_skills :: proc(root: string) -> []string {
	entries, _ := os.read_all_directory_by_path(join(root, SKILLS_DIR), context.allocator)
	names: [dynamic]string
	for entry in entries {
		if entry.type == .Directory && strings.has_prefix(entry.name, SKILL_PREFIX) {
			append(&names, strings.clone(entry.name))
		}
	}
	slice.sort(names[:])
	return names[:]
}

// Writes the agent guidance unified's checkout at `unified` ships into the game repo at `root`: its section of
// AGENTS.md (in place of the marked one, else appended; the file is made when there is none), and unified's skills
// copied whole into SKILLS_DIR, where a SKILL_PREFIX skill unified no longer ships is removed. Text is written with LF
// line endings. Stops the command when it can't.
write_agents :: proc(unified, root: string) {
	shipped := unified_skills(unified)
	skills := join(root, SKILLS_DIR)
	for name in unified_skills(root) {
		if !slice.contains(shipped, name) do remove_tree(join(skills, name))
	}
	for name in shipped {
		source, target := join(unified, SKILLS_DIR, name), join(skills, name)
		remove_tree(target)
		for rel_path in files_under(source) {
			write_text(join(target, rel_path), lf(must_read(join(source, rel_path))))
		}
	}
	agents := join(root, "AGENTS.md")
	existing, _ := read_text(agents)
	text, ok := agents_spliced(existing, must_read(join(unified, AGENTS_SECTION)))
	if !ok {
		fatal("%s has %q without %q after it: fix the markers by hand", agents, AGENTS_BEGIN_MARK, AGENTS_END)
	}
	write_text(agents, text)
}

// What is stale in the agent guidance of the game repo at `root` against unified's checkout at `unified`, a line each
// (none: it is current): AGENTS.md's marked section; each of unified's skills (a file missing, differing or not
// unified's); a SKILL_PREFIX skill unified no longer ships. `refresh` fixes each.
agents_problems :: proc(unified, root: string) -> []string {
	problems: [dynamic]string
	existing, found := read_text(join(root, "AGENTS.md"))
	spliced, ok := agents_spliced(existing, must_read(join(unified, AGENTS_SECTION)))
	switch {
	case !found:
		append(&problems, "AGENTS.md: missing")
	case !ok:
		append(&problems, aprintf("AGENTS.md: %q without %q after it", AGENTS_BEGIN_MARK, AGENTS_END))
	case !strings.contains(existing, AGENTS_BEGIN_MARK):
		append(&problems, "AGENTS.md: no unified section")
	case spliced != lf(existing):
		append(&problems, "AGENTS.md: the unified section differs from unified's")
	}
	shipped := unified_skills(unified)
	skills := join(root, SKILLS_DIR)
	for name in shipped {
		source, target := join(unified, SKILLS_DIR, name), join(skills, name)
		for rel_path in files_under(source) {
			copied, copy_found := read_text(join(target, rel_path))
			if !copy_found {
				append(&problems, aprintf("%s/%s/%s: missing", SKILLS_DIR, name, rel_path))
			} else if lf(copied) != lf(must_read(join(source, rel_path))) {
				append(&problems, aprintf("%s/%s/%s: differs from unified's", SKILLS_DIR, name, rel_path))
			}
		}
		for rel_path in files_under(target) {
			if !os.is_file(join(source, rel_path)) {
				append(&problems, aprintf("%s/%s/%s: not unified's", SKILLS_DIR, name, rel_path))
			}
		}
	}
	for name in unified_skills(root) {
		if !slice.contains(shipped, name) {
			append(&problems, aprintf("%s/%s: unified no longer ships it", SKILLS_DIR, name))
		}
	}
	return problems[:]
}

// AGENTS.md's text `existing` ("": no file yet) with `section` between AGENTS_BEGIN and AGENTS_END: in place of the
// marked section it has, else appended after a blank line. False when it has a begin marker without an end after it.
// Line endings become LF.
agents_spliced :: proc(existing, section: string) -> (text: string, ok: bool) {
	block := strings.concatenate({AGENTS_BEGIN, "\n", strings.trim_space(lf(section)), "\n", AGENTS_END, "\n"})
	current := lf(existing)
	begin := strings.index(current, AGENTS_BEGIN_MARK)
	if begin < 0 {
		head := strings.trim_right(current, " \t\n")
		return head == "" ? block : strings.concatenate({head, "\n\n", block}), true
	}
	end := strings.index(current[begin:], AGENTS_END)
	if end < 0 {
		return "", false
	}
	rest := strings.trim_prefix(current[begin + end + len(AGENTS_END):], "\n")
	return strings.concatenate({current[:begin], block, rest}), true
}

// The files under `dir`, recursively and sorted (find_files: hidden entries skipped), relative to it with /
// separators; none when it doesn't exist.
@(private)
files_under :: proc(dir: string) -> []string {
	if !os.is_directory(dir) do return nil
	base, _ := os.get_absolute_path(dir, context.allocator)
	base = strings.trim_right(base, "/\\")
	out: [dynamic]string
	for file in find_files(base, "") {
		rel_path, _ := strings.replace_all(file[len(base) + 1:], "\\", "/")
		append(&out, rel_path)
	}
	return out[:]
}

// `text` with LF line endings.
@(private)
lf :: proc(text: string) -> string {
	out, _ := strings.replace_all(text, "\r\n", "\n")
	return out
}

// `text` with the line endings a checkout gives the file at `path` (src/cli/README.md, Line endings): CRLF for a batch
// file, LF for every other.
@(private)
checkout_eol :: proc(path, text: string) -> string {
	if !strings.has_suffix(path, ".cmd") && !strings.has_suffix(path, ".bat") do return lf(text)
	out, _ := strings.replace_all(lf(text), "\n", "\r\n")
	return out
}
