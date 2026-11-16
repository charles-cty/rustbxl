use std::{env, fs, path::Path};

fn main() {
    let version = env::var("DEP_RUSTBXL_PROBE_VERSION").unwrap();
    let detail = env::var("DEP_RUSTBXL_PROBE_DETAIL_KEY").unwrap();
    assert_eq!(env::var("DEP_RUSTBXL_PROBE_METADATA").unwrap(), "literal=single-colon");
    assert!(env::var_os("DEP_RUSTBXL_PROBE_LITERAL").is_none());
    let probe = env::var("DEP_RUSTBXL_PROBE_PROBE").unwrap();
    let upstream = env::var("DEP_RUSTBXL_PROBE_OUTPUT").unwrap();
    assert!(Path::new(&upstream).is_dir());
    let target = env::var("TARGET").unwrap();
    assert!(upstream.contains(&format!("\\{target}\\")));
    println!("cargo:rustc-env=LINKS_MARKER={version}:{detail}:{probe}");
    println!("cargo:rustc-env=ADDED_METADATA={}", env::var("DEP_RUSTBXL_PROBE_ADDED_KEY").unwrap_or_else(|_| "absent".into()));
    if let Ok(git) = env::var("DEP_RUSTBXL_PROBE_GIT") {
        println!("cargo:rustc-env=GIT_MARKER={git}");
    }
    if let Ok(native) = env::var("DEP_RUSTBXL_PROBE_NATIVE") {
        println!("cargo:rustc-env=NATIVE_MARKER={native}");
    }
    let optional = Path::new("optional.txt").exists();
    let members = fs::read_dir("entries")
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .filter(|name| !name.to_string_lossy().starts_with('.'))
        .count();
    let external = fs::read_to_string(env::var("FIXTURE_EXTERNAL_INPUT").unwrap()).unwrap();
    let token = env::var("FIXTURE_TOKEN").unwrap();
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=optional.txt");
    println!("cargo:rerun-if-changed=entries");
    println!("cargo:rerun-if-changed={}", env::var("FIXTURE_EXTERNAL_INPUT").unwrap());
    println!("cargo:rerun-if-env-changed=FIXTURE_TOKEN");
    println!("cargo:rustc-env=BUILD_MARKER={}:{}:{}:{}", optional, members, external.trim(), token);
    println!("cargo:rustc-env=CANONICAL_MANIFEST={}", fs::canonicalize(env::var("CARGO_MANIFEST_DIR").unwrap()).unwrap().display());
    println!("cargo:rustc-check-cfg=cfg(has_optional)");
    if optional {
        println!("cargo:rustc-cfg=has_optional");
    }
    fs::copy("generated.rs.in", Path::new(&env::var("OUT_DIR").unwrap()).join("generated.rs")).unwrap();
}
