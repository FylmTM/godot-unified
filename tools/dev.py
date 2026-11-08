#!/usr/bin/env python3
"""Build, test, format and vet unified: the one entry point (Python 3.9+, stdlib only, any OS).

    python tools/dev.py build [dev|release|debug] [--arch x86_64]   # -> out/<mode>/survivor[.exe]
    python tools/dev.py test                    # odin test: unit tests + determinism lint
    python tools/dev.py check [check.py opts]   # release build, then T1-T9 (tools/check.py)
    python tools/dev.py fmt [--check]           # odinfmt over src/, tests/ and the games' Odin code
    python tools/dev.py vet                     # odin check with the strict flags, every target
    python tools/dev.py all                     # fmt --check, vet, test, check (what CI runs)
    python tools/dev.py gen [--force]           # Godot bindings: src/gdext/*.gen.odin (cached by input hash)
    python tools/dev.py godot-test              # binding tests: tests/godot under headless Godot
    python tools/dev.py game build <game> [dev|release] [--arch x86_64]   # games/<game>/.uni/bin/lib<game>.*
    python tools/dev.py game run <game> [-- args]       # windowed game (args after -- go to the game)
    python tools/dev.py game editor <game>              # the Godot editor on the game
    python tools/dev.py game headless <game> [--ticks N] # headless session, sim hash vs the offline binary
    python tools/dev.py game editor-check <game>        # headless editor: extension loads, no ERROR lines
    python tools/dev.py game validate|walk|shots|tour|coop|import [--game survivor]   # Godot project checks (tools/game.py)

Build modes (all with -vet -strict-style -vet-tabs -warnings-as-errors, bounds checks on):
  dev      -o:speed -use-separate-modules -debug   the everyday build: optimized, ~1 s to build
  release  -o:speed                                one LLVM module: the fastest binary, ~2.5 s
  debug    -o:none -debug                          unoptimized, for stepping in a debugger

Box3D comes from tools/box3d.py (built on first use, then a ~10 ms check). The bindings import the
static library by relative path, so plain `odin build games/survivor/simulation/headless
-collection:unified=src` / `odin test tests -all-packages -collection:unified=src` work too once it
is built; this script only adds the flags and timings. The binary built is the survivor test game's
headless binary (the CLI modes of spec/CORE.md §3 come from unified:headless).
--arch x86_64 (macOS only) builds for darwin_amd64 against the macos-x64 Box3D, for Rosetta checks.
"""

import concurrent.futures
import filecmp
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import box3d
import common
import imgui
from common import REPO, EXE, log

VET = ["-vet", "-strict-style", "-vet-tabs", "-warnings-as-errors"]
COLLECTION = "-collection:unified=" + (REPO / "src").as_posix()
MODES = {
    "dev": ["-o:speed", "-use-separate-modules", "-debug"],
    "release": ["-o:speed"],
    "debug": ["-o:none", "-debug"],
}
# Tests build like dev: optimized enough that the sim tests take milliseconds, fast to compile.
TEST_FLAGS = ["-o:speed", "-use-separate-modules", "-debug"]
VET_TARGETS = ["darwin_arm64", "darwin_amd64", "linux_amd64", "windows_amd64"]
FMT_DIRS = ["src", "tests", "games/survivor/simulation"]
HEADLESS = "games/survivor/simulation/headless"  # the binary build/check use
BINARY = "survivor"
# Packages vet type-checks (with everything they import): the headless binary, the tests, the binding test
# extension and the game's extension.
VET_PACKAGES = [HEADLESS, "tests", "tests/godot/ext", "games/survivor/simulation/extension"]
ODINFMT_HELP = """odinfmt not found. It ships with OLS; install the pinned build (the commit CI uses, see
OLS_COMMIT in tools/ci.py) with:
    python tools/ci.py odinfmt ~/.local/share/unified-odinfmt
and put that directory on PATH, or point ODINFMT at the binary (VS Code's OLS extension keeps one
in its globalStorage folder, danielgavin.ols/<id>/odinfmt-<arch>-<os>; it may need chmod +x)."""


