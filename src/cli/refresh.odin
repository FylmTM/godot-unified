// What unified ships into a game repo beyond the game itself, kept in line with the unified submodule
// (docs/agent-guide.md, How the integration works): the agent guidance (agents.odin), the shims and the formatter's
// style, which `init` writes; the starters, which `init` writes and the game owns after; and what an older unified
// copied in and keeps elsewhere now, retired. `refresh` brings a repo in line after a submodule bump, and `vet` fails
// while anything unified keeps differs.
package cli

import "core:os"
import "core:strings"

// The shims a game repo runs uni through: thin ones that run the submodule's own (template/repo/uni.tmpl and
// uni.cmd.tmpl), so the bootstrap is always the pinned unified's.
SHIMS :: []string{"uni", "uni.cmd"}

// Where a game repo's own files live in unified's checkout, as `init` starts them: template/repo/<path>.tmpl.
REPO_TEMPLATE :: "src/cli/template/repo"

// The formatter's style, unified's odinfmt.json, kept identical at a game repo's root: `uni fmt` formats with it, and
// the editor's language server (OLS formats on save) looks for it from the edited file upward, never into the
// submodule. Without the copy, a save in the editor rewrites a file into a style `uni fmt --check` rejects.
ODINFMT_CONFIG :: "odinfmt.json"

// A file a game repo starts with and owns after: `path` from the repo's root, `template` in STARTER_TEMPLATES.
Starter :: struct {
	path, template: string,
}

// Where the starters' text lives in unified's checkout, apart from template/repo/ so that no `.claude/` directory
// inside unified's tree acts on unified itself.
STARTER_TEMPLATES :: "src/cli/template/starters"

// The starters (write_starters): `.claude/settings.json` formats every Odin file an agent edits (`uni fmt --hook`,
// which builds odinfmt the first time), so CI's `fmt --check` holds; `ols.json` points the editor's language server
// at the `unified:` and `box3d:` collections and the game's packages. No permissions: what an agent may run without
// asking is each game's (and each developer's) to grant.
STARTERS :: []Starter{{".claude/settings.json", "settings.json"}, {"ols.json", "ols.json"}}

// Writes each starter missing from the game repo at `root`, from unified's checkout at `unified`, and never one that
// is there: once written it is the game's, kept as the game changed it. `init` writes them all; `refresh` writes the
// ones an older unified never wrote (and one the game deleted: a game that wants none keeps it empty). A starter an
// older unified ships no template for is skipped.
write_starters :: proc(unified, root: string) {
	for starter in STARTERS {
		path, template := join(root, starter.path), join(unified, STARTER_TEMPLATES, starter.template)
		if !os.exists(path) && os.is_file(template) do write_text(path, checkout_eol(path, must_read(template)))
	}
}

// The template of the shim `shim` (one of SHIMS) in unified's checkout at `unified`.
shim_template :: proc(unified, shim: string) -> string {
	return join(unified, REPO_TEMPLATE, aprintf("%s.tmpl", shim))
}

// What an older unified copied into a game repo, by path from its root. Each goes only when it is unified's copy:
// GUIDE.md by its title (unified/docs/gameplay.md now), unified_index.tres by its views metadata (the view index is
// built into the extension now).
@(private = "file")
Retired :: struct {
	path, mark, now: string,
}

@(private = "file")
RETIRED :: []Retired {
	{"GUIDE.md", "# Writing gameplay that survives rollback", "unified/docs/gameplay.md"},
	{"unified_index.tres", "metadata/views = {", "built into the extension"},
}

// How the game's code (copied from an older minimal_3d) named the guide, and what names it now.
@(private = "file")
GUIDE_REFERENCE :: "(GUIDE.md)"
@(private = "file")
GUIDE_NOW :: "(unified/docs/gameplay.md)"

// The .gitignore line and export filter an older unified's mirror (res://addons/unified/) needed. Its filter becomes
// the one for res://unified/, where the tool scripts are now.
@(private = "file")
LEGACY_FILTER :: "addons/unified/*"

@(private)
Refresh_Opts :: struct {}

