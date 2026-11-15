package cli

import "core:os"
import "core:strings"

// Line endings (SPEC.md, Line endings): every text file is LF in the working tree, except what .gitattributes marks
// `eol=crlf` (batch files: cmd.exe misreads labels and goto in an LF one). `fmt --check` fails on a file that breaks
// this, `fmt` fixes it. Git decides what is text (.gitattributes, else its own detection), so the check is one
// `git ls-files --eol` over the tracked and untracked, not ignored, files; it runs while odinfmt does.

// `git ls-files --eol` for the given paths (none: the whole project), started; eol_wait collects it.
eol_start :: proc(paths: []string) -> Proc {
	cmd: [dynamic]string
	append(
		&cmd,
		git(),
		"-C",
		state.project.root,
		"ls-files",
		"-z",
		"--eol",
		"--cached",
		"--others",
		"--exclude-standard",
	)
	if len(paths) > 0 {
		append(&cmd, "--")
		append(&cmd, ..paths)
	}
	return start({
		cmd     = cmd[:],
		capture = true,
		quiet   = true,
	})
}

Eol_File :: struct {
	path:    string, // relative to the project root, /-separated
	problem: string,
	crlf:    bool, // what the file should have: CRLF (else LF)
}

// The files whose line endings are wrong, from the started `git ls-files --eol`.
eol_wait :: proc(child: ^Proc) -> []Eol_File {
	result := wait(child)
	if !result.ok {
		fatal("git ls-files --eol failed:\n%s", result.stderr)
	}
	return eol_problems(result.stdout)
}

// Parses `git ls-files -z --eol` output: `i/<index> w/<worktree> attr/<attributes> \t<path>` entries, NUL-separated.
// Returns the files with a problem (eol_problem).
eol_problems :: proc(listing: string) -> []Eol_File {
	out: [dynamic]Eol_File
	rest := listing
	for len(rest) > 0 {
		entry := rest
		if end := strings.index_byte(rest, 0); end >= 0 {
			entry, rest = rest[:end], rest[end + 1:]
		} else {
			rest = ""
		}
		tab := strings.index_byte(entry, '\t')
		if tab < 0 {
			continue
		}
		info, path := entry[:tab], entry[tab + 1:]
		if problem, crlf := eol_problem(info); problem != "" {
			append(&out, Eol_File {
				path    = path,
				problem = problem,
				crlf    = crlf,
			})
		}
	}
	return out[:]
}

// What is wrong with one file's line endings, from its `git ls-files --eol` fields (`i/lf w/crlf attr/text eol=lf`):
// "" when nothing is. `crlf`: the file should be CRLF (its attributes say eol=crlf). Binary files (`-text`) and
// files without line endings (`none`) are fine.
eol_problem :: proc(info: string) -> (problem: string, crlf: bool) {
	index, worktree, attr: string
	fields := info
	for field in strings.fields_iterator(&fields) {
		switch {
		case strings.has_prefix(field, "i/"):
			index = field[2:]
		case strings.has_prefix(field, "w/"):
			worktree = field[2:]
		case strings.has_prefix(field, "attr/"):
			attr = info[strings.index(info, "attr/") + 5:]
		}
	}
	crlf = strings.contains(attr, "eol=crlf")
	if strings.contains(attr, "-text") || strings.contains(attr, "binary") {
		return "", crlf
	}
	switch {
	case index == "crlf" || index == "mixed":
		return "committed with CRLF line endings (git add --renormalize)", crlf
	case worktree == "mixed":
		return "mixed line endings", crlf
	case crlf && worktree == "lf":
		return "LF line endings; .gitattributes says CRLF", crlf
	case !crlf && worktree == "crlf":
		return "CRLF line endings", crlf
	}
	return "", crlf
}

// `text` with every line ending LF (crlf: CRLF).
eol_convert :: proc(text: string, crlf: bool) -> string {
	lf, _ := strings.replace_all(text, "\r\n", "\n")
	if !crlf {
		return lf
	}
	out, _ := strings.replace_all(lf, "\n", "\r\n")
	return out
}

// Rewrites a file with the line endings it should have, keeping its mode (the POSIX shim stays executable).
eol_fix :: proc(file: Eol_File) {
	path := join(state.project.root, file.path)
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return // listed by git, gone since
	}
	write_text(path, eol_convert(must_read(path), file.crlf))
	os.change_mode(path, info.mode)
}
