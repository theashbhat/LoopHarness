//
//  OpenClawFileStore.swift
//  Loop
//
//  Browse + edit the workspace of an OpenClaw VM over SSH. When the user joins
//  a remote execution backend the Files tab is sourced from here instead of the
//  on-device `Workspace`, so files shown are the ones the VM-side agent actually
//  reads and writes.
//
//  Transport mirrors `OpenClawConversationStore`: we shell out over `SSHSkill`,
//  base64-encoding file bytes both directions so arbitrary (incl. binary)
//  content can't corrupt the stream or break shell quoting. Paths flow through
//  `OpenClawConversationStore.shQuote` and the shared `workspaceDirExpression`
//  so spaces/tildes are handled once. Listings are lazy per folder (matching the
//  sidebar's expand-on-tap tree) and cached in memory for instant re-expansion.
//
//  Unlike the conversation store there is NO offline write queue: a file the
//  user explicitly saves must fail loudly if the VM is unreachable — there's no
//  safe merge story for arbitrary files, so silently queueing a stale overwrite
//  would be worse than surfacing the error.
//
//  Pure Foundation so it compiles for the iOS, macOS, and visionOS targets.
//

import Foundation
import os

private let openClawFileLog = Logger(subsystem: "com.bhat.intel", category: "OpenClawFiles")

/// One entry in a remote directory listing. `relativePath` is workspace-rooted
/// (no leading slash) so it can be handed straight back to `list`/`read`/`write`.
struct RemoteFileEntry: Equatable {
    let name: String
    let relativePath: String
    let isDirectory: Bool
}

enum OpenClawFileError: LocalizedError {
    case notConfigured
    case invalidPath(String)
    case fileTooLarge(Int)
    case commandFailed(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notConfigured:        return "This backend isn't configured."
        case .invalidPath(let p):   return "Invalid path: \(p)"
        case .fileTooLarge(let n):  return "File is \(n) bytes — over the \(Workspace.maxFileBytes)-byte cap."
        case .commandFailed(let d): return "The VM couldn't complete the request: \(d)"
        case .unreadable:           return "Couldn't decode the file from the VM."
        }
    }
}

final class OpenClawFileStore {

    let backendID: String
    private(set) var config: OpenClawConfig

    /// In-memory cache of directory listings keyed by workspace-relative path
    /// (root is ""). Lets re-expanding a folder render instantly; invalidated on
    /// any write into a folder and whenever the backend list changes.
    private let cacheLock = NSLock()
    private var listingCache: [String: [RemoteFileEntry]] = [:]

    init(backendID: String, config: OpenClawConfig) {
        self.backendID = backendID
        self.config = config
    }

    /// Push edited connection settings without recreating the store (keeps the
    /// listing cache). Clears the cache when the endpoint actually changed.
    func updateConfig(_ newConfig: OpenClawConfig) {
        guard newConfig != config else { return }
        config = newConfig
        invalidateCache()
    }

    func invalidateCache() {
        cacheLock.lock(); listingCache.removeAll(); cacheLock.unlock()
    }

