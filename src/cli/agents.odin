// The guidance unified ships for coding agents in a game repo (README.md, Agent guidance): a section of the repo's
// AGENTS.md between markers, and unified's game-facing skills copied into its .claude/skills/ with a stamp. Both come
// from the unified submodule, so they always match the library the game builds against; `init` writes them, `agents`
// rewrites them after a submodule bump, and `vet` fails while they differ from the submodule's.
package cli

import "core:os"
import "core:slice"
import "core:strings"

// The skills of unified's .claude/skills/ a game repo gets. Each is written for a game repo (unified at unified/) and
// is still right inside unified, which runs the same files; unified's other skills are its own.
GAME_SKILLS :: []string{"desync", "godot-game", "sim-change"}

// Where a project keeps its Claude Code skills, from its root: unified's own and, in a game repo, the copies.
SKILLS_DIR :: ".claude/skills"

// The stamp in a game repo's SKILLS_DIR: the skills that are unified's copies, a name per line after its `#` lines.
// `agents` rewrites and removes only those, so a game's own skills beside them are never touched.
SKILLS_STAMP :: "unified.txt"

// The AGENTS.md section's text, in unified's checkout. It lives once, there; a game repo's AGENTS.md holds it between
// AGENTS_BEGIN and AGENTS_END.
AGENTS_SECTION :: "src/cli/template/agents.md"

// The line before the section in a game repo's AGENTS.md. A line starting with AGENTS_BEGIN_MARK is the marker, so its
// wording can change.
AGENTS_BEGIN ::
	AGENTS_BEGIN_MARK +
	": `uni agents` writes this section from unified/src/cli/template/agents.md; edit outside it -->"

// How the section's first line starts.
AGENTS_BEGIN_MARK :: "<!-- unified: begin"

// The line after the section.
AGENTS_END :: "<!-- unified: end -->"

@(private)
Agents_Opts :: struct {}

// `agents`: rewrites the game repo's agent guidance from its unified submodule (write_agents), after a bump.
@(private)
cmd_agents :: proc(args: []string) -> Result {
	opts: Agents_Opts
	parse(&opts, args)
	if is_unified_repo() {
		usage("agents writes a game repo's guidance from its unified submodule; unified's own is the source")
	}
	count := write_agents(state.project.unified, state.project.root)
	return {
		ok      = true,
		summary = aprintf(
			"agents: AGENTS.md's unified section and the skills %s in %s/, from the submodule (%d more files)",
			strings.join(GAME_SKILLS, ", "),
			SKILLS_DIR,
			count,
		),
	}
}

// Writes the agent guidance unified's checkout at `unified` ships into the game repo at `root`: its section of
// AGENTS.md (in place of the marked one, else appended; the file is made when there is none) and each of GAME_SKILLS,
// copied whole into SKILLS_DIR with SKILLS_STAMP. A skill an older stamp lists that unified no longer ships is
// removed. Text is written with LF line endings. Returns how many files it wrote beside AGENTS.md (the skills' and the
// stamp); stops the command when it can't.
write_agents :: proc(unified, root: string) -> int {
	skills := join(root, SKILLS_DIR)
	for name in stamped_skills(root) {
		if !slice.contains(GAME_SKILLS, name) do remove_tree(join(skills, name))
	}
	count := 0
	for name in GAME_SKILLS {
		source := join(unified, SKILLS_DIR, name)
		if !os.is_file(join(source, "SKILL.md")) {
			fatal("unified at %s has no %s/%s/SKILL.md", unified, SKILLS_DIR, name)
		}
		target := join(skills, name)
		remove_tree(target)
		for rel_path in files_under(source) {
			write_text(join(target, rel_path), lf(must_read(join(source, rel_path))))
			count += 1
		}
	}
	write_text(join(skills, SKILLS_STAMP), stamp_text())
	agents := join(root, "AGENTS.md")
	existing, _ := read_text(agents)
	text, ok := agents_spliced(existing, must_read(join(unified, AGENTS_SECTION)))
	if !ok {
		fatal("%s has %q without %q after it: fix the markers by hand", agents, AGENTS_BEGIN_MARK, AGENTS_END)
	}
	write_text(agents, text)
	return count + 1
}

// What is stale in the agent guidance of the game repo at `root` against unified's checkout at `unified`, a line each
// (none: it is current): AGENTS.md's marked section, each of GAME_SKILLS (a file missing, differing or not
// unified's), a stamped skill unified no longer ships, the stamp itself. `agents` fixes each.
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
	skills := join(root, SKILLS_DIR)
	for name in GAME_SKILLS {
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
	for name in stamped_skills(root) {
		if !slice.contains(GAME_SKILLS, name) {
			append(&problems, aprintf("%s/%s: unified no longer ships it", SKILLS_DIR, name))
		}
	}
	stamp, _ := read_text(join(skills, SKILLS_STAMP))
	if lf(stamp) != stamp_text() {
		append(&problems, aprintf("%s/%s: missing or not current", SKILLS_DIR, SKILLS_STAMP))
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

// The skills the stamp in `root`'s SKILLS_DIR names (none without one).
@(private)
stamped_skills :: proc(root: string) -> []string {
	text, _ := read_text(join(root, SKILLS_DIR, SKILLS_STAMP))
	names: [dynamic]string
	for line in strings.split_lines(lf(text)) {
		name := strings.trim_space(line)
		if name != "" && !strings.has_prefix(name, "#") do append(&names, name)
	}
	return names[:]
}

// The stamp a write leaves: what it is, then GAME_SKILLS.
@(private)
stamp_text :: proc() -> string {
	lines: [dynamic]string
	append(
		&lines,
		"# unified's skills, copied from its submodule (unified/.claude/skills/) by `uni agents`, which rewrites and",
		"# removes only those named here; `uni vet` fails while one differs from unified's. Skills of the game's own go",
		"# beside them under other names.",
	)
	append(&lines, ..GAME_SKILLS)
	return strings.concatenate({strings.join(lines[:], "\n"), "\n"})
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
