# 12 · AI tooling: the `unified` CLI, Godot for agents, skills

How agents (Claude Code first) build, run, inspect and learn `unified` + Godot 4.7, and what knowledge we package for
them. Researched 2026-11-08. *(unverified)* marks claims not checked against a primary source. Builds on
`08-agent-tooling.md` (control protocol, harness), which this doc doesn't repeat.

## TL;DR and recommendation

1. **One `unified` CLI, written in Odin, built from the repo.** A two-line shim (`./unified`, `unified.cmd`)
   rebuilds the binary when its sources change, then runs it. This is the `cargo xtask` pattern: the repo's tooling
   in the repo's language ([matklad/cargo-xtask](https://github.com/matklad/cargo-xtask)). It replaces `tools/*.py`
   and every future script. It is also the only client of 08's control socket. Every command has `--json`, stable
   exit codes, and a time budget.
2. **Godot, text first.** Agents edit `.gd`, `.tscn`, `.tres` and `project.godot` as text. `unified godot …` wraps
   Godot's headless CLI (`--import`, `--check-only`, `--doctool`, exports). The runtime is driven through our own
   control server, which lives in the Odin GDExtension rather than in Godot. A small optional **editor bridge**
   covers only what an open editor must do: reload a scene changed on disk (Godot's "newer on disk" dialog can't be
   switched off), play or stop, and take an editor screenshot. **Don't adopt a third-party Godot MCP server.**
3. **Our own skills: few, short, in-repo** (`.claude/skills/`). They are versioned with the code they describe,
   need no install, and reload live. No plugin and no CLI-managed install yet. `unified check` lints the skills:
   frontmatter, and every `unified …` command they mention must exist. Packaging (plugin vs CLI sync) is decided
   when the first game repo consumes `unified` as a library.

## What the current Unity game taught

08 covers the harness-level lessons. These are the tooling ones.

**Worked, keep:**

- **A table of steps with time budgets**, plus the rule that a step slower than its
  budget is a bug. The CLI should print each step's time against its budget.
- **Narrowest proof first**: a test filter, then the everyday set before a check-in, and fuzzes once
  at the end of a big task, skipped when nothing they guard changed.
- **Small play verbs** (`shot`, `ui`, `key`, `mouse`, `teleport`, `view`, `friend`, `time`) and probes (a camera
  trace, a per-frame value trace). Agents used small, named verbs reliably.
- **F3 feedback with a cheapest-first procedure** (`show` + screenshot, then `entity`/`grep`, then a headless repro,
  then `done`). The procedure itself is a skill in all but name.
- **Concurrency rules**: build under a lock, run from a private copy, numbered slots for heavy jobs, "one Unity
  stream".

**Unity forced (design away):**

- **Sprawl.** About 17 bash, PowerShell and Python entry points, plus a shim to keep bash 3.2 and Git Bash happy. That
  is the "random scripts in random languages" AGENTS.md now forbids.
- **The bridge is C# strings.** `u eval "UnityEngine.Object.FindFirstObjectByType<…>().SetView(${2}f, …)"` inside
  bash. Quoting, `f` suffixes, no `using`, and timeouts in two units are lessons agents had to learn the hard way.
- **The bridge dies with the Editor.** Compile errors put Unity in Safe Mode, where the Pipeline package doesn't
  load, so `unity command` can't connect (Unity's own `unity-cli` skill warns about this). Modal dialogs block
  everything and need an Accessibility-API presser.
- **What Unity's CLI got right, and we copy:** `--json` on every command; the CLI as the single agent entry point
  (`unity command`, `unity run --command`); an attribute (`[CliCommand]`) for adding project commands; and
  `unity mcp configure`, which registers its MCP server in 16 clients. (Unity's skill `unity-cli/SKILL.md` v0.1.2-beta,
  read locally.)

## Prior art: Godot + AI

**Godot's own surface (primary, stable)**

