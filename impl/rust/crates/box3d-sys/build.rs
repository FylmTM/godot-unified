//! Links the static Box3D library built by `tools/box3d.py`.
//!
//! `impl/rust/build.py` runs `python tools/box3d.py --json` and passes `BOX3D_LIB_DIR` and
//! `BOX3D_LINK_LIBS` (comma separated). When they are absent (plain `cargo test`), this script runs
//! tools/box3d.py itself, with `--arch x86_64` when cross-building for x86_64-apple-darwin on an
//! arm64 Mac (the Rosetta check).

use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=BOX3D_LIB_DIR");
    println!("cargo:rerun-if-env-changed=BOX3D_LINK_LIBS");
    let (lib_dir, link_libs) = match std::env::var("BOX3D_LIB_DIR") {
        Ok(dir) => {
            let libs = std::env::var("BOX3D_LINK_LIBS").unwrap_or_default();
            (PathBuf::from(dir), libs.split(',').filter(|s| !s.is_empty()).map(String::from).collect())
        }
        Err(_) => run_box3d_py(),
    };
    let windows = std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows");
    let lib = lib_dir.join(if windows { "box3d.lib" } else { "libbox3d.a" });
    assert!(lib.exists(), "box3d-sys: {} not found (run python tools/box3d.py)", lib.display());
    println!("cargo:rerun-if-changed={}", lib.display());
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=box3d");
    for l in link_libs {
        println!("cargo:rustc-link-lib={l}");
    }
}

fn run_box3d_py() -> (PathBuf, Vec<String>) {
    let manifest = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let repo = manifest.join("../../../..");
    let script = repo.join("tools").join("box3d.py");
    let mut args = vec![script.to_string_lossy().into_owned(), "--json".to_string()];
    let host = std::env::var("HOST").unwrap_or_default();
    let target = std::env::var("TARGET").unwrap_or_default();
    if target != host && target.starts_with("x86_64-apple") {
        args.push("--arch".into());
        args.push("x86_64".into());
    }
    let pythons: &[&str] = if cfg!(windows) { &["python", "py", "python3"] } else { &["python3", "python"] };
    for py in pythons {
        let Ok(out) = Command::new(py).args(&args).output() else { continue };
        if !out.status.success() {
            panic!("box3d-sys: {py} tools/box3d.py failed:\n{}", String::from_utf8_lossy(&out.stderr));
        }
        let stdout = String::from_utf8_lossy(&out.stdout);
        let line = stdout.lines().rev().find(|l| !l.trim().is_empty()).expect("box3d.py printed nothing");
        let lib_dir = json_str(line, "lib_dir").expect("box3d.json: lib_dir");
        let libs = json_list(line, "link_libs");
        return (PathBuf::from(lib_dir), libs);
    }
    panic!("box3d-sys: no python interpreter found to run tools/box3d.py (or set BOX3D_LIB_DIR)");
}

/// Minimal extraction of `"key": "value"` from box3d.py's one-line JSON (no serde in build scripts).
fn json_str(line: &str, key: &str) -> Option<String> {
    let pat = format!("\"{key}\": \"");
    let start = line.find(&pat)? + pat.len();
    let end = line[start..].find('"')? + start;
    Some(line[start..end].replace("\\\\", "\\"))
}

fn json_list(line: &str, key: &str) -> Vec<String> {
    let pat = format!("\"{key}\": [");
    let Some(start) = line.find(&pat).map(|s| s + pat.len()) else { return Vec::new() };
    let end = line[start..].find(']').map(|e| e + start).unwrap_or(start);
    line[start..end].split(',').map(|s| s.trim().trim_matches('"').to_string()).filter(|s| !s.is_empty()).collect()
}
