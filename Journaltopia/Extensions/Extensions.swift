import CoreText
import Foundation
import SwiftUI
import UIKit

enum VariableFont {
    private static let wghtAxisTag = NSNumber(value: Int(0x77676874)) // 'wght'

    static func wghtValue(for weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight:
            100
        case .thin:
            200
        case .light:
            300
        case .regular:
            400
        case .medium:
            500
        case .semibold:
            600
        case .bold:
            700
        case .heavy:
            800
        case .black:
            900
        default:
            400
        }
    }

    private static func resolvedWght(weight: Font.Weight, override: CGFloat?) -> CGFloat {
        override ?? wghtValue(for: weight)
    }

    private static func resolvedFontName(_ name: String, size: CGFloat) -> String? {
        if UIFont(name: name, size: size) != nil {
            return name
        }

        if name == "Nunito", UIFont(name: "Nunito-ExtraLight", size: size) != nil {
            return "Nunito-ExtraLight"
        }

        return nil
    }

    private static func variationAttributes(for wght: CGFloat) -> [UIFontDescriptor.AttributeName: Any] {
        [
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [
                "wght": wght,
                wghtAxisTag: wght
            ]
        ]
    }

    static func uiFont(
        name: String,
        size: CGFloat,
        weight: Font.Weight,
        usesWeightAxis: Bool,
        wghtOverride: CGFloat? = nil
    ) -> UIFont? {
        guard let resolvedName = resolvedFontName(name, size: size) else {
            return nil
        }

        if usesWeightAxis {
            let wght = resolvedWght(weight: weight, override: wghtOverride)
            let baseDescriptor = UIFontDescriptor(name: resolvedName, size: size)
            let descriptor = baseDescriptor.addingAttributes(variationAttributes(for: wght))
            return UIFont(descriptor: descriptor, size: size)
        }

        return UIFont(name: resolvedName, size: size)
    }

    static func font(
        name: String,
        size: CGFloat,
        weight: Font.Weight,
        usesWeightAxis: Bool,
        wghtOverride: CGFloat? = nil
    ) -> Font {
        guard let uiFont = uiFont(
            name: name,
            size: size,
            weight: weight,
            usesWeightAxis: usesWeightAxis,
            wghtOverride: wghtOverride
        ) else {
            return .system(size: size, weight: weight)
        }

        return Font(uiFont)
    }
}

extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(
        name: String,
        fileName: String,
        mimeType: String,
        data: Data,
        boundary: String
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}

extension UIImage {
    func journaltopiaPreparedJPEGData(maxDimension: CGFloat = 2048, compressionQuality: CGFloat = 0.82) -> Data? {
        let longestSide = max(size.width, size.height)
        let resizeScale = longestSide > maxDimension ? maxDimension / longestSide : 1
        let targetSize = CGSize(width: size.width * resizeScale, height: size.height * resizeScale)
        let rendererScale = resizeScale == 1 ? scale : 1

        let flattened = journaltopiaOpaqueImage(size: targetSize, scale: rendererScale)
        return flattened.jpegData(compressionQuality: compressionQuality)
    }

    /// Returns a smaller image for grid/list cells. Preserves the original when already within bounds.
    func journaltopiaDownsampled(maxDimension: CGFloat) -> UIImage {
        let longestSide = max(size.width * scale, size.height * scale)
        guard longestSide > maxDimension, maxDimension > 0 else {
            return self
        }

        let resizeScale = maxDimension / longestSide
        let targetSize = CGSize(width: size.width * scale * resizeScale, height: size.height * scale * resizeScale)
        return journaltopiaOpaqueImage(size: targetSize, scale: 1)
    }

    private func journaltopiaOpaqueImage(size targetSize: CGSize, scale rendererScale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = rendererScale

        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: targetSize)).fill()
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

