import NectarKit
import SwiftUI

/// My Account, full screen. Passwords and sign-in methods stay on the web, where a keyboard is.
struct AccountView: View {

    @State
    private var model: AccountModel
    @State
    private var confirmingSignOutOthers = false
    @State
    private var revoking: JellyfinCredential?

    init(user: NectarUser, session: NectarSession) {
        _model = State(initialValue: AccountModel(user: user, session: session))
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 56) {
                profile
                if let problem = model.problem {
                    Text(problem).foregroundStyle(.orange)
                }
                playback
                devices
                jellyfin
            }
            .padding(80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .task { await model.load() }
        .alert("Sign out every other device?", isPresented: $confirmingSignOutOthers) {
            Button("Sign them out", role: .destructive) { Task { await model.signOutOthers() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Browsers and apps signed in as \(model.user.username) will need to sign in again. This TV stays signed in.")
        }
        .alert("Revoke \(revoking?.label ?? "this credential")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Revoke", role: .destructive) { if let credential = revoking { Task { await model.revoke(credential) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app using it will be signed out of nectar.")
        }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Account").font(.largeTitle.bold())
            Text(model.user.isAdmin ? "\(model.user.username) · administrator" : model.user.username).foregroundStyle(.secondary)
            Text("To change your password or how you sign in, use nectar in a web browser.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var playback: some View {
        Section("Language & playback") {
            if let preferences = model.preferences {
                LanguageMenu(title: "Audio", selection: preferences.audioLanguage, none: "The file's own") { code in
                    Task { await model.update { $0.audioLanguage = code } }
                }
                LanguageMenu(title: "Subtitle language", selection: preferences.subtitleLanguage, none: "None") { code in
                    Task { await model.update { $0.subtitleLanguage = code } }
                }
                Menu {
                    ForEach(Preferences.SubtitleMode.allCases, id: \.self) { mode in
                        Button(label(mode)) { Task { await model.update { $0.subtitleMode = mode } } }
                    }
                } label: {
                    Row(title: "Subtitles", value: label(preferences.subtitleMode))
                }
                Toggle(isOn: Binding(get: { preferences.preferOriginalAudio },
                                     set: { value in Task { await model.update { $0.preferOriginalAudio = value } } })) {
                    Text("Prefer the original language's audio")
                }
                .frame(width: 1000)
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var devices: some View {
        Section("Devices") {
            if let devices = model.devices {
                ForEach(devices) { device in
                    Button {
                        if !device.isCurrent { Task { await model.signOut(device) } }
                    } label: {
                        Row(title: device.isCurrent ? "\(device.name) · This TV" : device.name,
                            value: device.isCurrent ? lastUsed(device) : "\(lastUsed(device)) · Sign out")
                    }
                }
                if devices.contains(where: { !$0.isCurrent }) {
                    Button("Sign out every other device", role: .destructive) { confirmingSignOutOthers = true }
                }
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var jellyfin: some View {
        if model.credentialsEnabled || !model.credentials.isEmpty {
            Section("Jellyfin app credentials") {
                Text("Make new ones in nectar on the web: the password is shown once, and a TV is a shared screen.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.credentials.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(model.credentials) { credential in
                    Button { revoking = credential } label: {
                        Row(title: credential.label, value: credential.lastUsed.map { "used " + $0.formatted(.relative(presentation: .named)) + " · Revoke" } ?? "never used · Revoke")
                    }
                }
            }
        }
    }

    private func label(_ mode: Preferences.SubtitleMode) -> String {
        switch mode {
        case .serverDefault: "nectar's default"
        case .off: "Off"
        case .auto: "Automatic (when the audio isn't yours)"
        case .always: "Always"
        }
    }

    private func lastUsed(_ device: Device) -> String {
        device.lastUsed.map { "used " + $0.formatted(.relative(presentation: .named)) } ?? device.kind
    }
}

/// A titled group.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder
    let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3.bold())
            content()
        }
    }
}

/// A label on the left, its value on the right.
private struct Row: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .frame(width: 1000)
    }
}

/// A language chosen from nectar's list, or none.
private struct LanguageMenu: View {
    let title: String
    let selection: String?
    let none: String
    let choose: (String?) -> Void

    var body: some View {
        Menu {
            Button(none) { choose(nil) }
            ForEach(AccountModel.languages, id: \.self) { code in
                Button(AccountModel.name(of: code)) { choose(code) }
            }
        } label: {
            Row(title: title, value: selection.map(AccountModel.name(of:)) ?? none)
        }
    }
}
