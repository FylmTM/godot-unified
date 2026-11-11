package cli

import "core:os"
import "core:strings"

// A Godot ConfigFile as text, the format of pins.cfg, project.godot, .gdextension and export_presets.cfg: `[section]`
// lines and `key = value` lines (a quoted value is unquoted), `;` comments. Enough for the files we read; a value
// spanning several lines keeps only its first.
Config :: struct {
	sections: map[string]map[string]string,
}

config_parse :: proc(text: string) -> (c: Config) {
	section := ""
	text := text
	for line in strings.split_lines_iterator(&text) {
		s := strings.trim_space(line)
		if s == "" || s[0] == ';' || s[0] == '#' {
			continue
		}
		if s[0] == '[' && s[len(s) - 1] == ']' {
			section = s[1:len(s) - 1]
			if section not_in c.sections {
				c.sections[section] = {}
			}
			continue
		}
		eq := strings.index_byte(s, '=')
		if eq < 0 {
			continue
		}
		key := strings.trim_space(s[:eq])
		value := strings.trim_space(s[eq + 1:])
		if len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' {
			value = value[1:len(value) - 1]
		}
		m := c.sections[section]
		m[key] = value
		c.sections[section] = m
	}
	return
}

config_load :: proc(path: string) -> (c: Config, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return {}, false
	}
	return config_parse(string(data)), true
}

config_get :: proc(c: Config, section, key: string) -> (string, bool) {
	m, has := c.sections[section]
	if !has {
		return "", false
	}
	v, found := m[key]
	return v, found
}

// A pin from <unified>/pins.cfg; a missing one is a broken checkout, so it stops the command.
pin :: proc(section, key: string) -> string {
	v, ok := config_get(state.pins, section, key)
	if !ok {
		fatal("pins.cfg has no [%s] %s", section, key)
	}
	return v
}

// The project's .env (SPEC.md, Local settings): `KEY=value` lines of UNIFIED_* variables, `#` comments. Returns the
// pairs in file order, or an error message naming the bad line.
env_parse :: proc(text: string) -> (pairs: [dynamic][2]string, err: string) {
	text := text
	n := 0
	for line in strings.split_lines_iterator(&text) {
		n += 1
		s := strings.trim_space(line)
		if s == "" || s[0] == '#' {
			continue
		}
		eq := strings.index_byte(s, '=')
		if eq <= 0 {
			return pairs, tprint("line %d: not KEY=value", n)
		}
		key := strings.trim_space(s[:eq])
		if !strings.has_prefix(key, "UNIFIED_") {
			return pairs, tprint("line %d: %s: only UNIFIED_* variables belong here", n, key)
		}
		for ch in key {
			if !(ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_') {
				return pairs, tprint("line %d: %s: a key is A-Z, 0-9 and _", n, key)
			}
		}
		append(&pairs, [2]string{key, strings.trim_space(s[eq + 1:])})
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
	pairs, perr := env_parse(string(data))
	if perr != "" {
		fatal("%s: %s", path, perr)
	}
	keys := make([]string, len(pairs))
	for p, i in pairs {
		if os.set_env(p[0], p[1]) != nil {
			fatal("%s: cannot set %s", path, p[0])
		}
		keys[i] = p[0]
	}
	return keys
}