// `refresh`: brings the game repo in line with its unified submodule after a bump (write_refresh).
@(private)
cmd_refresh :: proc(args: []string) -> Result {
	opts: Refresh_Opts
	parse(&opts, args)
	if is_unified_repo() {
		usage("refresh brings a game repo in line with its unified submodule; unified's own checkout is the source")
	}
	problems := refresh_problems(state.project.unified, state.project.root)
	write_refresh(state.project.unified, state.project.root)
	return {
		ok      = true,
		summary = len(problems) == 0 ? "refresh: already in line with the unified submodule" : aprintf("refresh: %d fixed: %s", len(problems), strings.join(problems, "; ")),
	}
}

// Brings the game repo at `root` in line with unified's checkout at `unified`: the agent guidance (write_agents), the
// shims (`uni` executable in git too: write_shim_mode), the formatter's style (ODINFMT_CONFIG), the missing starters
// (write_starters), and what an older unified copied in deleted (RETIRED, the addons/unified mirror) or retargeted
// (its .gitignore line, its export filter). Stops the command when it can't.
write_refresh :: proc(unified, root: string) {
	write_agents(unified, root)
	for shim in SHIMS {
		path := join(root, shim)
		write_text(path, checkout_eol(path, must_read(shim_template(unified, shim))))
	}
	os.change_mode(join(root, "uni"), os.perm_number(0o755))
	write_shim_mode(root)
	odinfmt_config := join(root, ODINFMT_CONFIG)
	write_text(odinfmt_config, checkout_eol(odinfmt_config, must_read(join(unified, ODINFMT_CONFIG))))
	write_starters(unified, root)
	for retired in RETIRED {
		if is_retired_copy(root, retired) do os.remove(join(root, retired.path))
	}
	if !os.exists(join(root, "GUIDE.md")) {
		for file in game_files(root) {
			text, _ := read_text(file)
			if strings.contains(text, GUIDE_REFERENCE) &&
			   (strings.has_suffix(file, ".odin") || strings.has_suffix(file, ".gd")) {
				repointed, _ := strings.replace_all(text, GUIDE_REFERENCE, GUIDE_NOW)
				write_text(file, repointed)
			} else if strings.contains(text, "GUIDE.md") {
				log(
					"uni: %s still names GUIDE.md (the game's own text): the guide is unified/docs/gameplay.md",
					rel(file),
				)
			}
		}
	}
	remove_legacy_tools(root)
	if text, found := read_text(join(root, ".gitignore")); found {
		if kept, changed := without_legacy_ignore(text); changed do write_text(join(root, ".gitignore"), kept)
	}
	if text, found := read_text(join(root, "export_presets.cfg")); found && strings.contains(text, LEGACY_FILTER) {
		retargeted, _ := strings.replace_all(text, LEGACY_FILTER, "unified/*")
		write_text(join(root, "export_presets.cfg"), retargeted)
	}
}

// What differs in the game repo at `root` from what unified's checkout at `unified` ships, a line each (none: in
// line): agents_problems, a shim or its mode in git, the formatter's style, and each thing write_refresh retires.
// `refresh` fixes each. The starters are the game's: never a problem.
refresh_problems :: proc(unified, root: string) -> []string {
	problems: [dynamic]string
	append(&problems, ..agents_problems(unified, root))
	for shim in SHIMS {
		want := lf(must_read(shim_template(unified, shim)))
		have, found := read_text(join(root, shim))
		if !found || lf(have) != want {
			append(&problems, aprintf("%s: not unified's shim (it runs unified/%s)", shim, shim))
		}
	}
	if mode, _ := shim_git_entry(root); mode == "100644" {
		append(
			&problems,
			"uni: not executable in git (a Windows checkout drops the bit; a Linux or macOS clone can't run it)",
		)
	}
	if have, found := read_text(join(root, ODINFMT_CONFIG));
	   !found || lf(have) != lf(must_read(join(unified, ODINFMT_CONFIG))) {
		append(&problems, aprintf("%s: not unified's (the formatter's style)", ODINFMT_CONFIG))
	}
	for retired in RETIRED {
		if is_retired_copy(root, retired) {
			append(&problems, aprintf("%s: an older unified's copy (%s now)", retired.path, retired.now))
		}
	}
	if !os.exists(join(root, "GUIDE.md")) || is_retired_copy(root, RETIRED[0]) {
		for file in game_files(root) {
			if !strings.has_suffix(file, ".odin") && !strings.has_suffix(file, ".gd") do continue
			if text, _ := read_text(file); strings.contains(text, GUIDE_REFERENCE) {
				append(&problems, aprintf("%s: names %s (%s now)", rel_to(root, file), GUIDE_REFERENCE, GUIDE_NOW))
			}
		}
	}
	if os.is_file(join(root, LEGACY_TOOLS_DIR, MIRROR_STAMP)) {
		append(&problems, aprintf("%s: an older unified's mirror (res://%s now)", LEGACY_TOOLS_DIR, TOOLS_DIR))
	}
	if text, found := read_text(join(root, ".gitignore")); found {
		if _, changed := without_legacy_ignore(text); changed {
			append(&problems, aprintf(".gitignore: ignores %s/, an older unified's mirror", LEGACY_TOOLS_DIR))
		}
	}
	if text, found := read_text(join(root, "export_presets.cfg")); found && strings.contains(text, LEGACY_FILTER) {
		append(&problems, aprintf("export_presets.cfg: excludes %s (unified/* now)", LEGACY_FILTER))
	}
	return problems[:]
}

