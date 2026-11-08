"""Game project checks with headless Godot (Python 3.9+, stdlib only). Used by `dev.py game`:

    python tools/dev.py game validate [--game survivor]   # compile scripts, load scenes, run the menu 30 frames
    python tools/dev.py game walk                         # scripted UI walk with the mock session (headless)
    python tools/dev.py game shots                        # the walk in a window, PNGs to games/<game>/.uni/shots/
    python tools/dev.py game import                       # refresh Godot's import cache (.godot/)

Godot: $GODOT, else `godot` on PATH, else ~/tools/godot/Godot_v4.7.2.app (macOS). Every run has a timeout (Godot
can hang on some errors) and is judged by the JSON line the tool script prints, not by Godot's exit code alone
(it stays 0 on script errors). The import cache is refreshed first when it is missing or a script is newer.
"""

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import common
from common import REPO, log

GODOT_VERSION = "4.7.2"
MAC_DEFAULT = Path.home() / ("tools/godot/Godot_v%s.app/Contents/MacOS/Godot" % GODOT_VERSION)


def find_godot():
    exe = os.environ.get("GODOT") or shutil.which("godot")
    if not exe and common.IS_MACOS and MAC_DEFAULT.exists():
        exe = str(MAC_DEFAULT)
    if not exe:
        raise SystemExit("game: Godot %s not found: set GODOT or put `godot` on PATH" % GODOT_VERSION)
    return exe


def project_dir(game):
    d = REPO / "games" / game
    if not (d / "project.godot").exists():
        raise SystemExit("game: no Godot project at %s" % d)
    return d


def run_godot(proj, args, timeout, marker=None, quiet=False):
    """Run Godot; return (ok, parsed JSON after `marker`). Prints the output minus the banner."""
    cmd = [find_godot(), "--path", str(proj)] + args
    t0 = time.time()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out, rc = r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        log(out)
        raise SystemExit("game: Godot timed out after %d s: %s" % (timeout, " ".join(args)))
    data = None
    for line in out.splitlines():
        if marker and line.startswith(marker + " "):
            data = json.loads(line[len(marker) + 1:])
        elif not quiet and line.strip() and not line.startswith("Godot Engine v"):
            print(line)
    secs = time.time() - t0
    ok = rc == 0 and (marker is None or (data is not None and data.get("ok", not data.get("errors"))))
    return ok, data, secs


IMPORTED = {".svg", ".png", ".jpg", ".webp", ".wav", ".ogg", ".mp3", ".glb", ".gltf", ".fbx", ".ttf", ".otf"}


def import_signature(proj):
    """What an import depends on: global class names (class_name lines), new scripts (.uid files), imported assets
    (path + mtime). Editing a script body or a scene needs no import, so the edit loop skips it (~1.5 s)."""
    parts = []
    for p in sorted((proj / "game").rglob("*")):
        rel = p.relative_to(proj).as_posix()
        if p.suffix == ".gd":
            names = [l.strip() for l in p.read_text(errors="replace").splitlines() if l.startswith("class_name ")]
            parts.append("%s %s %s" % (rel, names, (p.parent / (p.name + ".uid")).exists()))
        elif p.suffix.lower() in IMPORTED:
            parts.append("%s %d" % (rel, p.stat().st_mtime_ns))
    return "\n".join(parts)


def ensure_imported(proj):
    stamp = proj / ".godot" / "unified_import.sig"
    sig = import_signature(proj)
    if not (proj / ".godot" / "global_script_class_cache.cfg").exists() or not stamp.exists() or stamp.read_text() != sig:
        ok, _, secs = run_godot(proj, ["--headless", "--import"], 120, quiet=True)
        log("game: import %.1fs" % secs)
        if not ok:
            raise SystemExit("game: import failed")
        stamp.write_text(import_signature(proj))  # the import may have added .uid files
    exts = sync_extension_list(proj)
    log("game: extensions: %s" % (", ".join(exts) if exts else "none built (mock session)"))


HOST_KEYS = {"macos": ["macos.debug", "macos.release", "macos"], "windows": ["windows.x86_64", "windows"],
             "linux": ["linux.x86_64", "linux"]}


def sync_extension_list(proj):
    """Godot loads the GDExtensions listed in .godot/extension_list.cfg (written by the import scan). List only those
    whose library for this host exists: a missing library is an error on every run, and the game falls back to its
    mock session anyway. Returns the extensions listed."""
    listed = []
    for ext in sorted((proj / "game").rglob("*.gdextension")):
        libs = {}
        section = ""
        for line in ext.read_text().splitlines():
            line = line.strip()
            if line.startswith("["):
                section = line
            elif section == "[libraries]" and "=" in line and not line.startswith(";"):
                k, v = line.split("=", 1)
                libs[k.strip()] = v.strip().strip('"')
        for key in HOST_KEYS[common.host_os()]:
            if key in libs and (proj / libs[key].replace("res://", "")).exists():
                listed.append("res://" + ext.relative_to(proj).as_posix())
                break
    path = proj / ".godot" / "extension_list.cfg"
    want = "".join(e + "\n" for e in listed)
    if not path.exists() or path.read_text() != want:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(want)
    return listed


def cmd_game(argv):
    sub = argv[0] if argv else "validate"
    game = argv[argv.index("--game") + 1] if "--game" in argv else "survivor"
    proj = project_dir(game)
    if sub == "import":
        ensure_imported(proj)
        return
    ensure_imported(proj)
    if sub == "validate":
        ok, data, secs = run_godot(
            proj, ["--headless", "-s", "res://game/tools/validate.gd", "--", "--no-settings"], 60, "VALIDATE_JSON")
    elif sub == "walk":
        ok, data, secs = run_godot(
            proj, ["--headless", "-s", "res://game/tools/ui_walk.gd", "--", "--mock", "--no-settings"], 90, "WALK_JSON")
    elif sub == "shots":
        front = _front_app()
        try:
            ok, data, secs = run_godot(
                proj,
                ["--resolution", "1280x720", "-s", "res://game/tools/ui_walk.gd", "--", "--mock", "--no-settings",
                 "--shots=res://.uni/shots"],
                180, "WALK_JSON")
        finally:
            _restore_app(front)
    else:
        raise SystemExit("game: unknown subcommand %r (validate, walk, shots, import)" % sub)
    log("game: %s %s in %.1fs" % (sub, "OK" if ok else "FAILED", secs))
    if not ok:
        raise SystemExit(1)


def _front_app():
    """macOS: windowed Godot steals focus; remember the frontmost app to give it back."""
    if not common.IS_MACOS:
        return None
    try:
        asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
        info = subprocess.run(["lsappinfo", "info", "-only", "bundleid", asn], capture_output=True, text=True).stdout
        return info.split("=", 1)[1].strip().strip('"') if "=" in info else None
    except OSError:
        return None


def _restore_app(bundle):
    if bundle and bundle != "[ NULL ]":
        subprocess.run(["open", "-b", bundle], capture_output=True)
