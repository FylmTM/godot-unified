#!/usr/bin/env python3
"""Build the Odin implementation of the unified core.

    python impl/odin/build.py dev|release|debug [--arch x86_64] [--check]

dev     -> impl/odin/out/dev/unified[.exe]      -o:speed -use-separate-modules -debug, bounds checks on.
           The everyday build: optimized code in per-package LLVM modules builds in under a second
           (about as fast as -o:none) and runs ~5x faster than -o:none (1000-enemy rollback: 1.26 ms
           vs 6.2 ms on an M4 Pro).
release -> impl/odin/out/release/unified[.exe]  -o:speed (one LLVM module), bounds checks on
debug   -> impl/odin/out/debug/unified[.exe]    -o:none -debug: unoptimized, for stepping in a debugger

Works from any cwd and needs only Python 3 and `odin` on PATH. Box3D (static library + headers with
the save/restore fork) comes from `python tools/box3d.py --json`; its library directory is passed to
the linker, and the bindings link it as "system:box3d".

--arch x86_64   macOS only: build for darwin_amd64 against the macos-x64 Box3D (Rosetta checks).
                The output path is the same, so tools/check.py --no-build tests that binary.
--check         also type-check the code for linux_amd64 and windows_amd64 (no linking).
"""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
IS_WINDOWS = os.name == "nt"
EXE = ".exe" if IS_WINDOWS else ""

COMMON = ["-vet", "-strict-style", "-vet-tabs", "-warnings-as-errors"]
MODES = {
    "dev": ["-o:speed", "-use-separate-modules", "-debug"],
    "release": ["-o:speed"],
    "debug": ["-o:none", "-debug"],
}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def box3d(arch):
    cmd = [sys.executable, str(REPO / "tools" / "box3d.py"), "--json"]
    if arch:
        cmd += ["--arch", arch]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, text=True)
    if r.returncode != 0:
        raise SystemExit("build: tools/box3d.py failed (%d)" % r.returncode)
    lines = [l for l in r.stdout.splitlines() if l.strip()]
    return json.loads(lines[-1])


def linker_flags(desc):
    lib_dir = desc["lib_dir"]
    if IS_WINDOWS:
        # tools/box3d.py builds Box3D with the DLL CRT (/MD), while Odin links the static one
        # (/defaultlib:libcmt). Use one CRT for the whole program: swap libcmt for msvcrt.
        # No quotes around the path: Odin's default Windows linker (RADLINK) keeps them and mangles the path
        # (/LIBPATH:"D:\x" became D:\D:\x in CI). The CI checkout path has no spaces.
        path = lib_dir.replace("/", "\\")
        if " " in path:
            raise SystemExit("build: Box3D lib path contains spaces, which RADLINK's /LIBPATH can't take: " + path)
        return "/LIBPATH:%s /NODEFAULTLIB:libcmt /DEFAULTLIB:msvcrt" % path
    flags = ["-L" + lib_dir] + ["-l" + l for l in desc.get("link_libs", [])]
    return " ".join(flags)


def odin_build(args, cwd):
    log("+ " + " ".join(args))
    t0 = time.time()
    r = subprocess.run(args, cwd=str(cwd))
    return r.returncode, time.time() - t0


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] not in MODES:
        raise SystemExit("usage: build.py dev|release|debug [--arch x86_64] [--check]")
    mode = argv[0]
    arch = None
    check = "--check" in argv
    if "--arch" in argv:
        arch = argv[argv.index("--arch") + 1]
    odin = shutil.which("odin")
    if not odin:
        raise SystemExit("build: odin not found on PATH")

    desc = box3d(arch)
    out_dir = HERE / "out" / mode
    out_dir.mkdir(parents=True, exist_ok=True)
    exe = out_dir / ("unified" + EXE)
    args = [odin, "build", "src/cli", "-out:" + str(exe)] + MODES[mode] + COMMON
    args.append("-extra-linker-flags:" + linker_flags(desc))
    if arch:
        if sys.platform != "darwin" or arch not in ("x86_64", "x64", "amd64"):
            raise SystemExit("build: --arch is only for macOS x86_64 (Rosetta) builds")
        args.append("-target:darwin_amd64")
    rc, secs = odin_build(args, HERE)
    if rc != 0:
        raise SystemExit("build: odin build failed (%d)" % rc)
    log("build: %s %s in %.2fs" % (mode, exe.relative_to(HERE).as_posix(), secs))

    if check:
        for target in ("linux_amd64", "windows_amd64", "darwin_arm64"):
            rc, secs = odin_build([odin, "check", "src/cli", "-target:" + target]
                                  + COMMON, HERE)
            if rc != 0:
                raise SystemExit("build: odin check -target:%s failed" % target)
            log("build: check %s ok (%.2fs)" % (target, secs))


if __name__ == "__main__":
    main()
