#!/usr/bin/env python3
"""Build a playable game release: extension, Godot export, signing, zip, smoke test (Python 3.9+, stdlib only).

    python tools/release.py build <game_dir> [--version V] [--embed-env A,B] [--no-smoke]
    python tools/release.py notes <game_dir> --tag TAG         # prerelease notes (markdown) on stdout
    python tools/release.py godot                              # only fetch Godot + this host's export templates

`build` makes the host platform's package (macOS arm64 on a Mac, Windows x64 on Windows) in
<game_dir>/.uni/release/: <game>-<version>-<platform>.zip and its .sha256. The same command runs locally and in
.github/workflows/release.yml (tag builds). Steps, each one fails loudly:
  1. dependencies: Box3D, then tools/imgui.py, tools/eos.py and `dev.py gen` when they exist,
  2. the game's GDExtension in release mode (`dev.py game build <game_dir> release` when dev.py has it, else
     `odin build <game_dir>/simulation/extension -build-mode:dll`), written where the game's .gdextension says;
     with --embed-env, each named environment variable must be set and its value must appear in the library
     (tag builds: the EOS IDs, which testers' machines don't have),
  3. Godot GODOT_VERSION (GODOT env, .toolchains/godot/, ~/tools/godot/, /Applications, else downloaded into
     .toolchains/godot/) and its export templates in Godot's standard folder (only this host's files are pulled
     out of the official .tpz with HTTP range reads: ~120 MB instead of 1.3 GB),
  4. headless import, then `--export-release` with the game's export_presets.cfg ("macOS" / "Windows Desktop");
     any ERROR line fails the step (Godot exits 0 on errors),
  5. macOS: ad-hoc `codesign --force --deep -s -`, verify, `ditto -c -k --keepParent`; Windows: zip,
  6. smoke test: the exported game runs headless for ~5 s (`-- --smoke-test`); it must exit 0, print no error and
     print the extension's `unified: extension initialized` line.
"""

import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path

import common
from common import REPO, IS_WINDOWS, IS_MACOS, log

GODOT_VERSION = "4.7.2"
GODOT_TAG = GODOT_VERSION + "-stable"
GODOT_RELEASES = "https://github.com/godotengine/godot/releases/download/" + GODOT_TAG + "/"
TEMPLATES_TPZ = "Godot_v%s_export_templates.tpz" % GODOT_TAG
TOOLCHAIN = REPO / ".toolchains" / "godot" / GODOT_VERSION

# Per host: the export preset name, the template files the export needs, the editor download and the
# platform keys a .gdextension [libraries] section may use for this host's release library.
HOSTS = {
    "macos": {
        "preset": "macOS",
        "templates": ["macos.zip"],
        "editor_zip": "Godot_v%s_macos.universal.zip" % GODOT_TAG,
        "editor_exe": "Godot.app/Contents/MacOS/Godot",
        "lib_keys": ["macos.release", "macos.arm64", "macos"],
        "platform": "macos-arm64",
    },
    "windows": {
        "preset": "Windows Desktop",
        # Godot checks for the debug template too, even for a release export.
        "templates": ["windows_release_x86_64.exe", "windows_debug_x86_64.exe"],
        "editor_zip": "Godot_v%s_win64.exe.zip" % GODOT_TAG,
        "editor_exe": "Godot_v%s_win64_console.exe" % GODOT_TAG,
        "lib_keys": ["windows.release.x86_64", "windows.x86_64", "windows.release", "windows"],
        "platform": "windows-x64",
    },
}

MARKER = "unified: extension initialized"
ERROR_RE = re.compile(r"^\s*(USER )?(SCRIPT )?ERROR\b|Parse Error|Can't open dynamic library|"
                      r"GDExtension dynamic library not found|Failed loading resource")
SMOKE_FRAMES = 300  # at --max-fps 60: ~5 s
IMPORT_TIMEOUT = 600
EXPORT_TIMEOUT = 600
SMOKE_TIMEOUT = 90


