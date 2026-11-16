use std::{env, path::Path};

fn main() {
    let version = env::var("DEP_RUSTBXL_PROBE_VERSION").unwrap();
    let upstream = env::var("DEP_RUSTBXL_PROBE_OUTPUT").unwrap();
    let current = env::var("OUT_DIR").unwrap();
    let target = env::var("TARGET").unwrap();
    assert!(Path::new(&upstream).is_dir());
    assert_eq!(upstream.contains(&format!("\\{target}\\")), current.contains(&format!("\\{target}\\")));
    assert!(!version.is_empty());
}
