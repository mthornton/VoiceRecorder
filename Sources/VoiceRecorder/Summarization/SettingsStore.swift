import Foundation
import Observation

/// User settings: the OpenRouter key (Keychain) and everything else (UserDefaults).
@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let modelID = "settings.modelID"
        static let customPrompt = "settings.customPrompt"
        static let defaultTemplateID = "settings.defaultTemplateID"
        static let speakerAware = "settings.speakerAwareTranscription"
        static let transcriptionModelID = "settings.transcriptionModelID"
    }

    private let defaults: UserDefaults

    var apiKey: String {
        didSet { KeychainStore.save(apiKey) }
    }

    var modelID: String {
        didSet { defaults.set(modelID, forKey: Keys.modelID) }
    }

    var customPrompt: String {
        didSet { defaults.set(customPrompt, forKey: Keys.customPrompt) }
    }

    var defaultTemplateID: String {
        didSet { defaults.set(defaultTemplateID, forKey: Keys.defaultTemplateID) }
    }

    /// When on, recordings are transcribed by an audio model via OpenRouter so
    /// turns get speaker labels. This uploads the audio itself, not just text —
    /// the only setting in the app that changes what leaves the device.
    var speakerAwareTranscription: Bool {
        didSet { defaults.set(speakerAwareTranscription, forKey: Keys.speakerAware) }
    }

    var transcriptionModelID: String {
        didSet { defaults.set(transcriptionModelID, forKey: Keys.transcriptionModelID) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apiKey = KeychainStore.load() ?? ""
        self.modelID = defaults.string(forKey: Keys.modelID) ?? CuratedModel.defaultID
        self.customPrompt = defaults.string(forKey: Keys.customPrompt) ?? SummaryTemplate.defaultCustomPrompt
        self.defaultTemplateID = defaults.string(forKey: Keys.defaultTemplateID) ?? SummaryTemplate.meeting.id
        // Defaults on, but it only takes effect once there's a key — see
        // `usesSpeakerAwareTranscription`.
        self.speakerAwareTranscription = defaults.object(forKey: Keys.speakerAware) as? Bool ?? true
        self.transcriptionModelID = defaults.string(forKey: Keys.transcriptionModelID)
            ?? CuratedTranscriptionModel.defaultID
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The setting alone isn't enough — without a key there's nothing to call,
    /// so transcription falls back to on-device rather than failing. This keeps
    /// the app fully usable before it's configured.
    var usesSpeakerAwareTranscription: Bool {
        speakerAwareTranscription && hasAPIKey
    }

    func template(withID id: String) -> SummaryTemplate {
        SummaryTemplate.template(withID: id, customPrompt: customPrompt)
    }

    var availableTemplates: [SummaryTemplate] {
        SummaryTemplate.all(customPrompt: customPrompt)
    }
}