def host():
    h = common.host_os()
    if h not in HOSTS:
        raise SystemExit("release: game builds are made on macOS and Windows only (this is %s)" % h)
    if h == "macos" and common.host_arch() != "arm64":
        raise SystemExit("release: macOS builds are arm64 and need an Apple Silicon host")
    return HOSTS[h]


def step(name):
    log("release: == %s" % name)
    return time.time()


def run(cmd, cwd=None, timeout=None, env=None):
    cmd = [str(c) for c in cmd]
    log("+ " + " ".join(cmd))
    r = subprocess.run(cmd, cwd=str(cwd) if cwd else None, timeout=timeout, env=env)
    if r.returncode != 0:
        raise SystemExit("release: failed (exit %d): %s" % (r.returncode, " ".join(cmd)))


# --- downloads --------------------------------------------------------------------------------------------------

class HttpRangeFile(io.RawIOBase):
    """A read-only, seekable view of a remote file over HTTP range requests, for zipfile. Sequential reads
    stay on one open-ended response, so pulling one member out costs a few requests, not one per chunk."""

    def __init__(self, url):
        super().__init__()
        r = urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=60)
        self.url = r.geturl()  # after redirects
        self.size = int(r.headers["Content-Length"])
        self.pos = 0
        self.resp = None
        self.resp_pos = -1
        self.fetched = 0

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, off, whence=0):
        self.pos = {0: off, 1: self.pos + off, 2: self.size + off}[whence]
        return self.pos

    def readinto(self, b):
        n = min(len(b), self.size - self.pos)
        if n <= 0:
            return 0
        if self.resp is None or self.resp_pos != self.pos:
            if self.resp is not None:
                self.resp.close()
            req = urllib.request.Request(self.url, headers={"Range": "bytes=%d-" % self.pos})
            self.resp = urllib.request.urlopen(req, timeout=120)
            if self.resp.status != 206:
                raise SystemExit("release: %s does not support range requests" % self.url)
            self.resp_pos = self.pos
        got = 0
        view = memoryview(b)
        while got < n:
            k = self.resp.readinto(view[got:n])
            if not k:
                break
            got += k
        self.pos += got
        self.resp_pos = self.pos
        self.fetched += got
        return got

    def close(self):
        if self.resp is not None:
            self.resp.close()
            self.resp = None
        super().close()


def download(url, dest):
    log("release: downloading " + url)
    tmp = dest.with_name(dest.name + ".part")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)
    os.replace(tmp, dest)


# --- Godot and export templates ---------------------------------------------------------------------------------

