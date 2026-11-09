#!/usr/bin/env python3
"""Build, test, format and vet unified: the one entry point (Python 3.9+, stdlib only, any OS).

    python tools/dev.py build [dev|release|debug]   # headless binaries -> out/<mode>/{survivor,friendslop,toy}[.exe]
    python tools/dev.py test                    # odin test: unit tests, every end-to-end suite, determinism lint
    python tools/dev.py check                   # release build, then the real-UDP multi-process test (toy) and
                                                # the survivor's rollback bench
    python tools/dev.py regen <game>|toy        # regenerate a reference run (simulation/tests/testdata/)
    python tools/dev.py fmt [--check]           # odinfmt over src/, tests/ and the games' Odin code
    python tools/dev.py vet                     # odin check with the strict flags, every target
    python tools/dev.py gen [--force]           # Godot bindings: src/gdext/*.gen.odin (cached by input hash)
    python tools/dev.py godot-test              # binding tests: tests/godot under headless Godot
    python tools/dev.py godot-checks            # godot-test, then per game: headless, session-check, editor-check,
                                                # validate, walk (CI's godot job runs exactly this)
    python tools/dev.py all                     # fmt --check, vet, test, check, godot-checks (everything CI runs)
    python tools/dev.py game build <game> [dev|release]  # games/<game>/.out/bin/lib<game>.*
    python tools/dev.py game run <game> [-- args]       # windowed game (args after -- go to the game)
    python tools/dev.py game editor <game>              # the Godot editor on the game
    python tools/dev.py game headless <game> [--ticks N] [--seed S] [--release] [--no-build]
                                                        # headless session, sim hash vs the offline binary
    python tools/dev.py game editor-check <game>        # headless editor: extension loads, no ERROR lines
    python tools/dev.py game session-check <game>       # headless: leave then host/join at once (~3 s)
    python tools/dev.py game play <game> [--minutes M] [--bench N] [--coop] [--release] [--no-build]
                                                        # windowed bot play check
    python tools/dev.py game validate|walk|shots|tour|coop|import <game> ...   # Godot project checks (tools/game.py)
    python tools/dev.py board list [--status S] [--area A]          # the work board (tools/board.py, AGENTS.md)
    python tools/dev.py board set <issue> [--status S] [--area A]   # move or file an issue on the board

<game> is a name under games/ or a project path. Every command rejects arguments it doesn't know; `-h` on any
command prints its options.

Build modes (all with -vet -strict-style -vet-tabs -warnings-as-errors, bounds checks on):
  dev      -o:speed -use-separate-modules -debug   the everyday build: optimized, ~1 s to build
  release  -o:speed                                one LLVM module: the fastest binary, ~2.5 s
  debug    -o:none -debug                          unoptimized, for stepping in a debugger

Box3D comes from tools/box3d.py (built on first use, then a ~10 ms check). The bindings import the
static library by relative path, so plain `odin build games/survivor/simulation/headless
-collection:unified=src` / `odin test tests -all-packages -collection:unified=src` work too once it
is built (add -out: or the binary lands in the current folder); this script adds the flags and timings.
`build` builds every headless binary (the CLI modes of src/headless/SPEC.md come from unified:headless):
each game's and the toy game's (tests/toy/headless).

End-to-end (src/headless/SPEC.md, End-to-end suites): each game's suite and the toy's run in `test`. `check`
keeps the real-UDP, real-clock test: a relay and 3 client processes of the toy's binary (one under `bad`),
960 ticks (~15 s); then, until the benchmarks take it over, the survivor's `bench --enemies 1000 --window 8`
(reported, not gated). Results go to out/check.json (CI's job summary) and process output to out/check/.
`regen` runs a suite with -define:UNIFIED_REGEN=true: its reference test writes a new reference run (ref.log,
ref.trace, the snapshot, ref.json saying where it was made), checks it, and the files show up in `git status`.
"""

import argparse
import concurrent.futures
import datetime
import filecmp
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import box3d
import common
import imgui
from common import REPO, EXE, log, redact

VET = ["-vet", "-strict-style", "-vet-tabs", "-warnings-as-errors"]
COLLECTION = "-collection:unified=" + (REPO / "src").as_posix()
MODES = {
    "dev": ["-o:speed", "-use-separate-modules", "-debug"],
    "release": ["-o:speed"],
    "debug": ["-o:none", "-debug"],
}
# Tests build like dev: optimized enough that the sim tests take milliseconds, fast to compile.
TEST_FLAGS = ["-o:speed", "-use-separate-modules", "-debug"]
VET_TARGETS = ["darwin_arm64", "darwin_amd64", "linux_amd64", "linux_arm64", "windows_amd64"]
FMT_DIRS = ["src", "tests"] + sorted(p.relative_to(REPO).as_posix() for p in (REPO / "games").glob("*/simulation"))
# The headless binaries `build` makes (out/<mode>/<name>): each game's and the toy game's.
HEADLESS = {"survivor": "games/survivor/simulation/headless", "friendslop": "games/friendslop/simulation/headless",
            "toy": "tests/toy/headless"}
