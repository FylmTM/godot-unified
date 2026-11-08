#!/usr/bin/env python3
"""Small helpers used by .github/workflows/ci.yml (Python 3.9+, stdlib only).

    python tools/ci.py detect <lang>             # sets `present=true|false` in $GITHUB_OUTPUT
    python tools/ci.py ensure-ninja              # pip-installs ninja if it isn't on PATH
    python tools/ci.py odin <tag> <dest>         # downloads + unpacks an Odin release, adds it to $GITHUB_PATH
    python tools/ci.py summary <artifacts-dir>   # markdown comparison table from all check.json files
"""

import io
import json
import os
import subprocess
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

import common
from common import REPO, log

LANGS = ["cpp", "odin", "rust"]
PLATFORMS = ["linux-x64", "windows-x64"]
TESTS = ["T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8", "T9"]


def gh_append(var, text):
    path = os.environ.get(var)
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text)
    else:
        log("[%s] %s" % (var, text.rstrip()))


def cmd_detect(lang):
    present = (REPO / "impl" / lang / "build.py").exists()
    gh_append("GITHUB_OUTPUT", "present=%s\n" % ("true" if present else "false"))
    if not present:
        msg = "impl/%s/build.py does not exist yet: skipping the %s job." % (lang, lang)
        log(msg)
        gh_append("GITHUB_STEP_SUMMARY", "%s\n" % msg)


def cmd_ensure_ninja():
    if common.which("ninja"):
        log("ninja: " + common.which("ninja"))
        return
    log("ninja not on PATH: installing it from PyPI")
    subprocess.run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check", "ninja"], check=True)
    scripts = Path(sys.executable).parent / ("Scripts" if common.IS_WINDOWS else "")
    gh_append("GITHUB_PATH", str(scripts) + "\n")


def find_odin(dest, exe):
    """The compiler binary: the shallowest regular file named odin[.exe] (core/odin/ is a directory)."""
    if not dest.exists():
        return []
    return sorted((p for p in dest.rglob(exe) if p.is_file()), key=lambda p: (len(p.parts), str(p)))


def cmd_odin(tag, dest):
    dest = Path(dest).resolve()
    exe = "odin.exe" if common.IS_WINDOWS else "odin"
    found = find_odin(dest, exe)
    if not found:
        osname = {"linux": "linux", "windows": "windows", "macos": "macos"}[common.host_os()]
        arch = {"x64": "amd64", "arm64": "arm64"}[common.host_arch()]
        ext = "zip" if common.IS_WINDOWS else "tar.gz"
        asset = "odin-%s-%s-%s.%s" % (osname, arch, tag, ext)
        url = "https://github.com/odin-lang/Odin/releases/download/%s/%s" % (tag, asset)
        log("odin: downloading " + url)
        data = urllib.request.urlopen(url, timeout=600).read()
        dest.mkdir(parents=True, exist_ok=True)
        if ext == "zip":
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                z.extractall(dest)
        else:
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as t:
                if hasattr(tarfile, "data_filter"):
                    t.extractall(dest, filter="data")
                else:
                    t.extractall(dest)
        found = find_odin(dest, exe)
        if not found:
            raise SystemExit("odin: %s not found in %s" % (exe, asset))
    odin = found[0]
    if not common.IS_WINDOWS:
        odin.chmod(0o755)
    gh_append("GITHUB_PATH", str(odin.parent) + "\n")
    log("odin: " + str(odin))


def fmt_cell(t):
    if t is None:
        return "-"
    s = t.get("status", "?").upper()
    return "%s %.0fs" % (s, t.get("seconds", 0))


def cmd_summary(art_dir):
    runs = {}
    for p in sorted(Path(art_dir).rglob("check.json")):
        try:
            j = json.loads(p.read_text())
        except ValueError:
            continue
        runs[(j.get("lang"), j.get("platform"))] = j
    cols = [(l, p) for l in LANGS for p in PLATFORMS]
    out = ["## unified core: T1-T9 (spec/CORE.md §4)", ""]
    out.append("| | " + " | ".join("%s<br>%s" % c for c in cols) + " |")
    out.append("|---|" + "---|" * len(cols))
    row = ["build"]
    for c in cols:
        j = runs.get(c)
        if j is None:
            row.append("not run")
        else:
            b = j.get("build") or {}
            row.append(("ok %.0fs" % b.get("seconds", 0)) if b.get("ok") else "FAIL")
    out.append("| " + " | ".join(row) + " |")
    for t in TESTS:
        out.append("| %s | " % t + " | ".join(
            fmt_cell((runs.get(c) or {}).get("tests", {}).get(t)) if c in runs else "-" for c in cols) + " |")
    out.append("| **all** | " + " | ".join(
        ("**PASS**" if runs[c].get("ok") else "**FAIL**") if c in runs else "-" for c in cols) + " |")
    out += ["", "Columns without a check.json were skipped (no impl/<lang>/build.py yet) or cancelled.", ""]

    out += ["### T9 bench (`bench --enemies 1000 --window 8`; target: step + 8-tick re-sim <= 6 ms)", "",
            "| lang | platform | step mean / p99 (us) | re-sim mean / p99 (us) | step + re-sim (ms) | save / restore (us) "
            "| snapshot (KiB) |", "|---|---|---|---|---|---|---|"]
    for c in cols:
        t9 = (runs.get(c) or {}).get("tests", {}).get("T9")
        d = (t9 or {}).get("data") or {}
        if "step_mean_us" not in d:
            continue
        out.append("| %s | %s | %.0f / %.0f | %.0f / %.0f | %.2f%s | %.0f / %.0f | %.0f |" % (
            c[0], c[1], d["step_mean_us"], d["step_p99_us"], d["resim_mean_us"], d["resim_p99_us"],
            d["step_plus_resim_us"] / 1000, "" if d["within_target"] else " (over)",
            d["save_mean_us"], d["restore_mean_us"], d["snapshot_bytes"] / 1024))
    fails = [(c, t, r) for c in cols for t, r in (runs.get(c) or {}).get("tests", {}).items()
             if r.get("status") != "pass"]
    if fails:
        out += ["", "### Failures", ""]
        for (l, p), t, r in fails:
            out.append("- **%s %s %s**: %s" % (l, p, t, r.get("detail", "").replace("\n", " ")[:500]))
    print("\n".join(out))


def main():
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "detect":
        cmd_detect(a[1])
    elif a == ["ensure-ninja"]:
        cmd_ensure_ninja()
    elif len(a) == 3 and a[0] == "odin":
        cmd_odin(a[1], a[2])
    elif len(a) == 2 and a[0] == "summary":
        cmd_summary(a[1])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
