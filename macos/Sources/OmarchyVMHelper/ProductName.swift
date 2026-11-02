import Foundation

/// The app a person sees running the VM: Try Omarchy, or the app that embeds
/// its kit. The run mode passes it to the launcher and the bridges, and the
/// launcher names the Omarchy window, its Dock entry and its menus after it.
enum ProductName {
    static let environmentKey = "OMARCHY_PRODUCT_NAME"
    /// The Omarchy window's Dock icon. The launcher uses the kit's own icon
    /// when it is absent.
    static let iconEnvironmentKey = "OMARCHY_PRODUCT_ICON"
    static let defaultName = "Try NixOS"

    static var current: String {
        ProcessInfo.processInfo.environment[environmentKey].flatMap(validated) ?? defaultName
    }

    static func validated(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard (1...64).contains(trimmed.count), name.utf8.count <= 255, trimmed == name,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return name
    }
}
