import Foundation
import RequestmanProxy
import RequestmanCertificates

typealias LocalCaptureService = LocalProxyCaptureService

extension LocalProxyCaptureService {
    convenience init(certificateProvider: any TLSCertificateProviding) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Requestman", isDirectory: true)
        self.init(journalURL: directory.appendingPathComponent("system-proxy-recovery.plist"), certificateProvider: certificateProvider)
    }
}
