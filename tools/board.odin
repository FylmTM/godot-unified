package main

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

import "unified:cli"

// The work board (GitHub Project 2, AGENTS.md "The board") through gh. Status and area are given by name,
// case-insensitive ("in progress", "merged, to review"); the field and option IDs are looked up from the project
// each run, so renaming a column needs no change here.

BOARD_OWNER :: "FylmTM"
BOARD_NUMBER :: "2"
BOARD_REPO :: "FylmTM/unified"
BOARD_DONE :: "Done" // the Status column whose issues are closed: `set --status done` closes the issue too

cmd_board :: proc(args: []string) -> cli.Result {
	if len(args) == 0 || (args[0] != "list" && args[0] != "set" && args[0] != "-h" && args[0] != "--help") {
		cli.usage("board list [--status S] [--area A] | board set <issue> [--status S] [--area A]")
	}
	Opts :: struct {
		issue:  string `args:"pos=0" usage:"set: issue number, #N or URL"`,
		status: string `usage:"a Status column by name"`,
		area:   string `usage:"an Area by name"`,
	}
	opts: Opts
	if args[0] == "-h" || args[0] == "--help" {
		cli.parse(&opts, args)
	}
	cli.parse(&opts, args[1:])
	if args[0] == "list" {
		if opts.issue != "" {
			cli.usage("list takes no issue")
		}
		return board_list(opts.status, opts.area)
	}
	return board_set(opts.issue, opts.status, opts.area)
}

@(private)
gh :: proc(args: ..string) -> string {
	cmd: [dynamic]string
	append(&cmd, "gh")
	append(&cmd, ..args)
	r := cli.run_proc({cmd = cmd[:], capture = true, quiet = true})
	if !r.ok {
		cli.fatal("gh %s failed: %s", strings.join(args[:min(2, len(args))], " "), strings.trim_space(r.stderr))
	}
	return r.stdout
}

@(private)
Field :: struct {
	id:      string,
	options: [][2]string, // [id, name], in board order
}

@(private)
board_fields :: proc() -> map[string]Field {
	Raw :: struct {
		fields: []struct {
			id:      string,
			name:    string,
			options: []struct {
				id:   string,
				name: string,
			},
		},
	}
	raw: Raw
	if json.unmarshal(
		   transmute([]byte)gh("project", "field-list", BOARD_NUMBER, "--owner", BOARD_OWNER, "--format", "json"),
		   &raw,
	   ) !=
	   nil {
		cli.fatal("cannot read the board's fields")
	}
	out: map[string]Field
	for f in raw.fields {
		if len(f.options) == 0 {
			continue
		}
		opts := make([][2]string, len(f.options))
		for o, i in f.options {
			opts[i] = {o.id, o.name}
		}
		out[f.name] = {f.id, opts}
	}
	return out
}

@(private)
option :: proc(fields: map[string]Field, field, value: string) -> (field_id, option_id, name: string) {
	f, ok := fields[field]
	if !ok {
		cli.fatal("the board has no %s field", field)
	}
	names: [dynamic]string
	for o in f.options {
		if strings.to_lower(o[1]) == strings.to_lower(value) {
			return f.id, o[0], o[1]
		}
		append(&names, o[1])
	}
	cli.usage("no %s %q; one of: %s", field, value, strings.join(names[:], ", "))
}

@(private)
board_set :: proc(issue, status, area: string) -> cli.Result {
	if issue == "" {
		cli.usage("set needs an issue")
	}
	if status == "" && area == "" {
		cli.usage("set needs --status and/or --area")
	}
	t := issue[strings.last_index_byte(issue, '/') + 1:]
	t = strings.trim_prefix(t, "#")
	n := cli.parse_i64(t)
	if n <= 0 {
		cli.usage("%q is not an issue number or URL", issue)
	}
	fields := board_fields()
	Item :: struct {
		id: string,
	}
	url := cli.tprint("https://github.com/%s/issues/%d", BOARD_REPO, n)
	item: Item
	json.unmarshal(
		transmute([]byte)gh(
			"project",
			"item-add",
			BOARD_NUMBER,
			"--owner",
			BOARD_OWNER,
			"--url",
			url,
			"--format",
			"json",
		),
		&item,
	)
	Proj :: struct {
		id: string,
	}
	proj: Proj
	json.unmarshal(
		transmute([]byte)gh("project", "view", BOARD_NUMBER, "--owner", BOARD_OWNER, "--format", "json"),
		&proj,
	)
	status_name := ""
	for change in ([][2]string{{"Status", status}, {"Area", area}}) {
		if change[1] == "" {
			continue
		}
		fid, oid, name := option(fields, change[0], change[1])
		if change[0] == "Status" {
			status_name = name
		}
		gh(
			"project",
			"item-edit",
			"--id",
			item.id,
			"--project-id",
			proj.id,
			"--field-id",
			fid,
			"--single-select-option-id",
			oid,
		)
	}
	closed := ""
	if status_name == BOARD_DONE { 	// Done means closed (AGENTS.md, The board)
		State :: struct {
			state: string,
		}
		st: State
		json.unmarshal(
			transmute([]byte)gh("issue", "view", cli.tprint("%d", n), "--repo", BOARD_REPO, "--json", "state"),
			&st,
		)
		if st.state != "CLOSED" {
			gh("issue", "close", cli.tprint("%d", n), "--repo", BOARD_REPO, "--reason", "completed")
			closed = ", closed"
		}
	}
	return {
		ok = true,
		summary = cli.tprint(
			"board: #%d%s%s%s",
			n,
			status_name != "" ? cli.tprint(" -> %s", status_name) : "",
			area != "" ? cli.tprint(" (area %s)", area) : "",
			closed,
		),
	}
}

@(private)
board_list :: proc(status, area: string) -> cli.Result {
	Items :: struct {
		items: []struct {
			status:  string,
			area:    string,
			title:   string,
			content: struct {
				number: int,
			},
		},
	}
	items: Items
	if json.unmarshal(
		   transmute([]byte)gh(
			   "project",
			   "item-list",
			   BOARD_NUMBER,
			   "--owner",
			   BOARD_OWNER,
			   "--format",
			   "json",
			   "--limit",
			   "500",
		   ),
		   &items,
	   ) !=
	   nil {
		cli.fatal("cannot read the board")
	}
	order: map[string]int
	for o, i in board_fields()["Status"].options {
		order[o[1]] = i
	}
	Row :: struct {
		order:  int,
		number: int,
		status: string,
		area:   string,
		title:  string,
	}
	rows: [dynamic]Row
	for it in items.items {
		if status != "" && strings.to_lower(it.status) != strings.to_lower(status) ||
		   area != "" && strings.to_lower(it.area) != strings.to_lower(area) {
			continue
		}
		o, has := order[it.status]
		append(&rows, Row{has ? o : 99, it.content.number, it.status, it.area, it.title})
	}
	slice.stable_sort_by(rows[:], proc(a, b: Row) -> bool {return a.order < b.order}) 	// board order within a column
	b := strings.builder_make()
	for r, i in rows {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		fmt.sbprintf(&b, "#%-4d %-18s %-13s %s", r.number, r.status, r.area, r.title)
	}
	return {ok = true, summary = strings.to_string(b), data = cli.box(rows[:])}
}
