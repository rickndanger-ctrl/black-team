/// How user-facing text names the computer Black Team runs on: "this Mac" on macOS, "this computer" on Linux.
public enum Place {
    #if os(macOS)
    public static let this = "this Mac"
    public static let the = "the Mac"
    public static let your = "your Mac"
    public static let kind = "Mac"
    #else
    public static let this = "this computer"
    public static let the = "the computer"
    public static let your = "your computer"
    public static let kind = "computer"
    #endif
}
