public enum ServerSetupState {
    case GettingReady
    case Ready(version: String)
    case Failed(message: String)
}
