fn main() {
    println!("cargo:rustc-env=ADDED_VALUE=added-dependency");
    println!("cargo::metadata=token=added-dependency");
}
