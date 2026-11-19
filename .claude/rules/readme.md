---
paths:
  - "src/**/README.md"
  - "src/**/*.odin"
  - "games/*/README.md"
  - "games/*/simulation/**/*.odin"
---

# Package and game READMEs, doc comments

The code is the spec. What a reader needs lives in two places, each fact once:

- **The README** (`src/<pkg>/README.md`, `games/<game>/README.md`): what it is, why it exists, where it fits (what
  uses it, what it uses), how it works, and the decisions and contracts a reader could get wrong that no single
  declaration shows (a trust model, an ordering rule, what is deliberately left out, why the obvious design isn't
  used). A game's README also says what the game shows and plays, and its rules in order, naming each tuning constant
  (`WALK_SPEED`) rather than its value.
- **Doc comments**: the header comment of each file (`odin doc` and `uni doc` show them as the package's doc) and a
  comment directly above every public proc and type (the lint fails on one without). A fact about one declaration
  (what it returns, when it fails, what it allocates, a rule its caller must keep) lives there, beside the code, so a
  change to the code changes its comment in the same diff.

A README holds no API listing, signatures, field lists, constant values, test lists, command options (`uni help`),
measurements (`uni bench`), byte layouts (the code's headers) or history (issue numbers, dates, what it replaced),
and nothing unbuilt. If a README sentence restates one declaration, it belongs on that declaration instead.

Point a reader at a fact by its home: a README section (`src/physics/README.md`, The boundary) for a cross-cutting
rule, a declaration (`physics.create_static`) for one proc's contract. `uni doc <pkg>` prints a package's API.
