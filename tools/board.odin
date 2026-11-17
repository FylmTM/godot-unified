package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "unified:cli"

// The work board (GitHub Project 2, AGENTS.md "The board") through gh. Status and area are given by name,
// case-insensitive ("in progress", "merged, to review"). The project's id and its fields' and options' ids change
// only when a column is renamed: they are kept in .out/board.json and fetched again when missing or when GitHub
// rejects one, so renaming a column needs no change here.

BOARD_OWNER :: "FylmTM"
BOARD_NUMBER :: "2"
BOARD_REPO :: "FylmTM/godot-unified"
BOARD_DONE :: "Done" // the Status column whose issues are closed: `set --status done` closes the issue too

Board_List_Opts :: struct {
	status: string `hint:"S" usage:"only this Status column, by name"`,
	area:   string `hint:"A" usage:"only this Area, by name"`,
}

Board_Set_Opts :: struct {
	issue:  string `args:"pos=0,required" usage:"set: issue number, #N or URL"`,
	status: string `hint:"S" usage:"a Status column by name"`,
	area:   string `hint:"A" usage:"an Area by name"`,
}

cmd_board :: proc(args: []string) -> cli.Result {
	if len(args) > 0 && args[0] == "list" {
		opts: Board_List_Opts
		cli.parse(&opts, args[1:])
		return board_list(opts.status, opts.area)
	}
	if len(args) > 0 && args[0] == "set" {
		opts: Board_Set_Opts
		cli.parse(&opts, args[1:])
		return board_set(opts.issue, opts.status, opts.area)
	}
	opts: Board_List_Opts
	cli.parse(&opts, args) // -h prints the help
	cli.usage("name a subcommand: list or set")
}

// Runs gh; a failure stops the command.
@(private)
gh :: proc(args: ..string) -> string {
	ran, ok := gh_try(..args)
	if !ok {
		cli.fatal("gh %s failed: %s", strings.join(args[:min(2, len(args))], " "), strings.trim_space(ran.stderr))
	}
	return ran.stdout
}

// Runs gh; the caller judges a failure.
@(private)
gh_try :: proc(args: ..string) -> (cli.Ran, bool) {
	cmd: [dynamic]string
	append(&cmd, "gh")
	append(&cmd, ..args)
	ran := cli.run_proc({cmd = cmd[:], capture = true, quiet = true})
	return ran, ran.ok
}

@(private)
Field :: struct {
	id:      string,
	options: [][2]string, // [id, name], in board order
}

// What .out/board.json keeps: the ids `set` needs.
@(private)
Board_Ids :: struct {
	project: string,
	fields:  map[string]Field,
}

// The project's ids: from .out/board.json, else (or with `refetch`) from GitHub, written back.
@(private)
board_ids :: proc(refetch := false) -> Board_Ids {
	path := cli.join(cli.state.project.out, "board.json")
	ids: Board_Ids
	if !refetch {
		if data, err := os.read_entire_file(path, context.allocator); err == nil {
			if json.unmarshal(data, &ids) == nil && ids.project != "" && len(ids.fields) > 0 {
				return ids
			}
		}
	}
	Raw_Fields :: struct {
		fields: []struct {
			id:      string,
			name:    string,
			options: []struct {
				id:   string,
				name: string,
			},
		},
	}
	raw: Raw_Fields
	listed := gh("project", "field-list", BOARD_NUMBER, "--owner", BOARD_OWNER, "--format", "json")
	if json.unmarshal_string(listed, &raw) != nil {
		cli.fatal("cannot read the board's fields: %s", cli.tail(listed, 300))
	}
	ids = {}
	for field in raw.fields {
		if len(field.options) == 0 {
			continue
		}
		options := make([][2]string, len(field.options))
		for option, i in field.options {
			options[i] = {option.id, option.name}
		}
		ids.fields[field.name] = {field.id, options}
	}
	Project :: struct {
		id: string,
	}
	project: Project
	viewed := gh("project", "view", BOARD_NUMBER, "--owner", BOARD_OWNER, "--format", "json")
	if json.unmarshal_string(viewed, &project) != nil || project.id == "" {
		cli.fatal("cannot read the board's id: %s", cli.tail(viewed, 300))
	}
	ids.project = project.id
	if data, err := json.marshal(ids, {pretty = true}); err == nil {
		cli.write_file(path, data)
	}
	return ids
}

// The ids of a field's option, by the option's name (case-insensitive).
@(private)
option_ids :: proc(ids: Board_Ids, field_name, value: string) -> (field_id, option_id, name: string) {
	field, ok := ids.fields[field_name]
	if !ok {
		cli.fatal("the board has no %s field", field_name)
	}
	names: [dynamic]string
	for option in field.options {
		if strings.to_lower(option[1]) == strings.to_lower(value) {
			return field.id, option[0], option[1]
		}
		append(&names, option[1])
	}
	cli.usage("no %s %q; one of: %s", field_name, value, strings.join(names[:], ", "))
}