def godot_version(exe):
    try:
        out = subprocess.run([str(exe), "--version"], capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.strip().splitlines()[-1] if out.strip() else ""


def find_godot(h):
    """GODOT env, our toolchain cache, the developer's usual places; else download the official editor."""
    want = GODOT_VERSION + ".stable.official"
    cands = []
    if os.environ.get("GODOT"):
        cands.append(Path(os.environ["GODOT"]))
    cands.append(TOOLCHAIN / h["editor_exe"])
    if IS_MACOS:
        # The standard build, not .NET (mono).
        cands += [Path.home() / "tools" / "godot" / ("Godot_v%s.app" % GODOT_VERSION) / "Contents/MacOS/Godot",
                  Path("/Applications/Godot.app/Contents/MacOS/Godot")]
    for c in cands:
        if c.is_file():
            v = godot_version(c)
            if v.startswith(want):
                return c
            log("release: skipping %s (version %r, want %s)" % (c, v, want))
    zpath = TOOLCHAIN / h["editor_zip"]
    download(GODOT_RELEASES + h["editor_zip"], zpath)
    if IS_MACOS:
        # ditto keeps the app's symlinks and permissions (zipfile would not).
        run(["ditto", "-x", "-k", zpath, TOOLCHAIN])
    else:
        with zipfile.ZipFile(zpath) as z:
            z.extractall(TOOLCHAIN)
    zpath.unlink()
    exe = TOOLCHAIN / h["editor_exe"]
    v = godot_version(exe)
    if not v.startswith(want):
        raise SystemExit("release: downloaded Godot reports %r, want %s" % (v, want))
    return exe


def templates_dir():
    """Godot's standard export template folder for this version."""
    name = GODOT_VERSION + ".stable"
    if IS_WINDOWS:
        return Path(os.environ["APPDATA"]) / "Godot" / "export_templates" / name
    if IS_MACOS:
        return Path.home() / "Library" / "Application Support" / "Godot" / "export_templates" / name
    return Path.home() / ".local" / "share" / "godot" / "export_templates" / name


def ensure_templates(h):
    d = templates_dir()
    need = [n for n in h["templates"] + ["version.txt"] if not (d / n).is_file()]
    if not need:
        log("release: export templates in %s" % d)
        return d
    d.mkdir(parents=True, exist_ok=True)
    local = TOOLCHAIN.parent / TEMPLATES_TPZ
    src = str(local) if local.is_file() else None
    t0 = time.time()
    if src:
        log("release: export templates from %s" % src)
        f = open(src, "rb")
    else:
        url = GODOT_RELEASES + TEMPLATES_TPZ
        log("release: export templates %s from %s (range reads)" % (", ".join(need), url))
        f = HttpRangeFile(url)
    with f, zipfile.ZipFile(f) as z:
        for n in need:
            tmp = d / (n + ".part")
            with z.open("templates/" + n) as zf, open(tmp, "wb") as out:
                shutil.copyfileobj(zf, out, 1 << 20)
            os.replace(tmp, d / n)
    if (d / "version.txt").read_text().strip() != GODOT_VERSION + ".stable":
        raise SystemExit("release: unexpected templates version in %s" % d)
    fetched = getattr(f, "fetched", 0)
    log("release: templates ready in %.1fs%s" % (time.time() - t0, " (%d MB fetched)" % (fetched >> 20)
                                                  if fetched else ""))
    return d


# --- the game ---------------------------------------------------------------------------------------------------

def read_cfg_section(path, section):
    """key -> value (quotes stripped) of one section of a Godot ConfigFile (.gdextension, project.godot)."""
    out, cur = {}, None
    for line in path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith(";"):
            continue
        if s.startswith("["):
            cur = s.strip("[]")
            continue
        if cur == section and "=" in s:
            k, v = s.split("=", 1)
            out[k.strip()] = v.strip().strip('"')
    return out


def gdextensions(game):
    skip = {".godot", ".uni"}
    return sorted(p for p in game.rglob("*.gdextension") if not skip & set(p.relative_to(game).parts))


def res_path(game, res):
    if not res.startswith("res://"):
        raise SystemExit("release: library path %r is not a res:// path" % res)
    return game / res[len("res://"):]


def release_libraries(game, h):
    """Every GDExtension library this host's export ships: (gdextension file, absolute library path)."""
    libs = []
    for ext in gdextensions(game):
        entries = read_cfg_section(ext, "libraries")
        key = next((k for k in h["lib_keys"] if k in entries), None)
        if key is None:
            raise SystemExit("release: %s has no library for this platform (keys tried: %s)"
                             % (ext, ", ".join(h["lib_keys"])))
        libs.append((ext, res_path(game, entries[key])))
    return libs


def release_dependencies(game, h):
    """Files the .gdextension [dependencies] sections ship with this host's export (e.g. the EOS SDK)."""
    deps = []
    for ext in gdextensions(game):
        entries = read_cfg_section(ext, "dependencies")
        key = next((k for k in h["lib_keys"] if k in entries), None)
        if key is not None:
            deps += [res_path(game, r) for r in re.findall(r'"(res://[^"]+)"', entries[key])]
    return deps


def eos_runtime_library():
    """The EOS SDK runtime library for this host, from tools/eos.py (None when the repo has no EOS)."""
    if not (REPO / "tools" / "eos.py").is_file():
        return None
    out = subprocess.run([sys.executable, str(REPO / "tools" / "eos.py"), "--json"], capture_output=True, text=True,
                         cwd=str(REPO))
    try:
        return Path(json.loads(out.stdout.strip().splitlines()[-1])["lib"])
    except (ValueError, KeyError, IndexError):
        raise SystemExit("release: `tools/eos.py --json` failed:\n" + out.stdout + out.stderr)


def dev_doc():
    sys.path.insert(0, str(REPO / "tools"))
    import dev
    return dev.__doc__ or ""


def build_dependencies():
    t = step("dependencies")
    import box3d
    box3d.ensure()
    for tool in ("imgui.py", "eos.py"):
        if (REPO / "tools" / tool).is_file():
            run([sys.executable, REPO / "tools" / tool], cwd=REPO)
    if "tools/dev.py gen" in dev_doc():
        run([sys.executable, REPO / "tools" / "dev.py", "gen"], cwd=REPO)
    log("release: dependencies in %.1fs" % (time.time() - t))


def build_extension(game, h):
    t = step("game extension (release)")
    libs = release_libraries(game, h)
    if not libs:
        raise SystemExit("release: %s has no .gdextension" % game)
    if "tools/dev.py game" in dev_doc():
        run([sys.executable, REPO / "tools" / "dev.py", "game", "build", game, "release"], cwd=REPO)
    else:
        if len(libs) != 1:
            raise SystemExit("release: the fallback build handles one .gdextension, %s has %d" % (game, len(libs)))
        out = libs[0][1]
        out.parent.mkdir(parents=True, exist_ok=True)
        if out.is_symlink():
            out.unlink()
        # No EOS_* defines here: odin rejects unused ones, and the game build reads them from the environment
        # (which also keeps the secrets off command lines and logs).
        run(["odin", "build", game / "simulation" / "extension", "-build-mode:dll", "-out:" + out.as_posix(),
             "-collection:unified=" + (REPO / "src").as_posix(), "-o:speed", "-vet", "-strict-style", "-vet-tabs",
             "-warnings-as-errors"], cwd=REPO)
    for ext, lib in libs:
        if not lib.is_file():
            raise SystemExit("release: %s names %s, which the build did not produce" % (ext.name, lib))
    log("release: extension in %.1fs" % (time.time() - t))
    return libs


def write_extension_list(game):
    """Godot loads the extensions listed here; the editor writes it on its first scan, which a fresh checkout
    hasn't had. Without it the import can't see the extension's classes."""
    p = game / ".godot" / "extension_list.cfg"
    p.parent.mkdir(parents=True, exist_ok=True)
    want = "".join("res://%s\n" % e.relative_to(game).as_posix() for e in gdextensions(game))
    if not p.exists() or p.read_text() != want:
        p.write_text(want)


def scan(text, allow=()):
    errs = []
    for line in text.splitlines():
        if ERROR_RE.search(line) and not any(re.search(a, line) for a in allow):
            errs.append(line.strip())
    return errs


def godot_step(godot, game, args, what, timeout):
    t = step(what)
    cmd = [str(godot), "--headless", "--path", str(game)] + args
    log("+ " + " ".join(cmd))
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        raise SystemExit("release: %s timed out after %d s" % (what, timeout))
    out = r.stdout + r.stderr
    errs = scan(out)
    if r.returncode != 0 or errs:
        sys.stderr.write(out[-20000:])
        raise SystemExit("release: %s failed (exit %d, %d error line(s)): %s"
                         % (what, r.returncode, len(errs), "; ".join(errs[:5])))
    log("release: %s in %.1fs" % (what, time.time() - t))
    return out


def preset_names(game):
    p = game / "export_presets.cfg"
    if not p.is_file():
        raise SystemExit("release: %s has no export_presets.cfg" % game)
    return re.findall(r'^name="([^"]*)"', p.read_text(encoding="utf-8"), re.M)


def export(godot, game, h, name):
    if h["preset"] not in preset_names(game):
        raise SystemExit("release: export_presets.cfg has no %r preset" % h["preset"])
    out_dir = game / ".uni" / "export" / h["platform"]
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True)
    target = out_dir / (name + (".app" if IS_MACOS else ".exe"))
    godot_step(godot, game, ["--export-release", h["preset"], str(target)], "export (%s)" % h["preset"],
               EXPORT_TIMEOUT)
    if not target.exists():
        raise SystemExit("release: the export produced no %s" % target)
    return target


