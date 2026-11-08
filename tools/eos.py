#!/usr/bin/env python3
"""The EOS C SDK files unified needs, in third_party/eos/ (git-ignored).

    python tools/eos.py                 # ensure third_party/eos/ exists (local SDK or the release)
    python tools/eos.py pack            # zip the pruned SDK -> out/eos-sdk-<version>.zip (for the release)
    python tools/eos.py upload          # pack, then upload it to the draft GitHub release eos-sdk-<version>
    python tools/eos.py defines         # print the -define flags for the EOS_* environment variables
                                        # (build scripts: eos.defines(), and eos.redacted(cmd) to log)
    python tools/eos.py --json          # ensure, then print {"root", "version", "lib"} as one JSON line

Only the pruned SDK is kept: SDK/Include/*, the shipping libraries for macOS (universal dylib),
Windows x64 (dll + import lib) and Linux x64 (so), and a VERSION file. Sources, in order:
  1. third_party/eos/ already populated with the pinned version: done (~1 ms),
  2. a local SDK unzipped by hand: $UNIFIED_EOS_SDK or $EOS_SDK (the unzipped root or its SDK/ dir),
     ~/tools/eos-sdk, or ~/tools/EOS-SDK-*-v<version>,
  3. the asset eos-sdk-<version>.zip of the draft release eos-sdk-<version> of FylmTM/unified, through
     the GitHub API with resumable download (token: $GH_TOKEN / $GITHUB_TOKEN, else `gh auth token`;
     a draft is visible to tokens with push access, so CI jobs need `contents: write`).
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

import common
from common import REPO, log

VERSION = "1.19.2.1"
REPO_SLUG = "FylmTM/unified"
RELEASE = "eos-sdk-" + VERSION
ASSET = RELEASE + ".zip"
ROOT = REPO / "third_party" / "eos"
SDK_FILES = [
    "SDK/Bin/libEOSSDK-Mac-Shipping.dylib",
    "SDK/Bin/EOSSDK-Win64-Shipping.dll",
    "SDK/Bin/libEOSSDK-Linux-Shipping.so",
    "SDK/Lib/EOSSDK-Win64-Shipping.lib",
]
LIB_NAMES = {
    "macos": "libEOSSDK-Mac-Shipping.dylib",
    "windows": "EOSSDK-Win64-Shipping.dll",
    "linux": "libEOSSDK-Linux-Shipping.so",
}
ENV_DEFINES = ["EOS_PRODUCT_ID", "EOS_SANDBOX_ID", "EOS_DEPLOYMENT_ID", "EOS_CLIENT_ID", "EOS_CLIENT_SECRET"]


def ready():
    v = ROOT / "VERSION"
    return v.is_file() and v.read_text().strip() == VERSION and (ROOT / "SDK" / "Include" / "eos_sdk.h").is_file()


def local_sdk():
    cands = []
    for k in ("UNIFIED_EOS_SDK", "EOS_SDK"):
        if os.environ.get(k):
            p = Path(os.environ[k])
            cands.append(p.parent if p.name == "SDK" else p)  # the unzipped root or its SDK/ dir
    tools = Path.home() / "tools"
    cands.append(tools / "eos-sdk")
    cands += sorted(tools.glob("EOS-SDK-*-v" + VERSION))
    for c in cands:
        if (c / "SDK" / "Include" / "eos_sdk.h").is_file():
            return c
    return None


def copy_pruned(src, dst):
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src / "SDK" / "Include", dst / "SDK" / "Include")
    for rel in SDK_FILES:
        s = src / rel
        if not s.is_file():
            raise SystemExit("eos: %s is missing in %s" % (rel, src))
        (dst / rel).parent.mkdir(parents=True, exist_ok=True)
        # A fresh file, not a clone: on macOS a clone of a quarantined download keeps a Gatekeeper
        # state under which dlopen blocks indefinitely, even after the xattr is removed.
        with open(s, "rb") as fi, open(dst / rel, "wb") as fo:
            shutil.copyfileobj(fi, fo, 1 << 20)
    (dst / "VERSION").write_text(VERSION + "\n")
    unquarantine(dst)


def unquarantine(root):
    """macOS: a browser-downloaded SDK carries com.apple.quarantine, and dlopen of the (Epic-signed)
    dylib then blocks in a Gatekeeper assessment that may wait for a user prompt. The staged copy is
    ours, so drop the flag from it (the original download keeps it)."""
    if common.IS_MACOS:
        subprocess.run(["xattr", "-dr", "com.apple.quarantine", str(root)], capture_output=True)


def gh_token():
    for k in ("GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(k):
            return os.environ[k]
    if shutil.which("gh"):
        r = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    raise SystemExit("eos: no local SDK and no GitHub token (GH_TOKEN, or `gh auth login`) to fetch %s" % RELEASE)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def asset_url(token):
    """The signed download URL of the release asset (drafts are only listed, not fetchable by tag)."""
    api = "https://api.github.com/repos/%s/releases?per_page=100" % REPO_SLUG
    hdr = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json"}
    with urllib.request.urlopen(urllib.request.Request(api, headers=hdr), timeout=30) as r:
        releases = json.load(r)
    for rel in releases:
        if rel.get("tag_name") == RELEASE:
            for a in rel.get("assets", []):
                if a["name"] == ASSET:
                    req = urllib.request.Request(a["url"], headers=dict(hdr, Accept="application/octet-stream"))
                    try:
                        urllib.request.build_opener(_NoRedirect).open(req, timeout=30)
                    except urllib.error.HTTPError as e:
                        if e.code in (301, 302, 303, 307, 308):
                            return e.headers["Location"], a["size"]
                        raise
    raise SystemExit("eos: release %s with asset %s not found in %s" % (RELEASE, ASSET, REPO_SLUG))


def download(get_url, size, dest):
    """GET with resume: connections that drop mid-file continue from where they stopped. The signed
    asset URL is single-use, so each attempt asks the API for a fresh one."""
    with open(dest, "wb"):
        pass
    for attempt in range(12):
        have = dest.stat().st_size
        if have >= size:
            return
        req = urllib.request.Request(get_url(), headers={"Range": "bytes=%d-" % have})
        try:
            with urllib.request.urlopen(req, timeout=60) as r, open(dest, "ab") as f:
                if have and r.status != 206:
                    raise SystemExit("eos: the asset host ignored the Range request")
                shutil.copyfileobj(r, f, 1 << 20)
        except (OSError, urllib.error.URLError) as e:
            log("eos: download interrupted at %d / %d bytes (%s), resuming" % (dest.stat().st_size, size, e))
            time.sleep(min(2 * (attempt + 1), 10))
    if dest.stat().st_size != size:
        raise SystemExit("eos: downloading %s failed" % ASSET)


def fetch_release():
    tmp = REPO / "out" / "eos-download"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    token = gh_token()
    _, size = asset_url(token)
    log("eos: downloading %s (%.1f MB) from draft release %s" % (ASSET, size / 1e6, RELEASE))
    download(lambda: asset_url(token)[0], size, tmp / ASSET)
    if ROOT.exists():
        shutil.rmtree(ROOT)
    with zipfile.ZipFile(tmp / ASSET) as z:
        for m in z.namelist():
            # The zip holds only SDK/... and VERSION; refuse anything that would escape ROOT.
            if m.startswith("/") or ".." in Path(m).parts:
                raise SystemExit("eos: unexpected path in %s: %s" % (ASSET, m))
        z.extractall(ROOT)
    shutil.rmtree(tmp)
    unquarantine(ROOT)


def ensure():
    """Makes third_party/eos/ hold the pinned SDK; returns its root."""
    if ready():
        return ROOT
    t0 = time.time()
    src = local_sdk()
    if src:
        log("eos: copying the SDK from %s" % src)
        copy_pruned(src, ROOT)
    else:
        fetch_release()
    if not ready():
        raise SystemExit("eos: %s is incomplete after setup" % ROOT)
    log("eos: SDK %s ready in %.1f s" % (VERSION, time.time() - t0))
    return ROOT


def lib_path(os_name=None):
    return ROOT / "SDK" / "Bin" / LIB_NAMES[os_name or common.host_os()]


def pack():
    ensure()
    out = REPO / "out" / ASSET
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        z.write(ROOT / "VERSION", "VERSION")
        for p in sorted((ROOT / "SDK").rglob("*")):
            if p.is_file():
                z.write(p, p.relative_to(ROOT).as_posix())
    log("eos: packed %s (%.1f MB)" % (out, out.stat().st_size / 1e6))
    return out


def upload():
    out = pack()
    have = subprocess.run(["gh", "release", "view", RELEASE, "-R", REPO_SLUG], capture_output=True).returncode == 0
    if not have:
        # A draft release: no git tag is created until it is published, so it can't be mistaken for
        # a game release; `gh release download` still finds it with repo access.
        cmd = ["gh", "release", "create", RELEASE, "-R", REPO_SLUG, "--draft", "--title",
               "EOS SDK %s (CI dependency)" % VERSION, "--notes",
               "Pruned EOS C SDK for CI (headers + macOS/Windows/Linux shipping libraries). "
               "Fetched by tools/eos.py. Not a game release; never publish."]
        log("+ " + " ".join(cmd))
        if subprocess.run(cmd).returncode != 0:
            raise SystemExit("eos: creating the release failed")
    cmd = ["gh", "release", "upload", RELEASE, str(out), "-R", REPO_SLUG, "--clobber"]
    log("+ " + " ".join(cmd))
    if subprocess.run(cmd).returncode != 0:
        raise SystemExit("eos: upload failed")


def defines():
    """The Odin -define flags that compile the credentials in (release builds); empty if unset."""
    flags = []
    for k in ENV_DEFINES:
        v = os.environ.get(k, "")
        if v:
            flags.append("-define:%s=%s" % (k, v))
    return flags


def redacted(cmd):
    """`cmd` for logging: the values of EOS -define flags replaced (the client secret ships in builds
    but never goes into logs)."""
    out = []
    for a in cmd:
        a = str(a)
        for k in ENV_DEFINES:
            if a.startswith("-define:%s=" % k):
                a = "-define:%s=***" % k
        out.append(a)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", nargs="?", default="ensure", choices=["ensure", "pack", "upload", "defines"])
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.cmd == "pack":
        pack()
    elif a.cmd == "upload":
        upload()
    elif a.cmd == "defines":
        print(" ".join(defines()))
    else:
        root = ensure()
        if a.json:
            print(json.dumps({"root": str(root), "version": VERSION, "lib": str(lib_path())}))


if __name__ == "__main__":
    main()
