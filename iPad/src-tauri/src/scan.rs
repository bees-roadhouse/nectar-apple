//! The camera scanner for the web client's "Scan a code" (#149). The scanner itself is Swift
//! (`gen/apple/Sources/nectar-ipad/NectarScanner.swift`), since VisionKit's has no Objective-C surface; this finds it
//! by name and calls it on the main thread. Main thread only.

use std::ffi::c_void;
use std::sync::Mutex;

use block2::RcBlock;
use objc2::msg_send;
use objc2::runtime::{AnyClass, AnyObject};
use objc2_foundation::NSString;
use tokio::sync::oneshot;

/// What the scan ends with: the accepted `/activate?code=` link on this server, `None` for Cancel, or why it
/// couldn't start.
pub type Answer = Result<Option<String>, String>;

/// Shows the scanner over `controller` (the webview's), for codes on `origin`; `answer` gets the result.
pub fn start(controller: *mut c_void, origin: &str, answer: oneshot::Sender<Answer>) {
    let Some(scanner) = AnyClass::get(c"NectarScanner") else {
        let _ = answer.send(Err("The scanner isn't in this build.".into()));
        return;
    };
    let Some(controller) = (unsafe { (controller as *mut AnyObject).as_ref() }) else {
        let _ = answer.send(Err("The app's window is gone.".into()));
        return;
    };
    // The Swift side calls this once; the sender is taken so a second call can't answer twice.
    let answer = Mutex::new(Some(answer));
    let done = RcBlock::new(move |link: *mut NSString| {
        if let Some(answer) = answer.lock().unwrap().take() {
            let _ = answer.send(Ok(unsafe { link.as_ref() }.map(|link| link.to_string())));
        }
    });
    let origin = NSString::from_str(origin);
    unsafe {
        let _: () = msg_send![scanner, scanFrom: controller, origin: &*origin, done: &*done];
    }
}
