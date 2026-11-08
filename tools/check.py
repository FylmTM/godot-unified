#!/usr/bin/env python3
"""The end-to-end tests T1-T9 of spec/CORE.md §4, run against the CLI binary.

    python tools/dev.py check [options]       # builds first (release), then runs this
    python tools/check.py [--mode release|dev|debug] [--only T1,T3] [--regen [--force]]
                          [--jobs N] [--timeout-scale X]

Drives out/<mode>/unified[.exe] through the CLI of spec/CORE.md §3 (it does not build it). Prints
one PASS/FAIL line per test with its wall time, writes out/check.json (summary) and out/check/
(each command's line, stdout/stderr, traces, logs, T9/bench.json), and exits 0 only if every
selected test passed. Exit codes: 0 all passed, 1 a test failed, 2 usage error or no binary.

Reference data for T7/T8 (testdata/, see testdata/README.md) is regenerated with --regen, only on
macOS ARM64 unless --force:
    unified sim      --ticks 3600 --players 4 --seed 7 --trace ref.trace --log ref.log
    unified snapshot --ticks 1800 --players 4 --seed 7 --out ref-1800.snap
then self-checked (replay of ref.log == ref.trace; resume of ref-1800.snap == ticks 1801-3600 of
ref.trace) before the files replace the committed ones.

Conventions (spec/CORE.md §3): ticks are numbered from 1 (the state after the k-th step is tick k;
`--ticks N` ends at tick N), every trace line is "%06d %016x" for ticks 1..N in order, and every
mode prints one JSON object as its last stdout line.
"""

import argparse
import concurrent.futures
import datetime
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

import common
from common import REPO, EXE, log

TEST_SEED = 42
REF_SEED = 7
REF_PLAYERS = 4
REF_TICKS = 3600
REF_SNAP_TICK = 1800
BENCH_TICKS = 600
BENCH_TARGET_US = 6000.0
ALL_TESTS = ["T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8", "T9"]
TRACE_RE = re.compile(r"^(\d{6,}) ([0-9a-f]{16})$")
LOG_HEADER = struct.Struct("<4sHQBI")  # magic, version, seed, players, ticks
LOG_TICK_BYTES = 4 * 4 + 1


class Fail(Exception):
    pass


# --- process helpers ------------------------------------------------------------------------------

class Ctx:
    def __init__(self, mode, outdir, scale, jobs):
        self.mode, self.out, self.scale, self.jobs = mode, outdir, scale, jobs
        self.binary = binary_path(mode)
        self.testdata = REPO / "testdata"
        self.cache = {}  # results shared between tests (T3 -> T4)

    def path(self, *parts):
        p = self.out.joinpath(*parts)
        p.parent.mkdir(parents=True, exist_ok=True)
        return p

    def rel(self, p):
        try:
            return Path(p).resolve().relative_to(REPO).as_posix()
        except ValueError:
            return str(p)


