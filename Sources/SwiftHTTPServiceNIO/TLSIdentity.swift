// TLSIdentity.swift
// SwiftHTTPServiceNIO
//
// Reading a certificate and a key, and refusing a bad pair.

import NIOSSL
import SwiftHTTPService

enum TLSIdentity {

    /// Loads the identity named by `files` and builds the server context: TLS 1.2 or newer, HTTP/1.1 only.
    ///
    /// Every failure is a ``HTTPServerError`` that says which part failed. None carries a path or any
    /// content of a file.
    static func makeContext(_ files: TLSFiles) throws(HTTPServerError) -> NIOSSLContext {
        let chain: [NIOSSLCertificate]
        do {
            chain = try NIOSSLCertificate.fromPEMFile(files.certificateChainPath)
        } catch {
            throw HTTPServerError.tlsCertificateUnreadable
        }
        guard !chain.isEmpty else { throw HTTPServerError.tlsCertificateUnreadable }
        let key: NIOSSLPrivateKey
        do {
            key = try NIOSSLPrivateKey(file: files.privateKeyPath, format: .pem)
        } catch {
            throw HTTPServerError.tlsKeyUnreadable
        }
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: chain.map { .certificate($0) }, privateKey: .privateKey(key))
        configuration.minimumTLSVersion = .tlsv12
        configuration.applicationProtocols = ["http/1.1"]
        do {
            return try NIOSSLContext(configuration: configuration)
        } catch {
            // BoringSSL checks that the key belongs to the certificate when the context is built.
            throw HTTPServerError.tlsIdentityRejected
        }
    }
}
