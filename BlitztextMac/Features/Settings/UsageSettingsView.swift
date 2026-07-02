import SwiftUI

struct UsageSettingsView: View {
    @Bindable var tracker: UsageTracker
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // MARK: - Dieser Monat
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Dieser Monat")

                HStack(spacing: 10) {
                    costTile(
                        title: "Kosten",
                        value: TokenPricing.format(tracker.costThisMonth),
                        icon: "eurosign.circle.fill",
                        color: .blue
                    )
                    costTile(
                        title: "Aufrufe",
                        value: "\(tracker.totalCallsThisMonth)",
                        icon: "bolt.fill",
                        color: .purple
                    )
                    costTile(
                        title: "Ersparnis",
                        value: tracker.localSavingsThisMonth > 0
                            ? TokenPricing.format(tracker.localSavingsThisMonth)
                            : "–",
                        icon: "leaf.fill",
                        color: .green
                    )
                }

                if tracker.localCallsThisMonth > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("\(tracker.localCallsThisMonth) lokale Aufrufe (Apple Intelligence / WhisperKit) kostenfrei. Ersparnis geschätzt gegenüber gpt-4o-mini / whisper-1.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // MARK: - Heute
            if tracker.costToday > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Heute")

                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(TokenPricing.format(tracker.costToday))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text("Remote-Kosten")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: - Nach Workflow
            let breakdown = tracker.costPerWorkflowThisMonth
            if !breakdown.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Aufschlüsselung")

                    VStack(spacing: 4) {
                        ForEach(breakdown, id: \.type) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: entry.type.icon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)

                                Text(entry.type.displayName)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.primary)

                                Spacer()

                                Text(TokenPricing.format(entry.cost))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.primary.opacity(0.03))
                            )
                        }
                    }
                }
            }

            // MARK: - Hinweis & Löschen
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Daten")

                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Verlauf wird nach 90 Tagen automatisch gelöscht. \(tracker.records.count) Einträge gespeichert.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !tracker.records.isEmpty {
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                                .font(.system(size: 10.5))
                            Text("Verlauf jetzt löschen")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(SubtleButtonStyle())
                    .confirmationDialog(
                        "Verlauf löschen?",
                        isPresented: $showDeleteConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Löschen", role: .destructive) {
                            tracker.deleteAllRecords()
                        }
                        Button("Abbrechen", role: .cancel) {}
                    } message: {
                        Text("Alle \(tracker.records.count) Einträge werden unwiderruflich gelöscht.")
                    }
                }
            }

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    // MARK: - Helper Views

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func costTile(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color.opacity(0.8))

            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(color.opacity(0.12), lineWidth: 0.5)
        )
    }
}
