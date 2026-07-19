fn main() {
    // ACCELERATE_URL is a secret fallback endpoint.
    //
    // Local builds:  set the env var before building.
    //   export ACCELERATE_URL=https://...
    //   cargo tauri build
    //
    // CI (GitHub Actions): store the value as a repository secret and expose it
    // only to the build job — never echo it or print it in workflow steps:
    //   env:
    //     ACCELERATE_URL: ${{ secrets.ACCELERATE_URL }}
    //
    // The `cargo:rustc-env=` directive below is consumed silently by Cargo and
    // does NOT appear in CI logs. Avoid printing the value anywhere else.
    let accelerate_url = std::env::var("ACCELERATE_URL").unwrap_or_default();
    println!("cargo:rustc-env=ACCELERATE_URL={}", accelerate_url);
    println!("cargo:rerun-if-env-changed=ACCELERATE_URL");
    // Tauri embeds the compiled web assets into the native binary. Without
    // this dependency edge, a standalone `cargo build --release` can ship a
    // new Rust backend with an older UI left in Cargo's codegen cache.
    println!("cargo:rerun-if-changed=../dist/index.html");

    // NekoPilot intentionally ships without a privileged macOS helper.
    // System-proxy mode runs sing-box as the signed-in user and needs no
    // XPC, root daemon, code-signing identity, or entitlement.
    #[cfg(target_os = "macos")]
    {
        if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
            // NSWindow.appearance override — workaround for Tauri 2.10 +
            // macOS 26 where setTheme() no-ops on the title bar.
            cc::Build::new()
                .file("src/macos_theme.m")
                .flag("-fobjc-arc")
                .flag("-fmodules")
                .compile("onebox_macos_theme");
            println!("cargo:rustc-link-lib=framework=Cocoa");
            println!("cargo:rerun-if-changed=src/macos_theme.m");
        }
    }

    tauri_build::build()
}
