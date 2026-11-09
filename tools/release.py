#!/usr/bin/env python3
"""Build a playable game release: extension, Godot export, signing, zip, smoke test (Python 3.9+, stdlib only).

    python tools/release.py build <game_dir> [--version V] [--embed-env A,B] [--no-smoke]   # V: from the tag
    python tools/release.py notes <game_dir> --tag TAG         # prerelease notes (markdown) on stdout
    python tools/release.py godot                              # only fetch Godot + this host's export templates

`build` makes the host platform's package (macOS arm64 on a Mac, Windows x64 on Windows) in
<game_dir>/.out/release/: <game>-v<version>-<platform>.zip (local builds: <game>-dev-<sha>-<platform>.zip, the sha
of the game's own git repository),
which unpacks to one folder of the same name holding the app, and its .sha256. The same command runs locally and in
.github/workflows/release.yml (tag builds). Steps, each one fails loudly:
  1. dependencies: Box3D (when the game imports physics), Dear ImGui, the EOS SDK (when its extension imports
     unified:eos) and the Godot bindings (box3d/imgui/eos.ensure, dev.cmd_gen),
  2. the game's GDExtension in release mode (dev.cmd_game_build), written where the game's .gdextension says;
     with --embed-env, each named environment variable must be set and its value must appear in the library
     (tag builds: the EOS IDs, which testers' machines don't have),
  3. Godot GODOT_VERSION (common.find_godot: the official build, else the hash-pinned download into
     .toolchains/godot/) and its export templates in Godot's standard folder (only this host's files are pulled
     out of the official .tpz with HTTP range reads, ~120 MB instead of 1.3 GB, each checked against its pinned
     SHA-256),
  4. the version: the tag's version (--version; local builds dev-<sha>) is stamped into project.godot
     (application/config/version, which the game shows) and the presets' version keys for the export, then the
     files are restored; the export must carry it (the .pck's project settings, macOS Info.plist) or the build
     fails. The committed files hold a placeholder, so the tag is the only source of a release's version,
  5. headless import, then `--export-release` with the game's export_presets.cfg ("macOS" / "Windows Desktop");
     any ERROR line fails the step (Godot exits 0 on errors),
  6. macOS: ad-hoc `codesign --force --deep -s -`, verify, `ditto -c -k --keepParent` of the folder;
     Windows: zip, the same folder layout,
  7. smoke test: the exported game runs headless for ~5 s (`-- --smoke-test`); it must exit 0, print no error and
     print the extension's `unified: extension initialized` line.
"""

import io
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path

import box3d
import common
import dev
import eos
import imgui
from common import IS_WINDOWS, IS_MACOS, GODOT_VERSION, GODOT_RELEASES, GODOT_TAG, log

TEMPLATES_TPZ = "Godot_v%s_export_templates.tpz" % GODOT_TAG
# SHA-256 of each export template file release.py pulls out of the official .tpz (GODOT_VERSION).
TEMPLATE_SHA256 = {
    "version.txt": "38885c88f75abbc797a1db7559719800279a00cfb9fa8b2e2868a7f6f84bad2e",
    "macos.zip": "88df5e2e6fee99088699be66e6d42e4da4fb0c5619d054297d755a49558a4792",
    "windows_release_x86_64.exe": "d34d36f3be1a6c49c56525ae86469b92e4f417ddf0b43cf00dd80c385c4b0562",
    "windows_debug_x86_64.exe": "51498b72b3a237f882ebd7d1787f06a4bc1eaf0572daab93837adcfd3cfdc107",
}