extension Color {
    static let storyInk = Color(red: 0.08, green: 0.07, blue: 0.22)
    static let storyGray = Color(red: 0.39, green: 0.39, blue: 0.46)
    static let storyPurple = Color(uiColor: .systemIndigo)
    static let storyLavender = Color(red: 0.91, green: 0.86, blue: 0.98)
    static let storyRose = Color(red: 0.93, green: 0.73, blue: 0.70)
    static let storyBlush = Color(red: 0.99, green: 0.95, blue: 0.92)
    static let storyCream = Color(red: 1.0, green: 0.98, blue: 0.94)
    static let storySoftPink = Color(red: 0.96, green: 0.90, blue: 0.89)
    static let storyPeach = Color(red: 0.93, green: 0.63, blue: 0.45)
    static let storyGold = Color(red: 0.95, green: 0.69, blue: 0.34)
    static let storyBorder = Color(red: 0.88, green: 0.80, blue: 0.78)
    static let homePageBackground = Color(red: 0.949, green: 0.949, blue: 0.969)
    static let homeCardGray = Color(red: 0.965, green: 0.965, blue: 0.982)
    static let homeInputGray = Color(red: 0.92, green: 0.92, blue: 0.94)
    static let homeMutedText = Color(red: 0.43, green: 0.44, blue: 0.54)
    static let homeBorder = Color(red: 0.86, green: 0.87, blue: 0.91)
    static let homeAccent = Color(uiColor: .systemIndigo)
    /// Destructive tint that stays legible on the dark storyboard viewer chrome.
    static let storyboardDeleteTint = Color(red: 1.0, green: 0.53, blue: 0.51)

    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }

        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            return nil
        }

        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension UIColor {
    var journaltopiaHexString: String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }

        return String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
    }
}

private struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            guard let navigationController = uiViewController.navigationController else {
                return
            }

            navigationController.interactivePopGestureRecognizer?.isEnabled = true
            navigationController.interactivePopGestureRecognizer?.delegate = nil
        }
    }
}

private struct GuardedInteractivePopGestureEnabler: UIViewControllerRepresentable {
    let shouldAllowPop: () -> Bool
    let onBlockedPop: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldAllowPop: shouldAllowPop, onBlockedPop: onBlockedPop)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.shouldAllowPop = shouldAllowPop
        context.coordinator.onBlockedPop = onBlockedPop
        context.coordinator.hostViewController = uiViewController

        DispatchQueue.main.async {
            guard let navigationController = uiViewController.navigationController else {
                return
            }

            context.coordinator.navigationController = navigationController
            navigationController.interactivePopGestureRecognizer?.isEnabled = true
            navigationController.interactivePopGestureRecognizer?.delegate = context.coordinator
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var shouldAllowPop: () -> Bool
        var onBlockedPop: () -> Void
        weak var hostViewController: UIViewController?
        weak var navigationController: UINavigationController?

        init(shouldAllowPop: @escaping () -> Bool, onBlockedPop: @escaping () -> Void) {
            self.shouldAllowPop = shouldAllowPop
            self.onBlockedPop = onBlockedPop
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard
                let navigationController,
                navigationController.viewControllers.count > 1,
                let hostViewController,
                let topViewController = navigationController.topViewController,
                isViewController(hostViewController, descendedFrom: topViewController)
            else {
                return false
            }

            guard !shouldAllowPop() else {
                return true
            }

            DispatchQueue.main.async {
                self.onBlockedPop()
            }
            return false
        }

        private func isViewController(_ viewController: UIViewController, descendedFrom ancestor: UIViewController) -> Bool {
            var current: UIViewController? = viewController

            while let viewController = current {
                if viewController === ancestor {
                    return true
                }

                current = viewController.parent
            }

            return false
        }
    }
}

extension View {
    func enableInteractivePopGesture() -> some View {
        background(InteractivePopGestureEnabler())
    }

    func guardedInteractivePopGesture(
        shouldAllowPop: @escaping () -> Bool,
        onBlockedPop: @escaping () -> Void
    ) -> some View {
        background(
            GuardedInteractivePopGestureEnabler(
                shouldAllowPop: shouldAllowPop,
                onBlockedPop: onBlockedPop
            )
        )
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func hideSharedBackgroundIfAvailable() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
