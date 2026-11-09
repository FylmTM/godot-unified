"""Game project checks with headless Godot (Python 3.9+, stdlib only). Used by `dev.py game` (or run this file
directly with the same arguments: `python tools/game.py validate survivor`):

    python tools/dev.py game validate <game>              # compile scripts, load scenes, run the menu 30 frames
    python tools/dev.py game walk <game>                  # scripted UI walk with the mock session (headless)
    python tools/dev.py game shots <game>                 # the walk in a window, PNGs to games/<game>/.out/shots/
    python tools/dev.py game tour <game> [--shots]        # the real game (library built): single player through
                                                          # lobby/match; headless quick check, or windowed with
                                                          # PNGs to games/<game>/.out/tour/ (plays to game over)
    python tools/dev.py game tour <game> --frames [--cold]   # windowed tour reporting frame times, hitches with the
                                                          # events around them and each first use's worst frame;
                                                          # --cold clears the shader caches
    python tools/dev.py game coop <game> [--shots] [--rejoin] [--lan]   # real online co-op over EOS (or --lan:
                                                          # direct UDP on 127.0.0.1): a host and a headless
                                                          # joiner (typed code) in two processes (manual:
                                                          # EOS may show macOS keychain prompts)
    python tools/dev.py game import <game>                # refresh Godot's import cache (.godot/)
    python tools/dev.py game export-level <game> [--check]   # game/levels/*.tscn -> .level files (src/level/SPEC.md);
                                                          # --check fails when a committed file is stale

Godot: common.find_godot(). Every run has a timeout (Godot can hang on some errors) and is judged by the JSON line
the tool script prints, not by Godot's exit code alone (it stays 0 on script errors). The import cache is refreshed
first when it is missing or a script's class_name or an asset changed.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import time

import common
from common import log

COMMANDS = ("validate", "walk", "shots", "tour", "coop", "import", "export-level")
LEVEL_EXPORTER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "level", "godot",
                              "level_export.gd")


def run_tool(proj, args, timeout, marker, quiet=False, strict=False):
    """Runs Godot on the project; returns (ok, the JSON after `marker`, seconds). Prints the output minus the
    banner. `strict`: also fail on ObjectDB/resource leaks at exit and on GDScript warnings (printed when Godot runs
    with `-d`)."""
    t0 = time.time()
    r = common.run_godot(["--path", proj] + args, timeout)
    out = r.stdout + r.stderr
    data = None
    for line in out.splitlines():
        if line.startswith(marker + " "):
            data = json.loads(line[len(marker) + 1:])
        elif not quiet and line.strip() and not line.startswith("Godot Engine v"):
            print(line)
    ok = r.returncode == 0 and data is not None and data.get("ok", not data.get("errors"))
    if strict:
        lines = out.splitlines()
        leaks = [l for l in lines if "leaked at exit" in l or "still in use at exit" in l]
        warns = [a for a, b in zip(lines, lines[1:]) if a.startswith("WARNING:") and "GDScript::reload" in b]
        for what, found in (("leak at exit", leaks), ("GDScript warning", warns)):
            if found:
                log("game: %d %s line(s): failing" % (len(found), what))
                ok = False
    return ok, data, time.time() - t0


def parser():
    ap = common.Strict(prog="dev.py game", description="Godot project checks (tools/game.py)")
    sub = ap.add_subparsers(dest="cmd", required=True, metavar="|".join(COMMANDS), parser_class=common.Strict)
    for name, helptext in (("validate", "compile scripts, load scenes, run the menu 30 frames (headless)"),
                           ("walk", "scripted UI walk with the mock session (headless)"),
                           ("shots", "the walk in a window, PNGs to <game>/.out/shots/"),
                           ("tour", "the real game through lobby and match (needs the game library)"),
                           ("coop", "online co-op over EOS: host + headless joiner (needs the game library)"),
                           ("import", "refresh Godot's import cache"),
                           ("export-level", "export game/levels/*.tscn to .level files (headless)")):
        p = sub.add_parser(name, help=helptext)
        p.add_argument("game", help="game name (games/<game>) or project path")
        if name in ("tour", "coop"):
            p.add_argument("--shots", action="store_true", help="windowed, with screenshots")
        if name == "tour":
            p.add_argument("--frames", action="store_true", help="windowed, reporting frame times and hitches")
            p.add_argument("--cold", action="store_true", help="with --frames: clear the shader caches first")
        if name == "coop":
            p.add_argument("--rejoin", action="store_true", help="the joiner leaves mid-match and joins again")
            p.add_argument("--lan", action="store_true", help="direct UDP on 127.0.0.1 instead of EOS (if the game's "
                           "coop tool supports it)")
        if name == "export-level":
            p.add_argument("--check", action="store_true", help="write nothing; fail when a .level file is stale")
    return ap


def main(argv):
    a = parser().parse_args(argv)
    proj = common.game_dir(a.game)
    exts = common.ensure_imported(proj)
    log("game: extensions: %s" % (", ".join(exts) if exts else "none built (mock session)"))
    if a.cmd == "import":
        return 0
    if a.cmd in ("tour", "coop") and not exts:
        raise SystemExit("game: %s needs the game library: python tools/dev.py game build %s" % (a.cmd, a.game))
    if a.cmd == "export-level":
        ok, data, secs = export_levels(proj, a.check)
    elif a.cmd == "validate":
        ok, data, secs = run_tool(
            proj, ["--headless", "-d", "-s", "res://game/tools/validate.gd", "--", "--no-settings"], 60,
            "VALIDATE_JSON", strict=True)
        if ok and os.path.isdir(os.path.join(proj, "game", "levels")):
            ok, _, lsecs = export_levels(proj, True)
            secs += lsecs
    elif a.cmd == "walk":
        ok, data, secs = run_tool(
            proj, ["--headless", "-s", "res://game/tools/ui_walk.gd", "--", "--mock", "--no-settings"], 90, "WALK_JSON",
            strict=True)
    elif a.cmd == "shots":
        with _keep_front_app():
            ok, data, secs = run_tool(
                proj, ["--resolution", "1280x720", "-s", "res://game/tools/ui_walk.gd", "--", "--mock",
                       "--no-settings", "--shots=res://.out/shots"], 180, "WALK_JSON")
    elif a.cmd == "tour":
        if a.cold and not a.frames:
            raise SystemExit("game: --cold goes with --frames")
        if a.shots or a.frames:
            if a.cold:
                _clear_shader_cache(proj)
            extra = (["--shots=res://.out/tour"] if a.shots else []) + (["--frames"] if a.frames else [])
            with _keep_front_app():
                ok, data, secs = run_tool(
                    proj, ["--resolution", "1280x720", "-s", "res://game/tools/tour.gd", "--", "--no-settings"] + extra,
                    240, "TOUR_JSON")
        else:
            ok, data, secs = run_tool(
                proj, ["--headless", "-s", "res://game/tools/tour.gd", "--", "--no-settings", "--quick"], 60,
                "TOUR_JSON")
    else:
        ok, data, secs = cmd_coop(proj, a.shots, a.rejoin, a.lan)
    log("game: %s %s in %.1fs" % (a.cmd, "OK" if ok else "FAILED", secs))
    return 0 if ok else 1


def export_levels(proj, check):
    """Runs unified's level exporter (installed into <game>/.out/tools/) on the project's levels."""
    tools = os.path.join(proj, ".out", "tools")
    os.makedirs(tools, exist_ok=True)
    shutil.copyfile(LEVEL_EXPORTER, os.path.join(tools, "level_export.gd"))
    ok, data, secs = run_tool(proj, ["--headless", "-s", "res://.out/tools/level_export.gd", "--"] +
                              (["--check"] if check else []), 60, "LEVEL_JSON")
    for lv in (data or {}).get("levels", []):
        log("game: %s -> %s (%d bytes%s)" % (lv["scene"], lv["level"], lv["bytes"],
                                              ", changed" if lv["changed"] else ""))
    for e in (data or {}).get("errors", []):
        log("game: level: " + e)
    return ok, data, secs


def _clear_shader_cache(proj):
    """Delete the project's compiled-shader caches, so the next run compiles like a player's first launch: the one in
    its Godot user dir and the editor's in .godot/ (runs read both). Absolute numbers still differ from an exported
    game's first launch (macOS: a ~2.5 s first frame there vs ~0.2 s here), so measure the export for those."""
    editor_cache = proj / ".godot" / "shader_cache"
    if editor_cache.is_dir():
        shutil.rmtree(editor_cache)
        log("game: cleared %s" % editor_cache)
    name = re.search(r'^config/name="([^"]+)"', (proj / "project.godot").read_text(), re.M).group(1)
    if common.IS_MACOS:
        base = os.path.expanduser("~/Library/Application Support/Godot")
    elif common.IS_WINDOWS:
        base = os.path.join(os.environ["APPDATA"], "Godot")
    else:
        base = os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "godot")
    cache = os.path.join(base, "app_userdata", name, "shader_cache")
    if os.path.isdir(cache):
        shutil.rmtree(cache)
        log("game: cleared %s" % cache)