def parse_json_line(text, what):
    for line in reversed(text.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            raise Fail("%s: last stdout line is not JSON: %r" % (what, line[:200]))
        if not isinstance(obj, dict):
            raise Fail("%s: final JSON line is not an object" % what)
        return obj
    raise Fail("%s: no JSON line on stdout" % what)


def start(ctx, name, args):
    """Start the binary with stdout/stderr redirected to files under out/check/."""
    out = open(ctx.path(name + ".stdout"), "w")
    err = open(ctx.path(name + ".stderr"), "w")
    cmd = [str(ctx.binary)] + [str(a) for a in args]
    ctx.path(name + ".cmd").write_text(" ".join(cmd) + "\n")
    kw = {}
    if common.IS_WINDOWS:
        kw["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    p = subprocess.Popen(cmd, stdout=out, stderr=err, stdin=subprocess.DEVNULL, cwd=str(ctx.out), **kw)
    p._files = (out, err)  # noqa: SLF001
    p._name = name  # noqa: SLF001
    p._t0 = time.time()  # noqa: SLF001
    return p


def finish(ctx, p, timeout):
    """Wait for p (killing it after timeout seconds); return the parsed final JSON object."""
    try:
        p.wait(timeout=max(1.0, timeout - (time.time() - p._t0)))
        timed_out = False
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        timed_out = True
    for f in p._files:
        f.close()
    name = p._name
    stdout = ctx.path(name + ".stdout").read_text(errors="replace")
    if timed_out:
        raise Fail("%s: timed out after %.0fs (killed)" % (name, timeout))
    if p.returncode != 0:
        tail = ctx.path(name + ".stderr").read_text(errors="replace").strip().splitlines()[-5:]
        raise Fail("%s: exit code %d%s" % (name, p.returncode, (": " + " | ".join(tail)) if tail else ""))
    return parse_json_line(stdout, name)


def run(ctx, name, args, timeout):
    return finish(ctx, start(ctx, name, args), timeout * ctx.scale)


def read_trace(path, expect_ticks=None, first=1):
    if not Path(path).exists():
        raise Fail("trace %s was not written" % path)
    lines = [l.rstrip("\r\n") for l in Path(path).read_text().splitlines() if l.strip()]
    ticks = []
    for i, l in enumerate(lines):
        m = TRACE_RE.match(l)
        if not m:
            raise Fail("%s:%d: malformed trace line %r (want \"%%06d %%016x\")" % (path, i + 1, l[:60]))
        ticks.append(int(m.group(1)))
    if expect_ticks is not None:
        want = list(range(first, first + expect_ticks))
        if ticks != want:
            got = "%d lines, ticks %s..%s" % (len(ticks), ticks[0] if ticks else "-", ticks[-1] if ticks else "-")
            raise Fail("%s: expected ticks %d..%d in order, got %s" % (path, want[0], want[-1], got))
    return lines


def trace_map(lines):
    return {int(l.split()[0]): l.split()[1] for l in lines}


def first_diff(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return "line %d: %s vs %s" % (i + 1, x, y)
    return "lengths %d vs %d" % (len(a), len(b))


def read_log_header(path):
    data = Path(path).read_bytes()
    if len(data) < LOG_HEADER.size:
        raise Fail("%s: shorter than the input-log header" % path)
    magic, version, seed, players, ticks = LOG_HEADER.unpack_from(data)
    if magic != b"UNIL":
        raise Fail("%s: bad magic %r (want b'UNIL')" % (path, magic))
    info = {"version": version, "seed": seed, "players": players, "ticks": ticks, "bytes": len(data)}
    want = LOG_HEADER.size + ticks * LOG_TICK_BYTES
    info["size_ok"] = len(data) == want
    if not info["size_ok"]:
        log("  note: %s is %d bytes; header + %d x 17 bytes = %d" % (path, len(data), ticks, want))
    return info


def checksums_of(client, what):
    """A client's verified checksums as {tick: hex}. Accepts [[tick, hex], ...] or {"tick": hex}."""
    cs = client.get("checksums")
    if cs is None:
        raise Fail("%s: client has no 'checksums'" % what)
    items = cs.items() if isinstance(cs, dict) else cs
    out = {}
    for t, h in items:
        out[int(t)] = str(h).lower()
    return out


def need(obj, key, what):
    if key not in obj:
        raise Fail("%s: JSON lacks '%s'" % (what, key))
    return obj[key]


def session_timeout(ticks):
    return ticks / 60.0 * 4 + 90


def free_udp_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


# --- checks shared by T3/T5/T6 --------------------------------------------------------------------

def check_clients(clients, ticks, what, expect_players, joiner=None, join_tick=None, need_rollbacks=False):
    """All clients reached `ticks`, their checksums agree, coverage is every 16th tick.
    Returns (by_player, reference {tick: hex})."""
    if len(clients) != len(expect_players):
        raise Fail("%s: %d clients in JSON, expected %d" % (what, len(clients), len(expect_players)))
    by_player = {}
    for c in clients:
        p = int(need(c, "player", what))
        by_player[p] = c
    if sorted(by_player) != sorted(expect_players):
        raise Fail("%s: players %s, expected %s" % (what, sorted(by_player), sorted(expect_players)))
    full = set(range(16, ticks + 1, 16))
    ref = None
    for p in sorted(by_player):
        c = by_player[p]
        ft = int(need(c, "final_tick", what))
        if ft != ticks:
            raise Fail("%s: player %d final_tick %d, expected %d" % (what, p, ft, ticks))
        cs = checksums_of(c, "%s player %d" % (what, p))
        if p == joiner:
            continue
        if set(cs) != full:
            missing = sorted(full - set(cs))[:5]
            raise Fail("%s: player %d checksums don't cover every 16th tick (missing e.g. %s)" % (what, p, missing))
        if ref is None:
            ref = cs
        elif cs != ref:
            t = min(t for t in full if cs[t] != ref[t])
            raise Fail("%s: player %d checksum differs at tick %d: %s vs %s" % (what, p, t, cs[t], ref[t]))
        if need_rollbacks and int(c.get("rollbacks", 0)) <= 0:
            raise Fail("%s: player %d reports no rollbacks" % (what, p))
    if joiner is not None:
        cs = checksums_of(by_player[joiner], "%s joiner" % what)
        if not cs:
            raise Fail("%s: joiner %d reported no verified checksums" % (what, joiner))
        first = min(cs)
        if first < join_tick:
            raise Fail("%s: joiner's first checksum is tick %d, before its join tick %d" % (what, first, join_tick))
        want = set(t for t in full if t >= first)
        if set(cs) != want:
            raise Fail("%s: joiner checksums not contiguous from tick %d to %d" % (what, first, ticks))
        for t in sorted(cs):
            if cs[t] != ref[t]:
                raise Fail("%s: joiner checksum differs at tick %d: %s vs %s" % (what, t, cs[t], ref[t]))
    return by_player, ref


def total_desyncs(obj, clients):
    return int(obj.get("desyncs", 0)) + sum(int(c.get("desyncs", 0)) for c in clients)


def client_stats(clients):
    return {str(c["player"]): {k: c.get(k) for k in
                               ("rollbacks", "rollback_depth_avg", "rollback_depth_max", "stall_ticks", "final_tick")}
            for c in clients}


# --- tests ----------------------------------------------------------------------------------------

def t1(ctx):
    j = run(ctx, "T1/synctest", ["synctest", "--ticks", 3600, "--window", 8, "--players", 4, "--seed", TEST_SEED], 900)
    mm = int(need(j, "mismatches", "synctest"))
    if mm != 0:
        raise Fail("%d mismatches" % mm)
    return "synctest 3600 ticks, window 8, 4 players: 0 mismatches", {"mismatches": mm}


def t2(ctx):
    traces = []
    for i in (1, 2):
        tr = ctx.path("T2", "sim%d.trace" % i)
        run(ctx, "T2/sim%d" % i, ["sim", "--ticks", 3600, "--players", 4, "--seed", TEST_SEED, "--trace", tr], 300)
        traces.append(read_trace(tr, 3600))
    if traces[0] != traces[1]:
        raise Fail("traces differ at " + first_diff(traces[0], traces[1]))
    return "two sim runs, 3600 ticks: identical traces (final %s)" % traces[0][-1].split()[1], {}


def session(ctx, name, clients, profile, ticks, extra=()):
    logf = ctx.path(name + ".log")
    j = run(ctx, name, ["session", "--clients", clients, "--transport", "loopback", "--profile", profile,
                        "--ticks", ticks, "--seed", TEST_SEED, "--log", logf] + list(extra),
            session_timeout(ticks))
    return j, logf


def t3_one(ctx, clients, profile):
    name = "T3/session-%dc-%s" % (clients, profile)
    j, logf = session(ctx, name, clients, profile, 3600)
    cl = need(j, "clients", name)
    check_clients(cl, 3600, name, list(range(clients)), need_rollbacks=profile in ("wan", "bad"))
    d = total_desyncs(j, cl)
    if d:
        raise Fail("%s: %d desyncs" % (name, d))
    return {"json": j, "log": logf, "stats": client_stats(cl)}


def t3(ctx):
    combos = [(c, p) for c in (2, 4) for p in ("ideal", "wan", "bad")]
    results, errors = {}, []
    with concurrent.futures.ThreadPoolExecutor(max_workers=ctx.jobs) as ex:
        futs = {ex.submit(t3_one, ctx, c, p): (c, p) for c, p in combos}
        for f in concurrent.futures.as_completed(futs):
            c, p = futs[f]
            try:
                results["%dc-%s" % (c, p)] = f.result()
            except Fail as e:
                errors.append(str(e))
    for k, r in results.items():
        ctx.cache["session-" + k] = r
    if errors:
        raise Fail("; ".join(sorted(errors)))
    rb = {k: sum(int(s["rollbacks"] or 0) for s in r["stats"].values()) for k, r in results.items()}
    return ("6 sessions (2/4 clients x ideal/wan/bad), 3600 ticks: 0 desyncs, checksums agree; rollbacks %s"
            % ", ".join("%s=%d" % (k, rb[k]) for k in sorted(rb)),
            {k: r["stats"] for k, r in sorted(results.items())})


def t4(ctx):
    r = ctx.cache.get("session-4c-bad")
    if r is None:
        log("  (T3 not run: running the 4-client 'bad' session for T4)")
        r = t3_one(ctx, 4, "bad")
    hdr = read_log_header(r["log"])
    tr = ctx.path("T4", "replay.trace")
    run(ctx, "T4/replay", ["replay", "--log", r["log"], "--trace", tr], 300)
    lines = read_trace(tr, hdr["ticks"])
    tm = trace_map(lines)
    cs = checksums_of(r["json"]["clients"][0], "T4 session")
    for t in sorted(cs):
        if tm.get(t) != cs[t]:
            raise Fail("replay trace tick %d is %s, session verified %s" % (t, tm.get(t), cs[t]))
    return "replay of the 4-client bad session log (%d ticks) matches %d verified checksums" % (
        hdr["ticks"], len(cs)), {"log": hdr}


def t5(ctx):
    ticks, n = 1800, 3
    port = free_udp_port()
    logf = ctx.path("T5", "relay.log")
    tmo = session_timeout(ticks) * ctx.scale
    relay = start(ctx, "T5/relay", ["relay", "--port", port, "--players", n, "--ticks", ticks, "--log", logf])
    time.sleep(0.5)
    procs = []
    for i in range(n):
        args = ["client", "--connect", "127.0.0.1:%d" % port, "--player", i, "--ticks", ticks]
        if i == n - 1:
            args += ["--profile", "bad"]
        procs.append(start(ctx, "T5/client%d" % i, args))
    errors, clients, rj = [], [], None
    for p in procs:
        try:
            clients.append(finish(ctx, p, tmo))
        except Fail as e:
            errors.append(str(e))
    try:
        rj = finish(ctx, relay, tmo if not errors else 10)
    except Fail as e:
        errors.append(str(e))
    if errors:
        raise Fail("; ".join(errors))
    for i, c in enumerate(clients):
        c.setdefault("player", i)
    check_clients(clients, ticks, "T5", list(range(n)))
    d = total_desyncs(rj, clients)
    if d:
        raise Fail("%d desyncs" % d)
    return "UDP relay + 3 client processes (one 'bad'), %d ticks, port %d: 0 desyncs" % (ticks, port), {
        "clients": client_stats(clients), "relay": rj}


def t6(ctx):
    name = "T6/session-latejoin"
    j, _ = session(ctx, name, 4, "wan", 3600, ["--late-join", "3@1200"])
    cl = need(j, "clients", name)
    by, _ = check_clients(cl, 3600, name, [0, 1, 2, 3], joiner=3, join_tick=1200)
    d = total_desyncs(j, cl)
    if d:
        raise Fail("%d desyncs" % d)
    first = min(checksums_of(by[3], name))
    return "late join 3@1200 under wan: 0 desyncs; joiner matches from tick %d" % first, {
        "joiner_first_checksum_tick": first, "clients": client_stats(cl)}


def ref_paths(base):
    return base / "ref.log", base / "ref.trace", base / ("ref-%d.snap" % REF_SNAP_TICK)


def t7(ctx):
    logf, trf, _ = ref_paths(ctx.testdata)
    if not logf.exists() or not trf.exists():
        raise Fail("no reference in %s: generate it on macOS ARM64 with `python tools/dev.py check --regen`"
                   % ctx.rel(ctx.testdata))
    hdr = read_log_header(logf)
    ref = read_trace(trf, REF_TICKS)
    tr = ctx.path("T7", "replay.trace")
    run(ctx, "T7/replay", ["replay", "--log", logf, "--trace", tr], 300)
    got = read_trace(tr, hdr["ticks"])
    if got != ref:
        raise Fail("replay of ref.log differs from ref.trace at " + first_diff(got, ref))
    return "replay of testdata/ref.log == ref.trace (%d ticks, final %s)" % (len(ref), ref[-1].split()[1]), {}


def t8(ctx):
    _, trf, snap = ref_paths(ctx.testdata)
    if not snap.exists() or not trf.exists():
        raise Fail("no reference in %s: generate it on macOS ARM64 with `python tools/dev.py check --regen`"
                   % ctx.rel(ctx.testdata))
    ref = read_trace(trf, REF_TICKS)[REF_SNAP_TICK:]
    tr = ctx.path("T8", "resume.trace")
    run(ctx, "T8/resume", ["resume", "--in", snap, "--ticks", REF_TICKS - REF_SNAP_TICK, "--trace", tr], 300)
    got = read_trace(tr, REF_TICKS - REF_SNAP_TICK, first=REF_SNAP_TICK + 1)
    if got != ref:
        raise Fail("resume trace differs from ref.trace at " + first_diff(got, ref))
    return "resume of ref-%d.snap (%d bytes) == ticks %d-%d of ref.trace" % (
        REF_SNAP_TICK, snap.stat().st_size, REF_SNAP_TICK + 1, REF_TICKS), {}


def t9(ctx):
    j = run(ctx, "T9/bench", ["bench", "--enemies", 1000, "--window", 8, "--ticks", BENCH_TICKS], 900)
    ctx.path("T9", "bench.json").write_text(json.dumps(j, indent=2) + "\n")
    data = {"raw": j}
    try:
        step, resim = float(j["step_us"]["mean"]), float(j["resim_us"]["mean"])
        total = step + resim
        data.update({"step_mean_us": step, "step_p99_us": float(j["step_us"]["p99"]),
                     "save_mean_us": float(j["save_us"]["mean"]), "restore_mean_us": float(j["restore_us"]["mean"]),
                     "resim_mean_us": resim, "resim_p99_us": float(j["resim_us"]["p99"]),
                     "step_plus_resim_us": total, "snapshot_bytes": int(j["snapshot_bytes"]),
                     "within_target": total <= BENCH_TARGET_US})
        msg = "step %.0f us + 8-tick re-sim %.0f us = %.2f ms (target <= 6 ms: %s); save %.0f us, restore %.0f us, " \
              "snapshot %d bytes" % (step, resim, total / 1000, "yes" if total <= BENCH_TARGET_US else "NO",
                                     data["save_mean_us"], data["restore_mean_us"], data["snapshot_bytes"])
    except (KeyError, TypeError, ValueError) as e:
        msg = "reported, but the JSON lacks an expected field (%s): see out/check/T9/bench.json" % e
    return msg, data


TESTS = {"T1": t1, "T2": t2, "T3": t3, "T4": t4, "T5": t5, "T6": t6, "T7": t7, "T8": t8, "T9": t9}
# Paced by the 60 Hz relay clock (~60 s, ~30 s, ~60 s of wall time, little CPU): started together up front so they
# overlap each other and T1/T2. T9 (timing-sensitive) runs after all of them have finished.
REALTIME = ["T3", "T5", "T6"]


# --- regen ----------------------------------------------------------------------------------------

def regen(ctx, force):
    tag = common.platform_tag()
    if tag != "macos-arm64" and not force:
        raise SystemExit("check: --regen only runs on macOS ARM64 (this is %s); the references are defined "
                         "as macOS ARM64 output. Pass --force to override." % tag)
    work = ctx.path("regen", "x").parent
    logf, trf, snap = ref_paths(work)
    log("regen: sim %d ticks, %d players, seed %d -> ref.trace + ref.log" % (REF_TICKS, REF_PLAYERS, REF_SEED))
    run(ctx, "regen/sim", ["sim", "--ticks", REF_TICKS, "--players", REF_PLAYERS, "--seed", REF_SEED,
                           "--trace", trf, "--log", logf], 300)
    ref = read_trace(trf, REF_TICKS)
    hdr = read_log_header(logf)
    if hdr["ticks"] != REF_TICKS or hdr["players"] != REF_PLAYERS or hdr["seed"] != REF_SEED:
        raise SystemExit("regen: ref.log header %s does not match the sim run" % hdr)
    log("regen: snapshot at tick %d" % REF_SNAP_TICK)
    run(ctx, "regen/snapshot", ["snapshot", "--ticks", REF_SNAP_TICK, "--players", REF_PLAYERS, "--seed", REF_SEED,
                                "--out", snap], 300)
    log("regen: self-check (replay and resume)")
    tr = ctx.path("regen", "check-replay.trace")
    run(ctx, "regen/replay", ["replay", "--log", logf, "--trace", tr], 300)
    if read_trace(tr, REF_TICKS) != ref:
        raise SystemExit("regen: replay of the new ref.log does not reproduce the sim trace")
    tr = ctx.path("regen", "check-resume.trace")
    run(ctx, "regen/resume", ["resume", "--in", snap, "--ticks", REF_TICKS - REF_SNAP_TICK, "--trace", tr], 300)
    if read_trace(tr, REF_TICKS - REF_SNAP_TICK, first=REF_SNAP_TICK + 1) != ref[REF_SNAP_TICK:]:
        raise SystemExit("regen: resume of the new snapshot does not reproduce ticks %d-%d"
                         % (REF_SNAP_TICK + 1, REF_TICKS))
    ctx.testdata.mkdir(parents=True, exist_ok=True)
    for src in (logf, trf, snap):
        dst = ctx.testdata / src.name
        dst.write_bytes(src.read_bytes())
    meta = {
        "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "platform": tag,
        "build_mode": ctx.mode,
        "git_commit": git_commit(),
        "seed": REF_SEED, "players": REF_PLAYERS, "ticks": REF_TICKS, "snapshot_tick": REF_SNAP_TICK,
        "final_checksum": ref[-1].split()[1],
        "commands": [
            "unified sim --ticks %d --players %d --seed %d --trace ref.trace --log ref.log"
            % (REF_TICKS, REF_PLAYERS, REF_SEED),
            "unified snapshot --ticks %d --players %d --seed %d --out ref-%d.snap"
            % (REF_SNAP_TICK, REF_PLAYERS, REF_SEED, REF_SNAP_TICK),
        ],
    }
    (ctx.testdata / "ref.json").write_text(json.dumps(meta, indent=2) + "\n")
    log("regen: wrote %s/{ref.log, ref.trace, ref-%d.snap, ref.json}" % (ctx.rel(ctx.testdata), REF_SNAP_TICK))


# --- main -----------------------------------------------------------------------------------------

def git_commit():
    r = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(REPO), capture_output=True, text=True)
    return r.stdout.strip() or None


def binary_path(mode):
    return REPO / "out" / mode / ("unified" + EXE)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="check.py", description="Run the spec/CORE.md §4 tests (T1-T9).")
    ap.add_argument("--mode", default="release", choices=["release", "dev", "debug"],
                    help="which build to test: out/<mode>/unified (default release)")
    ap.add_argument("--only", help="comma-separated subset, e.g. T1,T3")
    ap.add_argument("--regen", action="store_true", help="regenerate testdata/ (macOS ARM64 only) first")
    ap.add_argument("--force", action="store_true", help="allow --regen on a platform other than macOS ARM64")
    ap.add_argument("--jobs", type=int, default=6,
                    help="T3 sessions run in parallel (default 6: all at once; they are paced by the 60 Hz "
                         "clock, not by the CPU)")
    ap.add_argument("--serial", action="store_true",
                    help="run the real-time tests T3, T5, T6 one after another instead of overlapped")
    ap.add_argument("--timeout-scale", type=float, default=None,
                    help="multiply every timeout (default 1, 2 for dev, 8 for debug builds)")
    args = ap.parse_args(argv)

    only = ALL_TESTS
    if args.only:
        only = [t.strip().upper() for t in args.only.split(",") if t.strip()]
        bad = [t for t in only if t not in TESTS]
        if bad:
            ap.error("unknown test(s): " + ", ".join(bad))
        only = [t for t in ALL_TESTS if t in only]

    scale = args.timeout_scale or {"release": 1.0, "dev": 2.0, "debug": 8.0}[args.mode]
    outdir = REPO / "out" / "check"
    if outdir.exists():
        import shutil
        shutil.rmtree(outdir)
    outdir.mkdir(parents=True)
    ctx = Ctx(args.mode, outdir, scale, max(1, args.jobs))
    if not ctx.binary.exists():
        log("check: %s not found: build it first (`python tools/dev.py build %s`), or run `python tools/dev.py "
            "check`, which builds" % (ctx.rel(ctx.binary), args.mode))
        return 2
    summary = {
        "platform": common.platform_tag(), "mode": args.mode,
        "git_commit": git_commit(), "python": sys.version.split()[0],
        "started": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ok": False, "tests": {},
    }
    summary_path = REPO / "out" / "check.json"

    def write_summary():
        summary_path.write_text(json.dumps(summary, indent=2) + "\n")

    log("check: %s on %s, outputs in %s" % (ctx.rel(ctx.binary), summary["platform"], ctx.rel(outdir)))
    if args.regen:
        regen(ctx, args.force)

    def timed(name):
        t0 = time.time()
        try:
            detail, data = TESTS[name](ctx)
            status = "pass"
        except Fail as e:
            detail, data, status = str(e), {}, "fail"
        except Exception as e:  # a harness bug must not hide the other tests' results
            detail, data, status = "harness error: %r" % e, {}, "fail"
        return detail, data, status, time.time() - t0

    t_all = time.time()
    early = {}
    pool = None
    if not args.serial:
        overlap = [n for n in REALTIME if n in only]
        if overlap:
            pool = concurrent.futures.ThreadPoolExecutor(max_workers=len(overlap))
            early = {n: pool.submit(timed, n) for n in overlap}
            log("check: %s run concurrently (--serial to disable)" % ", ".join(overlap))
    for name in only:
        if name == "T9" and pool is not None:
            pool.shutdown(wait=True)  # no sessions running while the bench measures
        detail, data, status, secs = early[name].result() if name in early else timed(name)
        summary["tests"][name] = {"status": status, "seconds": round(secs, 2), "detail": detail, "data": data}
        print("%-3s %-4s %6.1fs  %s" % (name, status.upper(), secs, detail), flush=True)
        write_summary()

    failed = [n for n, t in summary["tests"].items() if t["status"] != "pass"]
    summary["ok"] = not failed
    summary["seconds"] = round(time.time() - t_all, 2)
    write_summary()
    print(json.dumps({"platform": summary["platform"], "ok": summary["ok"], "passed": len(only) - len(failed),
                      "failed": failed, "seconds": summary["seconds"], "summary": ctx.rel(summary_path)}), flush=True)
    return 0 if summary["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
