import Foundation

extension SavedServer {
    var displayAddress: String {
        "\(username)@\(host)\(port == 22 ? "" : ":\(port)")"
    }
}
