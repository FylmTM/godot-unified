#!/usr/bin/env python3
"""Toolchain setup and the job summary for .github/workflows/ci.yml (Python 3.9+, stdlib only).

    python tools/ci.py odin <tag> <dest>     # download (hash-pinned) + unpack an Odin release; add it to $GITHUB_PATH
    python tools/ci.py odinfmt <dest>        # build odinfmt from OLS at OLS_COMMIT with the odin on PATH
    python tools/ci.py godot                 # the official Godot editor (hash-pinned) in .toolchains/godot/<version>/
    python tools/ci.py ensure-ninja          # pip-install ninja if missing (only needed to build Box3D)
    python tools/ci.py compiler-id           # short id of the C compiler Box3D builds with (its CI cache key)
    python tools/ci.py summary               # markdown for $GITHUB_STEP_SUMMARY from out/
    python tools/ci.py cloud-setup           # cloud sessions only: every toolchain + third-party build (below)

`odinfmt` also works locally: it is the supported way to install the pinned formatter (put <dest> on
PATH or set ODINFMT=<dest>/odinfmt). Every step is a no-op when its output already exists.

`cloud-setup` provisions a Claude Code cloud session (Ubuntu x86_64; docs/CLOUD.md). It links .toolchains/ and
third_party/{box3d,imgui,eos}/ to ~/.cache/unified-cloud/, so what the environment's setup script builds there
survives into the cached VM snapshot and every fresh clone reuses it, then runs Odin, odinfmt, Godot, Box3D, Dear
ImGui and the EOS SDK in parallel. Run from the SessionStart hook it puts Odin on PATH through $CLAUDE_ENV_FILE.
It always exits 0 and prints one line saying what is ready and what failed (the hook's output reaches Claude).
"""

import json
import os
import subprocess
import sys
import tarfile
import zipfile
from pathlib import Path

import common
from common import REPO, EXE, log

# OLS (odinfmt) pinned to the build VS Code's OLS extension shipped on 2026-10-25
# (nightly-2026-10-25-85d88870). Formatting can change between OLS versions: bump deliberately,
# then run `python tools/dev.py fmt` and commit the result.
OLS_URL = "https://github.com/DanielGavin/ols.git"
OLS_COMMIT = "85d88870aebe1fb61b07db838e9db5728e6586ec"

# SHA-256 of the Odin release assets CI uses (GitHub's asset digests). A new ODIN_TAG in the workflows needs its
# hashes here: `gh api repos/odin-lang/Odin/releases/tags/<tag> --jq '.assets[] | [.name, .digest]'`.
ODIN_SHA256 = {
    "odin-linux-amd64-dev-2026-11.tar.gz": "65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618",
    "odin-linux-arm64-dev-2026-11.tar.gz": "5bdba22447ea46a99765235e401c2ad83930f967f987aab1531ed76c3aa7ea3b",
    "odin-macos-arm64-dev-2026-11.tar.gz": "fa10eee280c8786758e3ff0b8fdd9355e1c9447b1f0b8c72764e25ee4ebc3e22",
    "odin-windows-amd64-dev-2026-11.zip": "259effedf2997293c8fa4a5e497496f8ebce9f826652d9dd353a9dd2113c31fd",
}


def gh_append(var, text):
    path = os.environ.get(var)
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text)


def find_odin(dest, exe):
    """The compiler binary: the shallowest regular file named odin[.exe] (core/odin/ is a directory)."""
    if not dest.exists():
        return []
    return sorted((p for p in dest.rglob(exe) if p.is_file()), key=lambda p: (len(p.parts), str(p)))


def cmd_odin(tag, dest):
    dest = Path(dest).resolve()
    exe = "odin" + EXE
    found = find_odin(dest, exe)
    if not found:
        osname = common.host_os()
        arch = {"x64": "amd64", "arm64": "arm64"}[common.host_arch()]
        ext = "zip" if common.IS_WINDOWS else "tar.gz"
        asset = "odin-%s-%s-%s.%s" % (osname, arch, tag, ext)
        if asset not in ODIN_SHA256:
            raise SystemExit("odin: no pinned SHA-256 for %s: add it to ODIN_SHA256 in tools/ci.py" % asset)
        url = "https://github.com/odin-lang/Odin/releases/download/%s/%s" % (tag, asset)
        archive = common.download(url, dest.parent / asset, ODIN_SHA256[asset])
        dest.mkdir(parents=True, exist_ok=True)
        if ext == "zip":
            with zipfile.ZipFile(archive) as z:
                z.extractall(dest)
        else:
            with tarfile.open(archive, mode="r:gz") as t:
                if hasattr(tarfile, "data_filter"):
                    t.extractall(dest, filter="data")
                else:
                    t.extractall(dest)
        archive.unlink()
        found = find_odin(dest, exe)
        if not found:
            raise SystemExit("odin: %s not found in %s" % (exe, asset))
    odin = found[0]
    if not common.IS_WINDOWS:
        odin.chmod(0o755)
    gh_append("GITHUB_PATH", str(odin.parent) + "\n")
    log("odin: " + str(odin))


