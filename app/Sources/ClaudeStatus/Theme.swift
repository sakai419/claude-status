import SwiftUI

/// 黒背景の配色。システムの外観設定に関係なく、常にこの色で描く。
enum Theme {
    static let background = Color.black
    static let surface = Color(white: 0.075)
    static let surfaceHover = Color(white: 0.11)
    static let surfaceSelected = Color(white: 0.14)
    static let inset = Color(white: 0.05)
    static let line = Color.white.opacity(0.09)

    static let text = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.56)
    static let textTertiary = Color.white.opacity(0.34)
}

extension EnvironmentValues {
    /// メインウィンドウの拡大率（⌘+ / ⌘- / ⌘0）。文字と、文字に合わせて決めている寸法に掛ける
    @Entry var zoom: CGFloat = 1
}

extension View {
    /// システムフォントを、ウィンドウの拡大率を掛けた大きさで使う
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                    monospacedDigit: Bool = false) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }
}

private struct ScaledFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool
    @Environment(\.zoom) private var zoom

    func body(content: Content) -> some View {
        let font = Font.system(size: size * zoom, weight: weight, design: design)
        content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}
