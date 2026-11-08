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


def ensure_imported(proj):
    cache = proj / ".godot" / "global_script_class_cache.cfg"
    stale = not cache.exists()
    if not stale:
        t = cache.stat().st_mtime
        stale = any(p.stat().st_mtime > t for p in (proj / "game").rglob("*.gd"))
    if stale:
        ok, _, secs = run_godot(proj, ["--headless", "--import"], 120, quiet=True)
        log("game: import %.1fs" % secs)
        if not ok:
            raise SystemExit("game: import failed")
        cache.touch()


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
            proj, ["--headless", "-s", "res://game/tools/validate.gd", "--", "--mock", "--no-settings"], 60, "VALIDATE_JSON")
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
