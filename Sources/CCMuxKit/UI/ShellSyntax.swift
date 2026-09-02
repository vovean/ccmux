import Foundation

/// A very small shell tokenizer — hand-rolled, because the app takes no third-party
/// dependency for four colours. It does not understand shell (no heredocs, no
/// substitution nesting); it must only never change the text, so the runs concatenate
/// back to the input exactly and a mis-tokenised line is merely mis-coloured.
public enum ShellSyntax {
    public enum Kind: Equatable, Sendable {
        case plain
        case comment
        case string
        case keyword
        case variable
    }

    public struct Run: Equatable, Sendable {
        public var text: String
        public var kind: Kind
    }

    public static func highlight(_ source: String) -> [Run] {
        var runs: [Run] = []
        var plain = ""
        func flushPlain() {
            guard !plain.isEmpty else { return }
            runs.append(Run(text: plain, kind: .plain))
            plain = ""
        }
        func emit(_ text: String, _ kind: Kind) {
            flushPlain()
            runs.append(Run(text: text, kind: kind))
        }

        let characters = Array(source)
        var i = 0
        // Whether the next word starts a command. Only there does a bare `if` or `done`
        // mean the keyword rather than an argument that happens to spell one.
        var atCommandStart = true

        while i < characters.count {
            let c = characters[i]

            // A `#` only opens a comment where a word could start; `foo#bar` and `${x#y}`
            // are not comments.
            if c == "#", i == 0 || isWordBreak(characters[i - 1]) {
                var end = i
                while end < characters.count, characters[end] != "\n" { end += 1 }
                emit(String(characters[i..<end]), .comment)
                i = end
                continue
            }

            if c == "'" || c == "\"" {
                let (text, next) = readString(characters, from: i, quote: c)
                emit(text, .string)
                i = next
                atCommandStart = false
                continue
            }

            if c == "$", i + 1 < characters.count, isVariableStart(characters[i + 1]) {
                let (text, next) = readVariable(characters, from: i)
                emit(text, .variable)
                i = next
                atCommandStart = false
                continue
            }

            // Consumed with its escapee so a `\"` cannot be mistaken for an opening quote.
            if c == "\\", i + 1 < characters.count {
                plain.append(c)
                plain.append(characters[i + 1])
                i += 2
                continue
            }

            if isWordCharacter(c) {
                var end = i
                while end < characters.count, isWordCharacter(characters[end]) { end += 1 }
                let word = String(characters[i..<end])
                let isKeyword = atCommandStart && keywords.contains(word)
                if isKeyword { emit(word, .keyword) } else { plain += word }
                i = end
                // `then`, `do` and `else` are followed by a command, so the next word is
                // still at a command start. Only a plain word ends one.
                atCommandStart = isKeyword
                continue
            }

            plain.append(c)
            if isCommandBreak(c) { atCommandStart = true }
            i += 1
        }
        flushPlain()
        return runs
    }

    /// Reads through the closing quote, or to the end of the input if there is none —
    /// an unterminated string colours to the end rather than dropping the rest.
    private static func readString(_ characters: [Character], from start: Int,
                                   quote: Character) -> (String, Int) {
        var i = start + 1
        while i < characters.count {
            // Single quotes take no escapes at all in shell, not even for a backslash.
            if quote == "\"", characters[i] == "\\", i + 1 < characters.count {
                i += 2
                continue
            }
            if characters[i] == quote { i += 1; break }
            i += 1
        }
        return (String(characters[start..<i]), i)
    }

    private static func readVariable(_ characters: [Character],
                                     from start: Int) -> (String, Int) {
        var i = start + 1
        if characters[i] == "{" {
            while i < characters.count, characters[i] != "}" { i += 1 }
            if i < characters.count { i += 1 }
        } else if isNameStart(characters[i]) {
            while i < characters.count, isWordCharacter(characters[i]) { i += 1 }
        } else {
            i += 1 // $1, $?, $@, $#
        }
        return (String(characters[start..<i]), i)
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    private static func isNameStart(_ c: Character) -> Bool { c.isLetter || c == "_" }

    private static func isVariableStart(_ c: Character) -> Bool {
        isNameStart(c) || c.isNumber || c == "{" || c == "?" || c == "@" || c == "#"
            || c == "*" || c == "$" || c == "!"
    }

    private static func isWordBreak(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == ";" || c == "|" || c == "&" || c == "("
    }

    private static func isCommandBreak(_ c: Character) -> Bool {
        c == "\n" || c == ";" || c == "|" || c == "&" || c == "(" || c == "{"
    }

    private static let keywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
        "case", "esac", "in", "function", "select", "return", "exit", "break",
        "continue", "local", "export", "readonly", "declare", "set", "unset", "shift",
        "source", "trap", "eval", "exec", "echo", "printf", "read", "cd", "test",
    ]
}
