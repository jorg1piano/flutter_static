import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // Studio wants room for a sidebar, a canvas and an inspector; the
    // template's 800x600 is too small. The catalog window is a status
    // panel and does not care.
    var windowFrame = self.frame
    if let screen = NSScreen.main?.visibleFrame {
      let width = min(1480, screen.width - 80)
      let height = min(940, screen.height - 60)
      windowFrame = NSRect(
        x: screen.minX + (screen.width - width) / 2,
        y: screen.minY + (screen.height - height) / 2,
        width: width,
        height: height)
    }
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