# Packages vet type-checks (with everything they import): the headless binaries, the tests, the binding test
# extension and the games' extensions.
VET_PACKAGES = list(HEADLESS.values()) + ["tests", "tests/godot/ext", "games/survivor/simulation/extension",
                                          "games/friendslop/simulation/extension"]
ODINFMT_HELP = """odinfmt not found. It ships with OLS; install the pinned build (the commit CI uses, see
OLS_COMMIT in tools/ci.py) with:
    python tools/ci.py odinfmt ~/.local/share/unified-odinfmt
and put that directory on PATH, or point ODINFMT at the binary (VS Code's OLS extension keeps one
in its globalStorage folder, danielgavin.ols/<id>/odinfmt-<arch>-<os>; it may need chmod +x)."""


def odin():
    exe = shutil.which("odin")
    if not exe:
        raise SystemExit("dev: odin not found on PATH (see README.md, Getting started)")
    return exe


def run_odin(args, what):
    cmd = [odin()] + args
    log("+ " + " ".join(redact(cmd)))
    t0 = time.time()
    r = subprocess.run(cmd, cwd=str(REPO))
    secs = time.time() - t0
    if r.returncode != 0:
        raise SystemExit("dev: %s failed (exit %d)" % (what, r.returncode))
    return secs


def cmd_build(mode="dev"):
    """Builds every headless binary into out/<mode>/, side by side; returns that directory."""
    box3d.ensure()
    out = REPO / "out" / mode
    out.mkdir(parents=True, exist_ok=True)
    jobs = [(pkg, out / (name + EXE)) for name, pkg in HEADLESS.items()]
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(jobs)) as ex:
        secs = max(ex.map(lambda j: run_odin(["build", j[0], COLLECTION, "-out:" + j[1].as_posix()] + MODES[mode] + VET,
                                             "odin build " + j[0]), jobs))
    log("dev: build %s -> %s in %.2fs" % (mode, ", ".join(j[1].relative_to(REPO).as_posix() for j in jobs), secs))
    return out


GDEXT = REPO / "src" / "gdext"
GEN_OUTPUTS = [GDEXT / "api.gen.odin", GDEXT / "gdi" / "gdi.gen.odin"]


def cmd_gen(force=False):
    """Generates the Godot bindings from the committed API dump (no Godot needed). Skipped when the inputs
    (api/*.json, bindings.txt, the generator's source) hash the same as last time and the outputs exist."""
    import hashlib
    inputs = sorted((GDEXT / "api").glob("*.json")) + [GDEXT / "bindings.txt"] + sorted((GDEXT / "gen").glob("*.odin"))
    h = hashlib.sha1()
    for p in inputs:
        h.update(p.name.encode())
        h.update(p.read_bytes())
    key = h.hexdigest()
    out = REPO / "out" / "gen"
    stamp = out / "gdext.stamp"
    if not force and stamp.exists() and stamp.read_text() == key and all(p.exists() for p in GEN_OUTPUTS):
        return 0.0
    t0 = time.time()
    out.mkdir(parents=True, exist_ok=True)
    (GDEXT / "gdi").mkdir(exist_ok=True)
    gen = out / ("gdext_gen" + EXE)
    run_odin(["build", "src/gdext/gen", "-out:" + gen.as_posix(), "-o:minimal"] + VET, "build the binding generator")
    r = subprocess.run([str(gen), str(GDEXT / "api"), str(GDEXT / "bindings.txt"), str(GDEXT)], cwd=str(REPO))
    if r.returncode != 0:
        raise SystemExit("dev: binding generator failed (exit %d)" % r.returncode)
    stamp.write_text(key)
    secs = time.time() - t0
    log("dev: gen -> src/gdext/*.gen.odin in %.2fs" % secs)
    return secs


def build_extension(pkg, out, mode="dev", extra=()):
    """Builds an Odin package as a shared library (a GDExtension)."""
    cmd_gen()
    out.parent.mkdir(parents=True, exist_ok=True)
    return run_odin(["build", pkg, "-build-mode:dll", "-out:" + out.as_posix(), COLLECTION] + MODES[mode] + VET
                    + list(extra), "build " + pkg)


def godot_errors(text):
    return [l for l in text.splitlines() if "ERROR" in l or "SCRIPT ERROR" in l or "Parse Error" in l]


def cmd_godot_test():
    t0 = time.time()
    proj = REPO / "tests" / "godot"
    imgui.ensure()
    build_extension("tests/godot/ext", proj / ".out" / "bin" / common.lib_name("gdext_test"))
    common.write_extension_list(proj)
    # --verbose: Godot reports orphan StringNames and leaked objects at exit only then
    r = common.run_godot(["--headless", "--verbose", "--path", proj, "-s", "res://test.gd"], timeout=30)
    out = r.stdout + r.stderr
    sys.stdout.write("".join(l + "\n" for l in r.stdout.splitlines() if l.startswith(("PASS", "FAIL", "GDEXT"))))
    errs = godot_errors(out) + [l for l in out.splitlines() if "Orphan StringName" in l or "leaked at exit" in l]
    for e in errs:
        log("godot: " + e)
    if r.returncode != 0 or errs or "GDEXT TESTS: 0 failed" not in out:
        raise SystemExit("dev: godot-test failed (exit %d, %d error line(s))" % (r.returncode, len(errs)))
    log("dev: godot-test passed in %.2fs" % (time.time() - t0))


