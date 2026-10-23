import NectarKit
import SwiftUI

/// Account, native (#165 slice 1, Capping's `native-account.md`): the system's Settings idiom, with nectar's words.
/// The person as the header; language and playback saving as they change; sign-in (the password and linked
/// providers); devices, with approving another device's code; Jellyfin app credentials; and Sign out at the foot.
/// The TV app's `AccountModel` keeps preferences, devices and credentials; the rest is asked for here.
struct AccountScreen: View {

    let model: AccountModel
    /// Sign this iPhone out: the frame's, which also clears the token.
    let signOut: () -> Void

    @State
    private var providers: [SignInProvider] = []
    @State
    private var notice: String?
    @State
    private var changingPassword = false
    @State
    private var approving = false
    @State
    private var newCredential = false
    @State
    private var renaming: Device?
    @State
    private var renameTo = ""
    @State
    private var confirmOthers = false
    @State
    private var confirmSignOut = false
    @State
    private var revoking: JellyfinCredential?
    @State
    private var unlinking: SignInProvider?
    @Environment(\.dynamicTypeSize)
    private var typeSize

    var body: some View {
        List {
            header
            if let notice {
                Section { Label(notice, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange) }
            }
            if let preferences = model.preferences { playback(preferences) }
            signIn
            devices
            credentials
            Section {
                Button("Sign out", role: .destructive) { confirmSignOut = true }
            }
        }
        .listStyle(.insetGrouped)
        .tint(Color.brhGold)
        .scrollContentBackground(.hidden)
        .background(Color.brhNight)
        .task {
            await model.load()
            providers = (try? await model.session.signInProviders()) ?? []
        }
        .refreshable {
            await model.load()
            providers = (try? await model.session.signInProviders()) ?? []
        }
        .onChange(of: model.problem) { notice = model.problem }
        .sheet(isPresented: $changingPassword) { ChangePassword(session: model.session, done: signOut) }
        .sheet(isPresented: $approving) { ApproveDevice(session: model.session, code: "") }
        .sheet(isPresented: $newCredential, onDismiss: { Task { await model.load() } }) { NewCredential(session: model.session) }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameTo)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let device = renaming { rename(device) } }
        }
        .confirmationDialog("Sign out every other device?", isPresented: $confirmOthers, titleVisibility: .visible) {
            Button("Sign out other devices", role: .destructive) { Task { await model.signOutOthers() } }
        } message: {
            Text("Browsers and apps signed in as \(model.user.username) will need to sign in again. This iPhone stays signed in.")
        }
        .confirmationDialog("Sign out of nectar on this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive, action: signOut)
        }
        .confirmationDialog("Revoke \(revoking?.label ?? "")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button("Revoke", role: .destructive) { if let credential = revoking { Task { await model.revoke(credential) } } }
        } message: {
            Text("The app using it will be signed out of nectar.")
        }
        .confirmationDialog("Remove \(unlinking?.name ?? "")?", isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let provider = unlinking { unlink(provider) } }
        } message: {
            Text("You won't be able to sign in with \(unlinking?.name ?? "it") any more.")
        }
    }

    // MARK: The person

    private var header: some View {
        Section {
            VStack(spacing: 8) {
                Text(String(model.user.username.prefix(1)).uppercased())
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 64, height: 64)
                    .background(Color.brhCard, in: .circle)
                    .overlay { Circle().stroke(Color.brhGold, lineWidth: 1) }
                Text(model.user.username).font(.title2.weight(.semibold))
                Text(model.user.isAdmin ? "Admin" : "Member").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Language & playback

    private func playback(_ preferences: Preferences) -> some View {
        Section("Language & playback") {
            Picker("Language", selection: binding(\.locale, preferences)) {
                Text("Not set").tag(String?.none)
                ForEach(Self.locales, id: \.self) { tag in Text(Locale.current.localizedString(forIdentifier: tag) ?? tag).tag(String?.some(tag)) }
            }
            .pickerStyle(.navigationLink)
            NavigationLink {
                TimeZonePicker(selection: preferences.timeZone) { zone in Task { await model.update { $0.timeZone = zone } } }
            } label: {
                LabeledContent("Time zone", value: zoneLabel(preferences.timeZone))
            }
            Picker("Audio language", selection: binding(\.audioLanguage, preferences)) {
                Text("The file's default").tag(String?.none)
                ForEach(AccountModel.languages, id: \.self) { Text(AccountModel.name(of: $0)).tag(String?.some($0)) }
            }
            .pickerStyle(.navigationLink)
            Picker("Subtitle language", selection: binding(\.subtitleLanguage, preferences)) {
                Text("None preferred").tag(String?.none)
                ForEach(AccountModel.languages, id: \.self) { Text(AccountModel.name(of: $0)).tag(String?.some($0)) }
            }
            .pickerStyle(.navigationLink)
            Picker("Subtitles", selection: Binding(get: { preferences.subtitleMode }, set: { mode in Task { await model.update { $0.subtitleMode = mode } } })) {
                Text("Suggest a track in your language (default)").tag(Preferences.SubtitleMode.serverDefault)
                Text("None").tag(Preferences.SubtitleMode.off)
                Text("Suggest a track in your language").tag(Preferences.SubtitleMode.auto)
                Text("Burn a track in your language into the picture").tag(Preferences.SubtitleMode.always)
            }
            .pickerStyle(.navigationLink)
            Toggle("Prefer the original language's audio", isOn: Binding(get: { preferences.preferOriginalAudio }, set: { on in Task { await model.update { $0.preferOriginalAudio = on } } }))
            Picker("Bitrate cap", selection: Binding(get: { preferences.maxStreamingBitrate }, set: { cap in Task { await model.update { $0.maxStreamingBitrate = cap } } })) {
                Text("No cap").tag(Int?.none)
                ForEach(Self.caps, id: \.self) { Text("\($0 / 1_000_000) Mbit/s").tag(Int?.some($0)) }
            }
            .pickerStyle(.navigationLink)
        }
    }

    /// A text preference as a picker selection that saves as it changes.
    private func binding(_ key: WritableKeyPath<Preferences, String?>, _ preferences: Preferences) -> Binding<String?> {
        Binding(get: { preferences[keyPath: key] }, set: { value in Task { await model.update { $0[keyPath: key] = value } } })
    }

    private func zoneLabel(_ zone: String?) -> String {
        guard let zone else { return "Not set" }
        return zone == TimeZone.current.identifier ? "This device's" : zone.replacingOccurrences(of: "_", with: " ")
    }

    static let locales = ["en-US", "en-GB", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "nl-NL", "sv-SE", "ja-JP", "ko-KR", "zh-CN"]
    static let caps = [4_000_000, 8_000_000, 12_000_000, 20_000_000, 40_000_000, 80_000_000]

    // MARK: Sign-in

    private var signIn: some View {
        Section {
            Button("Change password") { changingPassword = true }.foregroundStyle(.primary)
            ForEach(providers) { provider in
                if provider.linked {
                    LabeledContent(provider.name, value: "Linked")
                        .swipeActions { Button("Remove", role: .destructive) { unlinking = provider } }
                    // Passkeys live with the provider (Keycloak's Signing in page), in the system's sign-in sheet.
                    if let account = provider.accountURL {
                        Button { WebAuth.shared.open(account) } label: {
                            Label("Passkeys and sign-in at \(provider.name)", systemImage: "person.badge.key")
                        }
                        .foregroundStyle(.primary)
                    }
                } else {
                    Button("Link \(provider.name)…") { link(provider) }.foregroundStyle(.primary)
                }
            }
        } header: {
            Text("Sign-in")
        } footer: {
            Text("The accounts at other services that can open this one. You can always keep at least one way in.")
        }
    }

    private func link(_ provider: SignInProvider) {
        Task {
            do {
                let url = try await model.session.linkURL(for: provider.id)
                WebAuth.shared.open(url) {
                    Task { providers = (try? await model.session.signInProviders()) ?? providers }
                }
            } catch {
                notice = Self.words(error, otherwise: "Couldn't start linking \(provider.name).")
            }
        }
    }

    private func unlink(_ provider: SignInProvider) {
        Task {
            do {
                try await model.session.unlink(provider: provider.id)
                providers = (try? await model.session.signInProviders()) ?? providers
            } catch {
                notice = Self.words(error, otherwise: "Couldn't remove \(provider.name).")
            }
        }
    }

    // MARK: Devices

    private var devices: some View {
        Section {
            ForEach(model.devices ?? []) { device in
                // At the accessibility sizes the plate goes under the name, so the name keeps the row's width.
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout())
                layout {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text(deviceLine(device)).font(.footnote).foregroundStyle(.secondary)
                    }
                    if !typeSize.isAccessibilitySize { Spacer() }
                    if device.isCurrent {
                        Text("This iPhone").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.brhCard, in: .capsule)
                    }
                }
                .swipeActions {
                    if !device.isCurrent {
                        Button("Sign out", role: .destructive) { Task { await model.signOut(device) } }
                    }
                    Button("Rename") { renameTo = device.name; renaming = device }.tint(.gray)
                }
            }
            Button("Approve another device…") { approving = true }.foregroundStyle(.primary)
            Button("Sign out every other device", role: .destructive) { confirmOthers = true }
        } header: {
            Text("Devices")
        }
    }

    /// kind · how it signed in · last used, in words rather than nectar's codes.
    private func deviceLine(_ device: Device) -> String {
        let kind: String = switch device.kind {
        case "web": "Browser"
        case "device_flow", "device": "App"
        case "jellyfin": "Jellyfin app"
        default: device.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
        let method: String? = switch device.signInMethod {
        case "password": "password"
        case "device_flow": "a code"
        case "passkey": "a passkey"
        case "oidc", "sso": "single sign-on"
        case nil: nil
        case let other?: other.replacingOccurrences(of: "_", with: " ")
        }
        let used = device.lastUsed.map { "last used " + $0.formatted(.relative(presentation: .named)) }
        return [kind, method.map { "signed in with " + $0 }, used].compactMap(\.self).joined(separator: " · ")
    }

    private func rename(_ device: Device) {
        let name = renameTo.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            do {
                try await model.session.rename(device: device.id, to: name)
                await model.load()
            } catch {
                notice = Self.words(error, otherwise: "Couldn't rename \(device.name).")
            }
        }
    }

    // MARK: Jellyfin app credentials

    private var credentials: some View {
        Section {
            if model.credentialsEnabled {
                ForEach(model.credentials) { credential in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(credential.label)
                        Text(credentialLine(credential)).font(.footnote).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Revoke", role: .destructive) { revoking = credential } }
                }
                Button("New credential…") { newCredential = true }.foregroundStyle(.primary)
            }
        } header: {
            Text("Jellyfin app credentials")
        } footer: {
            Text(model.credentialsEnabled
                ? "For apps like Infuse that sign in the Jellyfin way: a username and password made for one app, never your password."
                : "The server has Jellyfin app sign-in turned off.")
        }
    }

    private func credentialLine(_ credential: JellyfinCredential) -> String {
        let created = credential.createdAt.map { "created " + $0.formatted(date: .abbreviated, time: .omitted) }
        let used = credential.lastUsed.map { "last used " + $0.formatted(.relative(presentation: .named)) } ?? "never used"
        return [created, used].compactMap(\.self).joined(separator: " · ")
    }

    /// nectar's own words for a refusal, or a plain line.
    static func words(_ error: Error, otherwise: String) -> String {
        if case let NectarSessionError.refused(_, message) = error { return message }
        return otherwise
    }
}

