"""Shared helpers for the tools/ scripts (Python 3.9+, stdlib only)."""

import argparse
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
IS_WINDOWS = os.name == "nt"
IS_MACOS = sys.platform == "darwin"
EXE = ".exe" if IS_WINDOWS else ""

# What this run built or fetched for the first time (a dependency build, a download, a Godot import): a run that
# did any of it is cold, so dev.py doesn't hold it to its command's warm-run budget.
COLD = []

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
    if IS_WINDOWS:
        machine = os.environ.get("PROCESSOR_ARCHITEW6432") or os.environ.get("PROCESSOR_ARCHITECTURE") or machine
    return norm_arch(machine)


def platform_tag():
    """This machine's platform, e.g. macos-arm64, linux-x64, windows-x64."""
    return "%s-%s" % (host_os(), host_arch())


class Strict(argparse.ArgumentParser):
    """An argument parser that takes no abbreviations (--tick is not --ticks): unknown arguments are errors."""

    def __init__(self, *args, **kwargs):
        kwargs.setdefault("allow_abbrev", False)
        super().__init__(*args, **kwargs)


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def which(name):
    return shutil.which(name)


# --- downloads ----------------------------------------------------------------------------------------------------

def sha256_file(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_sha256(path, want, what=None):
    """Fails (and deletes `path`) unless its SHA-256 is `want`: every download that ends up in a toolchain or a
    shipped build is pinned by hash."""
    got = sha256_file(path)
    if got != want:
        Path(path).unlink()
        raise SystemExit("%s: SHA-256 mismatch: got %s, pinned %s" % (what or Path(path).name, got, want))


def download(url, dest, sha256):
    """GET `url` into `dest` (atomically), checked against the pinned SHA-256."""
    import urllib.request
    dest = Path(dest)
    log("downloading " + url)
    tmp = dest.with_name(dest.name + ".part")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=600) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)
    check_sha256(tmp, sha256, dest.name)
    os.replace(str(tmp), str(dest))
    return dest


def redact(args):
    """Command-line args for logging: the values of -define:EOS_* (credentials) replaced."""
    return [a.split("=", 1)[0] + "=***" if str(a).startswith("-define:EOS_") else str(a) for a in args]


# --- Godot ---------------------------------------------------------------------------------------------------------

GODOT_VERSION = "4.7.2"
GODOT_TAG = GODOT_VERSION + "-stable"
GODOT_RELEASES = "https://github.com/godotengine/godot/releases/download/" + GODOT_TAG + "/"
GODOT_DIR = REPO / ".toolchains" / "godot" / GODOT_VERSION  # downloaded editors (find_godot(fetch=True))
# Official editor builds per host OS: (release asset, executable inside it, SHA-256 of the asset). The hashes are
# GitHub's asset digests for the 4.7.2-stable release; bump them with GODOT_VERSION.
GODOT_EDITORS = {
    "macos": ("Godot_v%s_macos.universal.zip" % GODOT_TAG, "Godot.app/Contents/MacOS/Godot",
              "c58a24e31d720be9d62f60cb5627c4e695fb72f21b0cfe1bc9ccaa9a3b3ba63e"),
    "windows": ("Godot_v%s_win64.exe.zip" % GODOT_TAG, "Godot_v%s_win64_console.exe" % GODOT_TAG,
                "731980f9608d61333e5baf54a2ef17210acc7a538446c0cb9969f002aca1e953"),
    "linux": ("Godot_v%s_linux.x86_64.zip" % GODOT_TAG, "Godot_v%s_linux.x86_64" % GODOT_TAG,
              "cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4"),
}


