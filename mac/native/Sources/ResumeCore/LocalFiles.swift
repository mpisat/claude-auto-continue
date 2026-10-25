import Foundation

@MainActor public final class FileSessionSource: SessionSource {
    private let metadataRoot: URL
    private let projectsRoot: URL
    private var transcriptIndex: [String: [URL]]?
    private var directorySignatures: [URL: Date] = [:]

    public init(metadataRoot: URL, projectsRoot: URL) {
        self.metadataRoot = metadataRoot
        self.projectsRoot = projectsRoot
    }
    public func discover() throws -> [Session] {
        guard FileManager.default.fileExists(atPath: metadataRoot.path) else { return [] }
        var refreshedIndex = false
        if transcriptIndex == nil || indexDirectoriesChanged() { rebuildIndex(); refreshedIndex = true }
        guard let files = FileManager.default.enumerator(at: metadataRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [String: Session] = [:]
        for case let file as URL in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["sessionId"] as? String, id.hasPrefix("local_"),
                  let cli = object["cliSessionId"] as? String, !cli.isEmpty,
                  let cwd = object["cwd"] as? String, !cwd.isEmpty,
                  let title = object["title"] as? String,
                  let archived = object["isArchived"] as? Bool, !archived else { continue }
            let indexed = transcriptIndex?[cli]
            let missingCandidate = indexed?.contains { !FileManager.default.fileExists(atPath: $0.path) } == true
            if !refreshedIndex && (indexed == nil || missingCandidate) {
                rebuildIndex()
                refreshedIndex = true
            }
            guard let candidates = transcriptIndex?[cli], candidates.count == 1,
                  let transcript = candidates.first,
                  FileManager.default.fileExists(atPath: transcript.path) else { continue }
            found[id] = Session(id: id, cliSessionID: cli, cwd: cwd, title: title, transcriptURL: transcript)
        }
        return found.values.sorted { $0.id < $1.id }
    }
    private func rebuildIndex() {
        var index: [String: [URL]] = [:]
        var directories: [URL: Date] = [:]
        directories[projectsRoot] = directoryModified(projectsRoot)
        if let files = FileManager.default.enumerator(at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in files {
                let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                if values?.isDirectory == true { directories[file] = values?.contentModificationDate }
                if file.pathExtension == "jsonl" {
                    index[file.deletingPathExtension().lastPathComponent, default: []].append(file)
                }
            }
        }
        directorySignatures = directories
        transcriptIndex = index
    }
    private func directoryModified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
    private func indexDirectoriesChanged() -> Bool {
        directorySignatures.isEmpty || directorySignatures.contains { directoryModified($0.key) != $0.value }
    }
}

@MainActor public final class FileTranscriptSource: TranscriptSource {
    public private(set) var bytesRead = 0
    private struct Signature: Equatable {
        let size: UInt64
        let modified: Date
        let inode: UInt64
    }
    private var cache: [URL: (Signature, TranscriptSnapshot)] = [:]
    private let maxScanBytes: Int
    public init(maxScanBytes: Int = 8 * 1024 * 1024) { self.maxScanBytes = max(0, maxScanBytes) }
    public func latest(_ session: Session) throws -> TranscriptSnapshot {
        let url = session.transcriptURL
        let signature = try signature(url)
        if let cached = cache[url], cached.0 == signature { return cached.1 }
        let result = try scan(url, size: signature.size)
        guard try self.signature(url) == signature else { return .unavailable }
        cache[url] = (signature, result)
        return result
    }
    private func signature(_ url: URL) throws -> Signature {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return Signature(size: size.uint64Value, modified: modified, inode: inode.uint64Value)
    }
    private func scan(_ url: URL, size: UInt64) throws -> TranscriptSnapshot {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var position = size
        var pending = Data()
        var firstChunk = true
        var remaining = UInt64(maxScanBytes)
        while position > 0 && remaining > 0 {
            let length = min(position, min(65536, remaining))
            remaining -= length
            position -= length
            try file.seek(toOffset: position)
            guard let chunk = try file.read(upToCount: Int(length)), chunk.count == Int(length) else { return .unavailable }
            bytesRead += chunk.count
            if firstChunk {
                firstChunk = false
                // An incomplete append must suppress stale retry evidence.
                guard chunk.last == 10 else { return .unavailable }
            }
            pending = chunk + pending
            while let separator = pending.lastIndex(of: 10) {
                let line = pending.suffix(from: pending.index(after: separator))
                pending = pending.prefix(upTo: separator)
                if line.isEmpty { continue }
                if let result = parse(Data(line)) { return result }
            }
        }
        guard position == 0 else { return .unavailable }
        return pending.isEmpty ? .unavailable : (parse(pending) ?? .unavailable)
    }
    // nil means a known metadata/tool row. Unknown or malformed rows fail closed.
    private func parse(_ data: Data) -> TranscriptSnapshot? {
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unavailable }
        if row["isSidechain"] as? Bool == true || row["isMeta"] as? Bool == true { return nil }
        if let parent = row["parent_tool_use_id"], !(parent is NSNull) { return nil }
        let origin = row["origin"] as? [String: Any]
        if origin?["kind"] as? String == "task-notification" { return nil }
        guard let type = row["type"] as? String else { return .unavailable }
        if ["system", "progress", "file-history-snapshot", "queue-operation"].contains(type) { return nil }
        let metadataFields = ["custom-title": "customTitle", "agent-name": "agentName", "last-prompt": "lastPrompt",
                              "cost-state": "totalCostUSD", "mode": "mode", "isolation-latch": "side", "atis-latch": "atis",
                              "relocated": "relocatedCwd"]
        if let field = metadataFields[type], row["message"] == nil, row["sessionId"] is String, row[field] != nil { return nil }
        let message = row["message"] as? [String: Any]
        if type == "user", let content = message?["content"] as? [[String: Any]], !content.isEmpty,
           content.allSatisfy({ $0["type"] as? String == "tool_result" }) { return nil }
        guard let uuid = row["uuid"] as? String, !uuid.isEmpty else { return .unavailable }
        if type == "user" { return .human(uuid) }
        guard type == "assistant" else { return .unavailable }
        if row["error"] as? String == "rate_limit" {
            let params = row["apiErrorParams"] as? [String: Any]
            let info = params?["rate_limit_info"] as? [String: Any] ?? row["quotaLimits"] as? [String: Any]
            guard info?["status"] as? String == "rejected", info?["rateLimitType"] as? String == "five_hour",
                  let reset = info?["resetsAt"] as? NSNumber, CFGetTypeID(reset) != CFBooleanGetTypeID(),
                  reset.doubleValue.isFinite, reset.doubleValue > 0 else { return .unavailable }
            return .limited(LimitEvent(fingerprint: uuid, resetsAt: Date(timeIntervalSince1970: reset.doubleValue)))
        }
        guard row["error"] == nil, row["apiError"] == nil, let model = message?["model"] as? String, !model.isEmpty, model != "<synthetic>",
              let content = message?["content"] as? [[String: Any]], !content.isEmpty else { return .unavailable }
        return .assistant(uuid)
    }
}

@MainActor public final class AtomicStateStore: StateStore {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> ResumeState {
        guard FileManager.default.fileExists(atPath: url.path) else { return ResumeState() }
        return try JSONDecoder().decode(ResumeState.self, from: Data(contentsOf: url))
    }
    public func save(_ state: ResumeState) throws {
        let data = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