    /// Cached listing for a folder, if one was already fetched. Synchronous —
    /// lets the sidebar render an already-expanded folder without awaiting SSH.
    func cachedListing(_ relPath: String) -> [RemoteFileEntry]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return listingCache[normalize(relPath)]
    }

    // MARK: - Operations

    /// Non-recursive listing of one folder. Folders first, then files, each
    /// case-insensitively sorted. Results are cached.
    func list(_ relPath: String = "") async throws -> [RemoteFileEntry] {
        let rel = try validated(relPath)
        let dir = pathExpression(rel)
        // Portable, non-recursive listing with a type marker per entry. `* .[!.]*`
        // covers dotfiles too; the `[ -e ]` guard drops the literal globs when a
        // pattern matches nothing.
        let cmd = """
        cd \(dir) 2>/dev/null && for f in * .[!.]*; do [ -e "$f" ] || continue; if [ -d "$f" ]; then echo "D:$f"; else echo "F:$f"; fi; done
        """
        let result = try await run(cmd, timeout: 20)
        guard result.exitCode == 0 else {
            throw OpenClawFileError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var entries: [RemoteFileEntry] = []
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count > 2 else { continue }
            let marker = line.prefix(2)
            let name = String(line.dropFirst(2))
            guard name != "." && name != ".." else { continue }
            let childRel = rel.isEmpty ? name : rel + "/" + name
            if marker == "D:" {
                entries.append(RemoteFileEntry(name: name, relativePath: childRel, isDirectory: true))
            } else if marker == "F:" {
                entries.append(RemoteFileEntry(name: name, relativePath: childRel, isDirectory: false))
            }
        }
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        cacheLock.lock(); listingCache[rel] = entries; cacheLock.unlock()
        return entries
    }

    /// Read a file's bytes. Size-guarded (1 MB, matching the on-device
    /// workspace): the check runs shell-side so an oversized file is reported
    /// (and never base64-transferred) in a single round trip. base64 keeps
    /// binary content stream-safe.
    func read(_ relPath: String, maxBytes: Int = Workspace.maxFileBytes) async throws -> Data {
        let rel = try validated(relPath)
        let file = pathExpression(rel)
        let cap = maxBytes
        // Decide on the VM: emit OVERSIZE:<n> if too big, otherwise the sentinel
        // followed by the base64 body — so we never pull bytes we'll reject.
        let cmd = "sz=$(wc -c < \(file)) && if [ \"$sz\" -gt \(cap) ]; then echo \"OVERSIZE:$sz\"; else echo ===OCSIZE===; base64 \(file); fi"
        let result = try await run(cmd, timeout: 30)
        guard result.exitCode == 0 else {
            throw OpenClawFileError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let stdout = result.stdout
        if let range = stdout.range(of: "OVERSIZE:") {
            let n = Int(stdout[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? cap + 1
            throw OpenClawFileError.fileTooLarge(n)
        }
        let parts = stdout.components(separatedBy: "===OCSIZE===")
        guard parts.count == 2 else { throw OpenClawFileError.unreadable }
        let cleaned = parts[1]
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let data = Data(base64Encoded: cleaned) else { throw OpenClawFileError.unreadable }
        return data
    }

    /// Read a file by an ARBITRARY VM path — absolute (`/…`), home-relative (`~/…`),
    /// or workspace-relative — bypassing the workspace-containment check `read` uses.
    /// For rendering an attachment the agent named by full path, which may live
    /// outside the workspace (e.g. `/home/tony/out/chart.png`). Same size-guarded,
    /// base64-framed transfer as `read`. The VM is the user's own, so reading a path
    /// the agent surfaced is within this app's trust model; the size cap still applies.
    func readAnyPath(_ path: String, maxBytes: Int = Workspace.maxFileBytes) async throws -> Data {
        let file = Self.shellPathExpression(path, config: config)
        let cap = maxBytes
        // `MISSING` distinguishes "no such file" (empty `wc`) from a real read so a
        // bad guess fails fast instead of returning an empty/garbage body.
        let cmd = "sz=$(wc -c < \(file) 2>/dev/null); if [ -z \"$sz\" ]; then echo MISSING; elif [ \"$sz\" -gt \(cap) ]; then echo \"OVERSIZE:$sz\"; else echo ===OCSIZE===; base64 \(file); fi"
        let result = try await run(cmd, timeout: 30)
        let stdout = result.stdout
        if stdout.contains("MISSING") { throw OpenClawFileError.unreadable }
        if let range = stdout.range(of: "OVERSIZE:") {
            let n = Int(stdout[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? cap + 1
            throw OpenClawFileError.fileTooLarge(n)
        }
        let parts = stdout.components(separatedBy: "===OCSIZE===")
        guard parts.count == 2 else { throw OpenClawFileError.unreadable }
        let cleaned = parts[1]
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let data = Data(base64Encoded: cleaned) else { throw OpenClawFileError.unreadable }
        return data
    }

    /// A shell expression for an arbitrary path: expands a leading `~`/`~/` to
    /// `$HOME`, quotes an absolute path as-is, and treats anything else as
    /// workspace-relative. Mirrors `workspaceDirExpression`'s tilde handling.
    static func shellPathExpression(_ path: String, config: OpenClawConfig) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") {
            return "\"$HOME\"/" + OpenClawConversationStore.shQuote(String(path.dropFirst(2)))
        }
        if path.hasPrefix("/") { return OpenClawConversationStore.shQuote(path) }
        let base = OpenClawConversationStore.workspaceDirExpression(for: config)
        return base + "/" + OpenClawConversationStore.shQuote(path)
    }

    /// Locate the first file matching `name` anywhere under the workspace, returning
    /// its workspace-relative path (GNU find `-printf '%P'`). Used to resolve a bare
    /// filename the agent referenced (e.g. `gandalf-engineer-square.png`) to a real
    /// path for inline media, since the agent rarely says where the file lives.
    /// Returns nil when nothing matches.
    func findFile(named name: String) async throws -> String? {
        guard config.isConfigured else { return nil }
        let dir = OpenClawConversationStore.workspaceDirExpression(for: config)
        let q = OpenClawConversationStore.shQuote(name)
        // `-printf '%P'` prints the path relative to the workspace root; `head -1`
        // stops at the first hit. Stderr is dropped so a permission-denied dir in a
        // large tree doesn't pollute the result.
        let cmd = "find \(dir) -type f -name \(q) -printf '%P\\n' 2>/dev/null | head -1"
        let result = try await run(cmd, timeout: 20)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Write bytes to a file, creating parent directories as needed. Throws
    /// loudly on failure (no offline queue) — the caller surfaces the error.
    func write(_ data: Data, to relPath: String) async throws {
        let rel = try validated(relPath)
        let file = pathExpression(rel)
        let parent = parentExpression(rel)
        let b64 = data.base64EncodedString()
        let cmd = "mkdir -p \(parent) && printf %s \(OpenClawConversationStore.shQuote(b64)) | base64 -d > \(file)"
        let result = try await run(cmd, timeout: 30)
        guard result.exitCode == 0 else {
            throw OpenClawFileError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // The folder this file lives in changed — drop its cached listing.
        cacheLock.lock(); listingCache[parentRel(rel)] = nil; cacheLock.unlock()
    }

    /// A manifest file found in an immediate subfolder.
    struct SubfolderFile {
        let folderRelPath: String
        let fileRelPath: String
        let text: String
    }

    /// Read one manifest file (trying `fileNames` in order) from every immediate
    /// subfolder of `dirRelPath`, in a SINGLE base64-framed SSH round trip —
    /// rather than one read per folder. Subfolders without any of the files are
    /// skipped. Used to load every skill's SKILL.md at once. Returns [] if the
    /// directory doesn't exist.
    func loadManifests(inSubfoldersOf dirRelPath: String, fileNames: [String]) async throws -> [SubfolderFile] {
        let rel = try validated(dirRelPath)
        let dirExpr = pathExpression(rel)
        // Build the SKILL.md / skill.md (etc.) lookup chain shell-side.
        var matcher = "f=\"\""
        for (i, name) in fileNames.enumerated() {
            let q = OpenClawConversationStore.shQuote(name)
            let kw = i == 0 ? "if" : "elif"
            matcher += "; \(kw) [ -f \"$n\"/\(q) ]; then f=\"$n\"/\(q)"
        }
        matcher += "; fi"
        // Frame each match as `===OCMANIFEST:<folder>/<file>===` + base64 body.
        let cmd = """
        cd \(dirExpr) 2>/dev/null && for d in */ .*/; do [ -d "$d" ] || continue; n="${d%/}"; [ "$n" = "." ] && continue; [ "$n" = ".." ] && continue; \(matcher); [ -n "$f" ] || continue; echo "===OCMANIFEST:$f==="; base64 "$f"; done
        """
        let result = try await run(cmd, timeout: 30)
        // A missing skills dir makes `cd` fail (nonzero exit, empty stdout); that
        // is "no skills", not an error.
        guard result.exitCode == 0 else { return [] }
        return Self.parseManifestFraming(result.stdout, dirRelPath: rel)
    }

    /// Parse the `===OCMANIFEST:<folder>/<file>===` + base64 framing emitted by
    /// `loadManifests`. `static` for unit-testability.
    static func parseManifestFraming(_ output: String, dirRelPath: String) -> [SubfolderFile] {
        var results: [SubfolderFile] = []
        var currentFileInDir: String?
        var b64 = ""

        func flush() {
            guard let fileInDir = currentFileInDir else { return }
            let cleaned = b64.replacingOccurrences(of: "\n", with: "")
                             .replacingOccurrences(of: "\r", with: "")
                             .replacingOccurrences(of: " ", with: "")
            if let data = Data(base64Encoded: cleaned),
               let text = String(data: data, encoding: .utf8) {
                let fileRel = dirRelPath.isEmpty ? fileInDir : dirRelPath + "/" + fileInDir
                let folderInDir = (fileInDir as NSString).deletingLastPathComponent
                let folderRel = dirRelPath.isEmpty ? folderInDir : dirRelPath + "/" + folderInDir
                results.append(SubfolderFile(folderRelPath: folderRel, fileRelPath: fileRel, text: text))
            }
            currentFileInDir = nil
            b64 = ""
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("===OCMANIFEST:") && line.hasSuffix("===") {
                flush()
                currentFileInDir = String(line.dropFirst("===OCMANIFEST:".count).dropLast(3))
            } else {
                b64 += line
            }
        }
        flush()
        return results
    }

    /// Remove a file or directory (recursive). Used by skill deletion.
    func delete(_ relPath: String) async throws {
        let rel = try validated(relPath)
        let target = pathExpression(rel)
        let result = try await run("rm -rf \(target)", timeout: 20)
        guard result.exitCode == 0 else {
            throw OpenClawFileError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        cacheLock.lock(); listingCache[parentRel(rel)] = nil; cacheLock.unlock()
    }

    // MARK: - Helpers

    /// `<workspace>/<rel>` as a shell expression. Single-quoting the relative
    /// path keeps spaces safe; embedded `/` still acts as a path separator.
    private func pathExpression(_ rel: String) -> String {
        let base = OpenClawConversationStore.workspaceDirExpression(for: config)
        return rel.isEmpty ? base : base + "/" + OpenClawConversationStore.shQuote(rel)
    }

    private func parentExpression(_ rel: String) -> String {
        pathExpression(parentRel(rel))
    }

    private func parentRel(_ rel: String) -> String {
        guard let slash = rel.lastIndex(of: "/") else { return "" }
        return String(rel[..<slash])
    }

    private func normalize(_ relPath: String) -> String {
        relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Reject paths that could escape the workspace (`..` components, absolute
    /// paths). The SSH analogue of `Workspace.resolve`'s containment check.
    private func validated(_ relPath: String) throws -> String {
        let rel = normalize(relPath)
        guard !rel.hasPrefix("/") else { throw OpenClawFileError.invalidPath(relPath) }
        let components = rel.split(separator: "/")
        guard !components.contains("..") else { throw OpenClawFileError.invalidPath(relPath) }
        return rel
    }

    private func run(_ command: String, timeout: Double) async throws -> SSHSkill.CommandResult {
        guard config.isConfigured else { throw OpenClawFileError.notConfigured }
        do {
            return try await SSHSkill.shared.runCommand(command, on: config.sshConfig, timeout: timeout)
        } catch {
            openClawFileLog.error("file command failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
