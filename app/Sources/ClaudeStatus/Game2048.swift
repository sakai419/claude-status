import Foundation
import Observation

/// 2048 の盤面と手番の処理。描画は GameView。
/// ターン制なので、セッションに呼ばれたらいつ離れてもよい。盤面はアプリを閉じるまで残る。
@MainActor
@Observable
final class Game2048 {
    struct Tile: Identifiable {
        let id: Int
        var value: Int
        var row: Int
        var col: Int
        /// 隣に吸収されたタイル。合体先まで滑らせてから、次の手で取り除く
        var absorbed = false
    }

    enum Direction { case up, down, left, right }

    static let size = 4
    static let goal = 2048
    private static let bestKey = "game2048.best"

    private(set) var tiles: [Tile] = []
    private(set) var score = 0
    private(set) var best = UserDefaults.standard.integer(forKey: bestKey)
    private(set) var reachedGoal = false
    private(set) var keepPlaying = false
    private(set) var over = false
    @ObservationIgnored private var nextID = 0

    /// 達成画面か終了画面が出ていて、盤面を動かせない
    var paused: Bool { over || (reachedGoal && !keepPlaying) }

    init() { newGame() }

    func newGame() {
        tiles = []
        score = 0
        reachedGoal = false
        keepPlaying = false
        over = false
        spawn()
        spawn()
    }

    func continueAfterGoal() { keepPlaying = true }

    func move(_ dir: Direction) {
        guard !paused else { return }
        let live = tiles.filter { !$0.absorbed }
        var byPos: [Int: Tile] = [:]
        for t in live { byPos[t.row * Self.size + t.col] = t }

        var next: [Tile] = []
        var moved = false
        var gained = 0
        for line in lines(dir) {
            var placed: [Tile] = []
            var lastMerged = false
            for (r, c) in line {
                guard var tile = byPos[r * Self.size + c] else { continue }
                if let last = placed.last, !lastMerged, last.value == tile.value {
                    placed[placed.count - 1].value *= 2
                    gained += last.value * 2
                    lastMerged = true
                    tile.row = last.row
                    tile.col = last.col
                    tile.absorbed = true
                    next.append(tile)
                    moved = true
                } else {
                    let (tr, tc) = line[placed.count]
                    if tile.row != tr || tile.col != tc { moved = true }
                    tile.row = tr
                    tile.col = tc
                    placed.append(tile)
                    lastMerged = false
                }
            }
            next += placed
        }
        guard moved else { return }

        tiles = next
        score += gained
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: Self.bestKey)
        }
        if !reachedGoal, tiles.contains(where: { !$0.absorbed && $0.value >= Self.goal }) {
            reachedGoal = true
        }
        spawn()
        over = !canMove()
    }

    /// 動く方向の先頭（寄せる側の端）から並べた、各列・各行のマス
    private func lines(_ dir: Direction) -> [[(Int, Int)]] {
        let idx = Array(0..<Self.size)
        return idx.map { i in
            switch dir {
            case .left: idx.map { (i, $0) }
            case .right: idx.reversed().map { (i, $0) }
            case .up: idx.map { ($0, i) }
            case .down: idx.reversed().map { ($0, i) }
            }
        }
    }

    private func spawn() {
        let taken = Set(tiles.filter { !$0.absorbed }.map { $0.row * Self.size + $0.col })
        let empty = (0..<Self.size * Self.size).filter { !taken.contains($0) }
        guard let pos = empty.randomElement() else { return }
        tiles.append(Tile(id: nextID, value: Int.random(in: 0..<10) == 0 ? 4 : 2,
                          row: pos / Self.size, col: pos % Self.size))
        nextID += 1
    }

    private func canMove() -> Bool {
        var grid = Array(repeating: Array(repeating: 0, count: Self.size), count: Self.size)
        for t in tiles where !t.absorbed { grid[t.row][t.col] = t.value }
        for r in 0..<Self.size {
            for c in 0..<Self.size {
                let v = grid[r][c]
                if v == 0 { return true }
                if c + 1 < Self.size, grid[r][c + 1] == v { return true }
                if r + 1 < Self.size, grid[r + 1][c] == v { return true }
            }
        }
        return false
    }
}
