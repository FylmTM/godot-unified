---
name: board-work
description: How work moves on the unified board (GitHub Project 2) - taking an issue, the in-progress comment, branches and PRs, when an agent may merge, filing new findings as Backlog issues, and what cloud sessions do instead. Use when starting work on an issue, opening, updating or merging a PR, moving a card, or filing an issue.
---

# Working on the board

The board is the GitHub Project [unified](https://github.com/users/FylmTM/projects/2): one issue per reviewable piece
of work. It tracks issues only; PRs link to them. Operate it with `python tools/dev.py board list|set` (statuses and
areas by name) and `gh issue` / `gh pr`.

## Statuses

| Status | Meaning | Who moves it here |
|---|---|---|
| Backlog | Anything, unsorted | anyone |
| Design | Needs a decision or spec first: ends in a spec PR or a decision written in the issue | developer |
| Todo | Ready; the top of the column goes first | developer |
| In progress | A session owns it; the issue names the session and branch in a comment | the agent taking it |
| Review | A PR is open and waits for the developer | the agent |
| Merged, to review | An agent merged it (rules below); the developer reviews after the fact | the agent |
| Done | Merged and seen by the developer; the developer closes the issue | developer |

Agents take work only from Todo, or what the developer hands them directly. Never start Backlog or Design items on
your own; an item in another column may get a comment with questions or findings.

## Taking an issue

1. Read the issue and all its comments; follow its links (spec, parent issue, review notes).
2. Move it to In progress and comment which session works on it and on which branch.
3. Branch from `main` (`claude/<short-name>`). Every change is a PR from its own branch.

## The PR

- Link it with `Part of #N`, never `Closes`: the developer closes issues. A direct request with no issue:
  `Part of: no issue (requested in chat)`. One PR may cover several issues (`Part of #a, #b`, one commit per issue).
- Fill in `.github/pull_request_template.md`. "Decisions made without sign-off" lists every choice the developer
  hasn't seen, with the alternative considered.
- Commit messages end with the co-author line.
- Push your branch and open the PR without asking, then move the issue to Review.

## Merging

Only merging into `main` is gated. An agent may merge its own PR, after `python tools/dev.py all` passes and CI is
green, only when:

- the change is trivial (typo, formatting, test-only, a doc that only fixes facts), or
- the issue carries the `agent-may-merge` label.

It then moves the issue to "Merged, to review". Everything else waits in Review.

## New findings

Bugs, follow-ups and ideas outside the current request become new Backlog issues (`.github/ISSUE_TEMPLATE/work.md`:
what and why, done when), not notes in docs or reports. A finding that is part of the current request gets fixed,
not filed. Work the developer asks for in chat is done in that session, not filed first.

## Cloud sessions

The cloud GitHub proxy blocks GraphQL, so `gh issue`, `gh pr`, `gh project` and `dev.py board` fail there
(`docs/CLOUD.md`). Instead: push the branch, open the PR with the session's own GitHub tools, and comment on the
issue over REST:

```
gh api repos/FylmTM/unified/issues/<n>/comments -f body='...'
```

Leave the card to the developer.