def check_payload(target, files):
    """Every library the game needs made it into the export, as a real file (not a link into .uni/)."""
    for lib in files:
        found = list(target.rglob(lib.name) if target.is_dir() else target.parent.rglob(lib.name))
        if not found:
            raise SystemExit("release: %s is missing from the export" % lib.name)
        if any(p.is_symlink() for p in found):
            raise SystemExit("release: %s is a symlink in the export" % lib.name)
        if IS_MACOS and lib.suffix == ".dylib" and "arm64" not in lipo_archs(found[0]):
            raise SystemExit("release: %s has architectures %s, want arm64" % (lib.name, lipo_archs(found[0])))


def lipo_archs(path):
    return subprocess.run(["lipo", "-archs", str(path)], capture_output=True, text=True).stdout.split()


def thin_to_arm64(app):
    """Godot's macOS template is universal only (its presets can't pick arm64 alone), but our extension is
    arm64: drop the x86_64 slice so an Intel Mac refuses the app up front instead of failing to load the
    extension, and the download shrinks by ~half the engine."""
    for exe in (app / "Contents" / "MacOS").iterdir():
        if len(lipo_archs(exe)) > 1:
            run(["lipo", exe, "-thin", "arm64", "-output", exe])


def sign_and_zip(target, zip_path):
    t = step("sign + zip")
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    if zip_path.exists():
        zip_path.unlink()
    if IS_MACOS:
        thin_to_arm64(target)
        run(["codesign", "--force", "--deep", "-s", "-", target])
        run(["codesign", "--verify", "--deep", "--strict", target])
        run(["ditto", "-c", "-k", "--keepParent", target, zip_path])
    else:
        # The exe, its .pck and the libraries, inside one folder named like the zip.
        top = zip_path.stem
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            for p in sorted(target.parent.rglob("*")):
                if p.is_file():
                    z.write(p, "%s/%s" % (top, p.relative_to(target.parent).as_posix()))
    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    zip_path.with_name(zip_path.name + ".sha256").write_text("%s  %s\n" % (digest, zip_path.name))
    log("release: %s (%.1f MB) in %.1fs" % (zip_path.name, zip_path.stat().st_size / 1e6, time.time() - t))


