import Foundation
import Testing
@testable import RequestmanCore

struct RequestLogFilterPreferencesTests {
    @Test func savesCompleteFilterAndRestoresFromFreshPreferences() throws {
        let suite = "RequestLogFilterPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(RequestLogFilterPreferences.load(from: defaults) == nil)
        var filter = CaptureRecordFilter()
        filter.search = "orders"
        filter.resource = .json
        filter.inverted = true
        filter.conditionGroup = .init(combination: .any, conditions: [
            .init(field: .domain, value: "example.test -ads.test"),
            .init(field: .header, operation: .equals, value: "a, b", headerName: "X-Test", headerSource: .sent)
        ], groups: [.init(conditions: [.init(field: .method, value: "POST PUT"), .init()])])
        filter.project = "project"
        filter.environment = "dev"
        filter.outcome = .modified
        filter.method = "POST"
        filter.statusCode = 201
        filter.urlContains = "/orders"
        filter.domain = "example.test"
        filter.headerSource = .sent
        filter.headerCombination = .any
        filter.headers = [.init(name: "Content-Type", value: "json")]
        filter.activeOnly = true
        RequestLogFilterPreferences.save(filter, to: defaults)
        let fresh = try #require(UserDefaults(suiteName: suite))
        #expect(RequestLogFilterPreferences.load(from: fresh) == filter)

        // Reset persists an empty filter while keeping restoration enabled.
        RequestLogFilterPreferences.save(CaptureRecordFilter(), to: defaults)
        #expect(RequestLogFilterPreferences.load(from: fresh) == CaptureRecordFilter())
        RequestLogFilterPreferences.save(nil, to: defaults)
        #expect(RequestLogFilterPreferences.load(from: fresh) == nil)
        #expect(defaults.persistentDomain(forName: suite)?.isEmpty != false)
    }

    @Test func invalidSavedDataFallsBackToNoSavedFilter() throws {
        let suite = "RequestLogFilterPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        RequestLogFilterPreferences.save(CaptureRecordFilter(), to: defaults)
        let key = try #require(defaults.persistentDomain(forName: suite)?.keys.first)
        for data in [Data("invalid".utf8), Data("{}".utf8)] {
            defaults.set(data, forKey: key)
            #expect(RequestLogFilterPreferences.load(from: defaults) == nil)
        }
    }
}
