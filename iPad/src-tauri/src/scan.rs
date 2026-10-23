//! Scanning another device's sign-in QR with the camera, for the web client's "Scan a code" (#149): a full-screen
//! AVFoundation preview with Cancel, answered with the code's text, or nothing when cancelled. Main thread only.

use std::cell::RefCell;
use std::ffi::c_void;

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, ProtocolObject};
use objc2::{define_class, msg_send, sel, DefinedClass, MainThreadMarker, MainThreadOnly};
use objc2_av_foundation::{
    AVAuthorizationStatus, AVCaptureConnection, AVCaptureDevice, AVCaptureDeviceInput, AVCaptureMetadataOutput,
    AVCaptureMetadataOutputObjectsDelegate, AVCaptureOutput, AVCaptureSession, AVCaptureVideoPreviewLayer,
    AVLayerVideoGravityResizeAspectFill, AVMediaTypeVideo, AVMetadataMachineReadableCodeObject, AVMetadataObject,
    AVMetadataObjectTypeQRCode,
};
use objc2_core_foundation::{CGPoint, CGRect, CGSize};
use objc2_foundation::{NSArray, NSObject, NSObjectProtocol, NSString};
use objc2_ui_kit::{
    UIButton, UIButtonType, UIColor, UIControlEvents, UIControlState, UIImpactFeedbackGenerator,
    UIImpactFeedbackStyle, UILabel, UIModalPresentationStyle, UIViewController,
};
use tokio::sync::oneshot;

/// What the scan ends with: the code's text, `None` for Cancel, or why it couldn't start.
pub type Answer = Result<Option<String>, String>;

pub struct State {
    answer: RefCell<Option<oneshot::Sender<Answer>>>,
    session: Retained<AVCaptureSession>,
    screen: Retained<UIViewController>,
}

define_class!(
    /// Receives the camera's codes and the Cancel tap.
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[ivars = State]
    struct Scanner;

    unsafe impl NSObjectProtocol for Scanner {}

    unsafe impl AVCaptureMetadataOutputObjectsDelegate for Scanner {
        #[unsafe(method(captureOutput:didOutputMetadataObjects:fromConnection:))]
        fn found(&self, _output: &AVCaptureOutput, objects: &NSArray<AVMetadataObject>, _connection: &AVCaptureConnection) {
            let text = objects.iter().find_map(|object| {
                object.downcast::<AVMetadataMachineReadableCodeObject>().ok().and_then(|code| unsafe { code.stringValue() })
            });
            if let Some(text) = text {
                let main = MainThreadMarker::from(self);
                // The style-only form, not iOS 17.5's `forView:`, since the shell runs from iOS 15.
                #[allow(deprecated)]
                let tap = UIImpactFeedbackGenerator::initWithStyle(UIImpactFeedbackGenerator::alloc(main), UIImpactFeedbackStyle::Light);
                tap.impactOccurred();
                self.finish(Ok(Some(text.to_string())));
            }
        }
    }

    impl Scanner {
        #[unsafe(method(cancel:))]
        fn cancel(&self, _sender: &AnyObject) {
            self.finish(Ok(None));
        }
    }
);

impl Scanner {
    /// Stops the camera, puts the screen away, and answers once.
    fn finish(&self, answer: Answer) {
        let Some(sent) = self.ivars().answer.borrow_mut().take() else { return };
        unsafe { self.ivars().session.stopRunning() };
        self.ivars().screen.dismissViewControllerAnimated_completion(true, None);
        let _ = sent.send(answer);
        SCANNING.with(|scanning| scanning.borrow_mut().take());
    }
}

thread_local! {
    /// The scanner on screen, kept alive until it answers.
    static SCANNING: RefCell<Option<Retained<Scanner>>> = const { RefCell::new(None) };
}

/// Opens the scanner over `controller` (the webview's); `answer` gets the result, or why it couldn't start.
pub fn start(controller: *mut c_void, answer: oneshot::Sender<Answer>) {
    match open(controller) {
        Ok((scanner, controller)) => {
            *scanner.ivars().answer.borrow_mut() = Some(answer);
            controller.presentViewController_animated_completion(&scanner.ivars().screen, true, None);
            unsafe { scanner.ivars().session.startRunning() };
            SCANNING.with(|scanning| *scanning.borrow_mut() = Some(scanner));
        }
        Err(why) => {
            let _ = answer.send(Err(why));
        }
    }
}

