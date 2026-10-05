enum RemoteShellArgument {
    /// Quotes `value` as octal escapes for `printf %b`, so no byte of it is
    /// ever parsed by the remote login shell.
    static func octalEncoded(_ value: String) -> String {
        let bytes = value.utf8.map { byte in
            let digits = String(byte, radix: 8)
            return "\\0" + String(repeating: "0", count: 3 - digits.count) + digits
        }
        return "'\(bytes.joined())'"
    }
}
