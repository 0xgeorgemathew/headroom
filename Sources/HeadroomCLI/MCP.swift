import Foundation
import HeadroomKit

/// Optional stdio MCP server (PLAN §9). Built last; nothing depends on it.
enum MCPServer {
    static func run(url: URL) -> Int32 {
        FileHandle.standardError.write(Data("headroom mcp is not available in this build.\n".utf8))
        return 1
    }
}
