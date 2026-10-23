//! The system sign-in sheet (ASWebAuthenticationSession), for approving this device's code on the device itself
//! (Capping, #144). It opens over the app and shares Safari's saved passwords. nectar's `/activate` has no callback
//! to return through, so the shell closes the sheet itself when the code's poll ends. Main thread only.

use std::cell::RefCell;
use std::ffi::c_void;

use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2::{define_class, msg_send, AllocAnyThread, DefinedClass, MainThreadMarker, MainThreadOnly};
use objc2_authentication_services::{
    ASPresentationAnchor, ASWebAuthenticationPresentationContextProviding, ASWebAuthenticationSession,
};
use objc2_foundation::{NSError, NSObject, NSObjectProtocol, NSString, NSURL};
use objc2_ui_kit::UIViewController;

/// A scheme nothing opens: the sheet only ever ends by the shell closing it, or the person doing so.
const NO_CALLBACK: &str = "nectar-shell-unused";

define_class!(
    /// Tells the sheet which window to sit over.
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[ivars = Retained<NSObject>]
    struct Anchor;

    unsafe impl NSObjectProtocol for Anchor {}

    unsafe impl ASWebAuthenticationPresentationContextProviding for Anchor {
        #[unsafe(method_id(presentationAnchorForWebAuthenticationSession:))]
        fn anchor(&self, _session: &ASWebAuthenticationSession) -> Retained<ASPresentationAnchor> {
            self.ivars().clone()
        }
    }
);

thread_local! {
    /// The open sheet and its anchor, kept alive until it closes.
    static OPEN: RefCell<Option<(Retained<ASWebAuthenticationSession>, Retained<Anchor>)>> = const { RefCell::new(None) };
}

/// Opens the sheet at `url` over the window holding `controller` (the webview's view controller).
pub fn open(url: &str, controller: *mut c_void) -> Result<(), String> {
    let main = MainThreadMarker::new().ok_or("The sign-in sheet needs the main thread.")?;
    close();
    let controller = unsafe { (controller as *mut UIViewController).as_ref() }.ok_or("The app's window is gone.")?;
    let window = controller.view().and_then(|view| view.window()).ok_or("The app's window is gone.")?;
    let url = NSURL::URLWithString(&NSString::from_str(url)).ok_or("The approval link isn't a web address.")?;

    // The crate types the anchor as NSObject (a UIWindow on iOS).
    let window: Retained<NSObject> = Retained::into_super(Retained::into_super(Retained::into_super(window)));
    let anchor = Anchor::alloc(main).set_ivars(window);
    let anchor: Retained<Anchor> = unsafe { msg_send![super(anchor), init] };
    // Closed by the person, or by us: either way it's done, and nothing more is needed (the code screen stays).
    let done = RcBlock::new(|_url: *mut NSURL, _error: *mut NSError| {
        OPEN.with(|open| open.borrow_mut().take());
    });
    // The scheme form, not iOS 17.4's `callback:`, since the shell runs from iOS 15.
    #[allow(deprecated)]
    let session = unsafe {
        ASWebAuthenticationSession::initWithURL_callbackURLScheme_completionHandler(
            ASWebAuthenticationSession::alloc(),
            &url,
            Some(&NSString::from_str(NO_CALLBACK)),
            RcBlock::as_ptr(&done),
        )
    };
    unsafe {
        session.setPresentationContextProvider(Some(ProtocolObject::from_ref(&*anchor)));
        // Not ephemeral, so Safari's saved nectar password and session carry over.
        session.setPrefersEphemeralWebBrowserSession(false);
    }
    if !unsafe { session.start() } {
        return Err("The sign-in sheet didn't open.".into());
    }
    OPEN.with(|open| *open.borrow_mut() = Some((session, anchor)));
    Ok(())
}

/// Closes the sheet if one is open.
pub fn close() {
    if let Some((session, _anchor)) = OPEN.with(|open| open.borrow_mut().take()) {
        unsafe { session.cancel() };
    }
}
