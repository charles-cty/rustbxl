use std::{env, fs, path::Path, process::Command};

fn main() {
    if env::var_os("FIXTURE_GIT_QUERY").is_some() {
        let git = Command::new("git.exe").args(["rev-parse", "HEAD"]).output().unwrap();
        assert!(git.status.success());
        println!("cargo::metadata=git={}", String::from_utf8(git.stdout).unwrap().trim());
    }
    if env::var_os("FIXTURE_NATIVE_TOOLS").is_some() {
        let output = Path::new(&env::var("OUT_DIR").unwrap()).join("native");
        let configured = Command::new("cmake.exe")
            .args(["-S", "native", "-B"]).arg(&output)
            .args(["-G", "Ninja", "-DCMAKE_BUILD_TYPE=Debug"])
            .status().unwrap();
        assert!(configured.success());
        assert!(Command::new("cmake.exe").arg("--build").arg(&output).status().unwrap().success());
        assert!(output.join("native_probe.lib").is_file());
        let native = Command::new(output.join("native_probe_tool.exe")).output().unwrap();
        assert!(native.status.success());
        println!("cargo::metadata=native={}", String::from_utf8(native.stdout).unwrap().trim());
    }
    let compiler = env::var("RUSTC").unwrap();
    let direct = Command::new(&compiler).args(["--version", "--verbose"]).output().unwrap();
    assert!(direct.status.success());
    let mut wrapped = if let Ok(wrapper) = env::var("RUSTC_WRAPPER") {
        let mut command = Command::new(wrapper);
        command.arg(&compiler);
        command
    } else {
        Command::new(&compiler)
    };
    for _ in 0..2 {
        let version = wrapped.args(["--version", "--verbose"]).output().unwrap();
        assert!(version.status.success());
        assert_eq!(version.stdout, direct.stdout);
        wrapped = Command::new(&compiler);
    }
    let output = env::var("OUT_DIR").unwrap();
    let probes = Path::new(&output).join("probes");
    fs::create_dir_all(&probes).unwrap();
    let mode = fs::read_to_string("probe-mode.txt").unwrap();
    let source = if mode.trim() == "success" { "probe.rs" } else { "probe-error.rs" };
    let probe = Command::new(&compiler)
        .args(["--crate-name", "capability", "--crate-type", "lib", "--emit=metadata", "--out-dir"])
        .arg(&probes).arg(source).output().unwrap();
    assert_eq!(probe.status.success(), mode.trim() == "success");
    let failed = Command::new(&compiler)
        .args(["--crate-name", "expected_failure", "--crate-type", "lib", "--emit=metadata", "--out-dir"])
        .arg(&probes).arg("probe-error.rs").output().unwrap();
    assert!(!failed.status.success());
    assert!(String::from_utf8(failed.stderr).unwrap().contains("compiler capability probe must fail"));
    let metadata = fs::read_to_string("metadata.txt").unwrap();
    if metadata.starts_with("changed") {
        println!("cargo::metadata=added-key=new metadata key");
    }
    println!("cargo:VERSION=discarded");
    println!("cargo:VERSION={}", metadata.trim());
    println!("cargo::metadata=detail-key=left=right with spaces");
    println!("cargo:metadata=literal=single-colon");
    println!("cargo::metadata=probe={}", probe.status.success());
    println!("cargo::metadata=output={output}");
    for input in ["metadata.txt", "probe-mode.txt", "probe.rs", "probe-error.rs"] {
        println!("cargo:rerun-if-changed={input}");
    }
}