/// Every time zone, searchable; this device's first.
private struct TimeZonePicker: View {
    let selection: String?
    let choose: (String?) -> Void
    @State
    private var query = ""
    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        let device = TimeZone.current.identifier
        let zones = TimeZone.knownTimeZoneIdentifiers.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query.replacingOccurrences(of: " ", with: "_")) }
        List {
            if query.isEmpty {
                row("This device's (\(device.replacingOccurrences(of: "_", with: " ")))", device)
            }
            ForEach(zones, id: \.self) { zone in row(zone.replacingOccurrences(of: "_", with: " "), zone) }
        }
        .searchable(text: $query)
        .navigationTitle("Time zone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ zone: String) -> some View {
        Button {
            choose(zone)
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selection == zone { Image(systemName: "checkmark").foregroundStyle(Color.brhGold) }
            }
        }
    }
}

/// Hides a sensitive screen from the app switcher's snapshot (the element set's `sensitive`).
private struct Sensitive: ViewModifier {
    @Environment(\.scenePhase)
    private var phase

    func body(content: Content) -> some View {
        content.overlay { if phase != .active { Color.brhNight.ignoresSafeArea() } }
    }
}

/// Change password: the current one, the new one twice, the system's keychain and strong-password suggestion.
/// nectar signs every device out when it changes, this iPhone included, so success signs in again.
private struct ChangePassword: View {
    let session: NectarSession
    let done: () -> Void

