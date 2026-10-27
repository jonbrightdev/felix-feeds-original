import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Prepare an opaque iOS icon from the saved master. Xcode makes device sizes.
// Run from the project root; the optional argument selects a replacement master.
let sourcePath = CommandLine.arguments.dropFirst().first ?? "Design/AppIcon/FelixFeeds-Icon.png"
let sourceURL = URL(fileURLWithPath: sourcePath)
guard let input = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(input, 0, nil),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    fatalError("Could not read icon master: \(sourcePath)")
}
func writeIcon(size: Int, path: String) {
    guard let context = CGContext(data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Could not create icon bitmap.") }
    context.interpolationQuality = .high
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.setFillColor(CGColor(red: 0.18, green: 0.40, blue: 0.34, alpha: 1))
    context.fill(rect)
    context.draw(source, in: rect)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
              UTType.png.identifier as CFString, 1, nil) else { fatalError("Could not encode icon.") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not save icon.") }
}
writeIcon(size: 1024, path: "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
writeIcon(size: 64, path: "Design/AppIcon/Preview-64.png")
print("Built opaque 1024px app icon and 64px preview from \(sourcePath)")
