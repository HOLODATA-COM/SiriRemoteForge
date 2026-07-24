/// Strips `//` line comments from JSONC text, ignoring `//` inside string literals.
public enum JSONC {
    public static func strip(_ s: String) -> String {
        var out = String(); out.reserveCapacity(s.count)
        var inString = false, escaped = false
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if inString {
                out.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                i = s.index(after: i)
            } else if ch == "\"" {
                inString = true; out.append(ch); i = s.index(after: i)
            } else if ch == "/",
                      s.index(after: i) < s.endIndex,
                      s[s.index(after: i)] == "/" {
                while i < s.endIndex, s[i] != "\n" { i = s.index(after: i) }
            } else {
                out.append(ch); i = s.index(after: i)
            }
        }
        return out
    }
}
