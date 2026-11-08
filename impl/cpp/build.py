#!/usr/bin/env python3
"""Build the C++ implementation of the unified core.

    python impl/cpp/build.py dev|release        -> impl/cpp/out/<mode>/unified[.exe]   (the check.py contract)
    python impl/cpp/build.py asan|tsan          -> ASan+UBSan / TSan builds (local runs; clang on macOS/Linux)
    python impl/cpp/build.py release-x64        -> macOS only: x86_64 build against the macos-x64 Box3D (Rosetta)

Works from any cwd and needs no shell. Box3D comes from `python tools/box3d.py --json` (a no-op when it's
already built). CMake + Ninja drive clang/clang++ (clang-cl on Windows, with the MSVC environment loaded via
tools/common.py when the shell isn't a developer prompt). Products live under impl/cpp/out/.
"""

import hashlib
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "tools"))
import common  # noqa: E402  (tools/common.py: stdlib-only helpers shared with check.py and box3d.py)

MODES = {
    "dev": ("dev", None),
    "release": ("release", None),
    "asan": ("asan", None),
    "tsan": ("tsan", None),
    "release-x64": ("release", "x86_64"),
}


def log(msg):
    print("build.py: " + msg, file=sys.stderr, flush=True)


def run(cmd, **kw):
    cmd = [str(c) for c in cmd]
    r = subprocess.run(cmd, **kw)
    if r.returncode != 0:
        raise SystemExit("build.py: command failed (%d): %s" % (r.returncode, " ".join(cmd)))
    return r


def box3d(arch):
    cmd = [sys.executable, str(REPO / "tools" / "box3d.py"), "--json"]
    if arch:
        cmd += ["--arch", arch]
    r = run(cmd, stdout=subprocess.PIPE, text=True)
    lines = [l for l in r.stdout.splitlines() if l.strip()]
    if not lines:
        raise SystemExit("build.py: tools/box3d.py --json printed nothing")
    return json.loads(lines[-1])


def compilers():
    if common.IS_WINDOWS:
        cl = common.find_clang_cl()
        if not cl:
            raise SystemExit("build.py: clang-cl not found (install LLVM or VS 'C++ Clang tools')")
        return cl, cl
    cc, cxx = shutil.which("clang"), shutil.which("clang++")
    if not cxx:
        raise SystemExit("build.py: clang++ not found on PATH")
    return cc, cxx


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in MODES:
        raise SystemExit("usage: python impl/cpp/build.py " + "|".join(MODES))
    mode = sys.argv[1]
    uni_mode, arch = MODES[mode]
    if arch and not common.IS_MACOS:
        raise SystemExit("build.py: %s is a macOS-only (Rosetta) mode" % mode)
    t0 = time.time()
    common.ensure_msvc_env()
    for tool in ("cmake", "ninja"):
        if not shutil.which(tool):
            raise SystemExit("build.py: %s not found on PATH" % tool)

    b3 = box3d(arch)
    _, cxx = compilers()
    out_dir = HERE / "out" / mode
    build_dir = HERE / "out" / "build" / mode
    args = [
        "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_CXX_COMPILER=" + Path(cxx).as_posix(),
        "-DUNI_MODE=" + uni_mode,
        "-DBOX3D_INCLUDE_DIR=" + b3["include_dir"],
        "-DBOX3D_LIBRARY=" + b3["lib"],
        "-DBOX3D_LINK_LIBS=" + ";".join(b3.get("link_libs") or []),
        "-DUNI_OUTPUT_DIR=" + out_dir.as_posix(),
    ]
    if common.IS_MACOS:
        args += ["-DCMAKE_OSX_ARCHITECTURES=" + (arch or "arm64"), "-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0"]
    stamp = build_dir / "configure.stamp"
    key = hashlib.sha256(json.dumps([args, b3.get("key")]).encode()).hexdigest()
    if not (build_dir / "build.ninja").exists() or not stamp.exists() or stamp.read_text() != key:
        if build_dir.exists():
            shutil.rmtree(build_dir)
        build_dir.mkdir(parents=True)
        log("configuring %s (%s)" % (mode, Path(cxx).name))
        run(["cmake", "-S", HERE, "-B", build_dir] + args, stdout=subprocess.DEVNULL)
        stamp.write_text(key)
    run(["cmake", "--build", build_dir])
    exe = out_dir / ("unified" + common.EXE)
    if not exe.exists():
        raise SystemExit("build.py: expected %s" % exe)
    log("%s -> %s (%.1fs)" % (mode, exe.relative_to(REPO).as_posix(), time.time() - t0))


if __name__ == "__main__":
    main()
