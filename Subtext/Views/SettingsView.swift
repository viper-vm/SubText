import AuthenticationServices
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @AppStorage(Prefs.Key.clientID) private var clientID = Config.spotifyClientID
    @AppStorage(Prefs.Key.engine) private var engine: TranslationEngine = .apple
    @AppStorage(Prefs.Key.model) private var claudeModel: ClaudeModel = .opus
    @AppStorage(Prefs.Key.target) private var target = "en"
    @AppStorage(Prefs.Key.showRomanization) private var showRoman = true
    @AppStorage(Prefs.Key.showTranslation) private var showTranslation = true
    @AppStorage(Prefs.Key.showNotes) private var showNotes = true
    @AppStorage(Prefs.Key.offset) private var offset = 0.0
    @AppStorage(Prefs.Key.lockScreen) private var lockScreen = true

    @State private var keyDraft = ""
    @State private var keyHint = Prefs.claudeKeyHint
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                spotifySection
                translationSection
                claudeSection
                displaySection
                lockScreenSection
                Section {
                    NavigationLink("Set up the Shazam shortcut") { ShortcutHelpView() }
                } header: {
                    Text("Songs outside Spotify")
                } footer: {
                    Text("For music from other apps or playing around you: one tap runs Shazam and opens the song here.")
                }
                Section("Saved data") {
                    Button("Clear saved translations and answers", role: .destructive) { confirmClear = true }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    Link("Lyrics come from LRCLIB", destination: URL(string: "https://lrclib.net")!)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Clear every saved translation and answer?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear translations and answers", role: .destructive) { model.clearSavedTranslations() }
            } message: {
                Text("Lyrics and history stay. Songs are translated again the next time you open them.")
            }
            .onChange(of: target) { model.translateIfNeeded(force: false) }
        }
    }

    // MARK: Sections

    private var spotifySection: some View {
        Section {
            if model.spotify.isConnected {
                LabeledContent("Status") {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Color.spotifyGreen)
                }
                Button("Disconnect Spotify", role: .destructive) { model.disconnectSpotify() }
            } else {
                Button {
                    Task { await model.connectSpotify(using: webAuthenticationSession) }
                } label: {
                    Label("Connect Spotify", systemImage: "link")
                }
                .disabled(Prefs.spotifyClientID.isEmpty && clientID.isEmpty)
            }
            if let message = model.spotifyMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            DisclosureGroup("Spotify app details") {
                TextField("Client ID", text: $clientID)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LabeledContent("Redirect URI", value: Config.spotifyRedirectURI)
                    .font(.footnote)
            }
        } header: {
            Text("Spotify")
        } footer: {
            Text("Subtext reads what Spotify is playing, so the lyrics follow the song even on earphones. Spotify requires Premium for this.")
        }
    }

    private var translationSection: some View {
        Section {
            Picker("Translate into", selection: $target) {
                ForEach(TargetLanguage.all) { Text($0.name).tag($0.code) }
            }
            Picker("Translator", selection: $engine) {
                ForEach(TranslationEngine.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Translation")
        } footer: {
            Text("Apple's translator is free and private but knows about 20 languages (not Punjabi, Tamil or Telugu) and translates literally. Claude handles almost any language, explains idioms and references, and writes how each line sounds. When Apple can't do a song and a Claude key is saved, Claude is used.")
        }
    }

    private var claudeSection: some View {
        Section {
            if let keyHint {
                LabeledContent("API key", value: "Saved \(keyHint)")
                Button("Remove key", role: .destructive) {
                    Keychain.delete(Prefs.claudeKeyAccount)
                    self.keyHint = nil
                    engine = .apple
                }
            } else {
                SecureField("Paste your API key", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") {
                    let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { return }
                    Keychain.set(key, for: Prefs.claudeKeyAccount)
                    keyDraft = ""
                    keyHint = Prefs.claudeKeyHint
                    engine = .claude
                    model.translateIfNeeded(force: false)
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("Model", selection: $claudeModel) {
                ForEach(ClaudeModel.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("\(claudeModel.detail) Each song is translated once and saved, so replaying it costs nothing. Asking about a line costs about a cent or less per question. Get a key at console.anthropic.com; it stays in this iPhone's keychain.")
        }
    }

    private var lockScreenSection: some View {
        Section {
            Toggle("Lyrics on the Lock Screen", isOn: $lockScreen)
            if lockScreen && !LockScreenLyrics.systemAllows {
                Text("Live Activities are off for Subtext. Turn them on in the iPhone's Settings app → Subtext.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Lock Screen")
        } footer: {
            Text("While a song plays, the current line and its translation appear on the Lock Screen. To keep up, Subtext stays running in the background by playing silence under your music, which uses a little more battery. It stops after two minutes without music, or if you swipe Subtext away; open Subtext to start it again.")
        }
    }

    private var displaySection: some View {
        Section {
            Toggle("Pronunciation in English letters", isOn: $showRoman)
            Toggle("Translation", isOn: $showTranslation)
            Toggle("Notes on idioms and references", isOn: $showNotes)
            Stepper(value: $offset, in: -3...3, step: 0.25) {
                LabeledContent("Lyrics timing", value: offset == 0 ? "On time" : String(format: "%+.2f s", offset))
            }
        } header: {
            Text("Show")
        } footer: {
            Text("If the highlight runs behind the singing, raise the timing; if it runs ahead, lower it.")
        }
    }
}

struct ShortcutHelpView: View {
    var body: some View {
        List {
            Section {
                step(1, "Open the Shortcuts app and tap + to make a new shortcut.")
                step(2, "Add the action **Shazam It**.")
                step(3, "Add the action **Show Lyrics** (from Subtext). Tap **Song** and pick *Shazam Media → Title*; tap **Artist** and pick *Shazam Media → Artist*.")
                step(4, "Name it “What's this song?”.")
            } header: {
                Text("Make the shortcut")
            }
            Section {
                step(5, "In Settings → Accessibility → Touch → Back Tap, choose Double Tap and pick the shortcut.")
            } header: {
                Text("Run it with a tap on the back of the iPhone")
            } footer: {
                Text("You can also say “Hey Siri, what's this song?” or add it to Control Center. Shazam listens through the microphone, so it works best when the music is playing out loud.")
            }
        }
        .navigationTitle("Shazam shortcut")
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.bold())
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.18), in: Circle())
                .foregroundStyle(Color.accentColor)
            Text(text)
        }
        .padding(.vertical, 2)
    }
}
