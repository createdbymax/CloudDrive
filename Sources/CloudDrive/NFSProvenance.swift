import Foundation

enum NFSProvenance {
    /// Bind the mount table's filesystem ID to the worker's exact loopback NFS port.
    /// A generic NFS source such as 127.0.0.1:/ is not sufficient ownership evidence.
    static func matches(report: String, mountPath: String, port: Int) -> Bool {
        let header = mountPath + " from 127.0.0.1:/"
        let lines = report.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(of: header) else { return false }
        var current = false, found = false
        for line in lines.dropFirst(start + 1) {
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == "-- Current mount parameters:" { current = true; continue }
            guard current, text.hasPrefix("NFS parameters: ") else { continue }
            let values = text.dropFirst("NFS parameters: ".count).split(separator: ",").map(String.init)
            // Refuse ambiguous duplicate keys.
            let ports = values.filter { $0.hasPrefix("port=") }
            guard ports == ["port=\(port)"], values.contains("vers=3"), values.contains("tcp") else { return false }
            found = true
        }
        return found
    }
}
