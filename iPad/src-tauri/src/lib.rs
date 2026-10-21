mod auth;
mod handoff;
mod store;

use serde::Serialize;
use std::sync::Mutex;
use store::TokenStore;
use tauri::ipc::CapabilityBuilder;
use tauri::{AppHandle, Manager, State, WebviewUrl, WebviewWindowBuilder};

/// What the iPad calls itself in a person's device list (nectar shows it on `/activate` and Settings → Devices).
const DEVICE_NAME: &str = "Nectar on iPad";

/// HTTP for the sign-in, through reqwest. Tokens travel in form bodies and headers, never in URLs, and nothing here
/// logs a request.
struct Net(reqwest::Client);

impl auth::Http for Net {
    async fn get(&self, url: &str) -> Result<auth::Reply, String> {
        Self::reply(self.0.get(url).send().await).await
    }

    async fn post_form(&self, url: &str, form: &[(&str, &str)]) -> Result<auth::Reply, String> {
        Self::reply(self.0.post(url).form(form).send().await).await
    }
}

impl Net {
    async fn reply(sent: reqwest::Result<reqwest::Response>) -> Result<auth::Reply, String> {
        let response = sent.map_err(|e| e.without_url().to_string())?;
        let status = response.status().as_u16();
        let body = response.bytes().await.map_err(|e| e.without_url().to_string())?.to_vec();
        Ok(auth::Reply { status, body })
    }
}

/// The server the shell is signed in to.
struct Session {
    origin: String,
    endpoints: auth::Endpoints,
    access: String,
}

struct Shell {
    net: Net,
    store: store::Keychain,
    session: Mutex<Option<Session>>,
    pending: Mutex<Option<(String, auth::Endpoints, auth::DeviceCode)>>,
}

/// What the launch page shows while it waits for a person to approve.
#[derive(Serialize)]
struct CodeView {
    user_code: String,
    verification_uri: String,
    expires_in: u64,
    qr_svg: String,
}

#[tauri::command]
async fn begin_sign_in(server: String, shell: State<'_, Shell>) -> Result<CodeView, String> {
    let origin = handoff::server_origin(&server)?;
    let endpoints = auth::discover(&shell.net, &origin).await.map_err(|e| e.to_string())?;
    let code = auth::start(&shell.net, &endpoints, DEVICE_NAME).await.map_err(|e| e.to_string())?;
    let target = code.verification_uri_complete.clone().unwrap_or_else(|| code.verification_uri.clone());
    let qr_svg = qrcode::QrCode::new(target.as_bytes())
        .map(|qr| qr.render::<qrcode::render::svg::Color>().min_dimensions(240, 240).build())
        .unwrap_or_default();
    let view = CodeView { user_code: code.user_code.clone(), verification_uri: code.verification_uri.clone(), expires_in: code.expires_in, qr_svg };
    *shell.pending.lock().unwrap() = Some((origin, endpoints, code));
    Ok(view)
}

/// Waits for the person to approve the code shown, then opens their server, signed in.
#[tauri::command]
async fn finish_sign_in(app: AppHandle, shell: State<'_, Shell>) -> Result<(), String> {
    let (origin, endpoints, code) = shell.pending.lock().unwrap().take().ok_or("Ask for a code first.")?;
    match auth::poll(&shell.net, &endpoints, &code, tokio::time::sleep).await.map_err(|e| e.to_string())? {
        auth::Outcome::Approved(tokens) => {
            signed_in(&app, &shell, origin, endpoints, tokens)?;
            Ok(())
        }
        auth::Outcome::Denied => Err("The code was declined on the other device.".into()),
        auth::Outcome::Expired => Err("The code ran out. Ask for a new one.".into()),
    }
}

/// From the server's pages, when nectar refuses the web client's token (nectar #750): a fresh access token, or
/// `null` when the session is over, so the web client signs out and calls `signed_out`.
#[tauri::command]
async fn refresh_token(shell: State<'_, Shell>) -> Result<Option<String>, String> {
    let Some((origin, endpoints)) = shell.session.lock().unwrap().as_ref().map(|s| (s.origin.clone(), s.endpoints.clone())) else {
        return Ok(None);
    };
    let Some(refresh) = shell.store.refresh_token(&origin) else { return Ok(None) };
    match auth::refresh(&shell.net, &endpoints, &refresh).await {
        Ok(Some(tokens)) => {
            if let Some(rotated) = &tokens.refresh_token {
                shell.store.save_refresh_token(&origin, rotated)?;
            }
            if let Some(session) = shell.session.lock().unwrap().as_mut() {
                session.access = tokens.access_token.clone();
            }
            Ok(Some(tokens.access_token))
        }
        Ok(None) => {
            shell.store.forget(&origin);
            Ok(None)
        }
        // Offline isn't a sign-out: keep the refresh token, and let the web client's next refused call try again.
        Err(e) => Err(e.to_string()),
    }
}

