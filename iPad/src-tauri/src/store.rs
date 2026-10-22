//! Where the shell keeps a server's refresh token: the iOS Keychain on the device. Tests use the in-memory store, so
//! they never touch a real keychain.

#[cfg(test)]
use std::collections::HashMap;
#[cfg(test)]
use std::sync::Mutex;

/// The Keychain service every entry lives under.
const SERVICE: &str = "com.beesroadhouse.nectar.ipad";
/// The entry naming the server signed into last, for a cold start.
const LAST_SERVER: &str = "last-server";
/// The launch page's server list, as `servers::save` writes it (#135).
const SERVERS: &str = "servers";

pub trait TokenStore: Send + Sync {
    fn refresh_token(&self, origin: &str) -> Option<String>;
    fn save_refresh_token(&self, origin: &str, token: &str) -> Result<(), String>;
    fn forget(&self, origin: &str);
    fn last_server(&self) -> Option<String>;
    fn save_last_server(&self, origin: &str) -> Result<(), String>;
    fn servers(&self) -> Option<String>;
    fn save_servers(&self, json: &str) -> Result<(), String>;
}

/// The iOS Keychain, one generic-password entry per server origin.
pub struct Keychain;

impl Keychain {
    fn entry(account: &str) -> Option<keyring::Entry> {
        keyring::Entry::new(SERVICE, account).ok()
    }
}

impl TokenStore for Keychain {
    fn refresh_token(&self, origin: &str) -> Option<String> {
        Self::entry(origin)?.get_password().ok()
    }

    fn save_refresh_token(&self, origin: &str, token: &str) -> Result<(), String> {
        Self::entry(origin).ok_or("no keychain entry")?.set_password(token).map_err(|e| e.to_string())
    }

    fn forget(&self, origin: &str) {
        if let Some(entry) = Self::entry(origin) {
            let _ = entry.delete_credential();
        }
    }

    fn last_server(&self) -> Option<String> {
        Self::entry(LAST_SERVER)?.get_password().ok()
    }

    fn save_last_server(&self, origin: &str) -> Result<(), String> {
        Self::entry(LAST_SERVER).ok_or("no keychain entry")?.set_password(origin).map_err(|e| e.to_string())
    }

    fn servers(&self) -> Option<String> {
        Self::entry(SERVERS)?.get_password().ok()
    }

    fn save_servers(&self, json: &str) -> Result<(), String> {
        Self::entry(SERVERS).ok_or("no keychain entry")?.set_password(json).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
#[derive(Default)]
pub struct Memory {
    tokens: Mutex<HashMap<String, String>>,
    last: Mutex<Option<String>>,
    servers: Mutex<Option<String>>,
}

#[cfg(test)]
impl TokenStore for Memory {
    fn refresh_token(&self, origin: &str) -> Option<String> {
        self.tokens.lock().unwrap().get(origin).cloned()
    }

    fn save_refresh_token(&self, origin: &str, token: &str) -> Result<(), String> {
        self.tokens.lock().unwrap().insert(origin.to_string(), token.to_string());
        Ok(())
    }

    fn forget(&self, origin: &str) {
        self.tokens.lock().unwrap().remove(origin);
    }

    fn last_server(&self) -> Option<String> {
        self.last.lock().unwrap().clone()
    }

    fn save_last_server(&self, origin: &str) -> Result<(), String> {
        *self.last.lock().unwrap() = Some(origin.to_string());
        Ok(())
    }

    fn servers(&self) -> Option<String> {
        self.servers.lock().unwrap().clone()
    }

    fn save_servers(&self, json: &str) -> Result<(), String> {
        *self.servers.lock().unwrap() = Some(json.to_string());
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_are_kept_per_server_and_forgotten_alone() {
        let store = Memory::default();
        store.save_refresh_token("https://a.test", "ra").unwrap();
        store.save_refresh_token("https://b.test", "rb").unwrap();
        store.save_refresh_token("https://a.test", "ra2").unwrap();
        assert_eq!(store.refresh_token("https://a.test").as_deref(), Some("ra2"), "a rotation replaces");
        store.forget("https://a.test");
        assert_eq!(store.refresh_token("https://a.test"), None);
        assert_eq!(store.refresh_token("https://b.test").as_deref(), Some("rb"));
        assert_eq!(store.last_server(), None);
        store.save_last_server("https://b.test").unwrap();
        assert_eq!(store.last_server().as_deref(), Some("https://b.test"));
    }
}
