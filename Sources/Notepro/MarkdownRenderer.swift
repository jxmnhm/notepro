// MarkdownRenderer.swift — 轻量 Markdown → NSAttributedString 渲染
//
// 专为结果浮窗设计，覆盖 AI 常用的输出元素：标题(#/##/###)、无序列表(-/*/•)、
// 有序列表(1.)、任务清单(- [ ] / - [x])、加粗(**)、行内代码(`)、引用(>)、分隔线(---)、
// 表格(| a | b | + |---|---|，用 NSTextTable 渲染，支持 :--: 对齐)。
// 不追求完整 CommonMark，但保证标题、列表、表格清晰好看。currentText 仍存原始 Markdown。
import AppKit

enum MarkdownRenderer {

    static func attributed(from markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")

        var i = 0
        var firstBlock = true
        while i < lines.count {
            // 表格探测：当前行像表头(|...|)，下一行是分隔行(|---|:--:|...)
            if isTableRow(lines[i]),
               i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                var tableLines = [lines[i], lines[i + 1]]
                var j = i + 2
                while j < lines.count, isTableRow(lines[j]) {
                    tableLines.append(lines[j]); j += 1
                }
                if !firstBlock { out.append(NSAttributedString(string: "\n")) }
                out.append(renderTable(tableLines))
                firstBlock = false
                i = j
                continue
            }
            if !firstBlock { out.append(NSAttributedString(string: "\n")) }
            out.append(renderBlock(lines[i]))
            firstBlock = false
            i += 1
        }
        return out
    }

    // MARK: - 单行块级渲染
    private static func renderBlock(_ line: String) -> NSAttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // 分隔线
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = 4; p.paragraphSpacing = 4
            return NSAttributedString(string: "────────────",
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor,
                             .font: NSFont.systemFont(ofSize: 11),
                             .paragraphStyle: p])
        }

        // 标题
        if let h = headingLevel(trimmed) {
            let text = String(trimmed.dropFirst(h)).trimmingCharacters(in: .whitespaces)
            let sizes: [CGFloat] = [0, 19, 16, 14]   // h1/h2/h3
            let size = sizes[min(h, 3)]
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = 8; p.paragraphSpacing = 3
            let s = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.boldSystemFont(ofSize: size),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: p])
            applyInline(s)
            return s
        }

        // 任务清单 - [ ] / - [x]
        if let (checked, rest) = taskItem(trimmed) {
            let box = checked ? "☑︎ " : "☐ "
            let p = listParagraph()
            let s = NSMutableAttributedString(string: box, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: checked ? NSColor.systemGreen : NSColor.secondaryLabelColor,
                .paragraphStyle: p])
            let body = NSMutableAttributedString(string: rest, attributes: baseAttrs(p))
            applyInline(body)
            s.append(body)
            return s
        }

        // 无序列表
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
            let rest = String(trimmed.dropFirst(2))
            let p = listParagraph()
            let s = NSMutableAttributedString(string: "•  ", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.systemBlue,
                .paragraphStyle: p])
            let body = NSMutableAttributedString(string: rest, attributes: baseAttrs(p))
            applyInline(body)
            s.append(body)
            return s
        }

        // 有序列表 1. 2. ...
        if let dot = trimmed.firstIndex(of: "."),
           let num = Int(trimmed[trimmed.startIndex..<dot]),
           trimmed.index(after: dot) <= trimmed.endIndex {
            let after = trimmed[trimmed.index(after: dot)...]
            if after.first == " " {
                let rest = String(after.dropFirst())
                let p = listParagraph()
                let s = NSMutableAttributedString(string: "\(num).  ", attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: NSColor.systemBlue,
                    .paragraphStyle: p])
                let body = NSMutableAttributedString(string: rest, attributes: baseAttrs(p))
                applyInline(body)
                s.append(body)
                return s
            }
        }

        // 引用 >
        if trimmed.hasPrefix("> ") {
            let rest = String(trimmed.dropFirst(2))
            let p = NSMutableParagraphStyle()
            p.firstLineHeadIndent = 10; p.headIndent = 10
            let s = NSMutableAttributedString(string: "▎" + rest, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: p])
            applyInline(s)
            return s
        }

        // 普通段落
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        let s = NSMutableAttributedString(string: line, attributes: baseAttrs(p))
        applyInline(s)
        return s
    }

    private static func baseAttrs(_ p: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 13),
         .foregroundColor: NSColor.labelColor,
         .paragraphStyle: p]
    }

    private static func listParagraph() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.headIndent = 18; p.firstLineHeadIndent = 0; p.lineSpacing = 2
        p.paragraphSpacing = 2
        return p
    }

    private static func headingLevel(_ s: String) -> Int? {
        var n = 0
        for c in s { if c == "#" { n += 1 } else { break } }
        if n >= 1, n <= 6, s.count > n, Array(s)[n] == " " { return n }
        return nil
    }

    private static func taskItem(_ s: String) -> (Bool, String)? {
        let lower = s.lowercased()
        if lower.hasPrefix("- [ ] ") { return (false, String(s.dropFirst(6))) }
        if lower.hasPrefix("- [x] ") { return (true, String(s.dropFirst(6))) }
        return nil
    }

    // MARK: - 表格
    /// 一行是否像表格行：含至少两个「|」（典型 | a | b | 至少 3 个，但 a | b 也允许）
    private static func isTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("|") && t.filter { $0 == "|" }.count >= 2
    }

    /// 分隔行：每个单元格只由 - : 空格组成，如 |---|:--:|
    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        let cells = splitCells(t)
        guard !cells.isEmpty else { return false }
        for c in cells {
            let cc = c.trimmingCharacters(in: .whitespaces)
            if cc.isEmpty { return false }
            for ch in cc where ch != "-" && ch != ":" { return false }
        }
        return true
    }

    /// 把 "| a | b |" 切成 ["a","b"]，去掉首尾空管道
    private static func splitCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 解析对齐方式：:--- 左, :--: 中, ---: 右
    private static func alignments(from separator: String) -> [NSTextAlignment] {
        splitCells(separator).map { c -> NSTextAlignment in
            let cc = c.trimmingCharacters(in: .whitespaces)
            let l = cc.hasPrefix(":"), r = cc.hasSuffix(":")
            if l && r { return .center }
            if r { return .right }
            return .left
        }
    }

    /// 用 NSTextTable 渲染整张表格
    private static func renderTable(_ lines: [String]) -> NSAttributedString {
        let headerCells = splitCells(lines[0])
        let aligns = alignments(from: lines[1])
        let bodyRows = lines.dropFirst(2).map { splitCells($0) }
        let colCount = max(headerCells.count, bodyRows.map { $0.count }.max() ?? 0)

        let table = NSTextTable()
        table.numberOfColumns = colCount
        table.collapsesBorders = true

        let result = NSMutableAttributedString()
        let allRows: [(cells: [String], isHeader: Bool)] =
            [(headerCells, true)] + bodyRows.map { ($0, false) }

        for (rowIdx, row) in allRows.enumerated() {
            for col in 0..<colCount {
                let text = col < row.cells.count ? row.cells[col] : ""
                let align = col < aligns.count ? aligns[col] : .left

                let block = NSTextTableBlock(table: table, startingRow: rowIdx, rowSpan: 1,
                                             startingColumn: col, columnSpan: 1)
                block.setBorderColor(NSColor.separatorColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                if row.isHeader {
                    block.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25)
                }

                let p = NSMutableParagraphStyle()
                p.textBlocks = [block]
                p.alignment = align
                p.lineSpacing = 1

                let cell = NSMutableAttributedString(string: text + "\n", attributes: [
                    .font: row.isHeader ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: p])
                applyInline(cell)   // 单元格内也支持 **加粗** / `代码`
                result.append(cell)
            }
        }
        return result
    }

    // MARK: - 行内：**加粗** 和 `行内代码`
    private static func applyInline(_ s: NSMutableAttributedString) {
        applyPaired(s, marker: "**", weightBold: true)
        applyPaired(s, marker: "`", code: true)
    }

    private static func applyPaired(_ s: NSMutableAttributedString,
                                    marker: String,
                                    weightBold: Bool = false,
                                    code: Bool = false) {
        while true {
            let str = s.string as NSString
            let first = str.range(of: marker)
            guard first.location != NSNotFound else { break }
            let afterFirst = first.location + first.length
            guard afterFirst < str.length else { break }
            let rest = NSRange(location: afterFirst, length: str.length - afterFirst)
            let second = str.range(of: marker, options: [], range: rest)
            guard second.location != NSNotFound else { break }

            let contentRange = NSRange(location: afterFirst,
                                       length: second.location - afterFirst)
            // 取出现有字体大小
            var size: CGFloat = 13
            if contentRange.length > 0,
               let f = s.attribute(.font, at: contentRange.location, effectiveRange: nil) as? NSFont {
                size = f.pointSize
            }
            if weightBold {
                s.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: contentRange)
            }
            if code {
                s.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular), range: contentRange)
                s.addAttribute(.foregroundColor, value: NSColor.systemPink, range: contentRange)
            }
            // 删除后一个 marker，再删前一个（从后往前删，避免位移）
            s.deleteCharacters(in: second)
            s.deleteCharacters(in: first)
        }
    }
}
