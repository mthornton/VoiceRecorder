import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var keyDraft = ""
    @State private var isRevealed = false
    @State private var validation: Validation = .idle
    @State private var useCustomModel = false
    @State private var customModelDraft = ""

    private enum Validation: Equatable {
        case idle
        case checking
        case valid(String?)
        case invalid(String)
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                apiKeySection
                transcriptionSection
                modelSection
                templateSection
                aboutSection
            }
            .navigationTitle("Settings")
            .onAppear {
                keyDraft = settings.apiKey
                useCustomModel = !CuratedModel.all.contains { $0.id == settings.modelID }
                customModelDraft = useCustomModel ? settings.modelID : ""
            }
        }
    }

    // MARK: - API key

    private var apiKeySection: some View {
        Section {
            HStack {
                Group {
                    if isRevealed {
                        TextField("sk-or-v1-…", text: $keyDraft)
                    } else {
                        SecureField("sk-or-v1-…", text: $keyDraft)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .onChange(of: keyDraft) { _, _ in validation = .idle }

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack {
                Button("Save Key") { save() }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button("Test Key") { test() }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validation == .checking)
            }

            validationRow

            if settings.hasAPIKey {
                Button("Remove Key", role: .destructive) {
                    settings.apiKey = ""
                    keyDraft = ""
                    validation = .idle
                }
            }
        } header: {
            Text("OpenRouter API Key")
        } footer: {
            Text("Stored in the device Keychain. Recording, on-device transcription, playback, and search all work without a key. Summaries and speaker labels need one. Get a key at openrouter.ai/keys.")
        }
    }

    @ViewBuilder
    private var validationRow: some View {
        switch validation {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Checking with OpenRouter…").foregroundStyle(.secondary)
            }
            .font(.caption)
        case .valid(let label):
            Label(
                label.map { "Key is valid (\($0))" } ?? "Key is valid",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.green)
        case .invalid(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Transcription

    private var transcriptionSection: some View {
        @Bindable var settings = settings

        return Section {
            Toggle("Identify speakers", isOn: $settings.speakerAwareTranscription)

            if settings.speakerAwareTranscription {
                Picker("Transcription model", selection: $settings.transcriptionModelID) {
                    ForEach(CuratedTranscriptionModel.all) { model in
                        VStack(alignment: .leading) {
                            Text(model.name)
                            Text(model.note).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(model.id)
                    }
                }
                .pickerStyle(.navigationLink)

                if !settings.hasAPIKey {
                    Label(
                        "Needs an API key. Until you add one, recordings transcribe on-device without speaker labels.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Transcription")
        } footer: {
            // This is the one setting that changes what leaves the device, so it
            // says so plainly rather than in an About section nobody opens.
            Text(settings.speakerAwareTranscription
                 ? "Your audio is uploaded to OpenRouter to identify who is speaking, at roughly a cent per hour. Speaker labels are inferred from the audio, so they're good with a few clear speakers and less reliable with crosstalk or large groups.\n\nTurn this off to transcribe entirely on this device, free and private, with no speaker labels."
                 : "Recordings are transcribed on this device. Audio never leaves your phone, and there's no cost. Apple's on-device engine can't tell speakers apart.")
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        @Bindable var settings = settings

        return Section {
            Picker("Model", selection: modelSelection) {
                ForEach(CuratedModel.all) { model in
                    VStack(alignment: .leading) {
                        Text(model.name)
                        Text(model.note).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(model.id)
                }
                Text("Custom…").tag(customTag)
            }
            .pickerStyle(.inline)

            if useCustomModel {
                TextField("provider/model-id", text: $customModelDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { applyCustomModel() }

                Button("Use This Model") { applyCustomModel() }
                    .disabled(customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Summary Model")
        } footer: {
            Text(useCustomModel
                 ? "Any model id from openrouter.ai/models. Currently using \(settings.modelID)."
                 : "All of these have enough context for an hour-long transcript.")
        }
    }

    private var customTag: String { "__custom__" }

    private var modelSelection: Binding<String> {
        Binding(
            get: { useCustomModel ? customTag : settings.modelID },
            set: { newValue in
                if newValue == customTag {
                    useCustomModel = true
                } else {
                    useCustomModel = false
                    settings.modelID = newValue
                }
            }
        )
    }

    private func applyCustomModel() {
        let trimmed = customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.modelID = trimmed
    }

    // MARK: - Templates

    private var templateSection: some View {
        @Bindable var settings = settings

        return Section {
            Picker("Default template", selection: $settings.defaultTemplateID) {
                ForEach(settings.availableTemplates) { template in
                    Label(template.name, systemImage: template.systemImage).tag(template.id)
                }
            }

            NavigationLink {
                CustomPromptEditor(prompt: $settings.customPrompt)
            } label: {
                Label("Edit Custom Prompt", systemImage: "slider.horizontal.3")
            }
        } header: {
            Text("Summaries")
        } footer: {
            Text("The default is pre-selected on the record screen. You can change it per recording, and regenerate with a different one later.")
        }
    }

    private var aboutSection: some View {
        let speakerAware = settings.usesSpeakerAwareTranscription

        return Section {
            LabeledContent("Transcription", value: speakerAware ? "OpenRouter" : "On-device")
            LabeledContent("Speaker labels", value: speakerAware ? "Enabled" : "Not available")
            LabeledContent("Audio leaves device", value: speakerAware ? "Yes" : "No")
        } header: {
            Text("About")
        } footer: {
            Text(speakerAware
                 ? "Audio is uploaded for transcription, and the resulting text is sent to OpenRouter again for summarization."
                 : "Audio is transcribed on this device and never uploaded. Only the resulting text is sent to OpenRouter for summarization.")
        }
    }

    // MARK: - Actions

    private func save() {
        settings.apiKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func test() {
        let candidate = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        validation = .checking

        Task {
            do {
                let label = try await OpenRouterClient().validate(apiKey: candidate)
                validation = .valid(label)
                // Only persist a key we've confirmed works.
                settings.apiKey = candidate
            } catch {
                validation = .invalid(error.localizedDescription)
            }
        }
    }
}

private struct CustomPromptEditor: View {
    @Binding var prompt: String

    var body: some View {
        Form {
            Section {
                TextEditor(text: $prompt)
                    .frame(minHeight: 220)
                    .font(.body)
            } header: {
                Text("Custom Template Instructions")
            } footer: {
                Text("These instructions are given to the model along with the transcript. Describe what to focus on and how to present it.")
            }

            Section {
                Button("Reset to Default") {
                    prompt = SummaryTemplate.defaultCustomPrompt
                }
            }
        }
        .navigationTitle("Custom Prompt")
        .navigationBarTitleDisplayMode(.inline)
    }
}
