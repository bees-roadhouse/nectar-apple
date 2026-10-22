//! Handing the web client its sign-in (agreed with Forage on nectar-apple #127, nectar #750). The shell navigates to
//! the server with the access token in the URL's fragment, which never reaches the server. Before nectar's own code
//! runs, the initialization script moves it into `sessionStorage` and the cookie, where `web-solid`'s `auth.ts` reads
//! it, then strips the fragment. Later reloads keep whatever token the web client holds by then.

/// The fragment key the initialization script looks for.
pub const FRAGMENT_KEY: &str = "nectar_shell_token";

/// Runs before every page's own scripts, on the launch page and the server's pages alike.
/// - It hands over a token from the fragment, if there is one.
/// - It sets `__NECTAR_SHELL__`, which nectar reads when it needs it (nectar #750):
///   - `nativeHls` makes the player use `<video src>`, so it's AVPlayer underneath;
///   - `refreshToken` and `signedOut` go to the shell. Only the signed-in server's origin is allowed to call them.
pub const INIT_SCRIPT: &str = r#"(() => {
  const match = location.hash.match(/(?:^#|&)nectar_shell_token=([^&]*)/);
  if (match) {
    const token = decodeURIComponent(match[1]);
    try { sessionStorage.setItem("nectar_token", token); } catch (e) {}
    document.cookie = "nectar_session=" + encodeURIComponent(token) + "; Path=/; SameSite=Lax";
    history.replaceState(null, "", location.pathname + location.search);
  }
  const shell = (command) =>
    window.__TAURI_INTERNALS__ ? window.__TAURI_INTERNALS__.invoke(command) : Promise.resolve(null);
  window.__NECTAR_SHELL__ = {
    version: 1,
    nativeHls: true,
    refreshToken: () => shell("refresh_token"),
    signedOut: () => shell("signed_out"),
  };
})();"#;

/// What someone typed for a server, as an origin: `https://` added when there's no scheme, and any path dropped.
/// Plain `http` is allowed only for a local address, since the token rides on every request.
pub fn server_origin(input: &str) -> Result<String, String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err("Enter your server's address.".into());
    }
    let with_scheme = if trimmed.contains("://") { trimmed.to_string() } else { format!("https://{trimmed}") };
    let url = url::Url::parse(&with_scheme).map_err(|_| "That isn't a web address.".to_string())?;
    let host = url.host_str().ok_or_else(|| "That isn't a web address.".to_string())?;
    match url.scheme() {
        "https" => {}
        "http" if is_local(host) => {}
        "http" => return Err("Use https for a server outside your home network.".into()),
        _ => return Err("That isn't a web address.".into()),
    }
    Ok(url.origin().ascii_serialization())
}

/// An origin as the launch page pre-fills it (Capping, #131): `https://` dropped, since it's what a bare host means;
/// plain `http://` kept.
pub fn shown_address(origin: &str) -> String {
    origin.strip_prefix("https://").unwrap_or(origin).to_string()
}

fn is_local(host: &str) -> bool {
    host == "localhost"
        || host.ends_with(".local")
        || host.parse::<std::net::IpAddr>().is_ok_and(|ip| match ip {
            std::net::IpAddr::V4(v4) => v4.is_private() || v4.is_loopback(),
            std::net::IpAddr::V6(v6) => v6.is_loopback(),
        })
}

/// The server's home page, carrying the token in the fragment.
pub fn landing_url(origin: &str, access_token: &str) -> String {
    let token: String = url::form_urlencoded::byte_serialize(access_token.as_bytes()).collect();
    format!("{origin}/#{FRAGMENT_KEY}={token}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bare_host_becomes_an_https_origin_and_paths_go() {
        assert_eq!(server_origin("nectar.beesroadhouse.com").unwrap(), "https://nectar.beesroadhouse.com");
        assert_eq!(server_origin("  https://nectar.beesroadhouse.com/library/1?x=2 ").unwrap(), "https://nectar.beesroadhouse.com");
        assert_eq!(server_origin("https://nectar.test:8443/").unwrap(), "https://nectar.test:8443");
    }

    #[test]
    fn plain_http_only_at_home() {
        assert_eq!(server_origin("http://192.168.67.20:8096").unwrap(), "http://192.168.67.20:8096");
        assert_eq!(server_origin("http://nectar.local").unwrap(), "http://nectar.local");
        assert!(server_origin("http://nectar.beesroadhouse.com").is_err());
        assert!(server_origin("ftp://nectar.test").is_err());
        assert!(server_origin("").is_err());
    }

    #[test]
    fn the_last_server_is_shown_as_it_would_be_typed() {
        assert_eq!(shown_address("https://nectar.beesroadhouse.com"), "nectar.beesroadhouse.com");
        assert_eq!(shown_address("https://nectar.test:8443"), "nectar.test:8443");
        // Plain http stays visible, so it reads back as the exception it is, and round-trips.
        assert_eq!(shown_address("http://192.168.67.20:8096"), "http://192.168.67.20:8096");
        for origin in ["https://nectar.beesroadhouse.com", "http://nectar.local"] {
            assert_eq!(server_origin(&shown_address(origin)).unwrap(), origin);
        }
    }

    #[test]
    fn the_token_rides_in_the_fragment_never_the_query() {
        let url = landing_url("https://n.test", "a.b+c/d=");
        assert_eq!(url, "https://n.test/#nectar_shell_token=a.b%2Bc%2Fd%3D");
        assert!(!url.contains('?'), "a query would reach the server and its logs");
    }

    #[test]
    fn the_script_writes_where_the_web_client_reads() {
        // web-solid's src/auth.ts: STORAGE_KEY = "nectar_token", COOKIE_KEY = "nectar_session" (nectar 5937f1b).
        assert!(INIT_SCRIPT.contains(r#"sessionStorage.setItem("nectar_token""#));
        assert!(INIT_SCRIPT.contains(r#""nectar_session=""#));
        assert!(INIT_SCRIPT.contains(FRAGMENT_KEY));
        assert!(INIT_SCRIPT.contains("version: 1") && INIT_SCRIPT.contains("nativeHls: true"));
    }
}