// The `uni` shim's entry in the git index of the repo at `root`: its mode ("100644", "100755") and blob, or "" and ""
// when git has no `uni` there (no repo, not added yet, or git refused, e.g. a repo it deems unsafe). The index, not
// the file: a Windows checkout (core.filemode=false) never sees the file's mode, and a commit takes the index's.
@(private = "file")
shim_git_entry :: proc(root: string) -> (mode, blob: string) {
	result := run_proc(
		{cmd = strs(git(), "-C", root, "ls-files", "--stage", "--", "uni"), capture = true, quiet = true},
	)
	fields := strings.fields(result.stdout)
	if !result.ok || len(fields) < 2 do return "", ""
	return fields[0], fields[1]
}

// Marks the `uni` shim executable in the git index of the repo at `root` when git tracks it without the bit: the mode
// alone, never the file's content (the rest of a refresh stays unstaged, for the developer to review and commit).
@(private = "file")
write_shim_mode :: proc(root: string) {
	if mode, blob := shim_git_entry(root); mode == "100644" {
		must_run(
			{cmd = strs(git(), "-C", root, "update-index", "--cacheinfo", aprintf("100755,%s,uni", blob))},
			"marking the uni shim executable in git",
		)
	}
}

// Whether the game repo at `root` holds `retired`'s file and it is unified's copy (it holds the mark).
@(private = "file")
is_retired_copy :: proc(root: string, retired: Retired) -> bool {
	text, found := read_text(join(root, retired.path))
	return found && strings.contains(text, retired.mark)
}

// The game repo's own text files at `root` (.odin, .gd, .md): not hidden, not in unified/ or addons/.
@(private = "file")
game_files :: proc(root: string) -> []string {
	out: [dynamic]string
	walker := os.walker_create(root)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		skipped :=
			strings.has_prefix(info.name, ".") ||
			path_key(os.dir(info.fullpath)) == path_key(root) && (info.name == "unified" || info.name == "addons")
		if skipped {
			if info.type == .Directory do os.walker_skip_dir(&walker)
			continue
		}
		if info.type != .Regular do continue
		for suffix in ([]string{".odin", ".gd", ".md"}) {
			if strings.has_suffix(info.name, suffix) do append(&out, strings.clone(info.fullpath))
		}
	}
	return out[:]
}

// `path` relative to `root`, with / separators.
@(private = "file")
rel_to :: proc(root, path: string) -> string {
	relative, _ := strings.replace_all(strings.trim_left(path[len(root):], "/\\"), "\\", "/")
	return relative
}

// `text` (a .gitignore) without the addons/unified line and the comment right above it, when it names unified's tool
// scripts; `changed`: there was one.
without_legacy_ignore :: proc(text: string) -> (kept: string, changed: bool) {
	lines := strings.split(lf(text), "\n")
	out: [dynamic]string
	for line, i in lines {
		entry := strings.trim_space(line)
		if entry == LEGACY_TOOLS_DIR + "/" || entry == "/" + LEGACY_TOOLS_DIR + "/" {
			changed = true
			if len(out) > 0 && strings.has_prefix(out[len(out) - 1], "# unified's tool scripts") do pop(&out)
			continue
		}
		append(&out, lines[i])
	}
	return strings.join(out[:], "\n"), changed
}
