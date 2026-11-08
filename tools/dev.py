#!/usr/bin/env python3
"""Build, test, format and vet unified: the one entry point (Python 3.9+, stdlib only, any OS).

    python tools/dev.py build [dev|release|debug] [--arch x86_64]   # -> out/<mode>/survivor[.exe]
    python tools/dev.py test                    # odin test: unit tests + determinism lint
    python tools/dev.py check [check.py opts]   # release build, then T1-T9 (tools/check.py)
    python tools/dev.py fmt [--check]           # odinfmt over src/, tests/ and the games' Odin code
    python tools/dev.py vet                     # odin check with the strict flags, every target
    python tools/dev.py all                     # fmt --check, vet, test, check (what CI runs)
    python tools/dev.py game [validate|walk|shots|import] [--game survivor]   # Godot project checks (tools/game.py)

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


def run_odin(args, what):
    cmd = [odin()] + args
    log("+ " + " ".join(cmd))
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


def cmd_test():
    box3d.ensure()
    out = REPO / "out" / "test"
    out.mkdir(parents=True, exist_ok=True)
    exe = out / ("unified_tests" + EXE)
    secs = run_odin(["test", "tests", "-all-packages", COLLECTION, "-out:" + exe.as_posix()] + TEST_FLAGS + VET,
                    "odin test")
    log("dev: test passed in %.2fs (build + run)" % secs)


def cmd_vet():
    """odin check of the headless binary and the tests for every supported target, in parallel."""
    jobs = [(pkg, t) for t in VET_TARGETS for pkg in (HEADLESS, "tests")]
    t0 = time.time()

    def one(job):
        pkg, target = job
        extra = ["-no-entry-point"] if pkg == "tests" else []
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
    log("dev: vet ok (%s, tests x %s) in %.2fs" % (HEADLESS, ", ".join(VET_TARGETS), time.time() - t0))


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
            shutil.copytree(str(REPO / d), str(Path(tmp) / d))
        r = subprocess.run([exe, "-config:" + str(REPO / "odinfmt.json"), "-w", tmp],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit("dev: odinfmt failed:\n" + (r.stdout + r.stderr).strip())
        changed = []
        for d in FMT_DIRS:
            for src in sorted((REPO / d).rglob("*.odin")):
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
    elif cmd == "check":
        cmd_check(rest)
    elif cmd == "fmt":
        cmd_fmt(check="--check" in rest)
    elif cmd == "vet":
        cmd_vet()
    elif cmd == "game":
        import game
        game.cmd_game(rest)
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
