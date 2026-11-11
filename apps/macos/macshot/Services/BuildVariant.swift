enum BuildVariant {
    #if OFFLINE
    static let isOffline = true
    static let displayName = "PressShot Offline"
    #else
    static let isOffline = false
    static let displayName = "PressShot"
    #endif
}
