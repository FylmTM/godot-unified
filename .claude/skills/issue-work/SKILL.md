---
name: issue-work
description: How work moves through unified's GitHub issues - taking an issue, the in-progress comment, branches and PRs, Closes vs Part of, when an agent may merge, labels, and when a finding is fixed in place or filed. Use when starting work on an issue, opening, updating or merging a PR, or filing an issue.
---

# Working on issues

Planned work is the repo's GitHub issues, one per reviewable piece of work; there is no project board. PRs link to
issues. Operate them with `gh issue` / `gh pr`.

Issues are the developer's memory of what to do, not instructions to agents: which issue an agent starts, and how it
is handled (merge it or not, how far to take it), is said in chat.

## States and labels

- **Open**: work to do, whether its design is still being agreed or it is ready; the developer says which in chat.
- **Worked on**: an agent's comment names its session and branch; once its PR is open, GitHub shows the PR on the
  issue.
- **Closed**: done, normally by the merge of a PR that says `Closes #N`. Use GitHub's own reasons for the rest
  (not planned, duplicate).

Labels say only what kind of work an issue is, never a status: `bug` (something is wrong), `feature` (new behaviour
or capability), `review` (a review sitting: the developer reviews a part of the project with the agent). An issue
may have none.

Agents start an issue only when the developer says so in chat. Never start one on your own; any open issue may get a
comment with questions or findings.

## Taking an issue

1. Read the issue and all its comments; follow its links (parent issue, review notes).
2. Comment which session works on it and on which branch.
3. Branch from `main` (`claude/<short-name>`). Every change is a PR from its own branch.

## The PR

- **Say what the merge does to each issue.** `Closes #N` for every issue the PR finishes: GitHub closes it when the
  PR merges, so approving the merge is all the developer does. `Part of #N` for an issue the PR only advances; it
  stays open. A direct request with no issue: `Part of: no issue (requested in chat)`. One PR may cover several
  issues, one commit per issue: repeat the keyword before every number (`Closes #a, closes #b`), or GitHub closes
  only the first. Check with `gh pr view <n> --json closingIssuesReferences`. When the scope changes while the PR is
  open, update the line.
- Fill in `.github/pull_request_template.md`. "Decisions made without sign-off" lists every choice the developer
  hasn't seen, with the alternative considered.
- Commit messages end with the co-author line.
- Push your branch and open the PR without asking.

## Merging

Only merging into `main` is gated. An agent merges a PR only after `./uni verify` passes and CI is green
(macOS aside: it never blocks a merge; `main`'s run after the merge covers it, per AGENTS.md), and only when:

- **the developer asks for it in chat;**
- **or the change is trivial** (typo, formatting, test-only, a doc that only fixes facts); the report names the PR so
  the developer can look after the fact.

After a merge, check that every issue the PR closes is closed (`gh issue view <n>`). Issues it is only `Part of`
stay open; say which ones in the report. Everything else waits for the developer.

## Findings

Fix in place, in the current PR, whatever belongs to the current stream of work: a bug next to the change, a stale
doc or comment, a small cleanup or fix, a leftover the review turned up. Work the developer asks for in chat is done
in that session, not filed first.

File an issue (`.github/ISSUE_TEMPLATE/work.md`: what and why, done when; labelled `bug` or `feature`) only for:

- a new feature;
- a fix or improvement big or risky enough to need its own PR and review (a design question, a protocol or sim
  change nobody asked for, work across several modules).

Feedback for later from one stream of work (a review, a sitting, a batch) goes into as few issues as possible, each
still on one topic: one issue with a checklist, not one issue per item. Before filing, look for an open issue it
belongs to and add a comment there instead. Never notes in docs or reports.
