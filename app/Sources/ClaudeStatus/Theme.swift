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