def rel(p):
    try:
        return p.relative_to(REPO).as_posix()
    except ValueError:
        return str(p)


def cmd_game_build(gdir, mode="dev"):
    """Builds the game's GDExtension into <game>/.out/bin/. macOS dev builds get a new versioned file each time
    and lib<game>.dylib becomes a symlink to it: dyld never unloads an image with thread-locals (Odin's runtime
    has some), so reloading the same path in the editor would keep the old code."""
    t0 = time.time()
    if not (gdir / "simulation" / "extension").is_dir():
        raise SystemExit("dev: %s has no simulation/extension to build" % rel(gdir))
    name = gdir.name
    box3d.ensure()
    imgui.ensure()
    cmd_gen()
    out = gdir / ".out" / "bin" / common.lib_name(name)
    out.parent.mkdir(parents=True, exist_ok=True)
    versioned = common.IS_MACOS and mode != "release"
    if versioned:
        stamp = time.strftime("%Y%m%d-%H%M%S") + "-%03d" % (int(time.time() * 1000) % 1000)
        tmp = out.with_name("lib%s-%s.dylib" % (name, stamp))
    else:
        tmp = out.with_name(out.name + ".tmp" + (".dll" if common.IS_WINDOWS else ""))
    tag = "-define:UNIFIED_BUILD_TAG=%s-%s" % (mode, time.strftime("%Y%m%d-%H%M%S"))
    eos_defines = stage_eos(out.parent)
    secs = run_odin(["build", (gdir / "simulation" / "extension").as_posix(), "-build-mode:dll",
                     "-out:" + tmp.as_posix(), COLLECTION, tag] + eos_defines + MODES[mode] + VET,
                    "build the extension")
    if versioned:
        link = out.with_name(out.name + ".new")
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(tmp.name)
        os.replace(str(link), str(out))
        # keep the newest few builds: a running editor may still have older ones mapped
        for old in sorted(out.parent.glob("lib%s-*.dylib" % name))[:-4]:
            old.unlink()
            shutil.rmtree(str(old.with_name(old.name + ".dSYM")), ignore_errors=True)
    else:
        if out.is_symlink():
            out.unlink()
        os.replace(str(tmp), str(out))
        if common.IS_WINDOWS:
            for ext in (".pdb", ".lib", ".exp"):
                t = Path(str(tmp)[:-4] + ext)
                if t.exists():
                    os.replace(str(t), str(out.with_suffix(ext)))
    common.write_extension_list(gdir)
    log("dev: game build %s %s -> %s in %.2fs (odin %.2fs)" % (name, mode, rel(out), time.time() - t0, secs))
    return out


def extension_uses_eos(gdir):
    return any('"unified:eos"' in p.read_text(errors="replace")
               for p in (gdir / "simulation" / "extension").glob("*.odin"))


def stage_eos(bin_dir):
    """EOS (tools/eos.py): copies the SDK's runtime library next to the game library (the .gdextension's
    [dependencies] ships it from there) and returns the credential -define flags from EOS_* env vars. The
    library is loaded at run time, so a missing SDK only disables online play (warned, not fatal)."""
    if not (REPO / "tools" / "eos.py").exists() or not extension_uses_eos(bin_dir.parent.parent):
        return []  # odin rejects -defines nothing declares
    import eos
    try:
        eos.ensure()
    except SystemExit as e:
        log("dev: warning: EOS SDK not staged (%s); online play will be unavailable" % e)
        return eos.defines()
    src = eos.lib_path()
    dst = bin_dir / src.name
    if src.exists() and (not dst.exists() or dst.stat().st_size != src.stat().st_size):
        bin_dir.mkdir(parents=True, exist_ok=True)
        tmp = dst.with_name(dst.name + ".tmp")
        with open(src, "rb") as a, open(tmp, "wb") as b:  # a fresh copy: no clone of a quarantined file
            shutil.copyfileobj(a, b)
        os.replace(str(tmp), str(dst))
    return eos.defines()


def last_json_after(text, prefix):
    for line in reversed(text.splitlines()):
        if line.startswith(prefix):
            try:
                return json.loads(line[len(prefix):].strip())
            except ValueError:
                return None
    return None


