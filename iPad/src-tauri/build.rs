fn main() {
    // The sign-in sheet's class lives in AuthenticationServices, which nothing else links; without it the class
    // isn't found at run time (#144: the iPhone simulator panicked on the first tap).
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("ios") {
        println!("cargo:rustc-link-lib=framework=AuthenticationServices");
    }
    // Each command gets its own permission (`allow-begin-sign-in`, ...), so the launch page and the server's pages can
    // each be granted only the ones they need.
    let manifest = tauri_build::AppManifest::new().commands(&["begin_sign_in", "servers", "save_server", "remove_server", "open_saved", "resume", "finish_sign_in", "cancel_sign_in", "open_server", "refresh_token", "signed_out", "device", "open_approval"]);
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(manifest)).expect("failed to run tauri-build");
}
