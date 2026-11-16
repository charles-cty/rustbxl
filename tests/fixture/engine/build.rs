fn main() {
    assert_eq!(probe_support::value(), "probe-support");
    assert!(std::env::vars().all(|(key, _)| !key.starts_with("DEP_RUSTBXL_PROBE_")));
}