# Per host: the export preset name, the template files the export needs, the preset's version keys and the
# platform keys a .gdextension [libraries] section may use for this host's release library.
HOSTS = {
    "macos": {
        "preset": "macOS",
        "templates": ["macos.zip"],
        "version_keys": ["application/short_version", "application/version"],
        "lib_keys": ["macos.release", "macos.arm64", "macos"],
        "platform": "macos-arm64",
    },
    "windows": {
        "preset": "Windows Desktop",
        # Godot checks for the debug template too, even for a release export.
        "templates": ["windows_release_x86_64.exe", "windows_debug_x86_64.exe"],
        "version_keys": ["application/file_version", "application/product_version"],
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


# --- Godot and export templates ---------------------------------------------------------------------------------

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
    local = common.GODOT_DIR.parent / TEMPLATES_TPZ
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
            common.check_sha256(tmp, TEMPLATE_SHA256[n], "export template " + n)
            os.replace(tmp, d / n)
    if (d / "version.txt").read_text().strip() != GODOT_VERSION + ".stable":
        raise SystemExit("release: unexpected templates version in %s" % d)
    fetched = getattr(f, "fetched", 0)
    log("release: templates ready in %.1fs%s" % (time.time() - t0, " (%d MB fetched)" % (fetched >> 20)
                                                  if fetched else ""))
    return d


# --- the game ---------------------------------------------------------------------------------------------------

def res_path(game, res):
    if not res.startswith("res://"):
        raise SystemExit("release: library path %r is not a res:// path" % res)
    return game / res[len("res://"):]


def release_libraries(game, h):
    """Every GDExtension library this host's export ships: (gdextension file, absolute library path)."""
    libs = []
    for ext in common.gdextensions(game):
        entries = common.cfg_section(ext, "libraries")
        key = next((k for k in h["lib_keys"] if k in entries), None)
        if key is None:
            raise SystemExit("release: %s has no library for this platform (keys tried: %s)"
                             % (ext, ", ".join(h["lib_keys"])))
        libs.append((ext, res_path(game, entries[key])))
    return libs


def release_dependencies(game, h):
    """Files the .gdextension [dependencies] sections ship with this host's export (e.g. the EOS SDK)."""
    deps = []
    for ext in common.gdextensions(game):
        entries = common.cfg_section(ext, "dependencies")
        key = next((k for k in h["lib_keys"] if k in entries), None)
        if key is not None:
            deps += [res_path(game, r) for r in re.findall(r'"(res://[^"]+)"', entries[key])]
    return deps


def build_dependencies(game):
    """What the game's extension links: Box3D only when its code imports physics, EOS only when its extension
    imports unified:eos (dev.game_uses_box3d, dev.extension_uses_eos)."""
    t = step("dependencies")
    if dev.game_uses_box3d(game):
        box3d.ensure()
    imgui.ensure()
    if dev.extension_uses_eos(game):
        eos.ensure()
    dev.cmd_gen()
    log("release: dependencies in %.1fs" % (time.time() - t))


def build_extension(game, h):
    t = step("game extension (release)")
    libs = release_libraries(game, h)
    if not libs:
        raise SystemExit("release: %s has no .gdextension" % game)
    dev.cmd_game_build(game, "release")
    for ext, lib in libs:
        if not lib.is_file():
            raise SystemExit("release: %s names %s, which the build did not produce" % (ext.name, lib))
    log("release: extension in %.1fs" % (time.time() - t))
    return libs


# --- the version ------------------------------------------------------------------------------------------------

VERSION_RE = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+-]*")
NUMERIC_RE = re.compile(r"\d+(\.\d+){0,3}")


def platform_version(version):
    """What goes into the platforms' numeric version fields (macOS CFBundle*Version, Windows file version):
    the version itself when it is numeric (tags: 0.1.1), else 0.0.0 (local and manual builds)."""
    return version if NUMERIC_RE.fullmatch(version) else "0.0.0"


def set_keys(text, section, values, what):
    """`text` (a Godot ConfigFile) with each key of `values` in [section] set to the quoted value; every key must
    already be there exactly once."""
    lines = text.split("\n")
    cur, seen = None, {k: 0 for k in values}
    for i, line in enumerate(lines):
        st = line.strip()
        if st.startswith("["):
            cur = st.strip("[]")
        elif cur == section and "=" in st:
            k = st.split("=", 1)[0].strip()
            if k in values:
                lines[i] = '%s="%s"' % (k, values[k])
                seen[k] += 1
    bad = [k for k, n in seen.items() if n != 1]
    if bad:
        raise SystemExit("release: %s [%s] must set each of %s once" % (what, section, ", ".join(bad)))
    return "\n".join(lines)


class stamped_version:
    """Stamps `version` into project.godot (application/config/version) and the export preset's version keys
    for the duration of the export, then restores the files byte for byte."""

    def __init__(self, game, h, version):
        self.files = {game / "project.godot": None, game / "export_presets.cfg": None}
        self.game, self.h, self.version = game, h, version

    def __enter__(self):
        for f in self.files:
            self.files[f] = f.read_bytes()
        try:
            self._stamp()
        except BaseException:
            self.__exit__()
            raise
        return self

    def _stamp(self):
        proj, presets = self.files
        text = proj.read_bytes().decode("utf-8")
        proj.write_bytes(set_keys(text, "application", {"config/version": self.version}, "project.godot").encode())
        text = presets.read_bytes().decode("utf-8")
        idx = re.search(r'^\[preset\.(\d+)\]\s*\nname="%s"' % re.escape(self.h["preset"]), text, re.M)
        if not idx:
            raise SystemExit("release: export_presets.cfg has no %r preset" % self.h["preset"])
        num = platform_version(self.version)
        text = set_keys(text, "preset.%s.options" % idx.group(1), {k: num for k in self.h["version_keys"]},
                        "export_presets.cfg")
        presets.write_bytes(text.encode())
        log("release: version %s (platform fields %s) stamped for the export" % (self.version, num))

    def __exit__(self, *exc):
        for f, data in self.files.items():
            if data is not None:
                f.write_bytes(data)
        return False


def check_version(target, h, version):
    """The export carries the stamped version: in the .pck's project settings (what the game shows) and, on
    macOS, in Info.plist."""
    root = target if target.is_dir() else target.parent
    pcks = list(root.rglob("*.pck"))
    if len(pcks) != 1:
        raise SystemExit("release: expected one .pck in the export, found %d" % len(pcks))
    data = pcks[0].read_bytes()
    key = b"application/config/version"
    want = version.encode()
    i = data.find(key)
    if i < 0 or struct.pack("<I", len(want)) + want not in data[i + len(key):i + len(key) + 16 + len(want)]:
        raise SystemExit("release: %s does not carry application/config/version = %s" % (pcks[0].name, version))
    if IS_MACOS:
        with open(target / "Contents" / "Info.plist", "rb") as f:
            plist = plistlib.load(f)
        num = platform_version(version)
        got = (plist.get("CFBundleShortVersionString"), plist.get("CFBundleVersion"))
        if got != (num, num):
            raise SystemExit("release: Info.plist has versions %s, want %s" % (got, num))
    log("release: the export carries version %s" % version)


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
    out_dir = game / ".out" / "export" / h["platform"]
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True)
    target = out_dir / (name + (".app" if IS_MACOS else ".exe"))
    godot_step(godot, game, ["--export-release", h["preset"], str(target)], "export (%s)" % h["preset"],
               EXPORT_TIMEOUT)
    if not target.exists():
        raise SystemExit("release: the export produced no %s" % target)
    return target