    @State
    private var current = ""
    @State
    private var new = ""
    @State
    private var confirm = ""
    @State
    private var working = false
    @State
    private var refusal: String?
    @State
    private var changed = false
    /// nectar #830 keeps the device that changed it signed in; before that, this iPhone signs in again too.
    @State
    private var keptSignedIn = false
    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Current password", text: $current).textContentType(.password)
                } footer: {
                    if let refusal { Text(refusal).foregroundStyle(.red) }
                }
                Section {
                    SecureField("New password", text: $new).textContentType(.newPassword)
                    SecureField("Confirm", text: $confirm).textContentType(.newPassword)
                } footer: {
                    Text(new.isEmpty || confirm.isEmpty || new == confirm
                        ? "At least 12 characters. Changing it signs out every other device, which sign in again with the new password."
                        : "The two new passwords don't match.")
                }
                Section {
                    Button {
                        change()
                    } label: {
                        HStack(spacing: 8) {
                            if working { ProgressView().tint(Color.brhGoldInk) }
                            Text("Change password")
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(CapsuleStyle(primary: true))
                    .disabled(working || current.isEmpty || new.count < 12 || new != confirm)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Change password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Password changed", isPresented: $changed) {
                if keptSignedIn {
                    Button("OK") { dismiss() }
                } else {
                    Button("Sign in", action: done)
                }
            } message: {
                Text(keptSignedIn
                    ? "Every other device was signed out. This iPhone stays signed in."
                    : "Every device was signed out, this iPhone too. Sign in again with your new password.")
            }
        }
        .modifier(Sensitive())
        .sensoryFeedback(.warning, trigger: refusal)
    }

    private func change() {
        working = true
        refusal = nil
        Task {
            defer { working = false }
            do {
                keptSignedIn = try await session.changePassword(current: current, new: new)
                current = ""
                new = ""
                confirm = ""
                changed = true
            } catch {
                refusal = AccountScreen.words(error, otherwise: "Couldn't change it. Check your connection and try again.")
            }
        }
    }
}