def cmd_game_headless(gdir, ticks=256, seed=1, release=False, build=True):
    """A headless Godot session (single player, scripted input) for N ticks; the result must be clean and its
    checksums must equal the offline headless binary's for the same seed and inputs."""
    if ticks % 16:
        raise SystemExit("dev: --ticks must be a multiple of 16 (clients checksum every 16th verified tick)")
    if build:
        cmd_game_build(gdir, "release" if release else "dev")
    common.ensure_imported(gdir)
    t0 = time.time()
    r = common.run_godot(["--headless", "--path", gdir, "--", "--autostart", "--scripted", "--quit-at-end",
                   "--ticks", ticks, "--seed", seed], timeout=ticks / 64 + 30)
    wall = time.time() - t0
    out = r.stdout + r.stderr
    errs = godot_errors(out)
    res = last_json_after(r.stdout, "unified: result ")
    report = {"mode": "game-headless", "game": gdir.name, "ticks": ticks, "exit": r.returncode, "errors": errs,
              "wall_s": round(wall, 2)}
    if res is None:
        sys.stdout.write(out[-4000:])
        print(json.dumps(report))
        raise SystemExit("dev: no result from the headless session")
    report["final_tick"] = res.get("final_tick")
    report["checksums"] = res.get("checksums", [])[-1:] if res.get("checksums") else []
    ok = r.returncode == 0 and not errs and res.get("final_tick") == ticks
    ref = offline_checksums(gdir, ticks, seed)
    if ref is not None:
        mine = {c[0]: c[1] for c in res.get("checksums", [])}
        both = [t for t in ref if t in mine]
        report["offline_compared"] = len(both)
        report["matches_offline"] = bool(both) and all(mine[t] == ref[t] for t in both)
        ok = ok and report["matches_offline"]
    report["ok"] = ok
    print(json.dumps(report))
    if not ok:
        raise SystemExit("dev: game headless failed")


