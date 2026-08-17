import Foundation

extension LanguageSpec {
    /// 第一批语言（通用词法器驱动）。专用词法器见 SpecialLexers.swift。
    public static let all: [LanguageSpec] = [
        swift, javascript, typescript, python, bash, c, cpp, objectiveC, go, rust, sql, java, kotlin, csharp, ruby, php, lua, dart,
        dockerfile, makefile, graphql, protobuf, nginx, latex, r, scala, perl, haskell, elixir, zig,
    ]

    static var swift: LanguageSpec {
        var s = LanguageSpec(name: "swift")
        s.keywords = ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while", "as", "await", "async", "is", "super", "self", "Self", "throws", "try", "some", "any", "actor", "nonisolated", "isolated", "consuming", "borrowing", "macro", "package", "each", "weak", "unowned", "lazy", "mutating", "nonmutating", "override", "final", "required", "convenience", "dynamic", "optional", "indirect", "prefix", "postfix", "infix", "willSet", "didSet", "get", "set"]
        s.types = ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Float", "Double", "Bool", "String", "Character", "Array", "Dictionary", "Set", "Optional", "Result", "Error", "Any", "AnyObject", "Void", "Never", "Substring", "Data", "URL", "Date", "Range", "ClosedRange", "Task", "MainActor", "Sendable", "Hashable", "Equatable", "Codable", "Identifiable"]
        s.constants = ["true", "false", "nil"]
        s.tripleQuotes = true; s.nestedBlockComments = true; s.attributePrefix = 0x40 // @
        s.preprocessorPrefix = 0x23 // #if #available
        return s
    }

    static var javascript: LanguageSpec {
        var s = LanguageSpec(name: "javascript"); s.aliases = ["js", "mjs", "cjs", "jsx"]
        s.keywords = ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let", "new", "of", "return", "static", "super", "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield", "get", "set", "as"]
        s.types = ["Array", "Object", "String", "Number", "Boolean", "Promise", "Map", "Set", "Symbol", "Date", "RegExp", "Error", "JSON", "Math", "console", "window", "document", "BigInt"]
        s.constants = ["true", "false", "null", "undefined", "NaN", "Infinity"]
        s.backtickString = true; s.regexLiterals = true; s.attributePrefix = 0x40; s.identifierExtra = [0x24] // $
        return s
    }

    static var typescript: LanguageSpec {
        var s = javascript; s.name = "typescript"; s.aliases = ["ts", "tsx"]
        s.keywords.formUnion(["interface", "type", "enum", "implements", "namespace", "declare", "abstract", "readonly", "keyof", "infer", "is", "public", "private", "protected", "override", "satisfies", "module"])
        s.types.formUnion(["string", "number", "boolean", "any", "unknown", "never", "void", "object", "Record", "Partial", "Required", "Readonly", "Pick", "Omit"])
        return s
    }

    static var python: LanguageSpec {
        var s = LanguageSpec(name: "python"); s.aliases = ["py", "python3", "pyi"]
        s.keywords = ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case", "self", "cls"]
        s.types = ["int", "float", "str", "bytes", "bool", "list", "dict", "set", "tuple", "object", "type", "frozenset", "complex", "Exception", "ValueError", "TypeError", "KeyError"]
        s.constants = ["True", "False", "None", "NotImplemented", "Ellipsis"]
        s.builtins = ["print", "len", "range", "enumerate", "zip", "map", "filter", "sorted", "reversed", "isinstance", "open", "super", "getattr", "setattr", "hasattr", "abs", "min", "max", "sum", "any", "all", "iter", "next", "id", "hash", "repr", "format", "input", "round"]
        s.lineComments = ["#"]; s.blockComments = []; s.tripleQuotes = true; s.attributePrefix = 0x40
        s.rawStringPrefixes = ["r", "b", "f", "rb", "br", "fr", "rf", "u", "R", "B", "F"]
        return s
    }

