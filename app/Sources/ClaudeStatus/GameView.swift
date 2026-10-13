import SwiftUI

/// 待ち時間用のミニゲーム（2048）。右ペインを詳細の代わりに使う。
/// 矢印キー / WASD / hjkl で動かし、Esc で詳細に戻る。
struct GameView: View {
    let game: Game2048
    let onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.line).frame(height: 1)
            GeometryReader { geo in
                let side = max(min(geo.size.width - 52, geo.size.height - 150, 440), 200)
                VStack(spacing: 18) {
                    scores.frame(width: side)
                    board(side: side)
                    Text("← ↑ → ↓ / WASD で動かす · Esc で戻る")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .escape,
                           "w", "a", "s", "d", "h", "j", "k", "l"]) { press in
            if press.key == .escape {
                onClose()
                return .handled
            }
            guard let dir = direction(of: press.key) else { return .ignored }
            withAnimation(.easeOut(duration: 0.11)) { game.move(dir) }
            return .handled
        }
    }

    private func direction(of key: KeyEquivalent) -> Game2048.Direction? {
        switch key {
        case .upArrow, "w", "k": .up
        case .downArrow, "s", "j": .down
        case .leftArrow, "a", "h": .left
        case .rightArrow, "d", "l": .right
        default: nil
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "gamecontroller.fill")
                Text("2048")
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.08), in: Capsule())

            Spacer()

            IconButton(symbol: "arrow.counterclockwise", help: "最初からやり直す") {
                withAnimation(.easeOut(duration: 0.15)) { game.newGame() }
            }
            IconButton(symbol: "xmark", help: "詳細に戻る（Esc）", action: onClose)
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
    }

    private var scores: some View {
        HStack(spacing: 8) {
            Spacer()
            scoreBox("スコア", game.score)
            scoreBox("ベスト", game.best)
        }
    }

    private func scoreBox(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text("\(value)")
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.text)
                .contentTransition(.numericText(value: Double(value)))
        }
        .frame(minWidth: 72)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private func board(side: CGFloat) -> some View {
        let n = Game2048.size
        let gap = (side * 0.028).rounded()
        let cell = (side - gap * CGFloat(n + 1)) / CGFloat(n)
        let origin = { (i: Int) in gap + CGFloat(i) * (cell + gap) }

        return ZStack(alignment: .topLeading) {
            ForEach(0..<n * n, id: \.self) { i in
                RoundedRectangle(cornerRadius: cell * 0.1, style: .continuous)
                    .fill(Theme.inset)
                    .frame(width: cell, height: cell)
                    .offset(x: origin(i % n), y: origin(i / n))
            }
            ForEach(game.tiles) { tile in
                TileView(value: tile.value, size: cell)
                    .offset(x: origin(tile.col), y: origin(tile.row))
                    .zIndex(tile.absorbed ? 1 : 2)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.3).combined(with: .opacity)
                            .animation(.easeOut(duration: 0.14).delay(0.08)),
                        removal: .identity))
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
        .overlay { banner }
    }

    @ViewBuilder
    private var banner: some View {
        if game.over {
            BannerCard(title: "これ以上動けません", detail: "スコア \(game.score)") {
                Button("もう一度") { withAnimation { game.newGame() } }
                    .keyboardShortcut(.defaultAction)
            }
        } else if game.reachedGoal && !game.keepPlaying {
            BannerCard(title: "\(Game2048.goal) に届きました", detail: "スコア \(game.score)") {
                Button("最初から") { withAnimation { game.newGame() } }
                Button("続ける") { game.continueAfterGoal() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct BannerCard<Actions: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) { actions }
                .controlSize(.regular)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.opacity)
    }
}

private struct TileView: View {
    let value: Int
    let size: CGFloat

    var body: some View {
        Text("\(value)")
            .font(.system(size: size * fontScale, weight: .bold, design: .rounded).monospacedDigit())
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(value >= Game2048.goal * 2 ? Color.black.opacity(0.85) : Color.white.opacity(0.95))
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.1, style: .continuous))
            .shadow(color: value >= Game2048.goal ? color.opacity(0.6) : .clear, radius: 10)
    }

    private var fontScale: CGFloat {
        switch String(value).count {
        case ...2: 0.42
        case 3: 0.34
        default: 0.27
        }
    }

    /// 小さい数は灰色、大きくなるにつれて寒色から暖色へ。黒背景の上で段階が見分けやすい並び。
    private var color: Color {
        switch value {
        case 2: Color(white: 0.18)
        case 4: Color(white: 0.26)
        case 8: Color(hue: 0.52, saturation: 0.60, brightness: 0.52)
        case 16: Color(hue: 0.58, saturation: 0.62, brightness: 0.60)
        case 32: Color(hue: 0.70, saturation: 0.52, brightness: 0.64)
        case 64: Color(hue: 0.80, saturation: 0.56, brightness: 0.64)
        case 128: Color(hue: 0.92, saturation: 0.60, brightness: 0.70)
        case 256: Color(hue: 0.01, saturation: 0.66, brightness: 0.76)
        case 512: Color(hue: 0.06, saturation: 0.72, brightness: 0.82)
        case 1024: Color(hue: 0.10, saturation: 0.76, brightness: 0.86)
        case 2048: Color(hue: 0.14, saturation: 0.80, brightness: 0.92)
        default: Color(white: 0.94)
        }
    }
}
