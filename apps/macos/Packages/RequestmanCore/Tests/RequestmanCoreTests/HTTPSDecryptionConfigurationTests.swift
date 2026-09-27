import Foundation
import Testing
@testable import RequestmanCore

struct HTTPSDecryptionConfigurationTests {
    @Test func selectedDomainsRespectLabelBoundaries() throws {
        var configuration = HTTPSDecryptionConfiguration()
        configuration.decryptAllRequests = false
        configuration.domains = try HTTPSDecryptionConfiguration.parseDomains(" API.Example.COM. ; *.service.test ; localhost ; 127.0.0.1 ; api.example.com ")
        #expect(configuration.domains == ["api.example.com", "*.service.test", "localhost", "127.0.0.1"])
        for host in ["api.example.com", "API.EXAMPLE.COM.", "a.service.test", "a.b.service.test", "localhost", "127.0.0.1"] {
            #expect(configuration.shouldDecrypt(host: host))
        }
        for host in ["example.com", "other.example.com", "service.test", "evilservice.test", "service.test.evil", "api.example.com.evil", "x.api.example.com"] {
            #expect(!configuration.shouldDecrypt(host: host))
        }
        configuration.domains = []
        #expect(!configuration.shouldDecrypt(host: "api.example.com"))
        configuration.decryptAllRequests = true
        #expect(configuration.shouldDecrypt(host: "any.test"))
    }

    @Test func semicolonEntriesTrimWhitespaceAndIgnoreEmptyEntries() throws {
        #expect(try HTTPSDecryptionConfiguration.parseDomains(" ; \tAPI.Example.COM. \n; \n*.example.test\t ; ; ") == ["api.example.com", "*.example.test"])
        #expect(try HTTPSDecryptionConfiguration.parseDomains(" \n; \t; ").isEmpty)
    }

    @Test(arguments: ["*", "https://example.com", "example.com:443", "example.com/path", "foo.*.com", "*example.com", "example..com", "-example.com", "example.com..", "a.test b.test", "a.test\nb.test", "a.test,b.test", "a.test；b.test"])
    func invalidPatternsAreRejectedAndCannotExpandDecryption(pattern: String) {
        #expect(throws: WorkflowError.self) { try HTTPSDecryptionConfiguration.parseDomains(pattern) }
        var configuration = HTTPSDecryptionConfiguration()
        configuration.decryptAllRequests = false
        configuration.domains = [pattern]
        #expect(!configuration.shouldDecrypt(host: "example.com"))
    }

    @Test func oldWorkspaceDefaultsAndNewSettingsSurviveSaveAndArchive() throws {
        var document = WorkspaceDocument()
        document.httpsDecryption.decryptAllRequests = false
        document.httpsDecryption.domains = ["*.example.com"]
        let encoded = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(WorkspaceDocument.self, from: encoded) == document)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "httpsDecryption")
        let decoded = try JSONDecoder().decode(WorkspaceDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.httpsDecryption.decryptAllRequests)
        #expect(decoded.httpsDecryption.domains.isEmpty)
        let preferences = try PropertyListSerialization.data(fromPropertyList: [String: String](), format: .binary, options: 0)
        let archive = try WorkspaceArchive.decode(WorkspaceArchive(document: document, preferences: preferences).encoded())
        #expect(try archive.merging(into: WorkspaceDocument()).httpsDecryption == document.httpsDecryption)
        #expect(try WorkspaceArchive(project: WorkflowProject()).merging(into: document).httpsDecryption == document.httpsDecryption)
    }
}