def offline_checksums(gdir, ticks, seed):
    """The checksum the offline headless binary (simulation/headless, mode sim) reports for one scripted player at
    the last tick, as {tick: checksum}; None when the game has no headless binary."""
    pkg = gdir / "simulation" / "headless"
    if not pkg.is_dir():
        return None
    exe = REPO / "out" / "games" / (gdir.name + "_headless" + EXE)
    exe.parent.mkdir(parents=True, exist_ok=True)
    run_odin(["build", pkg.as_posix(), "-out:" + exe.as_posix(), COLLECTION] + MODES["release"] + VET,
             "build the headless binary")
    # --game <name>: the variant the game itself runs (its sim.Game name = the game's directory name); the
    # headless binary's default may be a test variant (survivor: the `stress` tuning).
    r = subprocess.run([str(exe), "sim", "--ticks", str(ticks), "--players", "1", "--seed", str(seed),
                        "--game", gdir.name],
                       capture_output=True, text=True, timeout=120)
    for line in reversed(r.stdout.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            cs = d.get("checksums")
            if cs:
                return {c[0]: c[1] for c in cs}
            if "final_checksum" in d:
                return {ticks: d["final_checksum"]}
    log("dev: the offline binary printed no checksums:\n" + (r.stdout + r.stderr)[-2000:])
    return None


def cmd_game_play(gdir, minutes=3.0, bench=None, coop=False, release=False, build=True):
    """The real-play check (game/tools/play_check.gd): a bot plays single player (or --bench N / --coop) in a window
    with the real extension; screenshots go to <game>/.out/shots/. Needs a display (not CI)."""
    if build:
        cmd_game_build(gdir, "release" if release else "dev")
    common.ensure_imported(gdir)
    extra = ["--minutes", str(minutes), "--shots=res://.out/shots"]
    if bench is not None:
        extra += ["--bench", str(bench)]
    if coop:
        extra.append("--coop")
    r = common.run_godot(["--path", gdir, "--resolution", "1280x720", "-s", "res://game/tools/play_check.gd", "--"] + extra,
                  timeout=minutes * 60 + 360)
    for line in r.stdout.splitlines():
        if line.startswith("  ok") or line.startswith("  FAIL"):
            log(line)
    res = last_json_after(r.stdout, "PLAY_JSON ")
    if res is None:
        sys.stdout.write((r.stdout + r.stderr)[-4000:])
        raise SystemExit("dev: the play check printed no result")
    print(json.dumps(res))
    if r.returncode != 0 or not res.get("ok"):
        raise SystemExit("dev: game play failed")


def cmd_game_session_check(gdir):
    """Session lifecycle under headless Godot (game/tools/session_check.gd): Leave, then Host or Join at once."""
    if not (gdir / ".out" / "bin" / common.lib_name(gdir.name)).exists():
        cmd_game_build(gdir)
    common.ensure_imported(gdir)
    t0 = time.time()
    r = common.run_godot(["--headless", "--path", gdir, "-s", "res://game/tools/session_check.gd"], timeout=60)
    for line in r.stdout.splitlines():
        if line.startswith("  FAIL"):
            log(line)
    res = last_json_after(r.stdout, "SESSION_JSON ")
    if res is None:
        sys.stdout.write((r.stdout + r.stderr)[-4000:])
        raise SystemExit("dev: the session check printed no result")
    res["wall_s"] = round(time.time() - t0, 2)
    print(json.dumps(res))
    if r.returncode != 0 or not res.get("ok"):
        raise SystemExit("dev: game session-check failed")


def cmd_game_editor_check(gdir):
    if not (gdir / ".out" / "bin" / common.lib_name(gdir.name)).exists():
        cmd_game_build(gdir)
    common.write_extension_list(gdir)
    t0 = time.time()
    r = common.run_godot(["--headless", "--editor", "--path", gdir, "--quit-after", "60"], timeout=120)
    out = r.stdout + r.stderr
    errs = godot_errors(out)
    loaded = "unified: extension initialized (editor)" in out
    print(json.dumps({"mode": "editor-check", "game": gdir.name, "exit": r.returncode, "errors": errs,
                      "extension_loaded": loaded, "wall_s": round(time.time() - t0, 2)}))
    if r.returncode != 0 or errs or not loaded:
        raise SystemExit("dev: editor-check failed")


Strict = common.Strict
DEV_GAME_COMMANDS = ("build", "run", "editor", "headless", "editor-check", "session-check", "play")


def game_parser():
    ap = Strict(prog="dev.py game", description="Build, run and check a game (games/<game>)")
    sub = ap.add_subparsers(dest="cmd", required=True, metavar="|".join(DEV_GAME_COMMANDS) + "|<tools/game.py>",
                            parser_class=Strict)
    p = sub.add_parser("build", help="the game's GDExtension into <game>/.out/bin/")
    p.add_argument("game")
    p.add_argument("mode", nargs="?", default="dev", choices=list(MODES))
    for name, helptext in (("run", "the game in a window (arguments after -- go to the game)"),
                           ("editor", "the Godot editor on the game")):
        p = sub.add_parser(name, help=helptext)
        p.add_argument("game")
        if name == "run":
            p.add_argument("args", nargs="*", help="after --: the game's own arguments")
    p = sub.add_parser("headless", help="headless session; its checksums must match the offline binary's")
    p.add_argument("game")
    p.add_argument("--ticks", type=int, default=256)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--release", action="store_true", help="build the extension in release mode")
    p.add_argument("--no-build", action="store_true", help="use the library already built")
    for name, helptext in (("editor-check", "headless editor: the extension loads, no ERROR lines"),
                           ("session-check", "headless: leave, then host/join at once")):
        sub.add_parser(name, help=helptext).add_argument("game")
    p = sub.add_parser("play", help="windowed bot play check with screenshots (needs a display)")
    p.add_argument("game")
    p.add_argument("--minutes", type=float, default=3.0)
    p.add_argument("--bench", type=int, help="N bot players, for a frame-time bench")
    p.add_argument("--coop", action="store_true")
    p.add_argument("--release", action="store_true", help="build the extension in release mode")
    p.add_argument("--no-build", action="store_true", help="use the library already built")
    return ap


def cmd_game(argv):
    import game
    if argv and argv[0] in game.COMMANDS:
        return game.main(argv)
    a = game_parser().parse_args(argv)
    gdir = common.game_dir(a.game)
    if a.cmd == "build":
        cmd_game_build(gdir, a.mode)
    elif a.cmd in ("run", "editor"):
        if not (gdir / ".out" / "bin" / common.lib_name(gdir.name)).exists():
            cmd_game_build(gdir)
        common.write_extension_list(gdir)
        cmd = [common.find_godot(), "--path", str(gdir)] + (["--editor"] if a.cmd == "editor" else []) + \
              (["--"] + a.args if a.cmd == "run" and a.args else [])
        return subprocess.call(cmd)
    elif a.cmd == "headless":
        cmd_game_headless(gdir, a.ticks, a.seed, a.release, not a.no_build)
    elif a.cmd == "play":
        cmd_game_play(gdir, a.minutes, a.bench, a.coop, a.release, not a.no_build)
    elif a.cmd == "editor-check":
        cmd_game_editor_check(gdir)
    elif a.cmd == "session-check":
        cmd_game_session_check(gdir)
    return 0


def games():
    """Every game: games/*/ with a project.godot."""
    return sorted(p.parent for p in (REPO / "games").glob("*/project.godot"))


def cmd_godot_checks():
    """Everything CI's godot job runs (headless Godot): the binding tests, then for every game with an extension
    a headless session against the offline binary, the session and editor checks, and the GDScript checks
    (validate, walk) when the game has those tool scripts."""
    import game
    cmd_godot_test()
    for gdir in games():
        if (gdir / "simulation" / "extension").is_dir():
            cmd_game_headless(gdir)
            if (gdir / "game" / "tools" / "session_check.gd").exists():
                cmd_game_session_check(gdir)
            cmd_game_editor_check(gdir)
        for name, script in (("validate", "validate.gd"), ("walk", "ui_walk.gd")):
            if (gdir / "game" / "tools" / script).exists() and game.main([name, str(gdir)]) != 0:
                raise SystemExit("dev: game %s %s failed" % (name, gdir.name))


def cmd_test():
    box3d.ensure()
    cmd_gen()
    out = REPO / "out" / "test"
    out.mkdir(parents=True, exist_ok=True)
    exe = out / ("unified_tests" + EXE)
    secs = run_odin(["test", "tests", "-all-packages", COLLECTION, "-out:" + exe.as_posix()] + TEST_FLAGS + VET,
                    "odin test")
    log("dev: test passed in %.2fs (build + run)" % secs)


def cmd_vet():
    """odin check of the headless binary, the tests and the extensions for every supported target, in parallel."""
    cmd_gen()
    jobs = [(pkg, t, ()) for t in VET_TARGETS for pkg in VET_PACKAGES]
    # godot_host without the dev UI (-define:UNIFIED_DEVUI=false) must keep compiling
    jobs += [(pkg, VET_TARGETS[0], ("-define:UNIFIED_DEVUI=false",)) for pkg in VET_PACKAGES if "extension" in pkg]
    # the suites as `regen` builds them (unified:headless/scenarios writes reference runs)
    jobs += [("tests", VET_TARGETS[0], ("-define:UNIFIED_REGEN=true",))]
    t0 = time.time()

    def one(job):
        pkg, target, defines = job
        extra = ([] if pkg in HEADLESS.values() else ["-no-entry-point"]) + list(defines)
        r = subprocess.run([odin(), "check", pkg, "-target:" + target, COLLECTION] + extra + VET,
                           cwd=str(REPO), capture_output=True, text=True)
        return job, r.returncode, (r.stdout + r.stderr).strip()

    failed = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(jobs)) as ex:
        for (pkg, target, defines), rc, text in ex.map(one, jobs):
            if rc != 0:
                failed.append(" ".join((pkg, target) + defines))
                log("vet: %s -target:%s %s FAILED\n%s" % (pkg, target, " ".join(defines), text))
    if failed:
        raise SystemExit("dev: vet failed: " + ", ".join(failed))
    log("dev: vet ok (%s x %s) in %.2fs" % (", ".join(VET_PACKAGES), ", ".join(VET_TARGETS), time.time() - t0))