def smoke(zip_path, name):
    """Unpacks the zip (what a tester gets) and runs the game headless for a few seconds."""
    t = step("smoke test")
    with tempfile.TemporaryDirectory(prefix="unified-smoke-") as tmp:
        tmp = Path(tmp)
        if IS_MACOS:
            run(["ditto", "-x", "-k", zip_path, tmp])
            app = tmp / (name + ".app")
            exe = next((app / "Contents" / "MacOS").iterdir())
        else:
            with zipfile.ZipFile(zip_path) as z:
                z.extractall(tmp)
            exe = tmp / zip_path.stem / (name + ".exe")
        log_file = tmp / "smoke.log"
        cmd = [str(exe), "--headless", "--log-file", str(log_file), "--max-fps", "60",
               "--quit-after", str(SMOKE_FRAMES), "--", "--smoke-test"]
        log("+ " + " ".join(cmd))
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                               timeout=SMOKE_TIMEOUT, cwd=str(tmp))
        except subprocess.TimeoutExpired:
            raise SystemExit("release: smoke test did not quit within %d s" % SMOKE_TIMEOUT)
        out = r.stdout + r.stderr
        if log_file.is_file():
            out += "\n" + log_file.read_text(encoding="utf-8", errors="replace")
        errs = scan(out)
        problems = []
        if r.returncode != 0:
            problems.append("exit %d" % r.returncode)
        if errs:
            problems.append("%d error line(s): %s" % (len(errs), "; ".join(errs[:5])))
        if MARKER not in out:
            problems.append("no %r line (the extension did not load)" % MARKER)
        if problems:
            sys.stderr.write(out[-20000:])
            raise SystemExit("release: smoke test failed: " + ", ".join(problems))
    log("release: smoke test ok (%d frames, exit 0, no errors) in %.1fs" % (SMOKE_FRAMES, time.time() - t))


def default_version():
    try:
        sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
                             cwd=str(REPO)).stdout.strip()
    except OSError:
        sha = ""
    return "dev-" + (sha or "local")


