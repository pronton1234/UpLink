import Foundation
import NetworkExtension

// A NetworkExtension *system* extension on macOS is a standalone executable,
// not a bundle the host app loads, so it needs its own entry point.
//
// `startSystemExtensionMode()` hands control to NetworkExtension, which
// instantiates the provider named under `NEProviderClasses` in Info.plist and
// drives its lifecycle. It returns immediately; `dispatchMain()` then parks the
// main thread so the process stays alive to service flows.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

dispatchMain()
