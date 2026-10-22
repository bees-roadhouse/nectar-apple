//! Device sign-in (RFC 8628) and token refresh against nectar, as NectarKit's `DeviceFlowClient` does for the TV
//! (nectar #379). The shell's client is `nectar-ipad` (nectar #750).

use serde::{Deserialize, Serialize};
use std::future::Future;
use std::time::Duration;

pub const CLIENT_ID: &str = "nectar-ipad";
pub const SCOPE: &str = "openid profile offline_access";
pub const DEVICE_GRANT: &str = "urn:ietf:params:oauth:grant-type:device_code";
const DEFAULT_INTERVAL: u64 = 5;
const SLOW_DOWN: u64 = 5;

/// One HTTP reply: the status and the body as sent.
pub struct Reply {
    pub status: u16,
    pub body: Vec<u8>,
}

/// One HTTP request. The seam that lets the flow run against a script in tests.
pub trait Http: Send + Sync {
    fn get(&self, url: &str) -> impl Future<Output = Result<Reply, String>> + Send;
    fn post_form(&self, url: &str, form: &[(&str, &str)]) -> impl Future<Output = Result<Reply, String>> + Send;
}

/// From the server's OpenID configuration.
#[derive(Debug, Clone, PartialEq)]
pub struct Endpoints {
    pub device_authorization: String,
    pub token: String,
}

/// The reply to `POST /device_authorization` (RFC 8628 §3.2).
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct DeviceCode {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub verification_uri_complete: Option<String>,
    pub expires_in: u64,
    pub interval: Option<u64>,
}

/// Tokens from a successful token request (RFC 6749 §5.1).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Tokens {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_in: Option<u64>,
}

/// How a round of polling ended.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    Approved(Tokens),
    /// The person declined on `/activate`.
    Denied,
    /// The code ran out: start again with a new one.
    Expired,
}

#[derive(Debug, Clone, PartialEq)]
pub enum AuthError {
    /// The server doesn't offer the device grant.
    NoDeviceFlow,
    /// An OAuth error code, or `http_<status>` when the body had none.
    Server(String),
    /// A reply that didn't parse.
    Body(String),
    Network(String),
}

impl std::fmt::Display for AuthError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AuthError::NoDeviceFlow => write!(f, "This server doesn't offer sign-in with a code."),
            AuthError::Server(code) => write!(f, "The server refused ({code})."),
            AuthError::Body(_) => write!(f, "The server's reply didn't make sense."),
            AuthError::Network(_) => write!(f, "Couldn't reach the server."),
        }
    }
}

/// What the launch page says when a request to `origin` fails: "Couldn't reach …" for the network, the error itself
/// for anything the server answered (#135).
pub fn explain(error: &AuthError, origin: &str) -> String {
    match error {
        AuthError::Network(_) => format!("Couldn't reach {}.", crate::handoff::shown_address(origin)),
        other => other.to_string(),
    }
}

pub async fn discover(http: &impl Http, server: &str) -> Result<Endpoints, AuthError> {
    #[derive(Deserialize)]
    struct Configuration {
        token_endpoint: String,
        device_authorization_endpoint: Option<String>,
    }
    let url = format!("{}/.well-known/openid-configuration", server.trim_end_matches('/'));
    let reply = http.get(&url).await.map_err(AuthError::Network)?;
    if reply.status != 200 {
        return Err(AuthError::Server(format!("http_{}", reply.status)));
    }
    let configuration: Configuration = parse(&reply.body)?;
    let device_authorization = configuration.device_authorization_endpoint.ok_or(AuthError::NoDeviceFlow)?;
    Ok(Endpoints { device_authorization, token: configuration.token_endpoint })
}

pub async fn start(http: &impl Http, endpoints: &Endpoints, device_name: &str) -> Result<DeviceCode, AuthError> {
    let name: String = device_name.chars().take(64).collect();
    let form = [("client_id", CLIENT_ID), ("scope", SCOPE), ("device_name", name.as_str())];
    let reply = http.post_form(&endpoints.device_authorization, &form).await.map_err(AuthError::Network)?;
    if reply.status != 200 {
        return Err(AuthError::Server(error_code(&reply)));
    }
    parse(&reply.body)
}

