import AppKit

@main
struct DolmoPasteMain {
    static func main() {
        // AppDelegate 跑在 MainActor 上（剪贴板轮询、面板、存储都在主线程）
        MainActor.assumeIsolated {
            // 截图评审模式：离屏渲染各界面后退出，不启动菜单栏、不监听剪贴板
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--snapshot") {
                let path = index + 1 < args.count ? args[index + 1] : NSTemporaryDirectory() + "dolmo-snapshots"
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                SnapshotRunner.run(outputDirectory: URL(fileURLWithPath: path, isDirectory: true))
                exit(0)
            }

            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            // 必须等到 applicationDidFinishLaunching 之后：store 是在那里建的，
            // 提前开窗口会拿到 nil，进程直接崩（--settings 调试入口踩过）
            if args.contains("--settings") {
                DispatchQueue.main.async { delegate.openMainWindow() }
            }
            app.run()
        }
    }
}
