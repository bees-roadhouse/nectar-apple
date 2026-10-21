use tauri::{WebviewUrl, WebviewWindowBuilder};

/// The playback tracer for nectar-apple #127, on a prototype branch that never merges. One window opens either the
/// server's own web client with a test token injected (the handoff agreed with Forage on #127), or a local page that
/// plays a decided HLS URL in a native `<video>`. Everything comes from the launch environment (`SIMCTL_CHILD_*`).
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let env = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
            let server = env("NECTAR_SERVER").unwrap_or_else(|| "https://nectar.trh.beesroadhouse.com".into());
            // Every video starts muted: the simulator's sound reaches Nate's speakers.
            let mut script = String::from(
                "window.__NECTAR_SHELL__ = { version: 1, nativeHls: true };\
                 for (const ev of ['loadedmetadata', 'play', 'playing']) \
                 document.addEventListener(ev, (e) => { if (e.target && 'muted' in e.target) e.target.muted = true; }, true);",
            );
            if let Some(token) = env("NECTAR_TOKEN") {
                let t = serde_json::to_string(&token)?;
                script.push_str(&format!(
                    "try {{ sessionStorage.setItem('nectar_token', {t}); \
                     document.cookie = 'nectar_session=' + encodeURIComponent({t}) + '; Path=/; SameSite=Lax'; }} catch (e) {{}}"
                ));
            }
            let url = match env("NECTAR_TRACER").as_deref() {
                Some("native") => {
                    let master = serde_json::to_string(&env("NECTAR_MASTER").unwrap_or_default())?;
                    script.push_str(&format!("window.__TRACER__ = {{ master: {master} }};"));
                    WebviewUrl::App("index.html".into())
                }
                _ => WebviewUrl::External(format!("{server}{}", env("NECTAR_PATH").unwrap_or_else(|| "/".into())).parse()?),
            };
            WebviewWindowBuilder::new(app, "main", url).initialization_script(&script).build()?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running the tracer");
}