    static var bash: LanguageSpec {
        var s = LanguageSpec(name: "bash"); s.aliases = ["sh", "shell", "zsh", "fish", "console", "shell-session"]
        s.keywords = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "select", "time", "return", "exit", "local", "export", "readonly", "declare", "typeset", "unset", "shift", "source", "alias", "break", "continue", "set", "trap", "eval", "exec"]
        s.builtins = ["echo", "printf", "cd", "ls", "cat", "grep", "sed", "awk", "find", "xargs", "curl", "wget", "git", "mkdir", "rm", "cp", "mv", "chmod", "chown", "sudo", "test", "read", "pwd", "touch", "tar", "zip", "ssh", "scp", "docker", "npm", "swift", "brew", "make", "python", "python3", "pip", "node", "open", "kill", "ps", "tail", "head", "sort", "uniq", "wc", "tr", "cut", "tee", "which", "env", "date", "sleep"]
        s.lineComments = ["#"]; s.blockComments = []; s.variablePrefix = 0x24; s.backtickString = true
        s.functionCallHeuristic = false; s.capitalizedTypeHeuristic = false
        return s
    }

    static var c: LanguageSpec {
        var s = LanguageSpec(name: "c"); s.aliases = ["h"]
        s.keywords = ["auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof", "static", "struct", "switch", "typedef", "union", "volatile", "while", "_Bool", "_Complex", "_Atomic", "_Static_assert", "_Thread_local", "typeof"]
        s.types = ["int", "char", "short", "long", "float", "double", "void", "unsigned", "signed", "size_t", "ssize_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "bool", "FILE", "uintptr_t", "intptr_t", "ptrdiff_t", "wchar_t"]
        s.constants = ["true", "false", "NULL", "EOF"]
        s.preprocessorPrefix = 0x23
        return s
    }

    static var cpp: LanguageSpec {
        var s = c; s.name = "cpp"; s.aliases = ["c++", "cc", "cxx", "hpp", "hh", "hxx"]
        s.keywords.formUnion(["alignas", "alignof", "and", "catch", "class", "concept", "consteval", "constexpr", "constinit", "const_cast", "co_await", "co_return", "co_yield", "decltype", "delete", "dynamic_cast", "explicit", "export", "friend", "mutable", "namespace", "new", "noexcept", "not", "operator", "or", "private", "protected", "public", "reinterpret_cast", "requires", "static_assert", "static_cast", "template", "this", "throw", "try", "typeid", "typename", "using", "virtual", "override", "final"])
        s.types.formUnion(["string", "vector", "map", "unordered_map", "set", "unordered_set", "pair", "tuple", "shared_ptr", "unique_ptr", "weak_ptr", "optional", "variant", "array", "deque", "list", "std", "auto", "string_view", "span"])
        s.constants.formUnion(["nullptr"])
        return s
    }

    static var objectiveC: LanguageSpec {
        var s = c; s.name = "objective-c"; s.aliases = ["objc", "objectivec", "m", "mm"]
        // @interface / @property 等由 attributePrefix(@) 识别为 attribute，不入关键字表
        s.keywords.formUnion(["self", "super", "nonatomic", "atomic", "strong", "weak", "copy", "assign", "readonly", "readwrite", "instancetype", "id", "in", "out", "inout", "bycopy", "byref", "oneway"])
        s.types.formUnion(["NSString", "NSArray", "NSDictionary", "NSObject", "NSInteger", "NSUInteger", "CGFloat", "BOOL", "NSNumber", "NSError", "NSData", "NSURL", "NSMutableArray", "NSMutableDictionary", "NSSet", "UIView", "NSView", "CGRect", "CGPoint", "CGSize", "SEL", "IMP", "Class"])
        s.constants.formUnion(["YES", "NO", "nil", "Nil"])
        s.attributePrefix = 0x40
        return s
    }

    static var go: LanguageSpec {
        var s = LanguageSpec(name: "go"); s.aliases = ["golang"]
        s.keywords = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"]
        s.types = ["bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any", "comparable"]
        s.constants = ["true", "false", "nil", "iota"]
        s.builtins = ["append", "cap", "close", "copy", "delete", "len", "make", "new", "panic", "print", "println", "recover", "clear", "min", "max"]
        s.backtickString = true
        return s
    }

    static var rust: LanguageSpec {
        var s = LanguageSpec(name: "rust"); s.aliases = ["rs"]
        s.keywords = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while", "union", "macro_rules"]
        s.types = ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box", "Rc", "Arc", "RefCell", "Cell", "HashMap", "HashSet", "BTreeMap", "Some", "None", "Ok", "Err"]
        s.constants = ["true", "false"]
        s.nestedBlockComments = true; s.rawStringPrefixes = ["r", "b", "br"]; s.lifetimeQuote = true
        s.preprocessorPrefix = 0x23 // #[derive] 近似为 meta
        return s
    }

    static var sql: LanguageSpec {
        var s = LanguageSpec(name: "sql"); s.aliases = ["mysql", "postgresql", "postgres", "sqlite", "plsql", "tsql"]
        s.keywords = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add", "column", "index", "view", "join", "inner", "left", "right", "outer", "full", "cross", "on", "as", "and", "or", "not", "in", "is", "like", "between", "exists", "group", "by", "order", "having", "limit", "offset", "union", "all", "distinct", "case", "when", "then", "else", "end", "primary", "key", "foreign", "references", "default", "constraint", "unique", "check", "if", "begin", "commit", "rollback", "transaction", "with", "recursive", "returning", "asc", "desc", "nulls", "first", "last", "over", "partition", "window", "explain", "analyze", "vacuum", "grant", "revoke", "cascade", "truncate", "replace", "using", "natural", "except", "intersect"]
        s.types = ["int", "integer", "bigint", "smallint", "serial", "bigserial", "varchar", "char", "text", "boolean", "bool", "date", "timestamp", "timestamptz", "time", "interval", "numeric", "decimal", "real", "float", "double", "precision", "json", "jsonb", "uuid", "bytea", "blob", "array"]
        s.constants = ["true", "false", "null"]
        s.builtins = ["count", "sum", "avg", "min", "max", "coalesce", "nullif", "now", "length", "lower", "upper", "substr", "substring", "concat", "cast", "round", "date_trunc", "extract", "row_number", "rank", "dense_rank", "lag", "lead", "array_agg", "string_agg", "json_agg", "greatest", "least", "trim"]
        s.lineComments = ["--"]; s.caseInsensitive = true; s.capitalizedTypeHeuristic = false
        return s
    }

    static var java: LanguageSpec {
        var s = LanguageSpec(name: "java")
        s.keywords = ["abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum", "extends", "final", "finally", "for", "goto", "if", "implements", "import", "instanceof", "interface", "native", "new", "package", "private", "protected", "public", "return", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "volatile", "while", "var", "record", "sealed", "permits", "yield"]
        s.types = ["boolean", "byte", "char", "short", "int", "long", "float", "double", "void", "String", "Object", "Integer", "Long", "Double", "Boolean", "List", "Map", "Set", "ArrayList", "HashMap", "HashSet", "Optional", "Stream"]
        s.constants = ["true", "false", "null"]
        s.tripleQuotes = true; s.attributePrefix = 0x40
        return s
    }

    static var kotlin: LanguageSpec {
        var s = LanguageSpec(name: "kotlin"); s.aliases = ["kt", "kts"]
        s.keywords = ["as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in", "interface", "is", "null", "object", "package", "return", "super", "this", "throw", "true", "try", "typealias", "typeof", "val", "var", "when", "while", "by", "catch", "constructor", "delegate", "dynamic", "field", "file", "finally", "get", "import", "init", "param", "property", "receiver", "set", "setparam", "value", "where", "abstract", "actual", "annotation", "companion", "const", "crossinline", "data", "enum", "expect", "external", "final", "infix", "inline", "inner", "internal", "lateinit", "noinline", "open", "operator", "out", "override", "private", "protected", "public", "reified", "sealed", "suspend", "tailrec", "vararg"]
        s.types = ["Int", "Long", "Short", "Byte", "Float", "Double", "Boolean", "Char", "String", "Unit", "Nothing", "Any", "List", "Map", "Set", "MutableList", "MutableMap", "Array", "Pair"]
        s.constants = ["true", "false", "null"]
        s.tripleQuotes = true; s.attributePrefix = 0x40; s.nestedBlockComments = true
        return s
    }

    static var csharp: LanguageSpec {
        var s = LanguageSpec(name: "csharp"); s.aliases = ["cs", "c#"]
        s.keywords = ["abstract", "as", "base", "break", "case", "catch", "checked", "class", "const", "continue", "default", "delegate", "do", "else", "enum", "event", "explicit", "extern", "finally", "fixed", "for", "foreach", "goto", "if", "implicit", "in", "interface", "internal", "is", "lock", "namespace", "new", "operator", "out", "override", "params", "private", "protected", "public", "readonly", "ref", "return", "sealed", "sizeof", "stackalloc", "static", "struct", "switch", "this", "throw", "try", "typeof", "unchecked", "unsafe", "using", "virtual", "volatile", "while", "var", "async", "await", "record", "get", "set", "init", "value", "yield", "where", "select", "from", "dynamic", "nameof", "with"]
        s.types = ["bool", "byte", "char", "decimal", "double", "float", "int", "long", "object", "sbyte", "short", "string", "uint", "ulong", "ushort", "void", "String", "List", "Dictionary", "Task", "IEnumerable", "Action", "Func"]
        s.constants = ["true", "false", "null"]
        s.attributePrefix = nil; s.rawStringPrefixes = ["@", "$", "$@", "@$"]; s.preprocessorPrefix = 0x23
        return s
    }

    static var ruby: LanguageSpec {
        var s = LanguageSpec(name: "ruby"); s.aliases = ["rb"]
        s.keywords = ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "undef", "unless", "until", "when", "while", "yield", "require", "require_relative", "include", "extend", "attr_accessor", "attr_reader", "attr_writer", "private", "public", "protected", "lambda", "proc", "raise", "puts", "print", "p"]
        s.constants = ["true", "false", "nil"]
        s.lineComments = ["#"]; s.blockComments = [("=begin", "=end")]; s.variablePrefix = 0x40; s.identifierExtra = [0x3F, 0x21] // ? !
        return s
    }

    static var php: LanguageSpec {
        var s = LanguageSpec(name: "php")
        s.keywords = ["abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "enddeclare", "endfor", "endforeach", "endif", "endswitch", "endwhile", "enum", "extends", "final", "finally", "fn", "for", "foreach", "function", "global", "goto", "if", "implements", "include", "include_once", "instanceof", "insteadof", "interface", "isset", "list", "match", "namespace", "new", "or", "print", "private", "protected", "public", "readonly", "require", "require_once", "return", "static", "switch", "throw", "trait", "try", "unset", "use", "var", "while", "xor", "yield"]
        s.types = ["int", "float", "string", "bool", "array", "object", "mixed", "void", "null", "iterable", "self", "static"]
        s.constants = ["true", "false", "null", "TRUE", "FALSE", "NULL"]
        s.lineComments = ["//", "#"]; s.variablePrefix = 0x24; s.attributePrefix = nil
        return s
    }

    static var lua: LanguageSpec {
        var s = LanguageSpec(name: "lua")
        s.keywords = ["and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not", "or", "repeat", "return", "then", "until", "while"]
        s.constants = ["true", "false", "nil"]
        s.builtins = ["print", "pairs", "ipairs", "require", "type", "tostring", "tonumber", "setmetatable", "getmetatable", "pcall", "error", "assert", "select", "unpack", "next", "rawget", "rawset"]
        s.lineComments = ["--"]; s.blockComments = [("--[[", "]]")]
        return s
    }

    static var dart: LanguageSpec {
        var s = LanguageSpec(name: "dart")
        s.keywords = ["abstract", "as", "assert", "async", "await", "break", "case", "catch", "class", "const", "continue", "covariant", "default", "deferred", "do", "dynamic", "else", "enum", "export", "extends", "extension", "external", "factory", "final", "finally", "for", "get", "hide", "if", "implements", "import", "in", "interface", "is", "late", "library", "mixin", "new", "on", "operator", "part", "required", "rethrow", "return", "sealed", "set", "show", "static", "super", "switch", "sync", "this", "throw", "try", "typedef", "var", "void", "when", "while", "with", "yield", "base"]
        s.types = ["int", "double", "num", "String", "bool", "List", "Map", "Set", "Future", "Stream", "Object", "Widget", "BuildContext", "Iterable", "Duration"]
        s.constants = ["true", "false", "null"]
        s.tripleQuotes = true; s.attributePrefix = 0x40; s.rawStringPrefixes = ["r"]
        return s
    }

    static var dockerfile: LanguageSpec {
        var s = LanguageSpec(name: "dockerfile"); s.aliases = ["docker"]
        s.keywords = ["from", "run", "cmd", "label", "maintainer", "expose", "env", "add", "copy", "entrypoint", "volume", "user", "workdir", "arg", "onbuild", "stopsignal", "healthcheck", "shell", "as"]
        s.lineComments = ["#"]; s.blockComments = []; s.variablePrefix = 0x24; s.caseInsensitive = true
        s.functionCallHeuristic = false; s.capitalizedTypeHeuristic = false
        return s
    }

    static var makefile: LanguageSpec {
        var s = LanguageSpec(name: "makefile"); s.aliases = ["make", "mk"]
        s.keywords = ["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "define", "endef", "export", "unexport", "override", "vpath", ".PHONY", ".DEFAULT", ".SUFFIXES", ".PRECIOUS", ".SILENT"]
        s.builtins = ["shell", "wildcard", "patsubst", "subst", "foreach", "call", "eval", "if", "or", "and", "strip", "findstring", "filter", "filter-out", "sort", "word", "words", "firstword", "lastword", "dir", "notdir", "suffix", "basename", "addsuffix", "addprefix", "join", "realpath", "abspath", "error", "warning", "info", "origin", "flavor", "value"]
        s.lineComments = ["#"]; s.blockComments = []; s.variablePrefix = 0x24; s.identifierExtra = [0x2E, 0x2D]
        s.functionCallHeuristic = false; s.capitalizedTypeHeuristic = false
        return s
    }

    static var graphql: LanguageSpec {
        var s = LanguageSpec(name: "graphql"); s.aliases = ["gql"]
        s.keywords = ["query", "mutation", "subscription", "fragment", "on", "type", "interface", "union", "enum", "input", "scalar", "schema", "extend", "directive", "implements", "repeatable"]
        s.types = ["Int", "Float", "String", "Boolean", "ID"]
        s.constants = ["true", "false", "null"]
        s.lineComments = ["#"]; s.blockComments = []; s.tripleQuotes = true; s.variablePrefix = 0x24; s.attributePrefix = 0x40
        return s
    }

    static var protobuf: LanguageSpec {
        var s = LanguageSpec(name: "protobuf"); s.aliases = ["proto", "proto3"]
        s.keywords = ["syntax", "package", "import", "option", "message", "enum", "service", "rpc", "returns", "repeated", "optional", "required", "oneof", "map", "reserved", "extend", "extensions", "to", "max", "stream", "public", "weak"]
        s.types = ["double", "float", "int32", "int64", "uint32", "uint64", "sint32", "sint64", "fixed32", "fixed64", "sfixed32", "sfixed64", "bool", "string", "bytes"]
        s.constants = ["true", "false"]
        return s
    }

    static var nginx: LanguageSpec {
        var s = LanguageSpec(name: "nginx"); s.aliases = ["nginxconf"]
        s.keywords = ["server", "location", "http", "events", "upstream", "listen", "server_name", "root", "index", "proxy_pass", "proxy_set_header", "return", "rewrite", "if", "include", "worker_processes", "worker_connections", "error_log", "access_log", "ssl_certificate", "ssl_certificate_key", "try_files", "add_header", "gzip", "client_max_body_size", "keepalive_timeout", "sendfile", "types", "default_type", "map", "set", "break", "last", "redirect", "permanent", "alias", "expires", "deny", "allow", "auth_basic", "limit_req", "fastcgi_pass"]
        s.lineComments = ["#"]; s.blockComments = []; s.variablePrefix = 0x24
        s.functionCallHeuristic = false; s.capitalizedTypeHeuristic = false
        return s
    }

    static var latex: LanguageSpec {
        var s = LanguageSpec(name: "latex"); s.aliases = ["tex"]
        s.lineComments = ["%"]; s.blockComments = []; s.stringQuotes = []
        s.variablePrefix = 0x5C // \command → variable 近似（渲染成 variable 色）
        s.functionCallHeuristic = false; s.capitalizedTypeHeuristic = false
        return s
    }

    static var r: LanguageSpec {
        var s = LanguageSpec(name: "r"); s.aliases = ["rlang", "rscript"]
        s.keywords = ["if", "else", "repeat", "while", "function", "for", "in", "next", "break", "library", "require", "return"]
        s.constants = ["TRUE", "FALSE", "NULL", "NA", "Inf", "NaN", "NA_integer_", "NA_real_", "NA_character_"]
        s.lineComments = ["#"]; s.blockComments = []; s.identifierExtra = [0x2E]
        return s
    }

    static var scala: LanguageSpec {
        var s = LanguageSpec(name: "scala")
        s.keywords = ["abstract", "case", "catch", "class", "def", "do", "else", "extends", "final", "finally", "for", "forSome", "if", "implicit", "import", "lazy", "match", "new", "object", "override", "package", "private", "protected", "return", "sealed", "super", "this", "throw", "trait", "try", "type", "val", "var", "while", "with", "yield", "given", "using", "enum", "extension", "then", "end"]
        s.types = ["Int", "Long", "Double", "Float", "Boolean", "Char", "String", "Unit", "Any", "AnyRef", "Nothing", "Option", "Some", "None", "List", "Seq", "Map", "Set", "Vector", "Either", "Future"]
        s.constants = ["true", "false", "null"]
        s.tripleQuotes = true; s.attributePrefix = 0x40; s.nestedBlockComments = true
        return s
    }

    static var perl: LanguageSpec {
        var s = LanguageSpec(name: "perl"); s.aliases = ["pl", "pm"]
        s.keywords = ["my", "our", "local", "sub", "if", "elsif", "else", "unless", "while", "until", "for", "foreach", "do", "last", "next", "redo", "return", "use", "no", "require", "package", "print", "printf", "die", "warn", "eval", "and", "or", "not", "xor", "shift", "push", "pop", "unshift", "splice", "keys", "values", "each", "defined", "undef", "ref", "bless", "wantarray"]
        s.lineComments = ["#"]; s.blockComments = [("=pod", "=cut")]; s.variablePrefix = 0x24; s.regexLiterals = true
        return s
    }

    static var haskell: LanguageSpec {
        var s = LanguageSpec(name: "haskell"); s.aliases = ["hs"]
        s.keywords = ["case", "class", "data", "deriving", "do", "else", "if", "import", "in", "infix", "infixl", "infixr", "instance", "let", "module", "newtype", "of", "then", "type", "where", "forall", "qualified", "as", "hiding", "family"]
        s.types = ["Int", "Integer", "Double", "Float", "Bool", "Char", "String", "Maybe", "Either", "IO", "Ordering", "Just", "Nothing", "Left", "Right"]
        s.constants = ["True", "False"]
        s.lineComments = ["--"]; s.blockComments = [("{-", "-}")]; s.nestedBlockComments = true; s.identifierExtra = [0x27]
        return s
    }

    static var elixir: LanguageSpec {
        var s = LanguageSpec(name: "elixir"); s.aliases = ["ex", "exs"]
        s.keywords = ["def", "defp", "defmodule", "defstruct", "defmacro", "defprotocol", "defimpl", "do", "end", "if", "else", "unless", "case", "cond", "when", "fn", "with", "for", "receive", "after", "rescue", "try", "catch", "raise", "import", "alias", "require", "use", "quote", "unquote", "and", "or", "not", "in"]
        s.constants = ["true", "false", "nil"]
        s.lineComments = ["#"]; s.blockComments = []; s.tripleQuotes = true; s.attributePrefix = 0x40; s.identifierExtra = [0x3F, 0x21]
        return s
    }

    static var zig: LanguageSpec {
        var s = LanguageSpec(name: "zig")
        s.keywords = ["const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "break", "continue", "defer", "errdefer", "try", "catch", "struct", "enum", "union", "error", "unreachable", "comptime", "inline", "export", "extern", "packed", "test", "and", "or", "orelse", "async", "await", "suspend", "resume", "noalias", "align", "volatile", "threadlocal", "usingnamespace", "anytype", "opaque"]
        s.types = ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f16", "f32", "f64", "f128", "bool", "void", "noreturn", "type", "anyerror", "c_int", "c_uint", "c_long"]
        s.constants = ["true", "false", "null", "undefined"]
        s.blockComments = []; s.attributePrefix = 0x40
        return s
    }
}
