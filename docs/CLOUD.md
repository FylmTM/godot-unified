# Cloud sessions

Claude Code cloud sessions run on an Ubuntu 24.04 x86_64 VM (4 vCPU, 16 GB, 30 GB disk) cloned from GitHub, and can
be started from the desktop app (environment selector → **Cloud**), claude.ai/code, the phone, or `claude --cloud
"<task>"`. They count against the Claude plan's usage, with no charge for the VM. This is the one-time setup the
developer does, and what sessions can and can't do.

## Setup

1. **GitHub App.** Install the [Claude GitHub App](https://github.com/apps/claude) on `FylmTM/unified` (the repo is
   private). It also enables Auto-fix: a session watches its PR and fixes failing CI or review comments.
2. **Environment.** At claude.ai/code (or the desktop app's environment selector) add an environment named
   `unified`: network access **Trusted** (covers GitHub releases and clones, PyPI, the Ubuntu mirrors), no
   environment variables, and this setup script:
   ```bash
   #!/bin/bash
   # unified: build the toolchains into this environment's cached snapshot (docs/CLOUD.md).
   repo=$(find / -maxdepth 5 \( -path /proc -o -path /sys -o -path /usr \) -prune -o -type f -path '*/tools/ci.py' \
       -print 2>/dev/null | while read -r f; do d=${f%/tools/ci.py}; grep -qs '^# unified' "$d/AGENTS.md" && echo "$d" && break; done)
   if [ -z "$repo" ] && git clone -q --depth 1 https://github.com/FylmTM/unified /tmp/unified-setup; then
       repo=/tmp/unified-setup
   fi
   [ -n "$repo" ] && python3 "$repo/tools/ci.py" cloud-setup
   rm -rf /tmp/unified-setup
   exit 0
   ```

## How it works

`python3 tools/ci.py cloud-setup` links `.toolchains/` and `third_party/{box3d,imgui,eos}/` to
`~/.cache/unified-cloud/` and fills them: Odin (the pinned release), odinfmt (pinned OLS), Godot, Box3D, Dear ImGui
and the EOS SDK. The setup script runs it once; the VM snapshot taken after it keeps the cache, so later sessions
start warm. The SessionStart hook in `.claude/settings.json` runs it again in every cloud session (it does nothing
locally): it relinks the fresh clone, puts Odin on PATH, rebuilds whatever a pin bump made stale, and prints one
line (what's ready, what failed) that Claude sees. The snapshot is rebuilt when the setup script changes and about
weekly.

## What sessions can't do

- **The board.** The cloud GitHub proxy blocks GraphQL, so `gh issue`, `gh pr`, `gh project` and `dev.py board`
  fail. What sessions do instead is in the `board-work` skill; the developer moves the card.
- **macOS and windows.** Nothing windowed (`game run|tour|coop|shots|play`), no EOS online play.
  `fmt`, `vet`, `test`, `check` and `godot-checks` run as on Linux CI.