def odin():
    exe = shutil.which("odin")
    if not exe:
        raise SystemExit("dev: odin not found on PATH (see README.md, Toolchain)")
    return exe


def redact(args):
    """Command-line args for logging: values of -define:EOS_* (credentials) replaced."""
    return [a.split("=", 1)[0] + "=***" if str(a).startswith("-define:EOS_") else str(a) for a in args]


def run_odin(args, what):
    cmd = [odin()] + args
    log("+ " + " ".join(redact(cmd)))
    t0 = time.time()
    r = subprocess.run(cmd, cwd=str(REPO))
    secs = time.time() - t0
    if r.returncode != 0:
        raise SystemExit("dev: %s failed (exit %d)" % (what, r.returncode))
    return secs


def cmd_build(mode="dev", arch=None):
    if mode not in MODES:
        raise SystemExit("dev: build mode must be dev, release or debug")
    target = []
    if arch:
        if not common.IS_MACOS or common.norm_arch(arch) != "x64":
            raise SystemExit("dev: --arch is only for macOS x86_64 (Rosetta) builds")
        target = ["-target:darwin_amd64"]
    box3d.ensure(arch)
    out = REPO / "out" / mode
    out.mkdir(parents=True, exist_ok=True)
    exe = out / (BINARY + EXE)
    secs = run_odin(["build", HEADLESS, COLLECTION, "-out:" + exe.as_posix()] + MODES[mode] + VET + target,
                    "odin build")
    log("dev: build %s -> %s in %.2fs" % (mode, exe.relative_to(REPO).as_posix(), secs))
    return exe


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


def ensure_extension_list(project, gdextension):
    """Godot loads the extensions listed in .godot/extension_list.cfg, which the editor writes on its first scan.
    Writing it here lets a fresh checkout run (and run headless) without opening the editor once."""
    p = project / ".godot" / "extension_list.cfg"
    p.parent.mkdir(parents=True, exist_ok=True)
    want = gdextension + "\n"
    if not p.exists() or p.read_text() != want:
        p.write_text(want)


def run_godot(args, timeout, cwd=None):
    """Runs Godot with a timeout (a headless Godot whose extension fails to load never exits)."""
    cmd = [common.find_godot()] + [str(a) for a in args]
    log("+ " + " ".join(cmd))
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        sys.stdout.write(out)
        raise SystemExit("dev: Godot timed out after %ds (did the extension load?)" % timeout)
    return r


def godot_errors(text):
    return [l for l in text.splitlines() if "ERROR" in l or "SCRIPT ERROR" in l or "Parse Error" in l]


def cmd_godot_test():
    t0 = time.time()
    proj = REPO / "tests" / "godot"
    imgui.ensure()
    build_extension("tests/godot/ext", proj / ".uni" / "bin" / common.lib_name("gdext_test"))
    ensure_extension_list(proj, "res://gdext_test.gdextension")
    r = run_godot(["--headless", "--path", proj, "-s", "res://test.gd"], timeout=30)
    out = r.stdout + r.stderr
    sys.stdout.write(r.stdout)
    errs = godot_errors(out)
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


def game_dir(name):
    """A game by name (games/<name>) or by path."""
    p = Path(name)
    if not p.is_absolute():
        p = (REPO / name) if (REPO / name / "project.godot").exists() or "/" in name else (REPO / "games" / name)
    if not (p / "simulation" / "extension").is_dir():
        raise SystemExit("dev: %s has no simulation/extension" % p)
    return p.resolve()


