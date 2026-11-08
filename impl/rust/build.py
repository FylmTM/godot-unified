#!/usr/bin/env python3
"""Build the Rust implementation of the unified core.

    python impl/rust/build.py dev|release [--target TRIPLE]

Output: impl/rust/out/<mode>/unified[.exe] (with --target: out/<mode>-<TRIPLE>/). Works from any
cwd, needs no bash. Box3D comes from `python tools/box3d.py --json` (always its -O2 build); its
lib dir and link libs are handed to the box3d-sys build script through BOX3D_LIB_DIR /
BOX3D_LINK_LIBS. `--target x86_64-apple-darwin` on an arm64 Mac builds against the macos-x64 Box3D
for the Rosetta determinism check. Cargo's target dir is impl/rust/target (what CI caches) unless
CARGO_TARGET_DIR is set.
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
EXE = ".exe" if os.name == "nt" else ""


def die(msg, code=1):
    print("build.py: " + msg, file=sys.stderr, flush=True)
    sys.exit(code)


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("dev", "release"):
        die("usage: build.py dev|release [--target TRIPLE]", 2)
    mode = args[0]
    target = None
    if "--target" in args:
        i = args.index("--target")
        if i + 1 >= len(args):
            die("--target needs a triple", 2)
        target = args[i + 1]

    t0 = time.time()
    box_cmd = [sys.executable, str(REPO / "tools" / "box3d.py"), "--json"]
    if target and target.startswith("x86_64-apple"):
        box_cmd += ["--arch", "x86_64"]
    r = subprocess.run(box_cmd, stdout=subprocess.PIPE, text=True)
    if r.returncode != 0:
        die("tools/box3d.py failed (%d)" % r.returncode)
    lines = [l for l in r.stdout.splitlines() if l.strip()]
    if not lines:
        die("tools/box3d.py printed no JSON")
    desc = json.loads(lines[-1])

    cargo = shutil.which("cargo")
    if not cargo:
        die("cargo not found on PATH (install rustup; impl/rust/rust-toolchain.toml pins the toolchain)")
    env = dict(os.environ)
    env["BOX3D_LIB_DIR"] = desc["lib_dir"]
    env["BOX3D_LINK_LIBS"] = ",".join(desc.get("link_libs") or [])
    if sys.platform == "darwin":
        env.setdefault("MACOSX_DEPLOYMENT_TARGET", "11.0")  # matches tools/box3d.py
    cmd = [cargo, "build", "--locked", "--profile", mode, "-p", "unified", "--bin", "unified"]
    if target:
        cmd += ["--target", target]
    print("+ " + " ".join(cmd), file=sys.stderr, flush=True)
    r = subprocess.run(cmd, cwd=str(HERE), env=env)
    if r.returncode != 0:
        die("cargo build failed (%d)" % r.returncode)

    target_dir = Path(env.get("CARGO_TARGET_DIR") or (HERE / "target"))
    if not target_dir.is_absolute():
        target_dir = HERE / target_dir
    profile_dir = "debug" if mode == "dev" else "release"
    built = target_dir / (target or "") / profile_dir / ("unified" + EXE)
    if not built.exists():
        die("expected %s after cargo build" % built)
    out = HERE / "out" / (mode if not target else "%s-%s" % (mode, target))
    out.mkdir(parents=True, exist_ok=True)
    dst = out / ("unified" + EXE)
    tmp = out / ("unified.tmp" + EXE)
    shutil.copy2(built, tmp)
    os.replace(tmp, dst)
    print("build.py: %s -> %s (%.1fs)" % (mode, dst, time.time() - t0), file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
