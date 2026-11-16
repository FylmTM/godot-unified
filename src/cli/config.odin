package cli

import "core:os"
import "core:strings"

// A Godot ConfigFile as text, the format of pins.cfg, project.godot, .gdextension and export_presets.cfg: `[section]`
// lines and `key = value` lines (a quoted value is unquoted), `;` comments. Enough for the files we read; a value
// spanning several lines keeps only its first.
Config :: struct {
	sections: map[string]map[string]string,
}

// Parses ConfigFile text (pins.cfg, project.godot, a .gdextension) into its sections; keys before the first
// section go in section "", and lines it doesn't understand are skipped.
config_parse :: proc(text: string) -> (config: Config) {
	section := ""
	text := text
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == ';' || trimmed[0] == '#' {
			continue
		}
		if trimmed[0] == '[' && trimmed[len(trimmed) - 1] == ']' {
			section = trimmed[1:len(trimmed) - 1]
			if section not_in config.sections {
				config.sections[section] = {}
			}
			continue
		}
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 {
			continue
		}
		key := strings.trim_space(trimmed[:eq])
		value := strings.trim_space(trimmed[eq + 1:])
		if len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' {
			value = value[1:len(value) - 1]
		}
		entries := config.sections[section]
		entries[key] = value
		config.sections[section] = entries
	}
	return
}

// Reads and parses a ConfigFile; false when the file can't be read.
config_load :: proc(path: string) -> (config: Config, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return {}, false
	}
	return config_parse(string(data)), true
}

// A key's value in a section; false when either is missing (`pin` makes that fatal for pins.cfg).
config_get :: proc(config: Config, section, key: string) -> (string, bool) {
	entries, has := config.sections[section]
	if !has {
		return "", false
	}
	value, found := entries[key]
	return value, found
}

// A pin from <unified>/pins.cfg; a missing one is a broken checkout, so it stops the command.
pin :: proc(section, key: string) -> string {
	value, ok := config_get(state.pins, section, key)
	if !ok {
		fatal("pins.cfg has no [%s] %s", section, key)
	}
	return value
}

// The project's .env (SPEC.md, Local settings): `KEY=value` lines of UNIFIED_* variables, `#` comments. Returns the
// pairs in file order, or an error message naming the bad line.
env_parse :: proc(text: string) -> (pairs: [dynamic][2]string, err: string) {
	text := text
	line_number := 0
	for line in strings.split_lines_iterator(&text) {
		line_number += 1
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' {
			continue
		}
		eq := strings.index_byte(trimmed, '=')
		if eq <= 0 {
			return pairs, aprintf("line %d: not KEY=value", line_number)
		}
		key := strings.trim_space(trimmed[:eq])
		if !strings.has_prefix(key, "UNIFIED_") {
			return pairs, aprintf("line %d: %s: only UNIFIED_* variables belong here", line_number, key)
		}
		for ch in key {
			if !(ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_') {
				return pairs, aprintf("line %d: %s: a key is A-Z, 0-9 and _", line_number, key)
			}
		}
		append(&pairs, [2]string{key, strings.trim_space(trimmed[eq + 1:])})
	}
	return pairs, ""
}

// Loads <root>/.env into this process's environment, so every child process inherits it. The file wins over the
// shell. Returns the keys it set.
env_load :: proc(root: string) -> []string {
	path := join(root, ".env")
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return nil
	}
	pairs, parse_err := env_parse(string(data))
	if parse_err != "" {
		fatal("%s: %s", path, parse_err)
	}
	keys := make([]string, len(pairs))
	for pair, i in pairs {
		if os.set_env(pair[0], pair[1]) != nil {
			fatal("%s: cannot set %s", path, pair[0])
		}
		keys[i] = pair[0]
	}
	return keys
}
