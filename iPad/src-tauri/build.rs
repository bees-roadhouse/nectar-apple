fn main() {
    // Each command gets its own permission (`allow-begin-sign-in`, ...), so the launch page and the server's pages can
    // each be granted only the ones they need.
    let manifest = tauri_build::AppManifest::new().commands(&["begin_sign_in", "last_server", "finish_sign_in", "cancel_sign_in", "open_server", "refresh_token", "signed_out"]);
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(manifest)).expect("failed to run tauri-build");
}
