import SwiftUI

/// エージェントの返答を読みやすく出すための簡易 Markdown 表示。
/// 見出し・箇条書き・コードブロック・表・引用をブロック単位で組み、
/// 行内の強調・コード・リンクは AttributedString の Markdown 解釈に任せる。
struct MarkdownText: View {
    private let blocks: [Block]

    init(_ text: String) {
        blocks = Block.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: level <= 1 ? 15 : level == 2 ? 13.5 : 12.5, weight: .semibold))
                .padding(.top, 2)
        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.system(size: 12.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 12, alignment: .trailing)
                        Text(inline(item.text))
                            .font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 12)
                }
            }
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(inline(cell))
                                    .font(.system(size: 12, weight: i == 0 ? .semibold : .regular))
                                    .fixedSize()
                            }
                        }
                        if i == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .padding(9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .fixedSize()
                    .padding(9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                Text(inline(text))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct ListItem {
    let indent: Int
    let marker: String
    let text: String
}

private enum Block {
    case heading(Int, String)
    case paragraph(String)
    case list([ListItem])
    case code(String)
    case table([[String]])
    case quote(String)
    case rule

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var items: [ListItem] = []
        var quote: [String] = []
        var table: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !items.isEmpty { blocks.append(.list(items)); items = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(table.map(cells))); table = [] }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if var lines = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
                continue
            }
            if trimmed.hasPrefix("```") { flush(); code = []; continue }
            if trimmed.isEmpty { flush(); continue }

            if let h = heading(trimmed) { flush(); blocks.append(.heading(h.0, h.1)); continue }
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), trimmed.count >= 3 {
                flush(); blocks.append(.rule); continue
            }
            if trimmed.hasPrefix("|") {
                if table.isEmpty { flush() }
                // 区切り行（|---|---|）は表示上のノイズなので落とす
                if !trimmed.allSatisfy({ "|-: ".contains($0) }) { table.append(trimmed) }
                continue
            }
            if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                if items.isEmpty { flush() }
                items.append(item)
                continue
            }
            if !items.isEmpty, line.hasPrefix("  ") {
                // 箇条書きの続きの行
                let last = items.removeLast()
                items.append(ListItem(indent: last.indent, marker: last.marker, text: last.text + "\n" + trimmed))
                continue
            }
            if !items.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
            paragraph.append(line)
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// "| a | b |" → ["a", "b"]
    private static func cells(_ row: String) -> [String] {
        var s = Substring(row.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|") { s = s.dropLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func heading(_ s: String) -> (Int, String)? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(s.dropFirst(hashes + 1)))
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " }.count / 2
        let s = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ "] where s.hasPrefix(bullet) {
            var text = String(s.dropFirst(2))
            var marker = "•"
            if text.hasPrefix("[ ] ") { marker = "☐"; text = String(text.dropFirst(4)) }
            if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { marker = "☑"; text = String(text.dropFirst(4)) }
            return ListItem(indent: indent, marker: marker, text: text)
        }
        let digits = s.prefix { $0.isNumber }
        if !digits.isEmpty, s.dropFirst(digits.count).hasPrefix(". ") {
            return ListItem(indent: indent, marker: digits + ".", text: String(s.dropFirst(digits.count + 2)))
        }
        return nil
    }
}
