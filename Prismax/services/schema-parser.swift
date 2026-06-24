import Foundation

/// Lightweight parser for Prisma `schema.prisma` files. Extracts the datasource
/// provider, generators, models, enums and their fields. This is intentionally
/// tolerant — it skips comments and unknown blocks rather than failing.
enum SchemaParser {

    struct Schema: Equatable {
        var datasourceProvider: String?
        var datasourceURL: String?
        var generators: [Generator]
        var models: [Model]
        var enums: [ModelEnum]
    }

    struct Generator: Equatable {
        var name: String
        var provider: String?
    }

    struct Model: Identifiable, Equatable, Hashable {
        var id: String { name }
        var name: String
        var fields: [Field]
        var isView: Bool
    }

    struct Field: Equatable, Hashable {
        var name: String
        var type: String
        var isRequired: Bool
        var isList: Bool
        var isUnique: Bool
        var isId: Bool
        var isRelation: Bool
        var defaultValue: String?
    }

    struct ModelEnum: Identifiable, Equatable, Hashable {
        var id: String { name }
        var name: String
        var values: [String]
    }

    /// Parses the given schema text. Never throws — malformed input yields an
    /// empty schema.
    static func parse(_ text: String) -> Schema {
        var schema = Schema(datasourceProvider: nil, datasourceURL: nil, generators: [], models: [], enums: [])
        // Strip line comments and block comments.
        let cleaned = stripComments(text)
        let blocks = extractBlocks(cleaned)

        for block in blocks {
            switch block.keyword {
            case "datasource":
                applyDatasource(block, to: &schema)
            case "generator":
                schema.generators.append(parseGenerator(block))
            case "model":
                schema.models.append(parseModel(block))
            case "enum":
                schema.enums.append(parseEnum(block))
            case "view":
                schema.models.append(parseModel(block, isView: true))
            default:
                break
            }
        }
        return schema
    }

    /// Convenience: parse a file at `path`.
    static func parseFile(at path: String) -> Schema {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return Schema(datasourceProvider: nil, datasourceURL: nil, generators: [], models: [], enums: [])
        }
        return parse(text)
    }

    // MARK: Block extraction

    struct RawBlock {
        let keyword: String
        let name: String
        let body: String
    }

    /// Walks the text and returns top-level `keyword name { ... }` blocks.
    private static func extractBlocks(_ text: String) -> [RawBlock] {
        var blocks: [RawBlock] = []
        var index = text.startIndex
        let end = text.endIndex

        while index < end {
            // Find the next identifier-like run.
            guard let wordRange = text.rangeOfCharacter(from: .letters, range: index..<end) else { break }
            let keywordStart = wordRange.lowerBound
            // Read the keyword.
            var kwEnd = keywordStart
            while kwEnd < end, text[kwEnd].isLetter { kwEnd = text.index(after: kwEnd) }
            let keyword = String(text[keywordStart..<kwEnd])

            // Skip "datasource db" — name follows the keyword.
            var nameEnd = kwEnd
            while nameEnd < end, text[nameEnd].isWhitespace { nameEnd = text.index(after: nameEnd) }
            var nameStart = nameEnd
            var nameFinish = nameStart
            while nameFinish < end, text[nameFinish].isLetter || text[nameFinish].isNumber || text[nameFinish] == "_" {
                nameFinish = text.index(after: nameFinish)
            }
            let name = (nameStart < nameFinish) ? String(text[nameStart..<nameFinish]) : ""
            if name.isEmpty { nameStart = kwEnd; nameFinish = kwEnd }

            // Find the opening brace.
            var brace = nameFinish
            while brace < end, text[brace] != "{" { brace = text.index(after: brace) }
            if brace >= end { break }

            // Find the matching close brace (naive — no nested braces in prisma).
            var close = text.index(after: brace)
            while close < end, text[close] != "}" { close = text.index(after: close) }
            if close >= end { break }

            let body = String(text[text.index(after: brace)..<close])
            blocks.append(RawBlock(keyword: keyword, name: name, body: body))

            index = text.index(after: close)
        }
        return blocks
    }

    private static func applyDatasource(_ block: RawBlock, to schema: inout Schema) {
        for line in block.body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("provider") {
                schema.datasourceProvider = extractValue(trimmed)
            } else if trimmed.hasPrefix("url") {
                schema.datasourceURL = extractValue(trimmed)
            }
        }
    }

    private static func parseGenerator(_ block: RawBlock) -> Generator {
        var provider: String?
        for line in block.body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("provider") { provider = extractValue(trimmed) }
        }
        return Generator(name: block.name, provider: provider)
    }

    private static func parseModel(_ block: RawBlock, isView: Bool = false) -> Model {
        var fields: [Field] = []
        for line in block.body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("@@") || trimmed.hasPrefix("//") { continue }

            // Split into field parts and attributes.
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }
            let name = parts[0]
            let rawType = parts[1]
            let type = rawType.trimmingCharacters(in: CharacterSet(charactersIn: "?[]"))

            // Everything after type is attributes (or default value clause).
            let attrPart = parts.dropFirst(2).joined(separator: " ")

            fields.append(Field(
                name: name,
                type: type,
                isRequired: !rawType.contains("?"),
                isList: rawType.contains("[]"),
                isUnique: attrPart.contains("@unique"),
                isId: attrPart.contains("@id"),
                isRelation: attrPart.contains("@relation"),
                defaultValue: extractDefault(attrPart)
            ))
        }
        return Model(name: block.name, fields: fields, isView: isView)
    }

    private static func parseEnum(_ block: RawBlock) -> ModelEnum {
        let values = block.body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        return ModelEnum(name: block.name, values: values)
    }

    // MARK: Value helpers

    /// Extracts the value after `=` (handles quotes and env() calls).
    private static func extractValue(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        // env("DATABASE_URL") → DATABASE_URL
        if value.hasPrefix("env(") {
            value = value.replacingOccurrences(of: "env(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return value
    }

    private static func extractDefault(_ attrPart: String) -> String? {
        guard let range = attrPart.range(of: "@default(") else { return nil }
        let start = range.upperBound
        guard let end = attrPart[start...].firstIndex(of: ")") else { return nil }
        return String(attrPart[start..<end])
    }

    private static func stripComments(_ text: String) -> String {
        // Remove block comments /* ... */
        var cleaned = text.replacingOccurrences(
            of: #"/\*[\s\S]*?\*/"#,
            with: "",
            options: .regularExpression
        )
        // Remove line comments //...
        cleaned = cleaned.replacingOccurrences(
            of: #"//.*"#,
            with: "",
            options: .regularExpression
        )
        return cleaned
    }
}
