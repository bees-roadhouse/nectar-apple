mod auth;
mod handoff;
mod servers;
mod store;
#[cfg(target_os = "ios")]
mod web_auth;

use serde::Serialize;
use std::sync::Mutex;
use store::TokenStore;
use tauri::ipc::CapabilityBuilder;
use tauri::{AppHandle, Manager, State, WebviewUrl, WebviewWindowBuilder};

/// What this is, "iPhone" or "iPad": the launch page's words, and the shell's name in a person's device list as
/// "Nectar on iPhone" (nectar shows it on `/activate` and Settings → Devices, #144). Read once, on the main thread.
fn device_kind() -> &'static str {
    #[cfg(target_os = "ios")]
    {
        use objc2_ui_kit::{UIDevice, UIUserInterfaceIdiom};
        if let Some(main) = objc2::MainThreadMarker::new() {
            if UIDevice::currentDevice(main).userInterfaceIdiom() == UIUserInterfaceIdiom::Phone {
                return "iPhone";
            }
        }
    }
    "iPad"
}

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
    device: &'static str,
    store: store::Keychain,
    session: Mutex<Option<Session>>,
    pending: Mutex<Option<Pending>>,
    /// The code's approval link, held apart from `pending` since the poll takes that (#144).
    approval: Mutex<Option<String>>,
    /// The signed-in landing URL, held while the launch page shows "Approved" (Capping, #131).
    handover: Mutex<Option<String>>,
    /// Stops the code being waited on, when the person asks for another ("Use a different address", #131).
    cancel: tokio::sync::Notify,
}

/// The code being waited on, and the server it's for.
struct Pending {
    origin: String,
    /// The name the person gave when adding the server, if this sign-in is adding one.
    name: Option<String>,
    endpoints: auth::Endpoints,
    code: auth::DeviceCode,
}

impl Shell {
    fn servers(&self) -> Vec<servers::Server> {
        servers::load(self.store.servers().as_deref(), self.store.last_server().as_deref())
    }

    fn keep(&self, list: &[servers::Server]) -> Result<(), String> {
        self.store.save_servers(&servers::save(list))
    }

    fn rows(&self) -> Vec<ServerRow> {
        let last = self.store.last_server();
        self.servers()
            .into_iter()
            .map(|s| ServerRow {
                address: handoff::shown_address(&s.origin),
                signed_in: self.store.refresh_token(&s.origin).is_some(),
                last: last.as_deref() == Some(s.origin.as_str()),
                origin: s.origin,
                name: s.name,
            })
            .collect()
    }
}