def odin_exe():
    """odin on PATH, else the one `ci.py odin` unpacked into .toolchains/odin (its $GITHUB_PATH entry only
    takes effect in later CI steps)."""
    found = common.which("odin") or next(iter(find_odin(REPO / ".toolchains" / "odin", "odin" + EXE)), None)
    if not found:
        raise SystemExit("odinfmt: odin not found on PATH or in .toolchains/odin")
    return str(Path(found).resolve())


def cmd_odinfmt(dest):
    dest = Path(dest).expanduser().resolve()
    out = dest / ("odinfmt" + EXE)
    stamp = dest / "odinfmt.commit"
    if out.exists() and stamp.exists() and stamp.read_text().strip() == OLS_COMMIT:
        log("odinfmt: %s (OLS %s)" % (out, OLS_COMMIT[:10]))
        return
    src = dest / "ols-src"
    src.mkdir(parents=True, exist_ok=True)
    git = ["git", "-c", "advice.detachedHead=false", "-C", str(src)]
    if not (src / ".git").exists():
        subprocess.run(git + ["init", "-q"], check=True)
        subprocess.run(git + ["remote", "add", "origin", OLS_URL], check=True)
    log("odinfmt: fetching OLS @ %s" % OLS_COMMIT[:10])
    subprocess.run(git + ["fetch", "-q", "--depth", "1", "origin", OLS_COMMIT], check=True)
    subprocess.run(git + ["checkout", "-q", "--force", "FETCH_HEAD"], check=True)
    cmd = [odin_exe(), "build", "tools/odinfmt/main.odin", "-file", "-collection:src=src", "-o:speed",
           "-out:" + str(out)]
    log("+ " + " ".join(cmd))
    subprocess.run(cmd, cwd=str(src), check=True)
    stamp.write_text(OLS_COMMIT + "\n")
    log("odinfmt: built %s" % out)


def cmd_ensure_ninja():
    if common.which("ninja"):
        log("ninja: " + common.which("ninja"))
        return
    # Into .toolchains/ninja with --target: a system Python (PEP 668, e.g. Ubuntu's) refuses installs into
    # itself, not into a target directory. The wheel's ninja binary lands in <target>/bin (Scripts on Windows).
    dest = REPO / ".toolchains" / "ninja"
    log("ninja not on PATH: installing it from PyPI into " + str(dest))
    subprocess.run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check", "--upgrade",
                    "--target", str(dest), "ninja"], check=True)
    for d in ("bin", "Scripts"):
        if (dest / d / ("ninja" + EXE)).is_file():
            gh_append("GITHUB_PATH", str(dest / d) + "\n")
            return
    raise SystemExit("ninja: no ninja%s in %s/bin or Scripts" % (EXE, dest))


def cmd_compiler_id():
    """The Box3D build's compiler version, hashed: box3d.py's own stamp doesn't cover the compiler, so CI's
    Box3D cache key does (a runner image with a new clang rebuilds it)."""
    import hashlib
    import box3d
    cc, _ = box3d.pick_compilers()
    print(hashlib.sha256(box3d.compiler_version(cc).encode()).hexdigest()[:12])


def cmd_summary():
    out = ["## unified: %s" % common.platform_tag(), ""]
    timings_path = REPO / "out" / "timings.json"
    if timings_path.exists():
        t = json.loads(timings_path.read_text())
        out += ["| step | seconds |", "|---|---:|"]
        out += ["| `dev.py %s` | %.1f |" % (k, v) for k, v in t.items()]
        out.append("")
    check_path = REPO / "out" / "check.json"
    if not check_path.exists():
        out.append("No out/check.json: T1-T9 did not run.")
        print("\n".join(out))
        return
    j = json.loads(check_path.read_text())
    out += ["### T1-T9 (src/headless/SPEC.md (T1-T9)): %s" % ("PASS" if j.get("ok") else "**FAIL**"), "",
            "| test | result | seconds | detail |", "|---|---|---:|---|"]
    for name, r in j.get("tests", {}).items():
        detail = r.get("detail", "").replace("|", "\\|").replace("\n", " ")[:300]
        out.append("| %s | %s | %.1f | %s |" % (name, r.get("status", "?").upper(), r.get("seconds", 0), detail))
    d = (j.get("tests", {}).get("T9") or {}).get("data") or {}
    if "step_mean_us" in d:
        out += ["", "### T9 bench (`bench --enemies 1000 --window 8 --ticks 600`, release)", "",
                "| | mean µs | p99 µs |", "|---|---:|---:|",
                "| forward step | %.0f | %.0f |" % (d["step_mean_us"], d["step_p99_us"]),
                "| save | %.0f | |" % d["save_mean_us"],
                "| restore | %.0f | |" % d["restore_mean_us"],
                "| 8-tick re-sim | %.0f | %.0f |" % (d["resim_mean_us"], d["resim_p99_us"]),
                "| **step + re-sim** | **%.0f** (%s 6 ms budget) | |" % (
                    d["step_plus_resim_us"], "within" if d["within_target"] else "**OVER**"),
                "", "Snapshot: %d bytes." % d["snapshot_bytes"]]
    print("\n".join(out))


