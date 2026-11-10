"""The work board (GitHub Project 2, AGENTS.md "The board"), behind `dev.py board` (stdlib + the gh CLI).

    python tools/dev.py board list [--status S] [--area A]   # issue, status, area, title
    python tools/dev.py board set <issue> [--status S] [--area A]   # adds the issue to the board if needed;
                                                                    # --status done also closes the issue

Status and area are given by name, case-insensitive ("in progress", "merged, to review"); the field and option IDs
are looked up from the project each run, so renaming a column needs no change here.
"""

import json
import subprocess

from common import Strict, log

OWNER, NUMBER, REPO = "FylmTM", "2", "FylmTM/unified"
DONE = "Done"  # the Status column whose issues are closed: `set --status done` closes the issue too


def gh(*args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("board: gh %s failed: %s" % (" ".join(args[:2]), r.stderr.strip() or r.stdout.strip()))
    return r.stdout


def project_id():
    return json.loads(gh("project", "view", NUMBER, "--owner", OWNER, "--format", "json"))["id"]


def fields():
    """{field name: (field id, {option name lowercased: (option id, option name)})} for single-select fields."""
    out = {}
    for f in json.loads(gh("project", "field-list", NUMBER, "--owner", OWNER, "--format", "json"))["fields"]:
        if "options" in f:
            out[f["name"]] = (f["id"], {o["name"].lower(): (o["id"], o["name"]) for o in f["options"]})
    return out


def option(fs, field, value):
    fid, opts = fs[field]
    hit = opts.get(value.lower())
    if hit is None:
        raise SystemExit("board: no %s %r; one of: %s" % (field, value, ", ".join(n for _, n in opts.values())))
    return fid, hit[0]


def issue_number(text):
    t = text.rsplit("/", 1)[-1].lstrip("#")
    if not t.isdigit():
        raise SystemExit("board: %r is not an issue number or URL" % text)
    return int(t)


def cmd_set(issue, status=None, area=None):
    if status is None and area is None:
        raise SystemExit("board: set needs --status and/or --area")
    fs = fields()
    changes = [option(fs, "Status", status) if status else None, option(fs, "Area", area) if area else None]
    n = issue_number(issue)
    url = "https://github.com/%s/issues/%d" % (REPO, n)
    item = json.loads(gh("project", "item-add", NUMBER, "--owner", OWNER, "--url", url, "--format", "json"))["id"]
    pid = project_id()
    for change in changes:
        if change:
            gh("project", "item-edit", "--id", item, "--project-id", pid, "--field-id", change[0],
               "--single-select-option-id", change[1])
    closed = ""
    if changes[0] and fs["Status"][1][status.lower()][1] == DONE:  # Done means closed (AGENTS.md, The board)
        if json.loads(gh("issue", "view", str(n), "--repo", REPO, "--json", "state"))["state"] != "CLOSED":
            gh("issue", "close", str(n), "--repo", REPO, "--reason", "completed")
            closed = ", closed"
    log("board: #%d%s%s%s" % (n, " -> " + status if status else "", " (area " + area + ")" if area else "", closed))


def cmd_list(status=None, area=None):
    items = json.loads(gh("project", "item-list", NUMBER, "--owner", OWNER, "--format", "json", "--limit", "500"))
    order = {name: i for i, (_, name) in enumerate(fields()["Status"][1].values())}
    rows = []
    for it in items["items"]:
        c = it.get("content", {})
        st, ar = it.get("status", ""), it.get("area", "")
        if status and st.lower() != status.lower() or area and ar.lower() != area.lower():
            continue
        rows.append((order.get(st, 99), st, ar, c.get("number", 0), it.get("title", "")))
    for _, st, ar, n, title in sorted(rows, key=lambda r: r[0]):  # stable: board order within a column
        print("#%-4d %-18s %-13s %s" % (n, st, ar, title))


def main(argv):
    ap = Strict(prog="dev.py board")
    sub = ap.add_subparsers(dest="cmd", required=True, parser_class=Strict)
    p = sub.add_parser("list", help="issues on the board, in column order")
    p.add_argument("--status")
    p.add_argument("--area")
    p = sub.add_parser("set", help="set an issue's status and/or area (adds it to the board if needed)")
    p.add_argument("issue", help="issue number, #N or URL")
    p.add_argument("--status")
    p.add_argument("--area")
    a = ap.parse_args(argv)
    if a.cmd == "list":
        cmd_list(a.status, a.area)
    else:
        cmd_set(a.issue, a.status, a.area)