/// One server as the launch page lists it.
#[derive(Serialize)]
struct ServerRow {
    origin: String,
    /// The origin as a person would type it.
    address: String,
    name: String,
    /// Holds a refresh token, so tapping it may open straight in.
    signed_in: bool,
    /// The one a cold start opens.
    last: bool,
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
async fn begin_sign_in(server: String, name: Option<String>, shell: State<'_, Shell>) -> Result<CodeView, String> {
    shell.cancel.notify_waiters();
    let origin = handoff::server_origin(&server)?;
    let endpoints = auth::discover(&shell.net, &origin).await.map_err(|e| auth::explain(&e, &origin))?;
    let code = auth::start(&shell.net, &endpoints, &format!("Nectar on {}", shell.device)).await.map_err(|e| auth::explain(&e, &origin))?;
    let target = code.verification_uri_complete.clone().unwrap_or_else(|| code.verification_uri.clone());
    let qr_svg = qrcode::QrCode::new(target.as_bytes())
        .map(|qr| qr.render::<qrcode::render::svg::Color>().min_dimensions(240, 240).build())
        .unwrap_or_default();
    let view = CodeView { user_code: code.user_code.clone(), verification_uri: code.verification_uri.clone(), expires_in: code.expires_in, qr_svg };
    *shell.approval.lock().unwrap() = Some(target);
    *shell.pending.lock().unwrap() = Some(Pending { origin, name, endpoints, code });
    Ok(view)
}

/// "iPhone" or "iPad", for the launch page's words (#144).
#[tauri::command]
fn device(shell: State<'_, Shell>) -> &'static str {
    shell.device
}

/// Opens the waiting code's approval page in the system sign-in sheet, over the app, so a person with no other
/// device can sign in there (Safari's saved passwords fill it) and approve this one (Capping, #144). The code's own
/// poll sees the approval and closes the sheet; closing it without approving just leaves the code screen. The URL
/// is the server's own, from the pending code; the page can't choose it.
#[tauri::command]
fn open_approval(app: AppHandle, shell: State<'_, Shell>) -> Result<(), String> {
    let target = shell.approval.lock().unwrap().clone().ok_or("There's no code waiting.")?;
    let parsed = url::Url::parse(&target).map_err(|_| "The server sent an approval link that isn't a web address.")?;
    if !matches!(parsed.scheme(), "https" | "http") {
        return Err("The server sent an approval link that isn't a web address.".into());
    }
    sheet(&app, Some(parsed.to_string()))
}

/// Opens the sign-in sheet at `url`, or closes the one that's open (`None`). On the main thread, where UIKit is.
fn sheet(app: &AppHandle, url: Option<String>) -> Result<(), String> {
    #[cfg(target_os = "ios")]
    {
        let window = app.get_webview_window("main").ok_or("The app's window is gone.")?;
        let (sent, got) = std::sync::mpsc::channel();
        window
            .with_webview(move |view| {
                let _ = sent.send(match &url {
                    Some(url) => web_auth::open(url, view.view_controller()),
                    None => Ok(web_auth::close()),
                });
            })
            .map_err(|e| e.to_string())?;
        return got.recv().map_err(|e| e.to_string())?;
    }
    #[cfg(not(target_os = "ios"))]
    {
        let _ = (app, url);
        Err("Signing in on this device needs iOS.".into())
    }
}

/// The launch page's list (#135).
#[tauri::command]
fn servers(shell: State<'_, Shell>) -> Vec<ServerRow> {
    shell.rows()
}

/// Adds a server, or changes the one at `previous`. A changed address forgets the old one's token.
#[tauri::command]
fn save_server(previous: Option<String>, address: String, name: String, shell: State<'_, Shell>) -> Result<Vec<ServerRow>, String> {
    let origin = handoff::server_origin(&address)?;
    let mut list = shell.servers();
    if let Some(replaced) = servers::upsert(&mut list, previous.as_deref(), &origin, &name) {
        shell.store.forget(&replaced);
    }
    shell.keep(&list)?;
    Ok(shell.rows())
}

/// Forgets a server and its token. Its session on the server stays until it expires or is signed out there: the
/// shell holds no access token for it.
#[tauri::command]
fn remove_server(origin: String, shell: State<'_, Shell>) -> Result<Vec<ServerRow>, String> {
    let mut list = shell.servers();
    servers::remove(&mut list, &origin);
    shell.keep(&list)?;
    shell.store.forget(&origin);
    Ok(shell.rows())
}

/// A tap on a listed server. `"opened"`: its token refreshed, and the shell is opening it. `"code"`: it needs a
/// code first. An error says the server couldn't be reached.
#[tauri::command]
async fn open_saved(origin: String, app: AppHandle, shell: State<'_, Shell>) -> Result<&'static str, String> {
    Ok(if try_open(&app, &shell, &origin).await? { "opened" } else { "code" })
}

/// From the launch page as it loads: a cold start opens the last server if its token still works. `"opened"`,
/// `"list"` when it can't, or an error when the server couldn't be reached.
#[tauri::command]
async fn resume(app: AppHandle, shell: State<'_, Shell>) -> Result<&'static str, String> {
    let Some(origin) = shell.store.last_server() else { return Ok("list") };
    if !shell.servers().iter().any(|s| s.origin == origin) {
        return Ok("list");
    }
    Ok(if try_open(&app, &shell, &origin).await? { "opened" } else { "list" })
}

/// Refreshes a server's stored token and opens it. `false` when there's no token or the server refused it (then
/// it's forgotten); an error when the server couldn't be reached, and the token is kept for next time.
async fn try_open(app: &AppHandle, shell: &Shell, origin: &str) -> Result<bool, String> {
    let Some(refresh) = shell.store.refresh_token(origin) else { return Ok(false) };
    let endpoints = auth::discover(&shell.net, origin).await.map_err(|e| auth::explain(&e, origin))?;
    match auth::refresh(&shell.net, &endpoints, &refresh).await.map_err(|e| auth::explain(&e, origin))? {
        Some(tokens) => {
            let landing = signed_in(app, shell, origin.to_string(), None, endpoints, tokens)?;
            navigate(app, &landing)?;
            Ok(true)
        }
        None => {
            shell.store.forget(origin);
            Ok(false)
        }
    }
}

/// Waits for the person to approve the code shown. `"approved"`: signed in, and `open_server` opens it.
/// `"expired"`: the code ran out, and the launch page asks for a new one without an error (Capping, #131).
/// `"cancelled"`: a newer code replaced this one.
#[tauri::command]
async fn finish_sign_in(app: AppHandle, shell: State<'_, Shell>) -> Result<&'static str, String> {
    let Pending { origin, name, endpoints, code } = shell.pending.lock().unwrap().take().ok_or("Ask for a code first.")?;
    // Created before polling starts, so a `begin_sign_in` from here on can't be missed.
    let cancelled = shell.cancel.notified();
    let outcome = tokio::select! {
        outcome = auth::poll(&shell.net, &endpoints, &code, tokio::time::sleep) => outcome,
        _ = cancelled => return Ok("cancelled"),
    };
    // The sign-in sheet, if the person approved in it, has done its job (or its code has); nothing else closes it.
    shell.approval.lock().unwrap().take();
    let _ = sheet(&app, None);
    match outcome.map_err(|e| e.to_string())? {
        auth::Outcome::Approved(tokens) => {
            let landing = signed_in(&app, &shell, origin, name, endpoints, tokens)?;
            *shell.handover.lock().unwrap() = Some(landing);
            Ok("approved")
        }
        auth::Outcome::Denied => Err("The code was declined on the other device.".into()),
        auth::Outcome::Expired => Ok("expired"),
    }
}

/// "Use a different address": stop waiting on the code shown.
#[tauri::command]
fn cancel_sign_in(shell: State<'_, Shell>) {
    shell.cancel.notify_waiters();
    shell.pending.lock().unwrap().take();
}

/// After the launch page's "Approved": the server's home, signed in.
#[tauri::command]
fn open_server(app: AppHandle, shell: State<'_, Shell>) -> Result<(), String> {
    let landing = shell.handover.lock().unwrap().take().ok_or("Sign in first.")?;
    navigate(&app, &landing)
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

/// Keeps the sign-in, lists the server (with `name` if it's being added), and lets the server's pages call the
/// shell; the URL that opens it signed in comes back.
fn signed_in(app: &AppHandle, shell: &Shell, origin: String, name: Option<String>, endpoints: auth::Endpoints, tokens: auth::Tokens) -> Result<String, String> {
    if let Some(refresh) = &tokens.refresh_token {
        shell.store.save_refresh_token(&origin, refresh)?;
    }
    let mut list = shell.servers();
    let name = name.or_else(|| list.iter().find(|s| s.origin == origin).map(|s| s.name.clone())).unwrap_or_default();
    servers::upsert(&mut list, None, &origin, &name);
    shell.keep(&list)?;
    shell.store.save_last_server(&origin)?;
    let landing = handoff::landing_url(&origin, &tokens.access_token);
    *shell.session.lock().unwrap() = Some(Session { origin: origin.clone(), endpoints, access: tokens.access_token });
    allow_server(app, &origin);
    Ok(landing)
}

fn navigate(app: &AppHandle, landing: &str) -> Result<(), String> {
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let net = Net(reqwest::Client::builder().timeout(std::time::Duration::from_secs(20)).build().expect("an HTTP client"));
    let kind = device_kind();
    tauri::Builder::default()
        .manage(Shell { net, device: kind, store: store::Keychain, session: Mutex::new(None), pending: Mutex::new(None), approval: Mutex::new(None), handover: Mutex::new(None), cancel: tokio::sync::Notify::new() })
        .invoke_handler(tauri::generate_handler![begin_sign_in, servers, save_server, remove_server, open_saved, resume, finish_sign_in, cancel_sign_in, open_server, refresh_token, signed_out, device, open_approval])
        .setup(|app| {
            WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .initialization_script(handoff::init_script(kind))
                // The brand's Night (--brh-bg), so the handover to the server's pages never flashes white (Capping, #130).
                .background_color(tauri::webview::Color(0x11, 0x12, 0x14, 0xff))
                .build()?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Nectar");
}
