/// A remote tmux that the launch or discovery script couldn't run.
enum TmuxExecutableProblem: Equatable, Sendable {
    case notFound
    case notExecutable

    /// Reads the scripts' exit status and the marker they print on stderr. A
    /// pty merges stderr into the rest of the output, so `output` is whatever
    /// stream holds it.
    init?(exitStatus: Int, output: String) {
        if exitStatus == 127,
           output.localizedCaseInsensitiveContains(SSHTmuxControlCommandBuilder.tmuxNotFoundMarker) {
            self = .notFound
        } else if exitStatus == 126,
                  output.localizedCaseInsensitiveContains(SSHTmuxControlCommandBuilder.tmuxNotExecutableMarker) {
            self = .notExecutable
        } else {
            return nil
        }
    }

    var message: String {
        switch self {
        case .notFound:
            "Install tmux on this server or update Executable Path."
        case .notExecutable:
            "Check the tmux executable and its permissions, then try again."
        }
    }
}

enum SSHTmuxControlCommandBuilder {
    static let tmuxNotFoundMarker = "remux: tmux executable not found"
    static let tmuxNotExecutableMarker = "remux: tmux executable cannot be executed"

    private static let fallbackRemotePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func attachOrCreateControlSessionCommand(
        tmuxExecutable: String,
        sessionName: String,
        initialViewport: TmuxControlViewport
    ) -> String {
        // The SSH login shell only parses this wrapper. /bin/sh owns the PATH
        // expression so fish and csh do not need to understand POSIX syntax.
        [
            "exec /bin/sh -c '\(launchScript)' remux",
            RemoteShellArgument.octalEncoded(tmuxExecutable),
            RemoteShellArgument.octalEncoded(sessionName),
            "\(initialViewport.columns)",
            "\(initialViewport.rows)",
        ].joined(separator: " ")
    }

    static func listSessionsCommand(tmuxExecutable: String) -> String {
        // Discovery runs through an ordinary SSH exec channel, never the
        // control-mode channel. Keep the configured executable out of the
        // login shell just as the attach command does.
        [
            "exec /bin/sh -c '\(discoveryScript)' remux",
            RemoteShellArgument.octalEncoded(tmuxExecutable),
        ].joined(separator: " ")
    }

    private static let launchScript = [
        #"PATH="${PATH:+$PATH:}\#(fallbackRemotePath)""#,
        "export PATH",
        "TERM=xterm-256color",
        "export TERM",
        #"tmux=$(printf %b "$1")"#,
        #"session=$(printf %b "$2")"#,
        #"resolved=$(command -v "$tmux" 2> /dev/null)"#,
        #"if [ -x "$resolved" ]; then exec "$resolved" -u -C new-session -A -s "$session" -x "$3" -y "$4"; fi"#,
        #"if [ -e "$tmux" ]; then echo "\#(tmuxNotExecutableMarker): $tmux" >&2; exit 126; fi"#,
        #"echo "\#(tmuxNotFoundMarker): $tmux" >&2"#,
        "exit 127",
    ].joined(separator: "; ")

    private static let discoveryScript = [
        #"PATH="${PATH:+$PATH:}\#(fallbackRemotePath)""#,
        "export PATH",
        "LC_ALL=C",
        "export LC_ALL",
        #"tmux=$(printf %b "$1")"#,
        #"resolved=$(command -v "$tmux" 2> /dev/null)"#,
        "if [ -x \"$resolved\" ]; then exec \"$resolved\" list-sessions -F \"#{session_name}\"; fi",
        #"if [ -e "$tmux" ]; then echo "\#(tmuxNotExecutableMarker): $tmux" >&2; exit 126; fi"#,
        #"echo "\#(tmuxNotFoundMarker): $tmux" >&2"#,
        "exit 127",
    ].joined(separator: "; ")
}
