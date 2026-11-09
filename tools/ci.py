#!/usr/bin/env python3
"""Toolchain setup and the job summary for .github/workflows/ci.yml (Python 3.9+, stdlib only).

    python tools/ci.py odin <tag> <dest>     # download (hash-pinned) + unpack an Odin release; add it to $GITHUB_PATH
    python tools/ci.py odinfmt <dest>        # build odinfmt from OLS at OLS_COMMIT with the odin on PATH
    python tools/ci.py godot                 # the official Godot editor (hash-pinned) in .toolchains/godot/<version>/
    python tools/ci.py ensure-ninja          # pip-install ninja if missing (only needed to build Box3D)
    python tools/ci.py compiler-id           # short id of the C compiler Box3D builds with (its CI cache key)
    python tools/ci.py summary               # markdown for $GITHUB_STEP_SUMMARY from out/

`odinfmt` also works locally: it is the supported way to install the pinned formatter (put <dest> on
PATH or set ODINFMT=<dest>/odinfmt). Every step is a no-op when its output already exists.
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
    log("ninja not on PATH: installing it from PyPI")
    subprocess.run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check", "ninja"], check=True)
    scripts = Path(sys.executable).parent / ("Scripts" if common.IS_WINDOWS else "")
    gh_append("GITHUB_PATH", str(scripts) + "\n")


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
    out += ["### T1-T9 (spec/CORE.md §4): %s" % ("PASS" if j.get("ok") else "**FAIL**"), "",
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
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
