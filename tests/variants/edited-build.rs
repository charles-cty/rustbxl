use std::{env, fs, path::Path};

fn main() {
    let optional = Path::new("optional.txt").exists();
    let members = fs::read_dir("entries").unwrap()
        .map(|entry| entry.unwrap().file_name())
        .filter(|name| !name.to_string_lossy().starts_with('.')).count();
    let _external = fs::read_to_string(env::var("FIXTURE_EXTERNAL_INPUT").unwrap()).unwrap();
    let token = env::var("FIXTURE_TOKEN").unwrap();
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=optional.txt");
    println!("cargo:rerun-if-changed=entries");
    println!("cargo:rustc-env=BUILD_MARKER={}:{}:script-changed:{}", optional, members, token);
    println!("cargo:rustc-env=CANONICAL_MANIFEST={}", fs::canonicalize(env::var("CARGO_MANIFEST_DIR").unwrap()).unwrap().display());
    println!("cargo:rustc-check-cfg=cfg(has_optional)");
    if optional { println!("cargo:rustc-cfg=has_optional"); }
    fs::copy("generated.rs.in", Path::new(&env::var("OUT_DIR").unwrap()).join("generated.rs")).unwrap();
}
