use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let task = args.first().map(|s| s.as_str()).unwrap_or("help");

    match task {
        "bundle" => bundle(),
        "help" | "--help" | "-h" => print_help(),
        other => {
            eprintln!("Unknown task: {other}");
            print_help();
            std::process::exit(1);
        }
    }
}

fn print_help() {
    eprintln!(
        "\
Usage: cargo xtask <task>

Tasks:
  bundle    Build Bunnylol.app"
    );
}

fn project_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("xtask must be inside workspace")
        .to_path_buf()
}

fn bundle() {
    let root = project_root();
    let macos_src = root.join("macos/Bunnylol");
    let build_dir = root.join("target/bundle");
    let app_bundle = build_dir.join("Bunnylol.app");
    let contents = app_bundle.join("Contents");
    let macos_dir = contents.join("MacOS");
    let resources = contents.join("Resources");

    if build_dir.exists() {
        fs::remove_dir_all(&build_dir).expect("Failed to clean build dir");
    }
    fs::create_dir_all(&macos_dir).expect("Failed to create MacOS dir");
    fs::create_dir_all(&resources).expect("Failed to create Resources dir");

    // Build Rust static library
    println!("Building Rust static library...");
    run(Command::new("cargo")
        .args(["build", "--release", "--features", "server", "--no-default-features"])
        .current_dir(&root));

    let static_lib = root.join("target/release/libbunnylol.a");
    assert!(static_lib.exists(), "Static library not found at {}", static_lib.display());

    println!("Copying Info.plist...");
    fs::copy(macos_src.join("Info.plist"), contents.join("Info.plist"))
        .expect("Failed to copy Info.plist");

    println!("Generating menu bar icons...");
    let icon_src = macos_src.join("bunny.png");
    run(Command::new("sips")
        .args(["-z", "18", "18", icon_src.to_str().unwrap(), "--out"])
        .arg(resources.join("bunny.png")));
    run(Command::new("sips")
        .args(["-z", "36", "36", icon_src.to_str().unwrap(), "--out"])
        .arg(resources.join("bunny@2x.png")));

    // Compile Swift + link Rust static library into a single binary
    println!("Compiling Swift app (linking Rust server)...");
    run(Command::new("swiftc")
        .args([
            "-O",
            "-target", "arm64-apple-macos12.0",
            "-import-objc-header",
        ])
        .arg(macos_src.join("bunnylol.h"))
        .arg(macos_src.join("AppDelegate.swift"))
        .arg(&static_lib)
        .args(["-lz", "-lm", "-lc++", "-liconv", "-lresolv"])
        .arg("-o")
        .arg(macos_dir.join("Bunnylol")));

    println!("Stripping binary...");
    run(Command::new("strip").arg(macos_dir.join("Bunnylol")));

    fs::write(contents.join("PkgInfo"), b"APPL????").expect("Failed to write PkgInfo");

    println!();
    println!("Build complete: {}", app_bundle.display());
    println!();
    println!("To install:");
    println!("  cp -r '{}' /Applications/", app_bundle.display());
    println!();
    println!("To run:");
    println!("  open '{}'", app_bundle.display());
}

fn run(cmd: &mut Command) {
    let status = cmd.status().unwrap_or_else(|e| {
        panic!("Failed to run {:?}: {e}", cmd.get_program());
    });
    if !status.success() {
        panic!("{:?} failed with {status}", cmd.get_program());
    }
}
