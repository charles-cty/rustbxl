use marker::Marker;

include!(concat!(env!("OUT_DIR"), "/generated.rs"));

#[derive(Marker)]
struct App;

fn main() {
    assert!(std::path::Path::new(GENERATED_PATH).starts_with("/_/target"));
    println!("{}:{}:{}:{}:{}", engine::render(42), App.marker(), GENERATED,
        env!("BUILD_MARKER"), include_str!("../label.txt").trim());
    println!("manifest={}", env!("CARGO_MANIFEST_DIR"));
    println!("canonical={}", env!("CANONICAL_MANIFEST"));
    println!("features={}:{}", cfg!(feature = "default-marker"), cfg!(feature = "extra"));
    println!("cargo-config={}", cfg!(from_cargo_config));
    println!("generated-path={}", GENERATED_PATH);
    #[cfg(has_optional)]
    println!("optional={}", include_str!("../new-input.txt").trim());
}