def check_embedded(libs, names):
    """Each value is compiled into one of the libraries (found as bytes; the values are never printed)."""
    blobs = [lib.read_bytes() for _, lib in libs]
    absent = [k for k in names if not any(os.environ[k].encode() in b for b in blobs)]
    if absent:
        raise SystemExit("release: the extension does not contain the value of %s (not passed as -define?)"
                         % ", ".join(absent))
    log("release: %s compiled into the extension" % ", ".join(names))


def cmd_build(game, version, embed_env, smoke_test):
    t0 = time.time()
    h = host()
    game = game.resolve()
    name = game.name
    missing = [k for k in embed_env if not os.environ.get(k)]
    if missing:
        raise SystemExit("release: missing environment (repo secrets?): " + ", ".join(missing))
    build_dependencies()
    libs = build_extension(game, h)
    if embed_env:
        check_embedded(libs, embed_env)
    t = step("Godot + export templates")
    godot = find_godot(h)
    ensure_templates(h)
    log("release: Godot %s (%s) in %.1fs" % (godot_version(godot), godot, time.time() - t))
    write_extension_list(game)
    godot_step(godot, game, ["--import"], "import", IMPORT_TIMEOUT)
    target = export(godot, game, h, name)
    files = [lib for _, lib in libs] + release_dependencies(game, h)
    if any(k.startswith("EOS_") for k in embed_env):
        eos_lib = eos_runtime_library()
        if eos_lib is not None and eos_lib.name not in {f.name for f in files}:
            files.append(eos_lib)
    check_payload(target, files)
    zip_path = game / ".uni" / "release" / ("%s-%s-%s.zip" % (name, version, h["platform"]))
    sign_and_zip(target, zip_path)
    if smoke_test:
        smoke(zip_path, name)
    log("release: done in %.1fs -> %s" % (time.time() - t0, zip_path))
    print(zip_path)


NOTES = """\
Test build of **{name} {version}** (commit `{commit}`). Unsigned prerelease for playtesting only.

## Download

- **macOS** (Apple Silicon): `{name}-{version}-macos-arm64.zip`
- **Windows** (x64): `{name}-{version}-windows-x64.zip`

`SHA256SUMS.txt` has the checksums (`shasum -a 256 -c SHA256SUMS.txt` / `certutil -hashfile <zip> SHA256`).

## Opening it

- **macOS:** unzip and open `{name}.app`. The app is ad-hoc signed, not notarized, so macOS blocks the first
  launch: click **Done**, open System Settings → Privacy & Security, scroll down to the message about `{name}`,
  click **Open Anyway** and confirm. (On macOS 14 and older, right-click the app → **Open** → **Open** also works.)
  Last resort, in Terminal: `xattr -dr com.apple.quarantine {name}.app`.
- **Windows:** unzip the whole folder, run `{name}.exe`. If SmartScreen says "Windows protected your PC", click
  **More info** → **Run anyway**.
{game_notes}"""


def cmd_notes(game, tag):
    game = game.resolve()
    name = game.name
    version = tag.split("-v", 1)[1] if "-v" in tag else tag
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
                            cwd=str(REPO)).stdout.strip()
    extra = game / "RELEASE_NOTES.md"
    game_notes = ("\n" + extra.read_text(encoding="utf-8")) if extra.is_file() else ""
    print(NOTES.format(name=name, version=version, commit=commit, game_notes=game_notes), end="")


def main():
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if a else 2

    def opt(flag, default=None):
        return a[a.index(flag) + 1] if flag in a else default

    if a[0] == "build" and len(a) >= 2:
        req = [k for k in (opt("--embed-env") or "").split(",") if k]
        cmd_build(Path(a[1]), opt("--version") or default_version(), req, "--no-smoke" not in a)
    elif a[0] == "notes" and len(a) >= 2 and "--tag" in a:
        cmd_notes(Path(a[1]), opt("--tag"))
    elif a == ["godot"]:
        h = host()
        log("release: %s" % find_godot(h))
        ensure_templates(h)
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