/// Polls until the person approves, declines, or the code runs out. A network failure or an unexpected reply keeps
/// polling; only the code's lifetime ends the loop.
pub async fn poll<F, S>(http: &impl Http, endpoints: &Endpoints, code: &DeviceCode, sleep: S) -> Result<Outcome, AuthError>
where
    S: Fn(Duration) -> F,
    F: Future<Output = ()>,
{
    let mut interval = code.interval.unwrap_or(DEFAULT_INTERVAL);
    let mut elapsed = 0;
    let form = [("grant_type", DEVICE_GRANT), ("device_code", code.device_code.as_str()), ("client_id", CLIENT_ID)];
    while elapsed + interval <= code.expires_in {
        sleep(Duration::from_secs(interval)).await;
        elapsed += interval;
        let Ok(reply) = http.post_form(&endpoints.token, &form).await else { continue };
        if reply.status == 200 {
            return Ok(Outcome::Approved(parse(&reply.body)?));
        }
        match error_code(&reply).as_str() {
            "authorization_pending" => {}
            "slow_down" => interval += SLOW_DOWN,
            "access_denied" => return Ok(Outcome::Denied),
            "expired_token" | "invalid_grant" => return Ok(Outcome::Expired),
            // Anything else (a proxy's 502, say) keeps polling until the code runs out.
            _ => {}
        }
    }
    Ok(Outcome::Expired)
}

/// A new access token from a refresh token, with the rotated refresh token. `Ok(None)` when the server refuses it
/// (the session was signed out, or the token was reused), so the shell signs in again.
pub async fn refresh(http: &impl Http, endpoints: &Endpoints, refresh_token: &str) -> Result<Option<Tokens>, AuthError> {
    let form = [("grant_type", "refresh_token"), ("refresh_token", refresh_token), ("client_id", CLIENT_ID)];
    let reply = http.post_form(&endpoints.token, &form).await.map_err(AuthError::Network)?;
    match reply.status {
        200 => Ok(Some(parse(&reply.body)?)),
        400 | 401 => Ok(None),
        status => Err(AuthError::Server(format!("http_{status}"))),
    }
}

fn parse<T: serde::de::DeserializeOwned>(body: &[u8]) -> Result<T, AuthError> {
    serde_json::from_slice(body).map_err(|e| AuthError::Body(e.to_string()))
}