def find_odinfmt():
    for c in (os.environ.get("ODINFMT"), shutil.which("odinfmt"),
              REPO / ".toolchains" / "odinfmt" / ("odinfmt" + EXE)):
        if c and Path(c).is_file():
            return str(c)
    raise SystemExit(ODINFMT_HELP)


def cmd_fmt(check=False):
    """Formats a scratch copy in one odinfmt run, then compares; only changed files are written back."""
    exe = find_odinfmt()
    t0 = time.time()
    with tempfile.TemporaryDirectory(prefix="unified-fmt-") as tmp:
        for d in FMT_DIRS:
            shutil.copytree(str(REPO / d), str(Path(tmp) / d), ignore=shutil.ignore_patterns("*.gen.odin"))
        r = subprocess.run([exe, "-config:" + str(REPO / "odinfmt.json"), "-w", tmp],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit("dev: odinfmt failed:\n" + (r.stdout + r.stderr).strip())
        changed = []
        for d in FMT_DIRS:
            for src in sorted((REPO / d).rglob("*.odin")):
                if src.name.endswith(".gen.odin"):
                    continue  # generated (python tools/dev.py gen)
                rel = src.relative_to(REPO)
                fmt = Path(tmp) / rel
                if not filecmp.cmp(str(src), str(fmt), shallow=False):
                    changed.append(rel.as_posix())
                    if not check:
                        shutil.copyfile(str(fmt), str(src))
    secs = time.time() - t0
    if check and changed:
        for c in changed:
            log("fmt: needs formatting: " + c)
        raise SystemExit("dev: %d file(s) need formatting: run `python tools/dev.py fmt`" % len(changed))
    log("dev: fmt %s (%d file(s) %s) in %.2fs" % ("check ok" if check else "done", len(changed),
                                                  "to change" if check else "changed", secs))


# `check`: the real-UDP, real-clock, multi-process test (src/headless/SPEC.md, End-to-end suites, Running).
UDP_TICKS = 960  # 15 s of the toy's 64 Hz clock
UDP_CLIENTS = 3  # the last one under the `bad` profile
TICK_HZ = 64


def free_udp_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class CheckFail(Exception):
    pass


def check_start(binary, work, name, args):
    """Starts the binary with its command line, stdout and stderr in out/check/<name>.*."""
    cmd = [str(binary)] + [str(a) for a in args]
    (work / (name + ".cmd")).write_text(" ".join(cmd) + "\n")
    out, err = open(work / (name + ".stdout"), "w"), open(work / (name + ".stderr"), "w")
    kw = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if common.IS_WINDOWS else {}
    p = subprocess.Popen(cmd, stdout=out, stderr=err, stdin=subprocess.DEVNULL, cwd=str(work), **kw)
    p.files, p.name, p.t0 = (out, err), name, time.time()
    return p


def check_finish(work, p, timeout):
    """Waits for p (killed after timeout seconds) and returns its final JSON line."""
    try:
        p.wait(timeout=max(1.0, timeout - (time.time() - p.t0)))
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        raise CheckFail("%s: timed out after %.0fs (killed)" % (p.name, timeout))
    finally:
        for f in p.files:
            f.close()
    if p.returncode != 0:
        tail = (work / (p.name + ".stderr")).read_text(errors="replace").strip().splitlines()[-5:]
        raise CheckFail("%s: exit code %d%s" % (p.name, p.returncode, (": " + " | ".join(tail)) if tail else ""))
    for line in reversed((work / (p.name + ".stdout")).read_text(errors="replace").splitlines()):
        if line.strip().startswith("{"):
            return json.loads(line)
    raise CheckFail("%s: no JSON line on stdout" % p.name)


def check_udp(binary, work):
    """A relay and UDP_CLIENTS client processes over localhost UDP on the real clock: every client verifies every
    tick, their checksums (every 16th tick) agree, and nobody reports a desync."""
    port = free_udp_port()
    timeout = UDP_TICKS / TICK_HZ * 4 + 90
    relay = check_start(binary, work, "relay", ["relay", "--port", port, "--players", UDP_CLIENTS,
                                                "--ticks", UDP_TICKS, "--log", work / "relay.log"])
    time.sleep(0.5)
    procs = [check_start(binary, work, "client%d" % i,
                         ["client", "--connect", "127.0.0.1:%d" % port, "--player", i, "--ticks", UDP_TICKS]
                         + (["--profile", "bad"] if i == UDP_CLIENTS - 1 else []))
             for i in range(UDP_CLIENTS)]
    errors, clients = [], []
    for p in procs:
        try:
            clients.append(check_finish(work, p, timeout))
        except CheckFail as e:
            errors.append(str(e))
    try:
        rj = check_finish(work, relay, timeout if not errors else 10)
    except CheckFail as e:
        errors.append(str(e))
    if errors:
        raise CheckFail("; ".join(errors))
    if rj.get("desyncs", 0) or any(c.get("desyncs", 0) for c in clients):
        raise CheckFail("desyncs: relay %d, clients %s" % (rj.get("desyncs", 0), [c.get("desyncs", 0) for c in clients]))
    want = list(range(16, UDP_TICKS + 1, 16))
    ref = None
    for c in clients:
        if c.get("final_tick") != UDP_TICKS:
            raise CheckFail("client %s verified up to tick %s of %d" % (c.get("player"), c.get("final_tick"), UDP_TICKS))
        cs = {t: h for t, h in c.get("checksums", [])}
        if sorted(cs) != want:
            raise CheckFail("client %s's checksums don't cover every 16th tick" % c.get("player"))
        if ref is None:
            ref = cs
        elif cs != ref:
            t = min(t for t in want if cs[t] != ref[t])
            raise CheckFail("client %s's checksum differs first at tick %d: %s vs %s" % (c.get("player"), t, cs[t], ref[t]))
    detail = "toy relay + %d client processes (one under `bad`) over UDP, %d ticks on the real clock: 0 desyncs, " \
             "checksums agree" % (UDP_CLIENTS, UDP_TICKS)
    return detail, {"port": port, "rollbacks": [c.get("rollbacks") for c in clients]}


BENCH_TARGET_US = 6000.0


def check_bench(binary, work):
    """Until the benchmarks take it over: the survivor's forward step + 8-tick re-sim at 1000 enemies (reported,
    not gated; target <= 6 ms)."""
    j = check_finish(work, check_start(binary, work, "bench", ["bench", "--enemies", 1000, "--window", 8,
                                                                "--ticks", 600]), 900)
    step, resim = float(j["step_us"]["mean"]), float(j["resim_us"]["mean"])
    data = {"step_mean_us": step, "step_p99_us": float(j["step_us"]["p99"]),
            "save_mean_us": float(j["save_us"]["mean"]), "restore_mean_us": float(j["restore_us"]["mean"]),
            "resim_mean_us": resim, "resim_p99_us": float(j["resim_us"]["p99"]), "step_plus_resim_us": step + resim,
            "snapshot_bytes": int(j["snapshot_bytes"]), "within_target": step + resim <= BENCH_TARGET_US, "raw": j}
    detail = "survivor: step %.0f us + 8-tick re-sim %.0f us = %.2f ms (target <= 6 ms: %s); snapshot %d bytes" % (
        step, resim, (step + resim) / 1000, "yes" if data["within_target"] else "NO", data["snapshot_bytes"])
    return detail, data


def cmd_check():
    """Release build, then the real-UDP multi-process test on the toy's binary and the survivor's bench. Writes
    out/check.json (the CI job summary reads it) and each process's output to out/check/."""
    out = cmd_build("release")
    work = REPO / "out" / "check"
    shutil.rmtree(str(work), ignore_errors=True)
    work.mkdir(parents=True)
    summary = {"platform": common.platform_tag(), "commit": git_commit(),
               "started": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
               "ok": False, "tests": {}}
    for name, run, binary in (("udp_processes", check_udp, "toy"), ("bench", check_bench, "survivor")):
        t0 = time.time()
        try:
            detail, data = run(out / (binary + EXE), work)
            status = "pass"
        except CheckFail as e:
            detail, data, status = str(e), {}, "fail"
        secs = time.time() - t0
        summary["tests"][name] = {"status": status, "seconds": round(secs, 2), "detail": detail, "data": data}
        print("%-13s %-4s %6.1fs  %s" % (name, status.upper(), secs, detail), flush=True)
    summary["ok"] = all(t["status"] == "pass" for t in summary["tests"].values())
    (REPO / "out" / "check.json").write_text(json.dumps(summary, indent=2) + "\n")
    if not summary["ok"]:
        raise SystemExit("dev: check failed (out/check.json, out/check/)")


def git_commit():
    """HEAD, with "+dirty" when the tree has changes (None outside a git checkout)."""
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(REPO), capture_output=True, text=True).stdout.strip()
    if not head:
        return None
    dirty = subprocess.run(["git", "status", "--porcelain"], cwd=str(REPO), capture_output=True, text=True).stdout
    return head + ("+dirty" if dirty.strip() else "")