/// From the server's pages once the web client has signed out: end this device's session, forget its token, and
/// go back to the launch page.
#[tauri::command]
async fn signed_out(app: AppHandle, shell: State<'_, Shell>) -> Result<(), String> {
    let session = shell.session.lock().unwrap().take();
    if let Some(session) = session {
        revoke(&shell.net.0, &session).await;
        shell.store.forget(&session.origin);
    }
    show_launch_page(&app)
}

/// Best effort: nectar's own device sign-out, with the session's last access token. A dead token can't, and needn't.
async fn revoke(client: &reqwest::Client, session: &Session) {
    #[derive(serde::Deserialize)]
    struct Devices {
        devices: Vec<Device>,
    }
    #[derive(serde::Deserialize)]
    struct Device {
        id: String,
        current: bool,
    }
    let list = client.get(format!("{}/api/v1/auth/devices", session.origin)).bearer_auth(&session.access).send().await;
    let Ok(devices) = (match list {
        Ok(response) if response.status().is_success() => response.json::<Devices>().await,
        _ => return,
    }) else {
        return;
    };
    if let Some(current) = devices.devices.iter().find(|d| d.current) {
        let _ = client.delete(format!("{}/api/v1/auth/devices/{}", session.origin, current.id)).bearer_auth(&session.access).send().await;
    }
}

fn signed_in(app: &AppHandle, shell: &Shell, origin: String, endpoints: auth::Endpoints, tokens: auth::Tokens) -> Result<(), String> {
    if let Some(refresh) = &tokens.refresh_token {
        shell.store.save_refresh_token(&origin, refresh)?;
    }
    shell.store.save_last_server(&origin)?;
    let landing = handoff::landing_url(&origin, &tokens.access_token);
    *shell.session.lock().unwrap() = Some(Session { origin: origin.clone(), endpoints, access: tokens.access_token });
    allow_server(app, &origin);
    let window = app.get_webview_window("main").ok_or("no window")?;
    window.navigate(landing.parse().map_err(|_| "bad server address")?).map_err(|e| e.to_string())
}

/// The server's pages may call refresh and sign-out, and nothing else. Added once per origin; a repeat is harmless.
fn allow_server(app: &AppHandle, origin: &str) {
    let identifier = format!("server-{}", origin.replace(['/', ':', '.'], "-"));
    let capability = CapabilityBuilder::new(identifier)
        .remote(format!("{origin}/*"))
        .window("main")
        .permission("allow-refresh-token")
        .permission("allow-signed-out");
    let _ = app.add_capability(capability);
}

fn show_launch_page(app: &AppHandle) -> Result<(), String> {
    let window = app.get_webview_window("main").ok_or("no window")?;
    window.navigate("tauri://localhost/index.html".parse().map_err(|_| "bad launch address")?).map_err(|e| e.to_string())
}

/// A cold start with a stored sign-in goes straight to the server. A refused refresh stays on the launch page.
async fn resume(app: AppHandle) {
    let shell = app.state::<Shell>();
    let Some(origin) = shell.store.last_server() else { return };
    let Some(refresh) = shell.store.refresh_token(&origin) else { return };
    let Ok(endpoints) = auth::discover(&shell.net, &origin).await else { return };
    match auth::refresh(&shell.net, &endpoints, &refresh).await {
        Ok(Some(tokens)) => {
            let _ = signed_in(&app, &shell, origin, endpoints, tokens);
        }
        Ok(None) => shell.store.forget(&origin),
        Err(_) => {}
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let net = Net(reqwest::Client::builder().timeout(std::time::Duration::from_secs(20)).build().expect("an HTTP client"));
    tauri::Builder::default()
        .manage(Shell { net, store: store::Keychain, session: Mutex::new(None), pending: Mutex::new(None) })
        .invoke_handler(tauri::generate_handler![begin_sign_in, finish_sign_in, refresh_token, signed_out])
        .setup(|app| {
            WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .initialization_script(handoff::INIT_SCRIPT)
                // The brand's Night (--brh-bg), so the handover to the server's pages never flashes white (Capping, #130).
                .background_color(tauri::webview::Color(0x11, 0x12, 0x14, 0xff))
                .build()?;
            tauri::async_runtime::spawn(resume(app.handle().clone()));
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Nectar");
}
