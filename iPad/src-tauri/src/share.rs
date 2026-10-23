//! Handing the code's approval link to another device (#148): the system share sheet (AirDrop, Messages, Mail,
//! Copy), and Handoff while a code is shown, so a Mac on the same Apple ID offers it in Safari. Main thread only.

use std::cell::RefCell;
use std::ffi::c_void;

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{AllocAnyThread, MainThreadMarker, MainThreadOnly};
use objc2_core_foundation::{CGPoint, CGRect, CGSize};
use objc2_foundation::{NSArray, NSString, NSURL, NSUserActivity, NSUserActivityTypeBrowsingWeb};
use objc2_ui_kit::{
    UIActivityViewController, UIDevice, UIModalPresentationStyle, UISheetPresentationControllerDetent, UIUserInterfaceIdiom,
    UIViewController,
};

thread_local! {
    /// The Handoff offer while a code is shown.
    static OFFERED: RefCell<Option<Retained<NSUserActivity>>> = const { RefCell::new(None) };
}

/// The share sheet for `url`, over `controller` (the webview's); on an iPad, a popover from `from` (x, y, w, h in
/// the page, which is the view's own points).
pub fn share(url: &str, controller: *mut c_void, from: [f64; 4]) -> Result<(), String> {
    let main = MainThreadMarker::new().ok_or("Sharing needs the main thread.")?;
    let controller = unsafe { (controller as *mut UIViewController).as_ref() }.ok_or("The app's window is gone.")?;
    let url = NSURL::URLWithString(&NSString::from_str(url)).ok_or("The approval link isn't a web address.")?;
    let items: Retained<NSArray<AnyObject>> = unsafe { Retained::cast_unchecked(NSArray::from_retained_slice(&[url])) };
    let sheet = unsafe {
        UIActivityViewController::initWithActivityItems_applicationActivities(UIActivityViewController::alloc(main), &items, None)
    };
    // Only an iPad's sheet is a popover from the control. On an iPhone it's left to the system's own bottom sheet: a
    // source given there made iOS 26 draw it as a clipped miniature by the control (Nate's iPhone, 2026-10-23).
    let pad = UIDevice::currentDevice(main).userInterfaceIdiom() == UIUserInterfaceIdiom::Pad;
    if !pad {
        // Stated outright on an iPhone: a page sheet at medium and large. Left to adapt, iOS 26 hosted it at the
        // wrong size, squashed into a corner (Nate's iPhone, 2026-10-23).
        sheet.setModalPresentationStyle(UIModalPresentationStyle::PageSheet);
        if let Some(sizes) = sheet.sheetPresentationController() {
            sizes.setDetents(&NSArray::from_retained_slice(&[
                UISheetPresentationControllerDetent::mediumDetent(main),
                UISheetPresentationControllerDetent::largeDetent(main),
            ]));
        }
    }
    if pad {
        if let (Some(popover), Some(view)) = (sheet.popoverPresentationController(), controller.view()) {
            let [x, y, w, h] = from;
            popover.setSourceView(Some(&view));
            popover.setSourceRect(CGRect::new(CGPoint::new(x, y), CGSize::new(w, h)));
        }
    }
    // From the window's top controller, so the sheet sits over the whole app, not inside the webview's.
    let mut top = controller.view().and_then(|view| view.window()).and_then(|window| window.rootViewController());
    while let Some(presented) = top.as_ref().and_then(|c| c.presentedViewController()) {
        top = Some(presented);
    }
    top.as_deref().unwrap_or(controller).presentViewController_animated_completion(&sheet, true, None);
    Ok(())
}

/// Offers `url` through Handoff, replacing any earlier offer; `None` withdraws it.
pub fn offer(url: Option<&str>) {
    if let Some(earlier) = OFFERED.with(|offered| offered.borrow_mut().take()) {
        earlier.invalidate();
    }
    let Some(url) = url.and_then(|url| NSURL::URLWithString(&NSString::from_str(url))) else { return };
    let activity = NSUserActivity::initWithActivityType(NSUserActivity::alloc(), unsafe { NSUserActivityTypeBrowsingWeb });
    activity.setWebpageURL(Some(&url));
    activity.becomeCurrent();
    OFFERED.with(|offered| *offered.borrow_mut() = Some(activity));
}