/// Approve another device: its code (typed, or from the scanner in More), what's asking, and one Approve.
struct ApproveDevice: View {
    let session: NectarSession
    @State
    var code: String

    @State
    private var found: DeviceCode?
    @State
    private var refusal: String?
    @State
    private var approved = false
    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .onSubmit { look() }
                } footer: {
                    Text("The code another device shows, like ABCD-EFGH.")
                }
                if let found {
                    Section {
                        LabeledContent("Device", value: found.deviceName ?? "A device")
                        LabeledContent("Code", value: found.code)
                    }
                }
                Section {
                    Button {
                        found == nil ? look() : approve()
                    } label: {
                        Text(approved ? "Approved" : found == nil ? "Look up" : "Approve").frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(CapsuleStyle(primary: true))
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || approved)
                    .listRowBackground(Color.clear)
                } footer: {
                    if let refusal { Text(refusal).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Approve a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(approved ? "Done" : "Cancel") { dismiss() } } }
            .task { if !code.isEmpty { look() } }
        }
        .sensoryFeedback(.success, trigger: approved)
    }

    private func look() {
        refusal = nil
        Task {
            do {
                found = try await session.lookUp(code: code.trimmingCharacters(in: .whitespaces).uppercased())
            } catch {
                refusal = "No device is waiting with that code. Check it and try again."
            }
        }
    }

    private func approve() {
        guard let found else { return }
        Task {
            do {
                try await session.decide(code: found.code, approve: true)
                approved = true
            } catch {
                refusal = AccountScreen.words(error, otherwise: "Couldn't approve it. Try again.")
            }
        }
    }
}

/// A new Jellyfin app credential: a label, the server's risk, Create; then the one-time card, never shown again.
private struct NewCredential: View {
    let session: NectarSession

    @State
    private var label = ""
    @State
    private var risk: (version: String, text: String)?
    @State
    private var made: NewJellyfinCredential?
    @State
    private var refusal: String?
    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let made {
                    Section {
                        copyRow("Username", made.username)
                        copyRow("Password", made.password)
                    } footer: {
                        Text("Enter these in the app now: the password won't be shown again.").foregroundStyle(.orange)
                    }
                } else {
                    Section {
                        TextField("Label, like Infuse on the iPad", text: $label)
                    } footer: {
                        if let risk { Text(risk.text) }
                    }
                    Section {
                        Button { create() } label: { Text("Create").frame(maxWidth: .infinity, minHeight: 48) }
                            .buttonStyle(CapsuleStyle(primary: true))
                            .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || risk == nil)
                            .listRowBackground(Color.clear)
                    } footer: {
                        if let refusal { Text(refusal).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("New credential")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(made == nil ? "Cancel" : "Done") { dismiss() } } }
            .task { risk = try? await session.jellyfinRisk() }
        }
        .modifier(Sensitive())
        .sensoryFeedback(.success, trigger: made != nil)
    }

    private func copyRow(_ title: String, _ value: String) -> some View {
        HStack {
            LabeledContent(title, value: value).textSelection(.enabled)
            Button("Copy") { UIPasteboard.general.string = value }.buttonStyle(.borderless)
        }
    }

    private func create() {
        guard let risk else { return }
        Task {
            do {
                made = try await session.createJellyfinCredential(label: label.trimmingCharacters(in: .whitespaces), riskVersion: risk.version)
            } catch {
                refusal = AccountScreen.words(error, otherwise: "Couldn't make it. Try again.")
            }
        }
    }
}
