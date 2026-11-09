#!/usr/bin/env python3
"""Fetch and build Dear ImGui (docking) + dear_bindings' C API as one static library, for src/imgui.

    python tools/imgui.py                  # host build -> third_party/imgui/build/<platform>/libimgui.a (imgui.lib)
    python tools/imgui.py --arch x86_64    # macOS only: x86_64 build (macos-x64)
    python tools/imgui.py --clean          # wipe the sources and this platform's build first

Pinned: Dear ImGui v1.92.9b-docking (git tag), dear_bindings v0.21's generated C API for that tag (release
files, so no Python generator step), matching the vendored odin-imgui declarations in src/imgui/. Six C++ files
compile in parallel (~2.5 s on an M4 Pro); later runs are a ~1 ms stamp check. Same compilers as Box3D:
clang++ on macOS and Linux, clang-cl + llvm-lib on Windows (static CRT, /MT, like Odin).

Other tools import this module and call ensure().
"""

import argparse
import concurrent.futures
import hashlib
import shutil
import subprocess
import sys
import time
from pathlib import Path

import common
from common import REPO, IS_WINDOWS, IS_MACOS, log

IMGUI_URL = "https://github.com/ocornut/imgui.git"
IMGUI_TAG = "v1.92.9b-docking"
IMGUI_COMMIT = "b48d1afbe8ee8b238e2961dc363a949dd7304e23"  # what IMGUI_TAG points at; checked after the clone
DB_TAG = "DearBindings_v0.21_ImGui_v1.92.9b-docking"
DB_URL = "https://github.com/dearimgui/dear_bindings/releases/download/%s/%s"
DB_FILES = {  # dear_bindings release files -> SHA-256 (they compile into shipped builds, so they are pinned)
    "dcimgui_nodefaultargfunctions.cpp": "c28edce9d2a73dfb59af802f5ebe5281a17168b54ed34d4e2f3827208ae9059a",
    "dcimgui_nodefaultargfunctions.h": "e1d5b97decc24ca21cae911eb1c956797877b81bd9049d0c218964adc1871b50",
}
RECIPE_VERSION = 1
MACOS_DEPLOYMENT_TARGET = "11.0"

ROOT = REPO / "third_party" / "imgui"
SRC = ROOT / "src"
SOURCES = ["imgui.cpp", "imgui_draw.cpp", "imgui_tables.cpp", "imgui_widgets.cpp", "imgui_demo.cpp",
           "dcimgui/dcimgui_nodefaultargfunctions.cpp"]
DEFINES = ["IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "IMGUI_DISABLE_OBSOLETE_KEYIO"]


def run(cmd, cwd=None):
    r = subprocess.run([str(c) for c in cmd], cwd=str(cwd) if cwd else None, capture_output=True, text=True)
    if r.returncode != 0:
        log((r.stdout + r.stderr).strip())
        raise SystemExit("imgui: command failed (%d): %s" % (r.returncode, " ".join(map(str, cmd))))
    return r


def ensure_source():
    stamp = ROOT / "src.stamp"
    want = "%s %s" % (IMGUI_TAG, DB_TAG)
    if stamp.exists() and stamp.read_text().strip() == want and (SRC / "imgui.cpp").exists():
        return
    if SRC.exists():
        shutil.rmtree(SRC)
    ROOT.mkdir(parents=True, exist_ok=True)
    log("imgui: fetching Dear ImGui %s" % IMGUI_TAG)
    run(["git", "-c", "core.autocrlf=false", "-c", "advice.detachedHead=false", "clone", "-q", "--depth", "1",
         "--branch", IMGUI_TAG, IMGUI_URL, SRC])
    head = run(["git", "-C", SRC, "rev-parse", "HEAD"]).stdout.strip()
    if head != IMGUI_COMMIT:
        raise SystemExit("imgui: %s is commit %s, pinned %s" % (IMGUI_TAG, head, IMGUI_COMMIT))
    (SRC / "dcimgui").mkdir()
    for f, sha in DB_FILES.items():
        common.download(DB_URL % (DB_TAG, f), SRC / "dcimgui" / f, sha)
    stamp.write_text(want + "\n")


def lib_path(tag):
    return ROOT / "build" / tag / ("imgui.lib" if IS_WINDOWS else "libimgui.a")


def compiler(arch):
    if IS_WINDOWS:
        common.ensure_msvc_env()
        cl = common.find_clang_cl()
        if not cl:
            raise SystemExit("imgui: clang-cl not found (install LLVM or VS's C++ Clang tools)")
        lib = Path(cl).with_name("llvm-lib.exe")
        return [cl, "/nologo", "/c", "/O2", "/MT", "/std:c++14", "/GR-", "/EHs-c-", "/DNDEBUG"] + \
               ["/D" + d for d in DEFINES] + ["/I" + str(SRC)], (str(lib) if lib.exists() else "lib.exe")
    cxx = shutil.which("clang++") or "c++"
    flags = [cxx, "-c", "-std=c++11", "-O2", "-DNDEBUG", "-fPIC", "-fno-exceptions", "-fno-rtti"] + \
            ["-D" + d for d in DEFINES] + ["-I" + str(SRC)]
    if IS_MACOS:
        flags += ["-arch", "x86_64" if common.norm_arch(arch or common.host_arch()) == "x64" else "arm64",
                  "-mmacosx-version-min=" + MACOS_DEPLOYMENT_TARGET]
    return flags, (shutil.which("llvm-ar") or "ar")


def recipe_key(tag):
    """Bump RECIPE_VERSION when the compiler flags change."""
    return hashlib.sha1(("%d %s %s %s %s" % (RECIPE_VERSION, IMGUI_TAG, DB_TAG, DEFINES, tag)).encode()).hexdigest()


def ensure(arch=None):
    """Builds the static library for this platform (arch: macOS x86_64 for Rosetta) unless it is up to date."""
    tag = common.platform_tag(arch)
    out = lib_path(tag)
    stamp = out.parent / "imgui.stamp"
    if out.exists() and stamp.exists() and stamp.read_text().strip() == recipe_key(tag):
        return out
    t0 = time.time()
    ensure_source()
    flags, ar = compiler(arch)
    obj_dir = ROOT / "obj" / tag
    obj_dir.mkdir(parents=True, exist_ok=True)
    objs = []

    def compile_one(src):
        o = obj_dir / (Path(src).stem + (".obj" if IS_WINDOWS else ".o"))
        out_flag = ["/Fo" + str(o)] if IS_WINDOWS else ["-o", str(o)]
        run(flags + [SRC / src] + out_flag)
        return o

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(SOURCES)) as ex:
        objs = list(ex.map(compile_one, SOURCES))
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    if IS_WINDOWS:
        run([ar, "/nologo", "/out:" + str(out)] + objs)
    else:
        run([ar, "rcs", out] + objs)
    stamp.write_text(recipe_key(tag) + "\n")
    log("imgui: built %s in %.1fs" % (out.relative_to(REPO).as_posix(), time.time() - t0))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arch")
    ap.add_argument("--clean", action="store_true")
    a = ap.parse_args()
    if a.clean:
        shutil.rmtree(SRC, ignore_errors=True)
        shutil.rmtree(lib_path(common.platform_tag(a.arch)).parent, ignore_errors=True)
    out = ensure(a.arch)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