def check_payload(target, files):
    """Every library the game needs made it into the export, as a real file (not a link into .out/)."""
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
    arm64: drop the x86_64 slice, so the app is arm64 only like everything in it and the download shrinks by ~half
    the engine. Universal libraries (the EOS SDK) get the same.
    Their original signatures break; the ad-hoc codesign that follows re-signs everything."""
    frameworks = app / "Contents" / "Frameworks"
    files = list((app / "Contents" / "MacOS").iterdir())
    files += sorted(frameworks.glob("*.dylib")) if frameworks.is_dir() else []
    for f in files:
        if len(lipo_archs(f)) > 1:
            run(["lipo", f, "-thin", "arm64", "-output", f])


def sign_and_zip(target, zip_path):
    t = step("sign + zip")
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    if zip_path.exists():
        zip_path.unlink()
    if IS_MACOS:
        thin_to_arm64(target)
        run(["codesign", "--force", "--deep", "-s", "-", target])
        run(["codesign", "--verify", "--deep", "--strict", target])
        # The .app inside one folder named like the zip.
        folder = target.parent / zip_path.stem
        folder.mkdir()
        target = target.rename(folder / target.name)
        run(["ditto", "-c", "-k", "--keepParent", folder, zip_path])
    else:
        # The exe, its .pck and the libraries, inside one folder named like the zip.
        top = zip_path.stem
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            for p in sorted(target.parent.rglob("*")):
                if p.is_file():
                    z.write(p, "%s/%s" % (top, p.relative_to(target.parent).as_posix()))
    # LF on every OS: SHA256SUMS.txt concatenates these, and macOS `shasum -c` rejects a CRLF line.
    zip_path.with_name(zip_path.name + ".sha256").write_bytes(
        ("%s  %s\n" % (common.sha256_file(zip_path), zip_path.name)).encode())
    log("release: %s (%.1f MB) in %.1fs" % (zip_path.name, zip_path.stat().st_size / 1e6, time.time() - t))


def smoke(zip_path, name):
    """Unpacks the zip (what a tester gets) and runs the game headless for a few seconds."""
    t = step("smoke test")
    with tempfile.TemporaryDirectory(prefix="unified-smoke-") as tmp:
        tmp = Path(tmp)
        if IS_MACOS:
            run(["ditto", "-x", "-k", zip_path, tmp])
            app = tmp / zip_path.stem / (name + ".app")
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


def release_label(version):
    """`v0.1.2` for a release version, a dev version (`dev-<sha>`) as is: the zip names use it."""
    return "v" + version if version[:1].isdigit() else version


def game_commit(game):
    """The short commit of the game's own repository (unified's for its in-repo games), "" outside git."""
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
                              cwd=str(game)).stdout.strip()
    except OSError:
        return ""


def default_version(game):
    return "dev-" + (game_commit(game) or "local")


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
    if not VERSION_RE.fullmatch(version):
        raise SystemExit("release: bad version %r (letters, digits, . + - only)" % version)
    missing = [k for k in embed_env if not os.environ.get(k)]
    if missing:
        raise SystemExit("release: missing environment (repo secrets?): " + ", ".join(missing))
    build_dependencies(game)
    libs = build_extension(game, h)
    if embed_env:
        check_embedded(libs, embed_env)
    t = step("Godot + export templates")
    godot = common.find_godot(fetch=True)
    ensure_templates(h)
    log("release: Godot %s (%s) in %.1fs" % (common.godot_version(godot), godot, time.time() - t))
    common.write_extension_list(game)
    with stamped_version(game, h, version):
        godot_step(godot, game, ["--import"], "import", IMPORT_TIMEOUT)
        target = export(godot, game, h, name)
    check_version(target, h, version)
    files = [lib for _, lib in libs] + release_dependencies(game, h)
    if any(k.startswith("EOS_") for k in embed_env) and eos.lib_path().name not in {f.name for f in files}:
        files.append(eos.lib_path())
    check_payload(target, files)
    zip_path = game / ".out" / "release" / ("%s-%s-%s.zip" % (name, release_label(version), h["platform"]))
    sign_and_zip(target, zip_path)
    if smoke_test:
        smoke(zip_path, name)
    log("release: done in %.1fs -> %s" % (time.time() - t0, zip_path))
    print(zip_path)


NOTES = """\
Test build of **{name} {version}** (commit `{commit}`). Unsigned prerelease for playtesting only.

