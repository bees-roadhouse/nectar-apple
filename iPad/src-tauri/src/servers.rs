//! The launch page's list of servers (#135): a name and an origin each, kept in the Keychain as one JSON entry next
//! to each server's refresh token. The list is plain data here, so every rule about it is tested without a device.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Server {
    /// As `handoff::server_origin` makes it: the key for the server's refresh token too.
    pub origin: String,
    pub name: String,
}

/// The stored list, or a one-server list made from #130's `last-server` entry the first time.
pub fn load(stored: Option<&str>, last: Option<&str>) -> Vec<Server> {
    match (stored, last) {
        (Some(json), _) => serde_json::from_str(json).unwrap_or_default(),
        (None, Some(origin)) => vec![Server { origin: origin.to_string(), name: default_name(origin) }],
        (None, None) => vec![],
    }
}

/// What's written back to the Keychain.
pub fn save(list: &[Server]) -> String {
    serde_json::to_string(list).expect("a server list always serializes")
}

/// Adds a server, or changes the one at `previous` (an edit). An address already in the list is the same server:
/// it's renamed, never doubled. A blank name becomes the host. The origin it replaced, if any, comes back, so its
/// token can be forgotten.
pub fn upsert(list: &mut Vec<Server>, previous: Option<&str>, origin: &str, name: &str) -> Option<String> {
    let name = if name.trim().is_empty() { default_name(origin) } else { name.trim().to_string() };
    let server = Server { origin: origin.to_string(), name };
    let at = previous.and_then(|p| list.iter().position(|s| s.origin == p));
    let same = list.iter().position(|s| s.origin == origin);
    match (at, same) {
        // An edit onto another entry's address: one server, where that one was.
        (Some(at), Some(same)) if at != same => {
            list[same] = server;
            Some(list.remove(at).origin)
        }
        (Some(at), _) => {
            let replaced = std::mem::replace(&mut list[at], server).origin;
            (replaced != origin).then_some(replaced)
        }
        (None, Some(same)) => {
            list[same] = server;
            None
        }
        (None, None) => {
            list.push(server);
            None
        }
    }
}

pub fn remove(list: &mut Vec<Server>, origin: &str) {
    list.retain(|s| s.origin != origin);
}

/// A server's name when none is given: its host, and the port if there is one.
pub fn default_name(origin: &str) -> String {
    origin.split_once("://").map_or(origin, |(_, rest)| rest).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server(origin: &str, name: &str) -> Server {
        Server { origin: origin.into(), name: name.into() }
    }

    #[test]
    fn a_first_launch_after_slice_2_keeps_the_server_it_had() {
        assert_eq!(load(None, None), vec![]);
        assert_eq!(load(None, Some("https://nectar.test")), vec![server("https://nectar.test", "nectar.test")]);
        let stored = save(&[server("https://a.test", "Home")]);
        assert_eq!(load(Some(&stored), Some("https://nectar.test")), vec![server("https://a.test", "Home")], "a stored list wins");
        assert_eq!(load(Some("not json"), None), vec![], "a damaged entry is an empty list, not a crash");
    }

    #[test]
    fn adding_appends_and_a_blank_name_is_the_host() {
        let mut list = vec![];
        assert_eq!(upsert(&mut list, None, "https://a.test", "Home"), None);
        assert_eq!(upsert(&mut list, None, "https://b.test:8443", "  "), None);
        assert_eq!(list, vec![server("https://a.test", "Home"), server("https://b.test:8443", "b.test:8443")]);
    }

    #[test]
    fn the_same_address_twice_is_one_server_renamed() {
        let mut list = vec![server("https://a.test", "Home")];
        upsert(&mut list, None, "https://a.test", "Roadhouse");
        assert_eq!(list, vec![server("https://a.test", "Roadhouse")]);
    }

    #[test]
    fn an_edit_keeps_its_place_and_hands_back_a_changed_origin() {
        let mut list = vec![server("https://a.test", "A"), server("https://b.test", "B")];
        assert_eq!(upsert(&mut list, Some("https://a.test"), "https://a.test", "Renamed"), None, "a rename keeps the token");
        assert_eq!(upsert(&mut list, Some("https://a.test"), "https://c.test", "Renamed"), Some("https://a.test".into()));
        assert_eq!(list, vec![server("https://c.test", "Renamed"), server("https://b.test", "B")]);
    }

    #[test]
    fn an_edit_onto_another_entrys_address_merges_them() {
        let mut list = vec![server("https://a.test", "A"), server("https://b.test", "B")];
        assert_eq!(upsert(&mut list, Some("https://a.test"), "https://b.test", "Both"), Some("https://a.test".into()));
        assert_eq!(list, vec![server("https://b.test", "Both")]);
    }

    #[test]
    fn removing_takes_only_that_server() {
        let mut list = vec![server("https://a.test", "A"), server("https://b.test", "B")];
        remove(&mut list, "https://a.test");
        remove(&mut list, "https://missing.test");
        assert_eq!(list, vec![server("https://b.test", "B")]);
    }

    #[test]
    fn the_default_name_is_the_host_and_port() {
        assert_eq!(default_name("https://nectar.beesroadhouse.com"), "nectar.beesroadhouse.com");
        assert_eq!(default_name("http://192.168.67.20:8096"), "192.168.67.20:8096");
    }
}