| Piece | What it gives agents |
|---|---|
| CLI ([4.7 docs](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html)) | `--headless` (dummy display and audio), `-s <script>` (a `SceneTree`/`MainLoop` script), `--check-only` (parse a script and quit), `--import` (import, then quit: the CI way), `--export-release/debug/pack`, `--doctool` + `--gdscript-docs`/`--gdextension-docs` (API reference as XML), `--dump-extension-api-with-docs`, `--write-movie` + `--fixed-fps`, `--log-file`, `--quit-after`. Unknown arguments are silently ignored, so a wrapper must validate them |
| Text formats ([TSCN](https://docs.godotengine.org/en/stable/engine_details/file_formats/tscn.html)) | `.tscn`/`.tres` are INI-like: `[gd_scene format=3 uid=…]`, `[ext_resource]`, `[sub_resource]`, `[node parent=…]`, `[connection]`. UIDs survive moves. The editor drops comments and default-valued properties on save. Hand-editing works but isn't a documented workflow |
| External edits | Scripts can auto-reload. Scenes changed on disk while open raise a reload/resave dialog that, per forum reports, can't be suppressed ([forum](https://forum.godotengine.org/t/window-when-a-scene-has-changed-outside-godot/133091), *unverified*) |
| GDScript LSP and DAP | `--lsp-port` and `--dap-port` (editor builds). The LSP runs inside the editor (default 6005). A headless editor as the LSP host is a community workaround ([OpenCode bridge](https://cdn.jsdelivr.net/npm/opencode-godot-lsp@1.0.1/README.md), *unverified*). |
| Debugger messages | `EngineDebugger.register_message_capture`/`send_message` in the game, and `EditorDebuggerPlugin` in the editor ([docs](https://docs.godotengine.org/en/stable/classes/class_enginedebugger.html)). `Expression` evaluates single expressions at runtime ([docs](https://docs.godotengine.org/en/stable/classes/class_expression.html)) |

**Godot MCP servers (community).** There is no official Godot or Godot Foundation MCP or AI integration (search
2026-11-08 found none). The landscape is fragmented:

| Project | Approach | Notes |
|---|---|---|
| [Coding-Solo/godot-mcp](https://github.com/Coding-Solo/godot-mcp) | Node server. Godot CLI for simple ops, one bundled `godot_operations.gd` for scene edits | ~6.6k stars, MIT. Run, stop, debug output, create scenes and nodes, UIDs. No screenshots or input |
| [godot-mcp-pro](https://github.com/youichi-uda/godot-mcp-pro) | Editor plugin, WebSocket 6505–6509 | $15, proprietary server. 162–187 tools (the README contradicts itself) |
| GDAI MCP | Editor plugin, Godot 4.2+ | $19. Scene and script edits, debugger output, screenshots, input ([roundup](https://www.summerengine.com/blog/best-godot-mcp-server)) |
| [godot-mcp-runtime](https://mcpservers.org/servers/erodenn/godot-mcp-runtime), [fernforestgames](https://github.com/fernforestgames/mcp-server-godot-editor), [letsagents](https://github.com/letsagents/godot-mcp), [OREBRON](https://github.com/OREBRON/godot-mcp), IvanMurzak (C#), hi-godot (Python) | Runtime autoloads or editor plugins | Each re-implements the same three things: run and capture output, edit scenes, screenshot plus input |

Assessment: these are useful as idea lists. None knows about ticks, peers, rollback or replays. Most are months old
and change weekly, and the comparisons are vendor-written (Summer Engine, Ziva). Adopting one would add a Node or
Python dependency and a second bridge next to our control server.

**In-editor assistants.** Ziva (commercial: reads the scene tree and errors, runs the game, can act as an MCP
server) and Summer Engine (its own Godot-compatible app) are products, not building blocks
([Ziva](https://ziva.sh/blogs/godot-ai-skills), vendor post).

**Godot skill packs** (Ziva's survey, 2026-09-27, vendor-authored):
[GodotPrompter](https://github.com/jame581/GodotPrompter) (56 skills, MIT, 4.3+),
[gd-agentic-skills](https://github.com/thedivergentai/gd-agentic-skills) (99, LGPL-3.0, 4.7+),
[awesome-gamedev-agent-skills](https://github.com/gamedev-skills/awesome-gamedev-agent-skills) (16 Godot skills of
74, Apache-2.0),
[Claude-Code-Game-Studios](https://github.com/Donchitos/Claude-Code-Game-Studios) (~25k stars, broad, not deep).
They teach GDScript gameplay: signals, state machines, UI, exports. Our gameplay is Odin and the Godot side is a thin
view, so most of that content is irrelevant to us. What remains valuable is 4.7 API correctness, and Godot's own
`--doctool` output gives us that exactly, for free.

## How skills and plugins work (Claude Code, November 2026)

**Instruction files.** Claude Code reads `AGENTS.md` natively (v2.1.277+) when there is no `CLAUDE.md` or
`CLAUDE.local.md` at or above the working directory. Otherwise it reads only the `CLAUDE.md` files, unless the
**Project instructions** setting is `claude-md-and-agents-md`. `@path` imports work in both. Subdirectory files load
on demand. `.claude/rules/*.md` can be path-scoped. The docs' rule of thumb: put every-session facts (commands,
layout, rules) in the instruction file, and move multi-step procedures to skills
([memory docs](https://code.claude.com/docs/en/memory)). [AGENTS.md](https://agents.md/) is an open format
stewarded by the Agentic AI Foundation (Linux Foundation). Codex, Cursor, Gemini CLI, Copilot, Jules, Zed and others
read it, and the nearest file wins.

**Skills** ([docs](https://code.claude.com/docs/en/skills)):

- **A skill is a folder** holding `SKILL.md` (YAML frontmatter, then Markdown) plus any `references/`, `scripts/` or
  `assets/`. Keep `SKILL.md` under 500 lines and link the detail.
- **Frontmatter:** `name` (defaults to the folder name) and `description` (Claude decides from it when to load the
  skill; together with `when_to_use` it is truncated at 1,536 characters in the listing). Optional fields:
  - `disable-model-invocation` (user-only) and `user-invocable: false` (model-only)
  - `allowed-tools` (pre-approved for that turn) and `disallowed-tools`
  - `paths` (globs that limit automatic activation)
  - `context: fork` + `agent` (run as a subagent)
  - `model`, `effort`, `hooks`, `arguments`/`argument-hint`
- **Substitutions:** `$ARGUMENTS`, `${CLAUDE_SKILL_DIR}`, `${CLAUDE_PROJECT_DIR}`. A line of the form
  ``!`cmd` `` runs a shell command before Claude reads the skill and inlines its output. For example,
  ``!`unified status --json` `` injects live state. If the command fails, the whole skill invocation aborts.
- **Locations and precedence:** enterprise > personal (`~/.claude/skills/`) > project (`.claude/skills/`, from the
  working directory up to the repo root). Nested `<subdir>/.claude/skills/` load on first access to that subdir.
  Plugin skills are namespaced (`/plugin:skill`). A skill and a `.claude/commands/x.md` file both become `/x`; the
  skill wins.
- **Cost:** progressive disclosure. Descriptions are always in context; bodies load on use and stay loaded. After
  compaction, the first 5,000 tokens of each skill used are re-attached. Edits to project and personal skills reload
  live.
- **The [Agent Skills standard](https://agentskills.io/specification.md)** is the portable subset, originally
  Anthropic's. `name` is required (≤64 characters, lowercase and hyphens, matching the folder) and so is
  `description` (≤1024 characters), plus optional `license`, `compatibility`, `metadata` and `allowed-tools`. The
  Claude-only keys are ignored by Claude Code's peers but *rejected* by claude.ai and the Skills API.

**Plugins** ([overview](https://code.claude.com/docs/en/plugins),
[manifest](https://code.claude.com/docs/en/plugins/manifest-reference.md),
[loading](https://code.claude.com/docs/en/plugins/loading.md)):

- **Layout:** a directory with an optional `.claude-plugin/plugin.json` (`name` required; `version`,
  `dependencies`, `userConfig`…). Components:
  - `skills/`, `agents/`, `hooks/hooks.json`
  - `.mcp.json` and `.lsp.json` (language servers: diagnostics after every edit, plus an `LSP` navigation tool)
  - `monitors/`
  - `bin/`, which is added to the Bash tool's `PATH` while the plugin is enabled
- **Marketplaces:** a git repo or directory with `.claude-plugin/marketplace.json` listing plugins and their
  sources (relative path, GitHub, git subdir, URL, npm, archive, command). Commands: `/plugin marketplace add
  owner/repo`, `/plugin install name@marketplace`, or `claude plugin …` from a shell.
- **Scopes:** user, project (the committed `.claude/settings.json` with `enabledPlugins` and
  `extraKnownMarketplaces`), or local. A project-enabled plugin with an external source is *not* fetched
  automatically. A relative-path plugin loads in place, with no install record. A plugin folder that has its own
  manifest and sits under `.claude/skills/` loads as `<name>@skills-dir` after the workspace trust dialog.
- **Versions:** the manifest's `version` pins users until it changes. Without one, the version is the commit SHA.
  Auto-update is off by default for third-party marketplaces. Installed copies live in
  `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`. `claude plugin validate --strict` is the CI check.

**How other tools consume skills:**

- **Codex** reads `.agents/skills` from the working directory up to the repo root, plus `~/.agents/skills` and
  `/etc/codex/skills`. Skills are invoked with `$name` or implicitly. An optional `agents/openai.yaml` adds UI
  metadata and policy ([docs](https://learn.chatgpt.com/docs/build-skills)).
- **Claude Code does not read `.agents/`.**
- **Unity's agent plugin** (installed here) is one repo carrying `.claude-plugin/`, `.codex-plugin/` and
  `.agents/plugins/marketplace.json`: one skill tree, three agents (Claude Code, Codex, Grok).
- **Vercel's [`skills` CLI](https://github.com/vercel-labs/skills)** installs skills from a repo by symlinking them
  into each agent's folder (`.claude/skills`, `.agents/skills`, `.cursor/skills`, …)
  ([write-up](https://codex.danielvaughan.com/2026/05/31/codex-cli-vercel-skills-cli-npx-skills-open-agent-skills-ecosystem/)).

## The `unified` CLI

**Why one tool.** AGENTS.md already mandates it. The current Unity game shows the alternative. The single help surface
also makes it cheap to teach: one skill, one `--help` tree. 08's spike criterion
("a fresh agent with only `uni --help`…") applies to the whole tool.

**Language: Odin, one binary.**

*For Odin:*

- It is the project's one language.
- The CLI can import the core directly. `unified test`, `replay verify` and `run headless` then call the sim
  in-process instead of spawning a runner.
- Fast start, no Python or Node on any machine, and identical behaviour on macOS, Linux and Windows.

*What the stdlib has* (checked locally against `odin dev-2026-11`):

- `core:os` process API (`process_start`, `process_exec`)
- `core:flags`, `core:encoding/json`
- `core:net` (TCP and UDP)
- `vendor:curl`

*Gaps:*

- `core:net` has no Unix-domain socket wrapper, so we'd go through `core:sys/posix` on macOS and Linux, and Winsock
  `AF_UNIX` or loopback TCP with a token on Windows.
- No HTTP client beyond curl.
- `core:os` was reworked during 2026, so expect some API churn
  ([forum](https://forum.odin-lang.org/t/a-cross-patform-way-ro-spawn-processes/603)).

**Bootstrap.** `./unified <args>` (sh) and `unified.cmd`: if any `tools/unified/**.odin` file is newer than
`.unified/bin/unified`, rebuild under a lock (`odin build tools/unified -o:speed`), then `exec`. Budgets *(to
measure)*: a no-op check under 50 ms, a rebuild under 3 s. CI calls the same shim.

**Conventions:**

- Subcommand groups, `--json` on everything, and exit codes 0 (ok), 1 (failed), 2 (usage), 3 (blocked or
  unavailable).
- Human output ends with one line per step: its time against its budget, with a `SLOW` flag when over.
- Worktree-local state lives in `.unified/` (gitignored): run dirs, artifacts, builds, locks. Machine-wide caches
  and slots live in `~/.cache/unified/`.
- `unified help --md` emits the command reference. A skill embeds it, and `unified check` fails when that copy is
  stale.

**Command sketch** (names are proposals):

| Group | Commands | Replaces or adds |
|---|---|---|
| setup | `doctor`, `setup` (pinned Odin, Godot 4.7.x, Box3D fork) | `tools/box3d.py`, CI install steps |
| build | `build [core\|ext\|runner\|all] [--mode dev\|release] [--arch x86_64]` | `impl/*/build.py` |
| test | `test [filter] [--sync-test k] [--fuzz quick\|full] [--no-cache]` | `tools/check.py` |
| check | `check` (fmt check, vet, determinism lint: banned imports/types, FMA flags), `fmt` | lint scripts |
| bench | `bench [name] [--compare <ref>] [--ci]` | ad-hoc bench runners |
| run | `run headless …`, `run game [--peers N] [--netsim …]`, `ls`, `stop <id>` | `play.sh` |
| control | `query`, `get`, `edit`, `step`, `pause`, `input`, `shot`, `view`, `log`, `perf`, `snapshot`, `rpc <method> <json>` | 08's protocol, one verb each |
| replay | `replay run\|verify\|bless\|diff` | — |
| feedback | `feedback list\|show\|entity\|grep\|check\|promote\|done` | `feedback.sh` |
| godot | `godot import\|check\|export\|docs <Class>\|api\|lsp\|open`, `godot editor reload\|scan\|play\|stop\|shot` | Godot CLI wrappers + bridge |
| ci | `ci <job>`, `ci summary` | `tools/ci.py` |
| agents | `agents check` (skills lint); later `agents sync` | — |
| (later) | `mcp` (stdio adapter over the same RPC) | — |

**Talking to a running game.** 08's control server is part of the Odin core's `dev-tools` layer, so it runs in both
the headless runner and the GDExtension inside Godot. The same verbs then work with or without Godot. Godot-only
handlers (screenshots via the viewport texture, camera, UI state) are registered by the extension. The CLI finds
instances through `.unified/run/<id>/control.json`. Eval:

- **The sim gets no eval.** Mutations go through debug commands on the input path (08), so determinism holds.
- **An optional dev-only `unified eval '<expr>'`** in the game runs Godot's `Expression` against a chosen node. It
  is an escape hatch for view-side questions, logged and off in release builds. Curated verbs come first. The current
  Unity game shows eval strings becoming the primary API when verbs are missing.

**Talking to an open editor (optional bridge).** A `@tool` EditorPlugin in the shared Godot project
(`addons/unified/`) listens only while the editor runs and writes `.unified/editor.json`. Verbs:

- `reload <scene>` (`EditorInterface.reload_scene_from_path`, so the external-change dialog never comes up;
  *unverified* that it pre-empts the dialog)
- `scan` (reimport)
- `play [scene]`, `stop`
- `shot` (the editor viewport)
- `errors` (the Output and Debugger panes)

It can be written in GDScript (simplest, and GDScript is already allowed in the view layer) or as an editor-level
class in our GDExtension (Odin only, harder to iterate). With the editor closed, `unified godot import` (headless
`--import`) does the same job. The bridge is never needed for correctness: every agent loop works without an editor.

## Godot workflow for agents

- **Edit text directly**: `.gd`, `.tscn`, `.tres`, `project.godot`, `.gdextension`.
- **The skill carries the rules**:
  - Hand-written scenes stay minimal (no default values).
  - New `ext_resource` entries use paths; Godot fills in UIDs on the next import or save.
  - Never edit `.godot/` or `.import` files.
  - Generated scenes, if any, are marked and rebuilt by a `unified` command, as the current game's level builder does.
- **Validate:**
  - `unified godot check` runs a headless import, then runs the project for N frames with `--quit-after` and
    `--log-file`, and parses `SCRIPT ERROR`/`ERROR` lines into JSON.
  - `--check-only -s` parses single scripts.
- **API truth:** `unified godot api` dumps `--doctool` (plus `--gdextension-docs` for our classes) into
  `.unified/godot-docs/` once per Godot version. `unified godot docs Node3D.look_at` prints one entry. This removes
  the main failure mode, Godot 3 or stale 4.x APIs in training data, more cheaply than any skill pack.
- **Look:** `unified run game` then `unified shot`. Note that `--headless` uses a dummy renderer, so it can't take
  pixel screenshots; captures need a real renderer (a window or `--write-movie`).
- **Code intelligence:** Claude Code's official LSP plugins cover neither Odin nor GDScript. A project plugin with a
  `.lsp.json` can register `ols` (Odin) and a stdio-to-TCP bridge to the editor's GDScript LSP. Community
  `gdscript-lsp` plugins already exist (*unverified quality*). OLS is the higher-value one: diagnostics after every
  Odin edit.
- **Is a "run code in the live editor" runner worth building?** Mostly no. Unity needed one because scenes and
  assets are binary or GUID-heavy YAML and the importer state lives only in the Editor. In Godot the files *are* the
  source, the importer runs headless, and runtime state belongs to our control server. The thin bridge above covers
  the rest.

## Skills: what, where, who manages them

**Write our own, few and narrow.** Candidates:

| Skill | Contents | Trigger |
|---|---|---|
| `unified-cli` | The loop, budgets and concurrency rules; links to the generated command reference; ``!`unified status --json` `` | Building, testing, running |
| `godot` | 4.7 project rules: text-edit rules, import and reload, `godot docs`, bridge verbs, gotchas | `paths: godot/**, **/*.tscn, **/*.gd` |
| `feedback` | F3 procedure (port of the current game's cheapest-first procedure) | "check in-game feedback" |
| `desync` | Debugging a checksum mismatch or replay divergence: per-system hashes, diff, shrink | On failure |
| `module-spec` | Writing a spec for sign-off (format, length) | New or changed module |

AGENTS.md keeps the always-true rules and the short command list; procedures move into skills. Third-party Godot
packs: none by default, under the minimal-dependency rule. Reading GodotPrompter for ideas is cheap.

**Where.** `.claude/skills/` in this repo. Skills are versioned with the code, reach every worktree for free, reload
live, and need no install. If the developer also uses Codex, the same folders can be symlinked as `.agents/skills`.
Keep frontmatter to the standard keys plus Claude extras only where needed.

**Plugin or CLI-managed install? Not yet; it matters once game repos exist.** Options for a game repo that uses
`unified` as a library:

| Option | Pros | Cons |
|---|---|---|
| A. Plugin in the `unified` repo (`.claude-plugin/marketplace.json` + `agent/` plugin); game repos declare it in `.claude/settings.json` | Standard; namespaced `/unified:*`; `bin/` could expose a shim on PATH; works for teammates | Version follows the marketplace, not the library version the game pins; a project-enabled external plugin isn't auto-fetched; a third-party marketplace doesn't auto-update by default |
| B. Skills-dir plugin: the game repo vendors `unified` (submodule) and commits `.claude/skills/unified → ../../unified/agent` | Version-locked to the vendored library; no marketplace; namespaced | Symlinks on Windows need `core.symlinks`; the trust dialog applies; the symlinked skills-dir form is *unverified* for project scope (Unity documents it for `~/.claude/skills`) |
| C. `unified agents sync` copies the matching skills into `.claude/skills/unified-*` (and `.agents/skills`), with a stamp that `unified doctor` checks | Version-locked; agent-neutral; works offline | We maintain an installer; copies drift if edited; reinvents part of plugin management |

Leaning: **B** if a spike shows it loads, otherwise **C**. Version lock with the library matters more than marketplace
updates for a project with one developer. **A** is for publishing `unified` to other people.

## Questions for the developer

1. **CLI language:** Odin with a rebuild shim (recommended), or keep Python for orchestration?
2. **Name:** `unified` only, or also a short `uni` alias (08 used `uni`)?
3. **Control transport:** Unix sockets (needs our own `AF_UNIX` code; the stdlib lacks it), or loopback TCP with a
   token everywhere (simpler, one code path)?
4. **Editor bridge:** build it now (GDScript or Odin), or start with text plus headless import and add it when the
   reload dialog bites?
5. **Eval escape hatch** (`Expression`, dev builds only): yes or no?
6. **Agents:** Claude Code only, or also Codex (adds `.agents/skills` symlinks)?
7. **Skills list:** are the five above right? Anything from the current game's agent docs to carry over?
8. **Game-repo distribution** (A/B/C): decide now or at the first game repo?
9. **LSP:** add an `ols` (and GDScript) `.lsp.json` plugin to the project?
10. **MCP adapter** (`unified mcp`): never, or later for clients without a shell?

## Sources

Claude Code: [skills](https://code.claude.com/docs/en/skills), [plugins](https://code.claude.com/docs/en/plugins),
[manifest](https://code.claude.com/docs/en/plugins/manifest-reference.md),
[loading/versions](https://code.claude.com/docs/en/plugins/loading.md),
[memory/AGENTS.md](https://code.claude.com/docs/en/memory),
[code intelligence](https://code.claude.com/docs/en/plugins/code-intelligence.md). Standards:
[agentskills.io spec](https://agentskills.io/specification.md), [agents.md](https://agents.md/),
[Codex skills](https://learn.chatgpt.com/docs/build-skills). Godot:
[CLI](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html),
[TSCN](https://docs.godotengine.org/en/stable/engine_details/file_formats/tscn.html),
[EngineDebugger](https://docs.godotengine.org/en/stable/classes/class_enginedebugger.html),
[Expression](https://docs.godotengine.org/en/stable/classes/class_expression.html). Prior art: linked inline.
Unity: `unity-agent-plugin` 0.1.2-beta (`unity-cli/SKILL.md`, `references/integration-advanced.md`), read from the
local plugin cache.
