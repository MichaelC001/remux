import Foundation

enum SSHPublicKeyRemoteInstallerError: Error, Equatable {
    case missingResource
    case unreadableResource
}

enum SSHPublicKeyRemoteInstaller {
    static func command(bundle: Bundle = .main) throws -> String {
        guard let resourceURL = bundle.url(
            forResource: "install_authorized_key",
            withExtension: "sh"
        ) else {
            throw SSHPublicKeyRemoteInstallerError.missingResource
        }

        let script: String
        do {
            script = try String(contentsOf: resourceURL, encoding: .utf8)
        } catch {
            throw SSHPublicKeyRemoteInstallerError.unreadableResource
        }

        let shellEscapedScript = script.replacingOccurrences(of: "'", with: "'\\''")
        return "exec sh -c '\(shellEscapedScript)'"
    }
}
