package test_cli

import "core:os"
import "core:strings"
import "core:testing"
import "unified:cli"

// This checkout: the source of the guidance a game repo gets.
UNIFIED_ROOT :: #directory + "/../.."

@(test)
agents_section_is_made_appended_and_replaced :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	block := strings.concatenate({cli.AGENTS_BEGIN, "\nnew\n", cli.AGENTS_END, "\n"})
	text, ok := cli.agents_spliced("", "new\n")
	testing.expect(t, ok)
	testing.expect_value(t, text, block)
	text, ok = cli.agents_spliced("# game\r\n\r\nown rules\r\n", "new")
	testing.expect_value(t, text, strings.concatenate({"# game\n\nown rules\n\n", block}))
	old := strings.concatenate(
		{"# game\n\n", cli.AGENTS_BEGIN_MARK, " (older wording) -->\nold\n", cli.AGENTS_END, "\n\nafter\n"},
	)
	text, ok = cli.agents_spliced(old, "new")
	testing.expect(t, ok)
	testing.expect_value(t, text, strings.concatenate({"# game\n\n", block, "\nafter\n"}))
	again, _ := cli.agents_spliced(text, "new")
	testing.expect_value(t, again, text)
	_, ok = cli.agents_spliced(strings.concatenate({cli.AGENTS_BEGIN, "\nold\n"}), "new")
	testing.expect(t, !ok, "a begin marker without an end is refused")
}

@(test)
agents_written_then_current_then_stale :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // the CLI never frees: it is short-lived
	root, temp_err := os.make_directory_temp("", "unified-agents-test-*", context.allocator)
	testing.expect(t, temp_err == nil)
	defer os.remove_all(root)
	skills := cli.join(root, cli.SKILLS_DIR)
	testing.expect(t, len(cli.agents_problems(UNIFIED_ROOT, root)) > 0, "an empty repo has no guidance")

	// a game's own skill and AGENTS.md text stay; a skill an older unified shipped goes
	cli.write_text(cli.join(root, "AGENTS.md"), "# game\n\nown rules\n")
	cli.write_text(cli.join(skills, "own", "SKILL.md"), "the game's own\n")
	cli.write_text(cli.join(skills, "retired", "SKILL.md"), "an older unified's\n")
	cli.write_text(cli.join(skills, cli.SKILLS_STAMP), "# stamp\nretired\n")
	cli.write_agents(UNIFIED_ROOT, root)
	testing.expect_value(t, len(cli.agents_problems(UNIFIED_ROOT, root)), 0)
	testing.expect(t, os.is_file(cli.join(skills, "own", "SKILL.md")))
	testing.expect(t, !os.exists(cli.join(skills, "retired")))
	agents, _ := cli.read_text(cli.join(root, "AGENTS.md"))
	testing.expect(t, strings.has_prefix(agents, "# game\n\nown rules\n\n"))
	for name in cli.GAME_SKILLS {
		testing.expect(t, os.is_file(cli.join(skills, name, "SKILL.md")), name)
	}

	// each kind of drift is named, and a write fixes them all
	cli.write_text(cli.join(skills, cli.GAME_SKILLS[0], "SKILL.md"), "edited\n")
	cli.write_text(cli.join(skills, cli.GAME_SKILLS[1], "extra.md"), "not unified's\n")
	os.remove(cli.join(skills, cli.GAME_SKILLS[2], "SKILL.md"))
	edited, _ := strings.replace(agents, "## unified", "## unified, edited", 1)
	cli.write_text(cli.join(root, "AGENTS.md"), edited)
	cli.write_text(cli.join(skills, cli.SKILLS_STAMP), "# stamp\n")
	problems := cli.agents_problems(UNIFIED_ROOT, root)
	wants := []string {
		"AGENTS.md: the unified section differs",
		"SKILL.md: differs from unified's",
		"extra.md: not unified's",
		"SKILL.md: missing",
		"unified.txt: missing or not current",
	}
	testing.expect_value(t, len(problems), len(wants))
	for want in wants {
		testing.expect(t, names(problems, want), want)
	}
	cli.write_agents(UNIFIED_ROOT, root)
	testing.expect_value(t, len(cli.agents_problems(UNIFIED_ROOT, root)), 0)
}

// Whether one of `problems` contains `want`.
names :: proc(problems: []string, want: string) -> bool {
	for problem in problems {
		if strings.contains(problem, want) do return true
	}
	return false
}
