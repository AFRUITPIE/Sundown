// Written by Scripts/pin-server.sh from the release's SHA256SUMS; don't edit by hand.
// 0.5.7 isn't released yet: run `Scripts/pin-server.sh 0.5.7` once it is, for its checksums.

extension ServerRelease {
    /// The server version npx runs, and a copy puts on a host. Moves with the protocol package's
    /// pin, which is the server this app was built against.
    public static let version = "0.5.7"

    /// Each platform's binary's SHA-256, which a copy must match before it goes to a host.
    public static let checksums: [String: String] = [:]
}