def cmd_coop(proj, shots, rejoin=False, lan=False):
    """Host (windowed with --shots, else headless) and a headless joiner with a fresh EOS device id, as two Godot
    processes; the host hands the lobby code over through a file. --rejoin: the joiner leaves mid-match and joins
    again with the same code. The joiner is always reaped, also when the host fails or times out: an orphan would
    stay connected to EOS."""
    extra = (["--rejoin"] if rejoin else []) + (["--lan"] if lan else [])
    code = proj / ".out" / "coop_code.txt"
    code.parent.mkdir(parents=True, exist_ok=True)
    if code.exists():
        code.unlink()
    env = dict(os.environ, USER="Friend", USERNAME="Friend", UNIFIED_EOS_FRESH_DEVICE="1")
    join_log = proj / ".out" / "coop_join.log"
    host_args = ["-s", "res://game/tools/coop.gd", "--", "--no-settings", "--role=host",
                 "--code-file=res://.out/coop_code.txt"] + extra
    if shots:
        host_args = ["--resolution", "1280x720"] + host_args + ["--shots=res://.out/coop"]
    else:
        host_args = ["--headless"] + host_args
    with open(join_log, "w") as jl:
        joiner = subprocess.Popen(
            [common.find_godot(), "--path", str(proj), "--headless", "-s", "res://game/tools/coop.gd", "--",
             "--no-settings", "--role=join", "--code-file=res://.out/coop_code.txt"] + extra,
            stdout=jl, stderr=subprocess.STDOUT, env=env)
        try:
            if shots:
                with _keep_front_app():
                    ok, data, secs = run_tool(proj, host_args, 180, "COOP_JSON")
            else:
                ok, data, secs = run_tool(proj, host_args, 180, "COOP_JSON")
            try:
                joiner.wait(timeout=30)
            except subprocess.TimeoutExpired:
                pass  # killed below; judged by its COOP_JSON line
        finally:
            if joiner.poll() is None:
                joiner.kill()
                joiner.wait()
    jdata = None
    for line in join_log.read_text(errors="replace").splitlines():
        if line.startswith("COOP_JSON "):
            jdata = json.loads(line[len("COOP_JSON "):])
        elif "[join]" in line:
            print(line)
    return ok and jdata is not None and jdata.get("ok"), data, secs


class _keep_front_app:
    """macOS: windowed Godot steals focus; give it back to the app that was in front."""

    def __enter__(self):
        self.bundle = None
        if common.IS_MACOS:
            try:
                asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
                info = subprocess.run(["lsappinfo", "info", "-only", "bundleid", asn], capture_output=True,
                                      text=True).stdout
                self.bundle = info.split("=", 1)[1].strip().strip('"') if "=" in info else None
            except OSError:
                pass
        return self

    def __exit__(self, *exc):
        if self.bundle and self.bundle != "[ NULL ]":
            subprocess.run(["open", "-b", self.bundle], capture_output=True)
        return False


if __name__ == "__main__":
    import sys
    sys.exit(main(sys.argv[1:]))
