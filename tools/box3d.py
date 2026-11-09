#!/usr/bin/env python3
"""Fetch, patch and build Box3D (static library + headers) for the host platform.

    python tools/box3d.py                  # host build -> third_party/box3d/build/<platform>/
    python tools/box3d.py --json           # same, then print the build description as one JSON line
    python tools/box3d.py --clean          # wipe the source checkout and this platform's build first

Steps (each skipped when already done, so a repeat run takes well under a second):
  1. git-fetch Box3D at the pinned commit into third_party/box3d/src (shallow, autocrlf off),
  2. apply third_party/box3d.patch (our save/restore fork; must apply exactly, no fuzz),
  3. configure + build with CMake + Ninja: Release, -O2 -DNDEBUG, static, samples/tests/benchmarks
     off, validation off, AVX2 path compiled out (BOX3D_DISABLE_AVX2: x64 then runs the same 4-wide
     path as ARM64/NEON, instead of picking 8-wide at runtime by CPUID), and install include/ + lib/ into third_party/box3d/build/<platform>/,
  4. verify from compile_commands.json that every Box3D source got the FP-contraction-off flag
     (Box3D's CMakeLists adds -ffp-contract=off, or /clang:-ffp-contract=off for clang-cl), -O2,
     NDEBUG and BOX3D_DISABLE_AVX2, then write box3d.json next to include/ and lib/.

Compiler: one family everywhere. clang/clang++ on macOS and Linux, clang-cl on Windows (from PATH,
else C:\\Program Files\\LLVM, else Visual Studio's bundled LLVM) with the MSVC environment loaded via
vswhere/vcvarsall if the shell is not already a developer prompt. The MSVC runtime is the static
one (/MT, MultiThreaded), which is what Odin links by default (libcmt), so the program has one CRT
and needs no linker overrides. Override the compiler with --cc/--cxx.

Other tools import this module and call ensure() (no subprocess, ~10 ms when up to date).
"""

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

import common
from common import REPO, IS_WINDOWS, IS_MACOS, log

BOX3D_URL = "https://github.com/erincatto/box3d.git"
BOX3D_COMMIT = "336263320469e5e9febfe18697ab562488f7e97a"
# Bump when the build recipe below changes in a way the inputs don't capture.
RECIPE_VERSION = 1
MACOS_DEPLOYMENT_TARGET = "11.0"

ROOT = REPO / "third_party" / "box3d"
SRC = ROOT / "src"
SRC_STAMP = ROOT / "src.stamp"
PATCH = REPO / "third_party" / "box3d.patch"


def run(cmd, cwd=None, quiet=False, env=None):
    cmd = [str(c) for c in cmd]
    if not quiet:
        log("+ " + " ".join(cmd))
    r = subprocess.run(cmd, cwd=str(cwd) if cwd else None, env=env,
                       stdout=subprocess.PIPE if quiet else None, stderr=subprocess.STDOUT if quiet else None,
                       text=True)
    if r.returncode != 0:
        if quiet and r.stdout:
            log(r.stdout)
        raise SystemExit("box3d: command failed (%d): %s" % (r.returncode, " ".join(cmd)))
    return r


def patch_bytes():
    # Normalize line endings: a Windows checkout with core.autocrlf=true turns the patch into CRLF.
    return PATCH.read_bytes().replace(b"\r\n", b"\n")


def git(*args, cwd=SRC, quiet=True):
    return run(["git", "-c", "core.autocrlf=false", "-c", "advice.detachedHead=false"] + list(args),
               cwd=cwd, quiet=quiet)


