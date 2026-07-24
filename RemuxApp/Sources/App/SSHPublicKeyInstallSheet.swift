import SwiftUI

enum SSHPublicKeyInstallPhase: Equatable {
    case idle
    case preflighting
    case passwordRequired
    case appending
    case verifying
    case alreadyInstalled
    case installed
    case failed(String)
}

struct SSHPublicKeyInstallSheet: View {
    let draft: TmuxConnectionDraft
    let onPreflight: (TmuxConnectionDraft) async throws -> SSHPublicKeyPreflightOutcome
    let onAppend: (TmuxConnectionDraft, String) async throws -> Void
    let onVerify: (TmuxConnectionDraft) async throws -> Void
    let onTrustHostKey: (SSHHostKeyTrustChallenge) throws -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var phase: SSHPublicKeyInstallPhase = .idle
    @State private var pendingTrust: PendingTrust?
    @State private var passwordError: String?
    @State private var operationTask: Task<Void, Never>?

    private struct PendingTrust {
        enum Phase: Equatable {
            case preflight
            case append
            case verify
        }

        let challenge: SSHHostKeyTrustChallenge
        let phase: Phase
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    phaseContent
                }
            }
            .navigationTitle("Install on Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .accessibilityIdentifier("connection.private-key.install-cancel")
                }
            }
        }
        .onAppear {
            start(.preflight)
        }
        .onDisappear {
            operationTask?.cancel()
            operationTask = nil
            password = ""
            pendingTrust = nil
        }
        .alert(
            hostTrustTitle,
            isPresented: hostTrustIsPresented
        ) {
            Button(hostTrustActionTitle) {
                confirmHostTrust()
            }
            .accessibilityIdentifier("connection.private-key.host-trust-confirm")

            Button("Cancel", role: .cancel) {
                rejectHostTrust()
            }
        } message: {
            Text(hostTrustMessage)
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .idle, .preflighting:
            ProgressView("Checking public key")

        case .passwordRequired:
            VStack(alignment: .leading, spacing: 12) {
                Text("Enter the server password once to install this public key.")
                    .foregroundStyle(.secondary)

                SecureField("Server password", text: $password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("connection.private-key.install-password")

                if let passwordError {
                    Text(passwordError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button("Install Public Key") {
                    start(.append)
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty)
                .accessibilityIdentifier("connection.private-key.install-confirm")
            }
            .padding(.vertical, 4)

        case .appending:
            ProgressView("Installing public key")

        case .verifying:
            ProgressView("Verifying public key")

        case .alreadyInstalled:
            installStatus("Already installed")

        case .installed:
            installStatus("Installed on host")

        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .accessibilityIdentifier("connection.private-key.install-status")
        }
    }

    private func installStatus(_ message: String) -> some View {
        Label {
            Text(message)
                .accessibilityIdentifier("connection.private-key.install-status")
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private func start(_ requestedPhase: PendingTrust.Phase) {
        operationTask?.cancel()
        operationTask = Task { @MainActor in
            await retry(requestedPhase)
        }
    }

    @MainActor
    private func retry(_ requestedPhase: PendingTrust.Phase) async {
        pendingTrust = nil
        var submittedPassword: String?

        do {
            switch requestedPhase {
            case .preflight:
                phase = .preflighting
                let outcome = try await onPreflight(draft)
                try Task.checkCancellation()

                switch outcome {
                case .alreadyInstalled:
                    password = ""
                    phase = .alreadyInstalled
                case .passwordRequired:
                    passwordError = nil
                    phase = .passwordRequired
                }

            case .append:
                phase = .appending
                submittedPassword = password
                password = ""
                try await onAppend(draft, submittedPassword ?? "")
                try Task.checkCancellation()
                submittedPassword = nil
                passwordError = nil
                await retry(.verify)

            case .verify:
                phase = .verifying
                try await onVerify(draft)
                try Task.checkCancellation()
                password = ""
                phase = .installed
            }
        } catch is CancellationError {
            return
        } catch TrustedHostStoreError.hostKeyTrustRequired(let challenge) {
            if requestedPhase == .append, let submittedPassword {
                password = submittedPassword
            }
            pendingTrust = PendingTrust(
                challenge: challenge,
                phase: requestedPhase
            )
        } catch {
            handleFailure(error, during: requestedPhase)
        }
    }

    private func handleFailure(_ error: Error, during failedPhase: PendingTrust.Phase) {
        if failedPhase == .append {
            password = ""
            if error as? SSHPublicKeyInstallerError == .passwordRejected {
                passwordError = error.localizedDescription
                phase = .passwordRequired
                return
            }
        }

        phase = .failed(error.localizedDescription)
    }

    private var hostTrustIsPresented: Binding<Bool> {
        Binding(
            get: { pendingTrust != nil },
            set: { isPresented in
                if !isPresented, pendingTrust != nil {
                    rejectHostTrust()
                }
            }
        )
    }

    private var hostTrustTitle: String {
        guard let challenge = pendingTrust?.challenge else {
            return "Verify Server"
        }

        switch challenge.kind {
        case .unknown:
            return "Verify Server"
        case .changed:
            return "Host Key Changed"
        }
    }

    private var hostTrustActionTitle: String {
        guard pendingTrust?.challenge.kind == .changed else {
            return "Trust Server"
        }
        return "Update Trust"
    }

    private var hostTrustMessage: String {
        guard let challenge = pendingTrust?.challenge else {
            return ""
        }

        let verification = challenge.receivedKeyFingerprint.map {
            "Received \(challenge.receivedKeyType) \($0)"
        } ?? "Received \(challenge.receivedKeyType)"

        switch challenge.kind {
        case .unknown:
            return "This is the first time Remux has seen the SSH host key for \(challenge.host). Trust it only if this fingerprint matches the server you expect.\n\n\(verification)"
        case .changed:
            return "The SSH host key for \(challenge.host) changed. Update trust only if this matches the server you expect.\n\n\(verification)"
        }
    }

    private func confirmHostTrust() {
        guard let pendingTrust else { return }

        do {
            try onTrustHostKey(pendingTrust.challenge)
            self.pendingTrust = nil
            start(pendingTrust.phase)
        } catch {
            if pendingTrust.phase == .append {
                password = ""
            }
            self.pendingTrust = nil
            phase = .failed(error.localizedDescription)
        }
    }

    private func rejectHostTrust() {
        guard let pendingTrust else { return }
        if pendingTrust.phase == .append {
            password = ""
        }
        self.pendingTrust = nil
        phase = .failed("Server identity was not trusted.")
    }

    private func cancel() {
        operationTask?.cancel()
        operationTask = nil
        password = ""
        pendingTrust = nil
        onCancel()
    }
}