def cmd_regen(name):
    """Regenerates a reference run on this machine: builds the suite (the toy's, tests/scenarios, or a game's,
    games/<game>/simulation/tests) with -define:UNIFIED_REGEN=true and runs it; its reference test writes and
    checks the new files. Commit them with the change that made them necessary, and say why."""
    pkg = REPO / "tests" / "scenarios" if name == "toy" else common.game_dir(name) / "simulation" / "tests"
    if not (pkg / "suite_test.odin").exists():
        raise SystemExit("dev: %s has no end-to-end suite (suite_test.odin)" % rel(pkg))
    box3d.ensure()
    exe = REPO / "out" / "regen" / ((name if name == "toy" else pkg.parent.parent.name) + "_suite" + EXE)
    exe.parent.mkdir(parents=True, exist_ok=True)
    run_odin(["test", rel(pkg), COLLECTION, "-out:" + exe.as_posix(), "-define:UNIFIED_REGEN=true",
              "-define:UNIFIED_REGEN_COMMIT=" + (git_commit() or "unknown")] + TEST_FLAGS + VET, "regen " + name)
    data = rel(pkg / "testdata")
    st = subprocess.run(["git", "status", "--short", "--", data], cwd=str(REPO), capture_output=True, text=True)
    log("dev: regen %s -> %s%s" % (name, data, (":\n" + st.stdout.rstrip()) if st.stdout.strip() else
                                   " (reproduced byte for byte: nothing changed)"))


