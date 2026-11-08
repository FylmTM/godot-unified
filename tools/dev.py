#!/usr/bin/env python3
"""Build, test, format and vet unified: the one entry point (Python 3.9+, stdlib only, any OS).

    python tools/dev.py build [dev|release|debug] [--arch x86_64]   # -> out/<mode>/unified[.exe]
    python tools/dev.py test                    # odin test: unit tests + determinism lint
    python tools/dev.py check [check.py opts]   # release build, then T1-T9 (tools/check.py)
    python tools/dev.py fmt [--check]           # odinfmt over src/ and tests/
    python tools/dev.py vet                     # odin check with the strict flags, every target
    python tools/dev.py all                     # fmt --check, vet, test, check (what CI runs)
    python tools/dev.py gen [--force]           # Godot bindings: src/gdext/*.gen.odin (cached by input hash)
    python tools/dev.py godot-test              # binding tests: tests/godot under headless Godot

Build modes (all with -vet -strict-style -vet-tabs -warnings-as-errors, bounds checks on):
  dev      -o:speed -use-separate-modules -debug   the everyday build: optimized, ~1 s to build
  release  -o:speed                                one LLVM module: the fastest binary, ~2.5 s
  debug    -o:none -debug                          unoptimized, for stepping in a debugger

Box3D comes from tools/box3d.py (built on first use, then a ~10 ms check). The bindings import the
static library by relative path, so plain `odin build src/cli` / `odin test tests -all-packages
-collection:unified=src` work too once it is built; this script only adds the flags and timings.
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
# Packages vet type-checks (with everything they import); libraries no test imports go here too.
VET_PACKAGES = ["src/cli", "tests", "tests/godot/ext"]
FMT_DIRS = ["src", "tests"]
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
    exe = out / ("unified" + EXE)
    secs = run_odin(["build", "src/cli", "-out:" + exe.as_posix()] + MODES[mode] + VET + target, "odin build")
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
    """odin check of the CLI and the tests for every supported target, in parallel."""
    cmd_gen()
    jobs = [(pkg, t) for t in VET_TARGETS for pkg in VET_PACKAGES]
    t0 = time.time()

    def one(job):
        pkg, target = job
        extra = [] if pkg == "src/cli" else ["-no-entry-point"]
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