def ensure_source(patch_sha):
    want = "%s %s" % (BOX3D_COMMIT, patch_sha)
    if SRC_STAMP.exists() and SRC_STAMP.read_text().strip() == want and (SRC / "src" / "world_state.c").exists():
        return False
    if not common.which("git"):
        raise SystemExit("box3d: git not found on PATH")
    if not (SRC / ".git").exists():
        if SRC.exists():
            shutil.rmtree(SRC)
        SRC.mkdir(parents=True)
        log("box3d: fetching %s @ %s" % (BOX3D_URL, BOX3D_COMMIT[:10]))
        git("init", "-q")
        git("config", "core.autocrlf", "false")
        git("remote", "add", "origin", BOX3D_URL)
    have = subprocess.run(["git", "cat-file", "-e", BOX3D_COMMIT + "^{commit}"], cwd=str(SRC),
                          capture_output=True).returncode == 0
    if not have:
        git("fetch", "-q", "--depth", "1", "origin", BOX3D_COMMIT)
    # Back to the pristine commit (drops an older patch), then apply ours strictly.
    git("checkout", "-q", "--force", "--detach", BOX3D_COMMIT)
    git("clean", "-q", "-fdx")
    tmp = ROOT / "box3d.lf.patch"
    tmp.write_bytes(patch_bytes())
    try:
        r = subprocess.run(["git", "apply", "--check", str(tmp)], cwd=str(SRC), capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit("box3d: third_party/box3d.patch does not apply cleanly to %s:\n%s"
                             % (BOX3D_COMMIT, r.stderr))
        git("apply", "--whitespace=nowarn", str(tmp))
    finally:
        tmp.unlink()
    SRC_STAMP.write_text(want + "\n")
    log("box3d: source ready (pinned commit + fork patch)")
    return True


def pick_compilers(cc=None, cxx=None):
    if cc:
        return cc, cxx or cc
    if IS_WINDOWS:
        cl = common.find_clang_cl()
        if not cl:
            raise SystemExit("box3d: clang-cl not found (install LLVM or the VS 'C++ Clang tools' component), "
                             "or pass --cc/--cxx")
        return cl, cl
    cc, cxx = common.which("clang"), common.which("clang++")
    if not cc or not cxx:
        raise SystemExit("box3d: clang/clang++ not found on PATH (or pass --cc/--cxx)")
    return cc, cxx


def compiler_version(cc):
    r = subprocess.run([cc, "--version"], capture_output=True, text=True)
    return (r.stdout.strip().splitlines() or ["?"])[0]


def cmake_args(cc, cxx, install_dir, arch):
    msvc_like = IS_WINDOWS and Path(cc).stem.lower() in ("clang-cl", "cl")
    opt = "/O2 /DNDEBUG" if msvc_like else "-O2 -DNDEBUG"
    defs = "/DBOX3D_DISABLE_AVX2" if msvc_like else "-DBOX3D_DISABLE_AVX2"
    a = [
        "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_C_COMPILER=" + cc,
        "-DCMAKE_CXX_COMPILER=" + cxx,
        "-DCMAKE_C_FLAGS=" + defs,
        "-DCMAKE_C_FLAGS_RELEASE=" + opt,
        "-DCMAKE_CXX_FLAGS_RELEASE=" + opt,
        "-DCMAKE_INSTALL_PREFIX=" + install_dir.as_posix(),
        "-DCMAKE_INSTALL_LIBDIR=lib",
        "-DCMAKE_INSTALL_INCLUDEDIR=include",
        "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DBOX3D_SAMPLES=OFF",
        "-DBOX3D_UNIT_TESTS=OFF",
        "-DBOX3D_BENCHMARKS=OFF",
        "-DBOX3D_DOCS=OFF",
        "-DBOX3D_VALIDATE=OFF",
        "-DBOX3D_PROFILE=OFF",
        "-DBOX3D_SANITIZE=OFF",
        "-DBOX3D_DISABLE_SIMD=OFF",
        "-DBOX3D_DOUBLE_PRECISION=OFF",
    ]
    if IS_MACOS:
        a += ["-DCMAKE_OSX_ARCHITECTURES=" + ("x86_64" if arch == "x64" else "arm64"),
              "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + MACOS_DEPLOYMENT_TARGET]
    if IS_WINDOWS:
        a += ["-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"]  # static CRT (/MT), like Odin
    return a


def verify_flags(work):
    db = json.loads((work / "compile_commands.json").read_text())
    entries = [e for e in db if Path(e["file"]).suffix == ".c"]
    if len(entries) < 20:
        raise SystemExit("box3d: compile_commands.json lists only %d C sources" % len(entries))
    required = ["-ffp-contract=off", "O2", "NDEBUG", "BOX3D_DISABLE_AVX2"]
    forbidden = ["BOX3D_VALIDATE", "-ffast-math", "/fp:fast", "-march", "/arch:AVX"]
    for e in entries:
        cmd = e.get("command") or " ".join(e.get("arguments", []))
        missing = [f for f in required if f not in cmd]
        bad = [f for f in forbidden if f in cmd]
        if IS_WINDOWS:
            flags = cmd.replace("/", "-").split()
            if "-MT" not in flags:
                missing.append("/MT (static CRT)")
            bad += [f for f in ("-MD", "-MDd", "-MTd") if f in flags]
        if missing or bad:
            raise SystemExit("box3d: flag check failed for %s: missing %s, forbidden %s\n%s"
                             % (e["file"], missing, bad, cmd))
    return len(entries)


def fast_key(tag, patch_sha):
    """Inputs checked on every call without starting a compiler: the recipe (this file), the commit
    and the patch. A compiler upgrade is not detected here: run with --clean after one."""
    me = hashlib.sha256(Path(__file__).read_bytes().replace(b"\r\n", b"\n")).hexdigest()
    return hashlib.sha256(("%s %s %s %s %s" % (RECIPE_VERSION, BOX3D_COMMIT, patch_sha, tag, me)).encode()).hexdigest()[:16]


def ensure(cc=None, cxx=None, clean=False):
    """Builds Box3D for this platform if needed and returns its description (box3d.json)."""
    arch = common.host_arch()
    tag = common.platform_tag()
    out = ROOT / "build" / tag
    work = ROOT / "work" / tag
    desc_path = out / "box3d.json"
    lib_name = "box3d.lib" if IS_WINDOWS else "libbox3d.a"
    if clean:
        for p in (SRC, SRC_STAMP, out, work):
            if p.is_dir():
                shutil.rmtree(p)
            elif p.exists():
                p.unlink()

    patch_sha = hashlib.sha256(patch_bytes()).hexdigest()
    fkey = fast_key(tag, patch_sha)
    desc = None
    if desc_path.exists():
        try:
            desc = json.loads(desc_path.read_text())
        except ValueError:
            desc = None
    if desc and desc.get("fast_key") == fkey and (out / "lib" / lib_name).exists():
        return desc

    t0 = time.time()
    common.ensure_msvc_env()
    cc, cxx = pick_compilers(cc, cxx)
    for tool in ("cmake", "ninja"):
        if not common.which(tool):
            raise SystemExit("box3d: %s not found on PATH (ninja: `python -m pip install ninja`)" % tool)
    cfg = cmake_args(cc, cxx, out, arch)
    compiler = compiler_version(cc)
    ensure_source(patch_sha)
    for p in (out, work):
        if p.exists():
            shutil.rmtree(p)
    work.mkdir(parents=True)
    log("box3d: building %s with %s" % (tag, compiler))
    run(["cmake", "-S", SRC, "-B", work] + cfg, quiet=True)
    run(["cmake", "--build", work, "--target", "box3d"], quiet=True)
    n = verify_flags(work)
    run(["cmake", "--install", work], quiet=True)
    lib = out / "lib" / lib_name
    if not lib.exists():
        raise SystemExit("box3d: expected %s after install" % lib)
    desc = {
        "fast_key": fkey,
        "platform": tag,
        "commit": BOX3D_COMMIT,
        "patch_sha256": patch_sha,
        "compiler": compiler,
        "cmake_args": cfg,
        "verified_sources": n,
        "dir": out.as_posix(),
        "include_dir": (out / "include").as_posix(),
        "lib": lib.as_posix(),
        "msvc_runtime": "MT" if IS_WINDOWS else None,
    }
    desc_path.write_text(json.dumps(desc, indent=2) + "\n")
    log("box3d: built %s in %.1fs; flags verified on %d sources" % (tag, time.time() - t0, n))
    return desc


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cc", help="C compiler (default clang, or clang-cl on Windows)")
    ap.add_argument("--cxx", help="C++ compiler (default clang++, or clang-cl on Windows)")
    ap.add_argument("--clean", action="store_true", help="delete the checkout and this platform's build first")
    ap.add_argument("--json", action="store_true", help="print the build description as one JSON line on stdout")
    args = ap.parse_args()
    desc = ensure(args.cc, args.cxx, args.clean)
    log("box3d: %s up to date: %s" % (desc["platform"], desc["lib"]))
    print(json.dumps(desc) if args.json else desc["dir"])


if __name__ == "__main__":
    main()
