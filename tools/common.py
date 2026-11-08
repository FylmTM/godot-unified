"""Shared helpers for the tools/ scripts (Python 3.9+, stdlib only)."""

import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
IS_WINDOWS = os.name == "nt"
IS_MACOS = sys.platform == "darwin"
EXE = ".exe" if IS_WINDOWS else ""

_ARCH_ALIASES = {
    "x86_64": "x64", "amd64": "x64", "x64": "x64",
    "arm64": "arm64", "aarch64": "arm64",
}


def host_os():
    if IS_WINDOWS:
        return "windows"
    if IS_MACOS:
        return "macos"
    if sys.platform.startswith("linux"):
        return "linux"
    raise SystemExit("unsupported OS: " + sys.platform)


def norm_arch(arch):
    a = _ARCH_ALIASES.get(arch.lower())
    if a is None:
        raise SystemExit("unsupported architecture: " + arch)
    return a


def host_arch():
    machine = platform.machine()
    if IS_MACOS and machine == "x86_64":
        # A Python running under Rosetta reports x86_64; the hardware may still be arm64.
        try:
            out = subprocess.run(["sysctl", "-n", "hw.optional.arm64"], capture_output=True, text=True)
            if out.stdout.strip() == "1":
                return "arm64"
        except OSError:
            pass
    if IS_WINDOWS:
        machine = os.environ.get("PROCESSOR_ARCHITEW6432") or os.environ.get("PROCESSOR_ARCHITECTURE") or machine
    return norm_arch(machine)


def platform_tag(arch=None):
    """e.g. macos-arm64, macos-x64, linux-x64, windows-x64."""
    return "%s-%s" % (host_os(), norm_arch(arch) if arch else host_arch())


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def which(name):
    return shutil.which(name)


GODOT_VERSION = "4.7.2"


def find_godot():
    """The Godot editor binary: $GODOT, `godot` on PATH, the CI download in .toolchains/godot/, then the usual
    macOS install places (standard build, not .NET)."""
    import glob
    if os.environ.get("GODOT"):
        return os.environ["GODOT"]
    for c in (which("godot"), REPO / ".toolchains" / "godot" / ("godot" + EXE)):
        if c and Path(c).is_file():
            return str(c)
    for pat in ("/Applications/Godot*.app", os.path.expanduser("~/tools/godot/Godot*.app")):
        for app in sorted(glob.glob(pat), key=lambda a: ("mono" in a, a)):
            exe = Path(app) / "Contents" / "MacOS" / "Godot"
            if exe.exists() and "mono" not in app:
                return str(exe)
    raise SystemExit("no Godot %s found: set GODOT=/path/to/godot (standard build, not .NET)" % GODOT_VERSION)


def lib_name(stem):
    """Shared library file name on this OS: libX.dylib, libX.so, X.dll."""
    if IS_WINDOWS:
        return stem + ".dll"
    return "lib%s.%s" % (stem, "dylib" if IS_MACOS else "so")


# --- MSVC environment (Windows) -------------------------------------------------------------------

def _vswhere():
    pf86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    p = Path(pf86) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
    return p if p.exists() else None


def vs_install_path():
    vswhere = _vswhere()
    if not vswhere:
        return None
    out = subprocess.run(
        [str(vswhere), "-latest", "-products", "*", "-requires",
         "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"],
        capture_output=True, text=True)
    path = out.stdout.strip().splitlines()
    return Path(path[0]) if path else None


def ensure_msvc_env(arch="x64"):
    """On Windows, import the vcvarsall.bat environment into os.environ unless a developer shell
    (INCLUDE/LIB set, e.g. by ilammy/msvc-dev-cmd in CI) is already active. No-op elsewhere."""
    if not IS_WINDOWS or (os.environ.get("INCLUDE") and os.environ.get("LIB")):
        return
    vs = vs_install_path()
    if not vs:
        log("warning: Visual Studio with C++ tools not found via vswhere; continuing without MSVC env")
        return
    vcvars = vs / "VC" / "Auxiliary" / "Build" / "vcvarsall.bat"
    out = subprocess.run('cmd /s /c ""%s" %s >nul && set"' % (vcvars, arch),
                         capture_output=True, text=True, shell=True)
    if out.returncode != 0:
        log("warning: vcvarsall.bat failed: " + out.stderr.strip())
        return
    for line in out.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            os.environ[k] = v
    log("MSVC environment loaded from " + str(vcvars))


def find_clang_cl():
    """clang-cl on PATH, then the standalone LLVM install, then Visual Studio's bundled LLVM."""
    p = which("clang-cl")
    if p:
        return p
    candidates = [Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "LLVM" / "bin" / "clang-cl.exe"]
    vs = vs_install_path()
    if vs:
        candidates.append(vs / "VC" / "Tools" / "Llvm" / "x64" / "bin" / "clang-cl.exe")
    for c in candidates:
        if c.exists():
            return str(c)
    return None
