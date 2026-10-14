use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=src/platform/macos_native.c");

    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }

    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR is set"));
    let object = out_dir.join("macos_native.o");
    let archive = out_dir.join("libperfmon_macos_native.a");

    let status = Command::new("cc")
        .args(["-c", "src/platform/macos_native.c", "-o"])
        .arg(&object)
        .status()
        .expect("failed to run the macOS C compiler");
    assert!(status.success(), "macOS native helper compilation failed");

    let status = Command::new("ar")
        .args(["crus"])
        .arg(&archive)
        .arg(&object)
        .status()
        .expect("failed to archive the macOS native helper");
    assert!(status.success(), "macOS native helper archiving failed");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=perfmon_macos_native");
    println!("cargo:rustc-link-lib=framework=IOKit");
    println!("cargo:rustc-link-lib=framework=CoreFoundation");
    println!("cargo:rustc-link-lib=proc");
}