/// The camera, its session and the screen over it, ready to present.
fn open<'a>(controller: *mut c_void) -> Result<(Retained<Scanner>, &'a UIViewController), String> {
    let main = MainThreadMarker::new().ok_or("The scanner needs the main thread.")?;
    let controller = unsafe { (controller as *mut UIViewController).as_ref() }.ok_or("The app's window is gone.")?;
    let video = unsafe { AVMediaTypeVideo }.ok_or("This device has no camera.")?;
    if matches!(unsafe { AVCaptureDevice::authorizationStatusForMediaType(video) }, AVAuthorizationStatus::Denied | AVAuthorizationStatus::Restricted) {
        return Err("Nectar can't use the camera. Turn it on in Settings → Nectar → Camera.".into());
    }
    let camera = unsafe { AVCaptureDevice::defaultDeviceWithMediaType(video) }.ok_or("This device has no camera.")?;
    // Creating the input asks for the camera the first time; the preview starts once it's allowed.
    let input = unsafe { AVCaptureDeviceInput::deviceInputWithDevice_error(&camera) }.map_err(|_| "The camera couldn't start.")?;
    let session = unsafe { AVCaptureSession::new() };
    let output = unsafe { AVCaptureMetadataOutput::new() };
    unsafe {
        if !session.canAddInput(&input) || !session.canAddOutput(&output) {
            return Err("The camera couldn't start.".into());
        }
        session.addInput(&input);
        session.addOutput(&output);
    }

    let screen = UIViewController::new(main);
    screen.setModalPresentationStyle(UIModalPresentationStyle::FullScreen);
    let view = screen.view().ok_or("The scanner's screen didn't load.")?;
    view.setBackgroundColor(Some(&UIColor::blackColor()));
    let bounds = controller.view().ok_or("The app's window is gone.")?.bounds();
    view.setFrame(bounds);
    let preview = unsafe { AVCaptureVideoPreviewLayer::layerWithSession(&session) };
    if let Some(fill) = unsafe { AVLayerVideoGravityResizeAspectFill } { unsafe { preview.setVideoGravity(fill) }; }
    preview.setFrame(bounds);
    view.layer().addSublayer(&preview);

    let scanner = Scanner::alloc(main).set_ivars(State { answer: RefCell::new(None), session, screen: screen.clone() });
    let scanner: Retained<Scanner> = unsafe { msg_send![super(scanner), init] };
    let qr = unsafe { AVMetadataObjectTypeQRCode };
    unsafe {
        output.setMetadataObjectsDelegate_queue(Some(ProtocolObject::from_ref(&*scanner)), Some(dispatch2::DispatchQueue::main()));
        output.setMetadataObjectTypes(Some(&NSArray::from_slice(&[qr])));
    }

    let hint = UILabel::new(main);
    hint.setText(Some(&NSString::from_str("Point at the code on the other screen.")));
    unsafe { hint.setTextColor(Some(&UIColor::whiteColor())) };
    hint.setTextAlignment(objc2_ui_kit::NSTextAlignment::Center);
    hint.setFrame(CGRect::new(CGPoint::new(16.0, bounds.size.height - 140.0), CGSize::new(bounds.size.width - 32.0, 44.0)));
    view.addSubview(&hint);

    let cancel = UIButton::buttonWithType(UIButtonType::System, main);
    cancel.setTitle_forState(Some(&NSString::from_str("Cancel")), UIControlState::Normal);
    unsafe { cancel.setTintColor(Some(&UIColor::whiteColor())) };
    let top = controller.view().map(|v| v.safeAreaInsets().top).unwrap_or(0.0);
    cancel.setFrame(CGRect::new(CGPoint::new(16.0, top + 8.0), CGSize::new(88.0, 44.0)));
    unsafe { cancel.addTarget_action_forControlEvents(Some(&scanner), sel!(cancel:), UIControlEvents::TouchUpInside) };
    view.addSubview(&cancel);
    Ok((scanner, controller))
}