// Puts the issue on the board (a no-op when it is there) and sets its fields in one GraphQL request; Done also closes
// the issue.
@(private)
board_set :: proc(issue, status, area: string) -> cli.Result {
	if status == "" && area == "" {
		cli.usage("set needs --status and/or --area")
	}
	number_text := strings.trim_prefix(issue[strings.last_index_byte(issue, '/') + 1:], "#")
	number := cli.parse_i64(number_text)
	if number <= 0 {
		cli.usage("%q is not an issue number or URL", issue)
	}
	ids := board_ids()
	Item :: struct {
		id: string,
	}
	item: Item
	added := gh(
		"project",
		"item-add",
		BOARD_NUMBER,
		"--owner",
		BOARD_OWNER,
		"--url",
		cli.aprintf("https://github.com/%s/issues/%d", BOARD_REPO, number),
		"--format",
		"json",
	)
	if json.unmarshal_string(added, &item) != nil || item.id == "" {
		cli.fatal("cannot add #%d to the board: %s", number, cli.tail(added, 300))
	}
	status_name := ""
	edit :: proc(ids: Board_Ids, item_id, status, area: string) -> (query, status_name: string) {
		builder := strings.builder_make()
		strings.write_string(&builder, "mutation {")
		for change, i in ([][2]string{{"Status", status}, {"Area", area}}) {
			if change[1] == "" {
				continue
			}
			field_id, option_id, name := option_ids(ids, change[0], change[1])
			if change[0] == "Status" {
				status_name = name
			}
			fmt.sbprintf(
				&builder,
				` edit%d: updateProjectV2ItemFieldValue(input: {{projectId: %q, itemId: %q, fieldId: %q, value: {{singleSelectOptionId: %q}}}}) {{ clientMutationId }}`,
				i,
				ids.project,
				item_id,
				field_id,
				option_id,
			)
		}
		strings.write_string(&builder, " }")
		return strings.to_string(builder), status_name
	}
	query: string
	query, status_name = edit(ids, item.id, status, area)
	if _, ok := gh_try("api", "graphql", "-f", cli.aprintf("query=%s", query)); !ok {
		// a column renamed since the ids were kept: fetch them again, once
		query, status_name = edit(board_ids(refetch = true), item.id, status, area)
		gh("api", "graphql", "-f", cli.aprintf("query=%s", query))
	}
	closed := ""
	if status_name == BOARD_DONE { 	// Done means closed (AGENTS.md, The board)
		ran, ok := gh_try("issue", "close", cli.aprintf("%d", number), "--repo", BOARD_REPO, "--reason", "completed")
		switch {
		case ok && !strings.contains(ran.stderr, "already closed"):
			closed = ", closed"
		case !ok && !strings.contains(ran.stderr, "already closed"):
			cli.fatal("gh issue close failed: %s", strings.trim_space(ran.stderr))
		}
	}
	return {
		ok      = true,
		summary = cli.aprintf(
			"board: #%d%s%s%s",
			number,
			status_name != "" ? cli.aprintf(" -> %s", status_name) : "",
			area != "" ? cli.aprintf(" (area %s)", area) : "",
			closed,
		),
	}
}

// The board's items, in board order within a column (the order of the Status field's options).
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
	listed := gh("project", "item-list", BOARD_NUMBER, "--owner", BOARD_OWNER, "--format", "json", "--limit", "500")
	if json.unmarshal_string(listed, &items) != nil {
		cli.fatal("cannot read the board: %s", cli.tail(listed, 300))
	}
	order: map[string]int
	for option, i in board_ids().fields["Status"].options {
		order[option[1]] = i
	}
	Row :: struct {
		order:  int,
		number: int,
		status: string,
		area:   string,
		title:  string,
	}
	rows: [dynamic]Row
	for item in items.items {
		if status != "" && strings.to_lower(item.status) != strings.to_lower(status) ||
		   area != "" && strings.to_lower(item.area) != strings.to_lower(area) {
			continue
		}
		column, known := order[item.status]
		append(&rows, Row{known ? column : 99, item.content.number, item.status, item.area, item.title})
	}
	slice.stable_sort_by(rows[:], proc(first, second: Row) -> bool {return first.order < second.order})
	builder := strings.builder_make()
	for row, i in rows {
		if i > 0 {
			strings.write_byte(&builder, '\n')
		}
		fmt.sbprintf(&builder, "#%-4d %-18s %-13s %s", row.number, row.status, row.area, row.title)
	}
	return {
		ok      = true,
		summary = strings.to_string(builder),
		data    = cli.box(rows[:]),
	}
}
