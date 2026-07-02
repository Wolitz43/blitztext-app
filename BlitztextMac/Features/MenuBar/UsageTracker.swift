import Foundation
import Observation

@Observable
@MainActor
final class UsageTracker {

    // MARK: - State

    private(set) var records: [UsageRecord] = []

    // MARK: - Init

    init() {
        load()
        deleteOldRecords()
    }

    // MARK: - Tracking

    func track(_ record: UsageRecord) {
        records.append(record)
        save()
    }

    // MARK: - Aggregierte Werte

    var costToday: Double {
        let start = Calendar.current.startOfDay(for: Date())
        return records
            .filter { $0.date >= start && $0.backend == .remote }
            .reduce(0) { $0 + $1.estimatedCostUSD }
    }

    var costThisMonth: Double {
        records
            .filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) && $0.backend == .remote }
            .reduce(0) { $0 + $1.estimatedCostUSD }
    }

    var totalCallsThisMonth: Int {
        records
            .filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) }
            .count
    }

    var localCallsThisMonth: Int {
        records
            .filter {
                Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month)
                && $0.backend == .local
            }
            .count
    }

    /// Geschätzte Ersparnis durch lokale Aufrufe diesen Monat.
    var localSavingsThisMonth: Double {
        records
            .filter {
                Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month)
                && $0.backend == .local
            }
            .reduce(0) { $0 + TokenPricing.hypotheticalRemoteCost(for: $1) }
    }

    /// Kosten aufgeschlüsselt nach Workflow-Typ (diesen Monat).
    var costPerWorkflowThisMonth: [(type: WorkflowType, cost: Double)] {
        let monthRecords = records.filter {
            Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month)
            && $0.backend == .remote
        }

        return WorkflowType.allCases.compactMap { type in
            let cost = monthRecords
                .filter { $0.workflowType == type }
                .reduce(0) { $0 + $1.estimatedCostUSD }
            return cost > 0 ? (type: type, cost: cost) : nil
        }
    }

    // MARK: - Verwaltung

    func deleteAllRecords() {
        records = []
        save()
    }

    func deleteOldRecords(olderThan days: Int = 90) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let before = records.count
        records = records.filter { $0.date >= cutoff }
        if records.count != before { save() }
    }

    // MARK: - Persistenz

    private static let usageURL: URL = {
        try? AppSupportPaths.ensureAppSupportDirectoryExists()
        return AppSupportPaths.usageURL
    }()

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: Self.usageURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.usageURL),
              let decoded = try? JSONDecoder().decode([UsageRecord].self, from: data) else {
            return
        }
        records = decoded
    }
}
