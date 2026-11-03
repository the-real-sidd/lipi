import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())

if let first = arguments.first, first.hasPrefix("--") {
    // Headless tools for testing and benchmarking: Lipi --help
    Log.echo = true
    Task { @MainActor in
        let code = await TestRunner.run(arguments)
        exit(code)
    }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
