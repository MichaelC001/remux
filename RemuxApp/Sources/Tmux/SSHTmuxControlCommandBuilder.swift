enum SSHTmuxControlCommandBuilder {
    private static let fallbackRemotePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func attachOrCreateControlSessionCommand(
        tmuxExecutable: String,
        sessionName: String,
        initialViewport: TmuxControlViewport
    ) -> String {
        let tmux = shellEscape(tmuxExecutable)
        let session = shellEscape(sessionName)

        // Single -C: pure control mode without the DCS 1000p envelope that
        // -CC emits for in-terminal clients (and without -CC's hard tty
        // requirement). The session channel is a bare exec stream feeding
        // Ghostty's tmux session parser directly.
        return """
        export PATH="${PATH:+$PATH:}\(fallbackRemotePath)" TERM=xterm-256color; exec \(tmux) -C new-session -A -s \(session) -x \(initialViewport.columns) -y \(initialViewport.rows)
        """
    }

    private static func shellEscape(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
