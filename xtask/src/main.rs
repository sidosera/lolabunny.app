use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const APP_NAME: &str = "Bunnylol";
const LIB_NAME: &str = "libbunnylol.a";
const CARGO_FEATURES: &[&str] = &["server"];
const MACOS_DEPLOYMENT_TARGET: &str = "12.0";

const ICON_SOURCE: &str = "bunny.png";
const ICON_SIZE_1X: u32 = 18;
const ICON_SIZE_2X: u32 = 36;

const APP_ICON_SIZES: &[(u32, &str)] = &[
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
];

const SYSTEM_LIBS: &[&str] = &["-lz", "-lm", "-lc++", "-liconv", "-lresolv"];
const PKGINFO_CONTENT: &[u8] = b"APPL????";

const MACOS_SOURCE_DIR: &str = "macos/Bunnylol";
const BRIDGING_HEADER: &str = "bunnylol.h";
const SWIFT_SOURCE: &str = "AppDelegate.swift";
const INFO_PLIST: &str = "Info.plist";
const ENTITLEMENTS: &str = "Bunnylol.entitlements";

/// Ad-hoc identity; override with CODESIGN_IDENTITY env var for distribution builds.
const DEFAULT_SIGN_IDENTITY: &str = "-";

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
  bundle    Build {APP_NAME}.app"
    );
}

fn project_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("xtask must be inside workspace")
        .to_path_buf()
}

fn host_arch() -> &'static str {
    if cfg!(target_arch = "aarch64") {
        "aarch64"
    } else if cfg!(target_arch = "x86_64") {
        "x86_64"
    } else {
        panic!("Unsupported host architecture; expected aarch64 or x86_64");
    }
}

fn rust_target_triple(arch: &str) -> String {
    format!("{arch}-apple-darwin")
}

fn swiftc_target_triple(arch: &str) -> String {
    let swift_arch = match arch {
        "aarch64" => "arm64",
        other => other,
    };
    format!("{swift_arch}-apple-macos{MACOS_DEPLOYMENT_TARGET}")
}

fn bundle() {
    let arch = host_arch();
    let rust_target = rust_target_triple(arch);
    let swift_target = swiftc_target_triple(arch);

    println!("Architecture: {arch}");
    println!("Rust target:  {rust_target}");
    println!("Swift target: {swift_target}");
    println!();

    let root = project_root();
    let macos_src = root.join(MACOS_SOURCE_DIR);

    let build_dir = root.join("target/bundle");
    let app_bundle = build_dir.join(format!("{APP_NAME}.app"));
    let contents = app_bundle.join("Contents");
    let macos_dir = contents.join("MacOS");
    let resources = contents.join("Resources");

    if build_dir.exists() {
        fs::remove_dir_all(&build_dir).expect("Failed to clean build dir");
    }
    fs::create_dir_all(&macos_dir).expect("Failed to create MacOS dir");
    fs::create_dir_all(&resources).expect("Failed to create Resources dir");

    println!("Building Rust static library ({rust_target})...");
    run(Command::new("cargo")
        .args(["build", "--release", "--target", &rust_target])
        .args(["--features", &CARGO_FEATURES.join(",")])
        .arg("--no-default-features")
        .current_dir(&root));

    let static_lib = root
        .join("target")
        .join(&rust_target)
        .join("release")
        .join(LIB_NAME);
    assert!(
        static_lib.exists(),
        "Static library not found at {}",
        static_lib.display()
    );

    println!("Copying {INFO_PLIST}...");
    fs::copy(macos_src.join(INFO_PLIST), contents.join(INFO_PLIST))
        .expect("Failed to copy Info.plist");

    println!("Generating menu bar icons...");
    let icon_src = root.join(ICON_SOURCE);
    let icon_src_str = icon_src.to_str().expect("Non-UTF-8 icon path");
    generate_icon(icon_src_str, &resources, ICON_SIZE_1X, "bunny.png");
    generate_icon(icon_src_str, &resources, ICON_SIZE_2X, "bunny@2x.png");

    println!("Generating app icon...");
    generate_app_icns(icon_src_str, &resources);

    println!("Compiling Swift app (linking Rust, target {swift_target})...");
    run(Command::new("swiftc")
        .args(["-O", "-target", &swift_target, "-import-objc-header"])
        .arg(macos_src.join(BRIDGING_HEADER))
        .arg(macos_src.join(SWIFT_SOURCE))
        .arg(&static_lib)
        .args(SYSTEM_LIBS)
        .arg("-o")
        .arg(macos_dir.join(APP_NAME)));

    println!("Stripping binary...");
    run(Command::new("strip").arg(macos_dir.join(APP_NAME)));

    fs::write(contents.join("PkgInfo"), PKGINFO_CONTENT).expect("Failed to write PkgInfo");

    codesign(&app_bundle, &macos_src.join(ENTITLEMENTS));

    println!();
    println!("Build complete: {}", app_bundle.display());
    println!();
    println!("To install:");
    println!("  cp -r '{}' /Applications/", app_bundle.display());
    println!();
    println!("To run:");
    println!("  open '{}'", app_bundle.display());
}

fn generate_app_icns(src: &str, resources: &Path) {
    let iconset = resources.join("AppIcon.iconset");
    fs::create_dir_all(&iconset).expect("Failed to create iconset dir");

    for &(size, name) in APP_ICON_SIZES {
        generate_icon(src, &iconset, size, name);
    }

    run(Command::new("iconutil")
        .args(["--convert", "icns"])
        .arg(&iconset)
        .args(["--output"])
        .arg(resources.join("AppIcon.icns")));

    fs::remove_dir_all(&iconset).expect("Failed to clean up iconset dir");
}

fn generate_icon(src: &str, resources: &Path, size: u32, name: &str) {
    let size_str = size.to_string();
    run(Command::new("sips")
        .args(["-z", &size_str, &size_str, src, "--out"])
        .arg(resources.join(name)));
}

fn codesign(bundle: &Path, entitlements: &Path) {
    let identity = env::var("CODESIGN_IDENTITY").unwrap_or_else(|_| DEFAULT_SIGN_IDENTITY.into());
    println!("Signing with identity: {identity}");
    run(Command::new("codesign")
        .args(["--force", "--deep", "--sign", &identity])
        .arg("--entitlements")
        .arg(entitlements)
        .arg(bundle));
}

fn run(cmd: &mut Command) {
    let status = cmd.status().unwrap_or_else(|e| {
        panic!("Failed to run {:?}: {e}", cmd.get_program());
    });
    if !status.success() {
        panic!("{:?} failed with {status}", cmd.get_program());
    }
}