CLOUD_CACHE = Path.home() / ".cache" / "unified-cloud"
CLOUD_LINKS = (".toolchains", "third_party/box3d", "third_party/imgui", "third_party/eos")  # all git-ignored


def pinned_odin_tag():
    """The Odin release the hashes in ODIN_SHA256 are for (the workflows' ODIN_TAG)."""
    pre, suf = "odin-linux-amd64-", ".tar.gz"
    tags = {k[len(pre):-len(suf)] for k in ODIN_SHA256 if k.startswith(pre) and k.endswith(suf)}
    if len(tags) != 1:
        raise SystemExit("ci.py: expected one pinned Linux Odin release in ODIN_SHA256, found %s" % sorted(tags))
    return tags.pop()


def cmd_cloud_setup():
    import concurrent.futures
    import time
    t0 = time.time()
    for rel in CLOUD_LINKS:
        p = REPO / rel
        if not p.is_symlink() and not p.exists():
            target = CLOUD_CACHE / rel.replace("/", "-")
            target.mkdir(parents=True, exist_ok=True)
            p.symlink_to(target, target_is_directory=True)
    odin_dir = REPO / ".toolchains" / "odin"

    def odin_and_fmt():
        cmd_odin(pinned_odin_tag(), odin_dir)
        os.environ["PATH"] = str(find_odin(odin_dir, "odin" + EXE)[0].parent) + os.pathsep + os.environ["PATH"]
        cmd_odinfmt(REPO / ".toolchains" / "odinfmt")

    def godot():
        common.find_godot(fetch=True)

    def box3d():
        import box3d
        box3d.ensure()

    def imgui():
        import imgui
        imgui.ensure()

    def eos():
        import eos
        eos.ensure()

    steps = {"odin+odinfmt": odin_and_fmt, "godot": godot, "box3d": box3d, "imgui": imgui, "eos": eos}
    failed = {}
    with concurrent.futures.ThreadPoolExecutor(len(steps)) as pool:
        futures = {name: pool.submit(fn) for name, fn in steps.items()}
        for name, f in futures.items():
            try:
                f.result()
            except (Exception, SystemExit) as e:
                failed[name] = str(e).strip().splitlines()[-1][:200] if str(e).strip() else type(e).__name__
    odin = find_odin(odin_dir, "odin" + EXE)
    env_file = os.environ.get("CLAUDE_ENV_FILE")
    if env_file and odin:
        with open(env_file, "a", encoding="utf-8") as f:
            f.write('export PATH="%s:$PATH"\n' % odin[0].parent)
    ready = [n for n in steps if n not in failed]
    msg = "unified cloud-setup (%.0f s): ready: %s" % (time.time() - t0, ", ".join(ready) or "nothing")
    if failed:
        msg += "; FAILED: " + "; ".join("%s (%s)" % kv for kv in failed.items())
        msg += ". Rerun `python3 tools/ci.py cloud-setup` for the full log."
    print(msg, flush=True)


def main():
    a = sys.argv[1:]
    if len(a) == 3 and a[0] == "odin":
        cmd_odin(a[1], a[2])
    elif len(a) == 2 and a[0] == "odinfmt":
        cmd_odinfmt(a[1])
    elif a == ["ensure-ninja"]:
        cmd_ensure_ninja()
    elif a == ["godot"]:
        exe = common.find_godot(fetch=True)
        log("godot: %s (%s)" % (exe, common.godot_version(exe)))
    elif a == ["compiler-id"]:
        cmd_compiler_id()
    elif a == ["summary"]:
        cmd_summary()
    elif a == ["cloud-setup"]:
        cmd_cloud_setup()
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