/// The OAuth `error` code in a reply (RFC 6749 §5.2), or `http_<status>` when there's none.
fn error_code(reply: &Reply) -> String {
    #[derive(Deserialize)]
    struct OAuthError {
        error: String,
    }
    serde_json::from_slice::<OAuthError>(&reply.body).map(|e| e.error).unwrap_or_else(|_| format!("http_{}", reply.status))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::Mutex;

    /// Answers requests from a script, in order, and records what was asked.
    struct Script {
        replies: Mutex<VecDeque<Result<Reply, String>>>,
        asked: Mutex<Vec<(String, Vec<(String, String)>)>>,
    }

    impl Script {
        fn new(replies: Vec<Result<(u16, &str), &str>>) -> Self {
            let replies = replies
                .into_iter()
                .map(|r| r.map(|(status, body)| Reply { status, body: body.as_bytes().to_vec() }).map_err(String::from))
                .collect();
            Script { replies: Mutex::new(replies), asked: Mutex::new(Vec::new()) }
        }

        fn next(&self, url: &str, form: &[(&str, &str)]) -> Result<Reply, String> {
            let form = form.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
            self.asked.lock().unwrap().push((url.to_string(), form));
            self.replies.lock().unwrap().pop_front().expect("the script ran out")
        }

        fn asked(&self) -> Vec<(String, Vec<(String, String)>)> {
            self.asked.lock().unwrap().clone()
        }
    }

    impl Http for Script {
        async fn get(&self, url: &str) -> Result<Reply, String> {
            self.next(url, &[])
        }
        async fn post_form(&self, url: &str, form: &[(&str, &str)]) -> Result<Reply, String> {
            self.next(url, form)
        }
    }

    fn endpoints() -> Endpoints {
        Endpoints { device_authorization: "https://n.test/device_authorization".into(), token: "https://n.test/token".into() }
    }

    fn code(expires_in: u64, interval: Option<u64>) -> DeviceCode {
        DeviceCode {
            device_code: "dc".into(),
            user_code: "BDWP-HQPK".into(),
            verification_uri: "https://n.test/activate".into(),
            verification_uri_complete: Some("https://n.test/activate?code=BDWP-HQPK".into()),
            expires_in,
            interval,
        }
    }

    const TOKENS: &str = r#"{"access_token":"at","token_type":"Bearer","expires_in":3600,"refresh_token":"rt"}"#;

    #[test]
    fn only_a_network_failure_reads_as_unreachable() {
        assert_eq!(explain(&AuthError::Network("dns".into()), "https://nectar.test"), "Couldn't reach nectar.test.");
        assert_eq!(explain(&AuthError::NoDeviceFlow, "https://nectar.test"), AuthError::NoDeviceFlow.to_string());
        assert_eq!(explain(&AuthError::Server("http_500".into()), "http://10.0.0.2:8096"), AuthError::Server("http_500".into()).to_string());
    }

    #[tokio::test]
    async fn discovery_finds_the_device_and_token_endpoints() {
        let http = Script::new(vec![Ok((200, r#"{"issuer":"https://n.test","token_endpoint":"https://n.test/token","device_authorization_endpoint":"https://n.test/device_authorization"}"#))]);
        assert_eq!(discover(&http, "https://n.test/").await, Ok(endpoints()));
        assert_eq!(http.asked()[0].0, "https://n.test/.well-known/openid-configuration", "one slash, whatever the server URL ends with");
    }

    #[tokio::test]
    async fn a_server_without_the_device_grant_says_so() {
        let http = Script::new(vec![Ok((200, r#"{"token_endpoint":"https://n.test/token"}"#))]);
        assert_eq!(discover(&http, "https://n.test").await, Err(AuthError::NoDeviceFlow));
    }

    #[tokio::test]
    async fn starting_asks_as_the_ipad_client_with_offline_access() {
        let http = Script::new(vec![Ok((200, r#"{"device_code":"dc","user_code":"BDWP-HQPK","verification_uri":"https://n.test/activate","verification_uri_complete":"https://n.test/activate?code=BDWP-HQPK","expires_in":600,"interval":5}"#))]);
        let started = start(&http, &endpoints(), "Nate's iPad").await.unwrap();
        assert_eq!(started.user_code, "BDWP-HQPK");
        let (url, form) = &http.asked()[0];
        assert_eq!(url, "https://n.test/device_authorization");
        assert!(form.contains(&("client_id".into(), "nectar-ipad".into())));
        assert!(form.contains(&("scope".into(), SCOPE.into())));
        assert!(form.contains(&("device_name".into(), "Nate's iPad".into())));
    }

    #[tokio::test]
    async fn polling_waits_through_pending_and_slow_down_then_takes_the_tokens() {
        let http = Script::new(vec![
            Ok((400, r#"{"error":"authorization_pending"}"#)),
            Err("offline"),
            Ok((400, r#"{"error":"slow_down"}"#)),
            Ok((200, TOKENS)),
        ]);
        let waits = Mutex::new(Vec::new());
        let outcome = poll(&http, &endpoints(), &code(600, Some(5)), |d| {
            waits.lock().unwrap().push(d.as_secs());
            async {}
        })
        .await
        .unwrap();
        assert_eq!(outcome, Outcome::Approved(Tokens { access_token: "at".into(), refresh_token: Some("rt".into()), expires_in: Some(3600) }));
        assert_eq!(*waits.lock().unwrap(), vec![5, 5, 5, 10], "slow_down adds five seconds from then on");
        let form = &http.asked()[0].1;
        assert!(form.contains(&("grant_type".into(), DEVICE_GRANT.into())));
        assert!(form.contains(&("device_code".into(), "dc".into())));
    }

    #[tokio::test]
    async fn a_declined_code_is_denied_and_a_dead_one_expired() {
        let denied = Script::new(vec![Ok((400, r#"{"error":"access_denied"}"#))]);
        assert_eq!(poll(&denied, &endpoints(), &code(600, None), |_| async {}).await, Ok(Outcome::Denied));
        let dead = Script::new(vec![Ok((400, r#"{"error":"expired_token"}"#))]);
        assert_eq!(poll(&dead, &endpoints(), &code(600, None), |_| async {}).await, Ok(Outcome::Expired));
    }

    #[tokio::test]
    async fn polling_stops_when_the_code_runs_out() {
        let http = Script::new(vec![Ok((400, r#"{"error":"authorization_pending"}"#)), Ok((400, r#"{"error":"authorization_pending"}"#))]);
        assert_eq!(poll(&http, &endpoints(), &code(10, Some(5)), |_| async {}).await, Ok(Outcome::Expired));
        assert_eq!(http.asked().len(), 2, "two polls fit in ten seconds at five each");
    }

    #[tokio::test]
    async fn refresh_rotates_and_a_refusal_is_none() {
        let http = Script::new(vec![Ok((200, TOKENS))]);
        let fresh = refresh(&http, &endpoints(), "old").await.unwrap().unwrap();
        assert_eq!(fresh.refresh_token.as_deref(), Some("rt"));
        let form = &http.asked()[0].1;
        assert!(form.contains(&("grant_type".into(), "refresh_token".into())));
        assert!(form.contains(&("refresh_token".into(), "old".into())));
        assert!(form.contains(&("client_id".into(), "nectar-ipad".into())));

        let refused = Script::new(vec![Ok((400, r#"{"error":"invalid_grant"}"#))]);
        assert_eq!(refresh(&refused, &endpoints(), "old").await, Ok(None));
        let offline = Script::new(vec![Err("offline")]);
        assert!(matches!(refresh(&offline, &endpoints(), "old").await, Err(AuthError::Network(_))), "offline isn't a sign-out");
    }
}