def cmd_game_build(gdir, mode="dev", arch=None):
    """Builds the game's GDExtension into <game>/.uni/bin/. macOS dev builds get a new versioned file each time
    and lib<game>.dylib becomes a symlink to it: dyld never unloads an image with thread-locals (Odin's runtime
    has some), so reloading the same path in the editor would keep the old code."""
    t0 = time.time()
    if mode not in MODES:
        raise SystemExit("dev: build mode must be dev, release or debug")
    name = gdir.name
    box3d.ensure(arch)
    imgui.ensure(arch)
    cmd_gen()
    out = gdir / ".uni" / "bin" / common.lib_name(name)
    out.parent.mkdir(parents=True, exist_ok=True)
    target = []
    if arch:
        if not common.IS_MACOS or common.norm_arch(arch) != "x64":
            raise SystemExit("dev: --arch is only for macOS x86_64 (Rosetta) builds")
        target = ["-target:darwin_amd64"]
    versioned = common.IS_MACOS and mode != "release"
    if versioned:
        stamp = time.strftime("%Y%m%d-%H%M%S") + "-%03d" % (int(time.time() * 1000) % 1000)
        tmp = out.with_name("lib%s-%s.dylib" % (name, stamp))
    else:
        tmp = out.with_name(out.name + ".tmp" + (".dll" if common.IS_WINDOWS else ""))
    tag = "-define:UNIFIED_BUILD_TAG=%s-%s" % (mode, time.strftime("%Y%m%d-%H%M%S"))
    eos_defines = stage_eos(out.parent)
    secs = run_odin(["build", (gdir / "simulation" / "extension").as_posix(), "-build-mode:dll",
                     "-out:" + tmp.as_posix(), COLLECTION, tag] + eos_defines + MODES[mode] + VET + target,
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
    ensure_extension_list(gdir, "res://game/%s.gdextension" % name)
    log("dev: game build %s %s -> %s in %.2fs (odin %.2fs)" % (name, mode, rel(out), time.time() - t0, secs))
    return out


def extension_uses_eos(gdir):
    return any('"unified:eos"' in p.read_text(errors="replace")
               for p in (gdir / "simulation" / "extension").glob("*.odin"))


def ensure_imported(gdir):
    """A fresh checkout has no Godot import cache: import once (warm: skipped), so the timed run doesn't."""
    if (gdir / ".godot" / "imported").is_dir():
        return
    t0 = time.time()
    r = run_godot(["--headless", "--path", gdir, "--import"], timeout=300)
    if r.returncode != 0:
        sys.stdout.write((r.stdout + r.stderr)[-3000:])
        raise SystemExit("dev: Godot import failed")
    log("dev: imported %s in %.1fs" % (rel(gdir), time.time() - t0))


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


def cmd_game_headless(gdir, argv):
    """A headless Godot session (single player, scripted input) for N ticks; the result must be clean and its
    checksums must equal the offline headless binary's for the same seed and inputs."""
    ticks = int(argv[argv.index("--ticks") + 1]) if "--ticks" in argv else 256
    seed = argv[argv.index("--seed") + 1] if "--seed" in argv else "1"
    if ticks % 16:
        raise SystemExit("dev: --ticks must be a multiple of 16 (clients checksum every 16th verified tick)")
    if "--no-build" not in argv:
        cmd_game_build(gdir, "release" if "--release" in argv else "dev")
    ensure_imported(gdir)
    t0 = time.time()
    r = run_godot(["--headless", "--path", gdir, "--", "--autostart", "--scripted", "--quit-at-end",
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
    r = subprocess.run([str(exe), "sim", "--ticks", str(ticks), "--players", "1", "--seed", str(seed)],
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


def cmd_game_editor_check(gdir):
    if not (gdir / ".uni" / "bin" / common.lib_name(gdir.name)).exists():
        cmd_game_build(gdir)
    ensure_extension_list(gdir, "res://game/%s.gdextension" % gdir.name)
    t0 = time.time()
    r = run_godot(["--headless", "--editor", "--path", gdir, "--quit-after", "60"], timeout=120)
    out = r.stdout + r.stderr
    errs = godot_errors(out)
    loaded = "unified: extension initialized (editor)" in out
    print(json.dumps({"mode": "editor-check", "game": gdir.name, "exit": r.returncode, "errors": errs,
                      "extension_loaded": loaded, "wall_s": round(time.time() - t0, 2)}))
    if r.returncode != 0 or errs or not loaded:
        raise SystemExit("dev: editor-check failed")


GAME_PY_COMMANDS = ("validate", "walk", "shots", "tour", "coop", "import")  # tools/game.py (the game client's project checks)


def cmd_game(argv):
    if argv and argv[0] in GAME_PY_COMMANDS and (REPO / "tools" / "game.py").exists():
        import game
        return game.cmd_game(argv) or 0
    if len(argv) < 2:
        raise SystemExit("usage: dev.py game build|run|editor|headless|editor-check <game> ...")
    sub, gdir, rest = argv[0], game_dir(argv[1]), argv[2:]
    if sub == "build":
        mode = rest[0] if rest and not rest[0].startswith("-") else "dev"
        arch = rest[rest.index("--arch") + 1] if "--arch" in rest else None
        cmd_game_build(gdir, mode, arch)
    elif sub in ("run", "editor"):
        if not (gdir / ".uni" / "bin" / common.lib_name(gdir.name)).exists():
            cmd_game_build(gdir)
        ensure_extension_list(gdir, "res://game/%s.gdextension" % gdir.name)
        extra = rest[rest.index("--") + 1:] if "--" in rest else rest
        cmd = [common.find_godot(), "--path", str(gdir)] + (["--editor"] if sub == "editor" else []) + \
              (["--"] + extra if extra and sub == "run" else [])
        return subprocess.call(cmd)
    elif sub == "headless":
        cmd_game_headless(gdir, rest)
    elif sub == "editor-check":
        cmd_game_editor_check(gdir)
    else:
        raise SystemExit("dev: unknown game command %s" % sub)
    return 0


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
    jobs = [(pkg, t) for t in VET_TARGETS for pkg in VET_PACKAGES]
    t0 = time.time()

    def one(job):
        pkg, target = job
        extra = [] if pkg == HEADLESS else ["-no-entry-point"]
        r = subprocess.run([odin(), "check", pkg, "-target:" + target, COLLECTION] + extra + VET,
                           cwd=str(REPO), capture_output=True, text=True)
        return job, r.returncode, (r.stdout + r.stderr).strip()

    failed = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(jobs)) as ex:
        for (pkg, target), rc, text in ex.map(one, jobs):
            if rc != 0:
                failed.append("%s %s" % (pkg, target))
                log("vet: %s -target:%s FAILED\n%s" % (pkg, target, text))
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


def cmd_check(argv):
    import check
    mode = "release"
    if "--mode" in argv:
        mode = argv[argv.index("--mode") + 1]
    cmd_build(mode)
    rc = check.main(argv)
    if rc != 0:
        raise SystemExit(rc)


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0 if argv else 2
    cmd, rest = argv[0], argv[1:]
    t0 = time.time()
    if cmd == "build":
        mode = rest[0] if rest and not rest[0].startswith("-") else "dev"
        arch = rest[rest.index("--arch") + 1] if "--arch" in rest else None
        cmd_build(mode, arch)
    elif cmd == "test":
        cmd_test()
    elif cmd == "gen":
        cmd_gen(force="--force" in rest)
    elif cmd == "godot-test":
        cmd_godot_test()
    elif cmd == "game":
        rc = cmd_game(rest)
        if rc:
            return rc
    elif cmd == "check":
        cmd_check(rest)
    elif cmd == "fmt":
        cmd_fmt(check="--check" in rest)
    elif cmd == "vet":
        cmd_vet()
    elif cmd == "all":
        cmd_fmt(check=True)
        cmd_vet()
        cmd_test()
        cmd_check(rest)
    else:
        print(__doc__)
        return 2
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
