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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apiKey = KeychainStore.load() ?? ""
        self.modelID = defaults.string(forKey: Keys.modelID) ?? CuratedModel.defaultID
        self.customPrompt = defaults.string(forKey: Keys.customPrompt) ?? SummaryTemplate.defaultCustomPrompt
        self.defaultTemplateID = defaults.string(forKey: Keys.defaultTemplateID) ?? SummaryTemplate.meeting.id
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func template(withID id: String) -> SummaryTemplate {
        SummaryTemplate.template(withID: id, customPrompt: customPrompt)
    }

    var availableTemplates: [SummaryTemplate] {
        SummaryTemplate.all(customPrompt: customPrompt)
    }
}