def parser():
    ap = Strict(prog="dev.py", add_help=False)
    sub = ap.add_subparsers(dest="cmd", parser_class=Strict)
    p = sub.add_parser("build")
    p.add_argument("mode", nargs="?", default="dev", choices=list(MODES))
    for name in ("test", "vet", "check", "all", "godot-test", "godot-checks"):
        sub.add_parser(name)
    sub.add_parser("gen").add_argument("--force", action="store_true")
    sub.add_parser("fmt").add_argument("--check", action="store_true")
    sub.add_parser("regen", help="regenerate a reference run").add_argument(
        "suite", help="a game under games/, or `toy` (the library's own, tests/scenarios)")
    for name in ("game", "board"):  # their own parsers validate the rest
        sub.add_parser(name, add_help=False, prefix_chars="\0").add_argument("argv", nargs="*")
    return ap


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0 if argv else 2
    a = parser().parse_args(argv)
    t0 = time.time()
    if a.cmd == "build":
        cmd_build(a.mode)
    elif a.cmd == "test":
        cmd_test()
    elif a.cmd == "gen":
        cmd_gen(force=a.force)
    elif a.cmd == "godot-test":
        cmd_godot_test()
    elif a.cmd == "godot-checks":
        cmd_godot_checks()
    elif a.cmd == "game":
        rc = cmd_game(a.argv)
        if rc:
            return rc
    elif a.cmd == "board":
        import board

        board.main(a.argv)
        return 0  # no timing line: board commands are interactive, not build steps
    elif a.cmd == "check":
        cmd_check()
    elif a.cmd == "regen":
        cmd_regen(a.suite)
    elif a.cmd == "fmt":
        cmd_fmt(check=a.check)
    elif a.cmd == "vet":
        cmd_vet()
    elif a.cmd == "all":
        cmd_fmt(check=True)
        cmd_vet()
        cmd_test()
        cmd_check()
        cmd_godot_checks()
    secs = time.time() - t0
    log("dev: %s done in %.1fs" % (" ".join(argv), secs))
    record_timing(" ".join(argv), secs)
    return 0


def record_timing(what, secs):
    """Wall times of the last run of each command, in out/timings.json (shown in the CI summary)."""
    path = REPO / "out" / "timings.json"
    try:
        t = json.loads(path.read_text()) if path.exists() else {}
    except ValueError:
        t = {}
    t[what] = round(secs, 2)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(t, indent=2) + "\n")


if __name__ == "__main__":
    sys.exit(main())