def godot_candidates():
    """Where a Godot editor may be, in order: $GODOT, `godot` on PATH, the download in .toolchains/godot/<version>/,
    then (macOS) ~/tools/godot/Godot_v<version>.app and /Applications/Godot*.app. Standard builds only, not .NET."""
    import glob
    cands = []
    if os.environ.get("GODOT"):
        cands.append(Path(os.environ["GODOT"]))
    if which("godot"):
        cands.append(Path(which("godot")))
    cands.append(GODOT_DIR / GODOT_EDITORS[host_os()][1])
    if IS_MACOS:
        cands.append(Path.home() / "tools" / "godot" / ("Godot_v%s.app" % GODOT_VERSION) / "Contents/MacOS/Godot")
        for pat in (os.path.expanduser("~/tools/godot/Godot*.app"), "/Applications/Godot*.app"):
            cands += [Path(a) / "Contents/MacOS/Godot" for a in sorted(glob.glob(pat)) if "mono" not in a.lower()]
    seen, out = set(), []
    for c in cands:
        if c.is_file() and c not in seen:
            seen.add(c)
            out.append(c)
    return out


def godot_version(exe):
    try:
        out = subprocess.run([str(exe), "--version"], capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.splitlines()[-1] if out else ""


def find_godot(fetch=False):
    """The Godot editor binary (godot_candidates()). download=True (release builds, CI) also requires the exact
    official GODOT_VERSION and downloads the hash-pinned editor into GODOT_DIR when no candidate has it."""
    cands = godot_candidates()
    if not fetch:
        if not cands:
            raise SystemExit("no Godot %s found: set GODOT=/path/to/godot (standard build, not .NET)" % GODOT_VERSION)
        return str(cands[0])
    want = GODOT_VERSION + ".stable.official"
    for c in cands:
        v = godot_version(c)
        if v.startswith(want):
            return str(c)
        log("godot: skipping %s (version %r, want %s)" % (c, v, want))
    asset, exe_rel, sha = GODOT_EDITORS[host_os()]
    zpath = download(GODOT_RELEASES + asset, GODOT_DIR / asset, sha)
    COLD.append("Godot download")
    if IS_MACOS:
        # ditto keeps the app's symlinks and permissions (zipfile would not).
        subprocess.run(["ditto", "-x", "-k", str(zpath), str(GODOT_DIR)], check=True)
    else:
        import zipfile
        with zipfile.ZipFile(zpath) as z:
            z.extractall(GODOT_DIR)
    zpath.unlink()
    exe = GODOT_DIR / exe_rel
    if not IS_WINDOWS:
        exe.chmod(0o755)
    v = godot_version(exe)
    if not v.startswith(want):
        raise SystemExit("godot: the downloaded editor reports %r, want %s" % (v, want))
    return str(exe)


def run_godot(args, timeout, cwd=None):
    """Runs Godot with a timeout (a headless Godot can hang, e.g. when an extension fails to load) and returns the
    CompletedProcess with text output. On a timeout it prints what Godot wrote and exits."""
    cmd = [find_godot()] + [str(a) for a in args]
    log("+ " + " ".join(cmd))
    try:
        # stdin closed: with -d, a script error must end the run, not wait at the debugger prompt
        return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                              timeout=timeout, cwd=None if cwd is None else str(cwd), stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        sys.stdout.write(out[-8000:])
        raise SystemExit("godot: timed out after %ds: %s" % (timeout, " ".join(str(a) for a in args)))


def game_dir(name):
    """A Godot project by path or by game name; it must have a project.godot. A relative path is tried against the
    current directory first (a game outside this repo: `python3 unified/tools/dev.py game build .`), then against
    the repo; a bare name is games/<name>."""
    p = Path(name)
    if not p.is_absolute():
        if (Path.cwd() / name / "project.godot").is_file():
            p = Path.cwd() / name
        elif "/" in name or "\\" in name or (REPO / name / "project.godot").exists():
            p = REPO / name
        else:
            p = REPO / "games" / name
    if not (p / "project.godot").is_file():
        raise SystemExit("no Godot project (project.godot) at %s" % p)
    return p.resolve()


# Feature keys a .gdextension [libraries] section may use for this host's library.
_LIB_KEYS = {
    "macos": ["macos.debug", "macos.release", "macos.arm64", "macos"],
    "windows": ["windows.x86_64", "windows.release.x86_64", "windows.release", "windows"],
    "linux": ["linux.x86_64", "linux"],
}


def gdextensions(proj):
    """The project's .gdextension files (not in .godot/ or .out/)."""
    skip = {".godot", ".out"}
    return sorted(p for p in Path(proj).rglob("*.gdextension") if not skip & set(p.relative_to(proj).parts))


def cfg_section(path, section):
    """key -> value (quotes stripped) of one section of a Godot ConfigFile (.gdextension, project.godot)."""
    out, cur = {}, None
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith(";"):
            continue
        if s.startswith("["):
            cur = s.strip("[]")
        elif cur == section and "=" in s:
            k, v = s.split("=", 1)
            out[k.strip()] = v.strip().strip('"')
    return out


def write_extension_list(proj):
    """Godot loads the GDExtensions listed in .godot/extension_list.cfg, which the editor writes on its first scan.
    Writes it for a fresh checkout, listing only extensions whose library for this host exists: a missing library
    is an error on every run (a game without its library falls back to its mock session). Returns the list."""
    proj = Path(proj)
    listed = []
    for ext in gdextensions(proj):
        libs = cfg_section(ext, "libraries")
        for key in _LIB_KEYS[host_os()]:
            if key in libs and (proj / libs[key].replace("res://", "", 1)).exists():
                listed.append("res://" + ext.relative_to(proj).as_posix())
                break
    path = proj / ".godot" / "extension_list.cfg"
    want = "".join(e + "\n" for e in listed)
    if not path.exists() or path.read_text() != want:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(want)
    return listed


# .csv: Godot imports CSV files as translations by default.
_IMPORTED = {".svg", ".png", ".jpg", ".webp", ".wav", ".ogg", ".mp3", ".glb", ".gltf", ".fbx", ".ttf", ".otf", ".csv"}


def _import_signature(proj):
    """What an import depends on: global class names (class_name lines), new scripts (.uid files), imported assets
    (path + mtime). Editing a script body or a scene needs no import, so the edit loop skips it (~1.5 s). Walks what
    Godot scans: no hidden entries (.godot, .out, .git), no directory holding a .gdignore (a unified submodule)."""
    parts = []
    for root, dirs, files in os.walk(proj):
        dirs[:] = [d for d in dirs if not d.startswith(".") and not os.path.exists(os.path.join(root, d, ".gdignore"))]
        for name in files:
            p = Path(root, name)
            if name.startswith("."):
                continue
            rel = p.relative_to(proj).as_posix()
            if p.suffix == ".gd":
                names = [l.strip() for l in p.read_text(errors="replace").splitlines() if l.startswith("class_name ")]
                parts.append("%s %s %s" % (rel, names, (p.parent / (p.name + ".uid")).exists()))
            elif p.suffix.lower() in _IMPORTED:
                parts.append("%s %d" % (rel, p.stat().st_mtime_ns))
    return "\n".join(sorted(parts))


def ensure_imported(proj):
    """Refreshes Godot's import cache (.godot/) when it is missing or stale, then writes the extension list.
    Returns the extensions listed."""
    proj = Path(proj)
    stamp = proj / ".godot" / "unified_import.sig"
    exts = write_extension_list(proj)  # before the import, so it sees the extension's classes
    sig = _import_signature(proj)
    fresh = (proj / ".godot" / "global_script_class_cache.cfg").exists() and stamp.exists()
    if not fresh or stamp.read_text() != sig:
        t0 = time.time()
        r = run_godot(["--headless", "--path", proj, "--import"], 300)
        if r.returncode != 0:
            sys.stdout.write((r.stdout + r.stderr)[-4000:])
            raise SystemExit("godot: import of %s failed (exit %d)" % (proj, r.returncode))
        stamp.write_text(_import_signature(proj))  # the import may have added .uid files
        COLD.append("Godot import of " + proj.name)
        log("godot: imported %s in %.1fs" % (proj.name, time.time() - t0))
    return exts


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
