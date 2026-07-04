import XCTest
import NIOCore
@testable import Remux

final class GhosttyTerminalDisconnectReasonClassifierTests: XCTestCase {
    func testTransportStartFailureMapsKnownBoundaryErrors() {
        let hostKeyChange = SSHHostKeyChange(
            serverID: UUID(),
            host: "example.com",
            trustedKeyType: "ssh-ed25519",
            trustedOpenSSHPublicKey: "ssh-ed25519 trusted",
            receivedKeyType: "ssh-ed25519",
            receivedOpenSSHPublicKey: "ssh-ed25519 received"
        )
        let changedReason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
            TrustedHostStoreError.hostKeyChanged(hostKeyChange)
        )
        XCTAssertEqual(
            changedReason.kind,
            .hostKey
        )
        XCTAssertEqual(changedReason.hostKeyChange, hostKeyChange)

        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                TrustedHostStoreError.invalidHostKey
            ).kind,
            .hostKey
        )
    }

    func testTransportStartFailureMapsSSHErrors() {
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.remoteExit(1)
            ).kind,
            .remoteExit
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.channelRequestFailed(.exec)
            ).kind,
            .profile
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.closed
            ).kind,
            .transportIO
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.stalePreparedConnection
            ).kind,
            .transportIO
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.alreadyStarted
            ).kind,
            .profile
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.unsupportedInboundChannel
            ).kind,
            .profile
        )
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                SSHTmuxControlTransportError.controlSessionNoResponse(.seconds(15))
            ).kind,
            .profile
        )
    }

    func testTransportStartFailureMapsAuthenticationTextFallbacks() {
        for message in [
            "authentication failed",
            "bad password",
            "Permission denied",
        ] {
            XCTAssertEqual(
                GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
                    DescribedError(message)
                ).kind,
                .authentication,
                message
            )
        }
    }

    func testTransportStartFailureMapsConnectTimeoutAsServerUnreachable() {
        let reason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
            ChannelError.connectTimeout(.seconds(30))
        )

        XCTAssertEqual(reason.kind, .serverUnreachable)
    }

    func testTransportStartFailureMapsUnknownFallback() {
        let reason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(
            DescribedError("connection fizzled")
        )

        XCTAssertEqual(reason.kind, .unknown)
        XCTAssertEqual(reason.message, "connection fizzled")
    }

    func testForegroundMissingHostUsesCurrentMessage() {
        XCTAssertEqual(
            GhosttyTerminalDisconnectReasonClassifier.foregroundMissingHost(),
            TerminalDisconnectReason(
                kind: .transportIO,
                message: "tmux transport unavailable after foreground"
            )
        )
    }
}

final class TrustedHostStoreTests: XCTestCase {
    func testTrustReplacementHostKeyUpdatesOnlyMatchingTrustedKey() throws {
        let root = temporaryRoot()
        let serverID = UUID()
        let trusted = TrustedHostIdentity(
            serverID: serverID,
            host: "server.example.com",
            keyType: "ssh-ed25519",
            openSSHPublicKey: "ssh-ed25519 trusted",
            trustedAt: Date(timeIntervalSince1970: 1)
        )
        try saveIdentities([trusted], root: root)

        let store = TrustedHostStore(rootURL: root)
        try store.trustReplacementHostKey(
            SSHHostKeyChange(
                serverID: serverID,
                host: "server.example.com",
                trustedKeyType: "ssh-ed25519",
                trustedOpenSSHPublicKey: "ssh-ed25519 trusted",
                receivedKeyType: "ecdsa-sha2-nistp256",
                receivedOpenSSHPublicKey: "ecdsa-sha2-nistp256 received"
            )
        )

        let identities = try loadIdentities(root: root)
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities[0].serverID, serverID)
        XCTAssertEqual(identities[0].host, "server.example.com")
        XCTAssertEqual(identities[0].keyType, "ecdsa-sha2-nistp256")
        XCTAssertEqual(identities[0].openSSHPublicKey, "ecdsa-sha2-nistp256 received")
    }

    func testTrustReplacementHostKeyRejectsStaleChange() throws {
        let root = temporaryRoot()
        let serverID = UUID()
        let current = TrustedHostIdentity(
            serverID: serverID,
            host: "server.example.com",
            keyType: "ssh-ed25519",
            openSSHPublicKey: "ssh-ed25519 current",
            trustedAt: Date(timeIntervalSince1970: 1)
        )
        try saveIdentities([current], root: root)

        let store = TrustedHostStore(rootURL: root)

        XCTAssertThrowsError(
            try store.trustReplacementHostKey(
                SSHHostKeyChange(
                    serverID: serverID,
                    host: "server.example.com",
                    trustedKeyType: "ssh-ed25519",
                    trustedOpenSSHPublicKey: "ssh-ed25519 stale",
                    receivedKeyType: "ecdsa-sha2-nistp256",
                    receivedOpenSSHPublicKey: "ecdsa-sha2-nistp256 received"
                )
            )
        ) { error in
            guard case TrustedHostStoreError.staleHostKeyChange(host: "server.example.com") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try loadIdentities(root: root), [current])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func saveIdentities(_ identities: [TrustedHostIdentity], root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let data = try encoder.encode(identities)
        try data.write(to: root.appendingPathComponent("trusted-hosts.json"), options: .atomic)
    }

    private func loadIdentities(root: URL) throws -> [TrustedHostIdentity] {
        let data = try Data(contentsOf: root.appendingPathComponent("trusted-hosts.json"))
        return try JSONDecoder().decode([TrustedHostIdentity].self, from: data)
    }
}

private struct DescribedError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