## Download

- **macOS** (Apple Silicon): `{name}-{label}-macos-arm64.zip`
- **Windows** (x64): `{name}-{label}-windows-x64.zip`

Each zip unpacks to a folder of the same name with the game inside.

`SHA256SUMS.txt` has the checksums (`shasum -a 256 -c SHA256SUMS.txt` / `certutil -hashfile <zip> SHA256`).

## Opening it

- **macOS:** unzip and open `{name}.app` in the `{name}-{label}-macos-arm64` folder. The app is ad-hoc signed,
  not notarized, so macOS blocks the first launch: click **Done**, open System Settings → Privacy & Security,
  scroll down to the message about `{name}`, click **Open Anyway** and confirm. (On macOS 14 and older, right-click the app → **Open** → **Open** also works.)
  Last resort, in Terminal: `xattr -dr com.apple.quarantine {name}-{label}-macos-arm64`.
- **Windows:** unzip, run `{name}.exe` in the `{name}-{label}-windows-x64` folder. If SmartScreen says
  "Windows protected your PC", click **More info** → **Run anyway**.
{game_notes}"""


def cmd_notes(game, tag):
    game = game.resolve()
    name = game.name
    version = tag.split("-v", 1)[1] if "-v" in tag else tag
    commit = game_commit(game)
    extra = game / "RELEASE_NOTES.md"
    game_notes = ("\n" + extra.read_text(encoding="utf-8")) if extra.is_file() else ""
    print(NOTES.format(name=name, version=version, label=release_label(version), commit=commit, game_notes=game_notes), end="")


def main():
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if a else 2

    def opt(flag, default=None):
        return a[a.index(flag) + 1] if flag in a else default

    if a[0] == "build" and len(a) >= 2:
        req = [k for k in (opt("--embed-env") or "").split(",") if k]
        cmd_build(Path(a[1]), opt("--version") or default_version(Path(a[1]).resolve()), req, "--no-smoke" not in a)
    elif a[0] == "notes" and len(a) >= 2 and "--tag" in a:
        cmd_notes(Path(a[1]), opt("--tag"))
    elif a == ["godot"]:
        h = host()
        log("release: %s" % common.find_godot(fetch=True))
        ensure_templates(h)
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
