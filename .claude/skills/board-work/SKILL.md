---
name: board-work
description: How work moves on the unified board (GitHub Project 2) - taking an issue, the in-progress comment, branches and PRs, Closes vs Part of, when an agent may merge, moving issues to Done (which closes them), and filing new findings as Backlog issues. Use when starting work on an issue, opening, updating or merging a PR, moving a card, or filing an issue.
---

# Working on the board

The board is the GitHub Project [unified](https://github.com/users/FylmTM/projects/2): one issue per reviewable piece
of work. It tracks issues only; PRs link to them. Operate it with `python tools/dev.py board list|set` (statuses and
areas by name) and `gh issue` / `gh pr`.

Issues are the developer's memory of what to do, not instructions to agents: how a piece of work is handled (merge it
or not, how far to take it) is said in chat. No labels steer agents.

## Statuses

| Status | Meaning | Who moves it here |
|---|---|---|
| Backlog | Anything, unsorted | anyone |
| Design | Needs a decision or spec first: ends in a spec PR or a decision written in the issue | developer |
| Todo | Ready; the top of the column goes first | developer |
| In progress | A session owns it; the issue names the session and branch in a comment | the agent taking it |
| Review | A PR is open and waits for the developer | the agent |
| Merged, to review | An agent merged a trivial change on its own (below); the developer reviews after the fact | the agent |
| Done | Finished; the issue is closed | the developer, or the agent after a merge the developer asked for |

**Done means closed.** `python tools/dev.py board set <n> --status Done` moves the card and closes the issue (as
completed) in one step; never leave a Done issue open or a closed issue in another column.

Agents take work only from Todo, or what the developer hands them directly. Never start Backlog or Design items on
your own; an item in another column may get a comment with questions or findings.

## Taking an issue

1. Read the issue and all its comments; follow its links (spec, parent issue, review notes).
2. Move it to In progress and comment which session works on it and on which branch.
3. Branch from `main` (`claude/<short-name>`). Every change is a PR from its own branch.

## The PR

- **Say what the merge does to each issue.** `Closes #N` for every issue the PR finishes: GitHub closes it when the
  PR merges, so approving the merge is all the developer does. `Part of #N` for an issue the PR only advances; it
  stays open. A direct request with no issue: `Part of: no issue (requested in chat)`. One PR may cover several
  issues (`Closes #a, #b`, one commit per issue). When the scope changes while the PR is open, update the line.
- Fill in `.github/pull_request_template.md`. "Decisions made without sign-off" lists every choice the developer
  hasn't seen, with the alternative considered.
- Commit messages end with the co-author line.
- Push your branch and open the PR without asking, then move its issues to Review.

## Merging

Only merging into `main` is gated. An agent merges a PR only after `python tools/dev.py all` passes and CI is green,
and only when:

- **the developer asks for it in chat.** Then every issue the PR closes goes to Done (`board set <n> --status Done`,
  which also closes it if the merge hasn't). Issues it is only `Part of` stay open, back in the column they belong
  in; say which ones in the report.
- **or the change is trivial** (typo, formatting, test-only, a doc that only fixes facts). Then its issues go to
  "Merged, to review"; the developer moves them to Done after looking.

Everything else waits in Review.

## New findings

Bugs, follow-ups and ideas outside the current request become new Backlog issues (`.github/ISSUE_TEMPLATE/work.md`:
what and why, done when), not notes in docs or reports. A finding that is part of the current request gets fixed,
not filed. Work the developer asks for in chat is done in that session, not filed first.
