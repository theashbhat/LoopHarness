//
//  OpenClawSkillStore.swift
//  Loop
//
//  Lists + edits the skills that live in an OpenClaw VM's workspace
//  (`<workspace>/skills/<name>/SKILL.md`). When the user joins a remote
//  execution backend the Skills tab is sourced from here instead of the
//  on-device `DynamicSkillRegistry`.
//
//  VM skills use the Claude Code / openclaw layout: a folder per skill holding a
//  `SKILL.md` whose YAML frontmatter carries `name` + `description` (and a
//  markdown body of instructions). This is a different shape from the iOS app's
//  `skill.json` + `skill.js` `DynamicSkillRegistry` skills, so we parse the
//  frontmatter directly. Because SKILL.md is markdown, editing reuses the
//  existing markdown editor.
//
//  This store does NOT execute anything: the agent runs on the VM (a VM-side
//  daemon), so remote skills are browsed/edited here and run there. Local
//  `DynamicSkillRegistry` execution is used only when the active backend is
//  Local. We layer on `OpenClawFileStore` for all SSH I/O rather than
//  re-implementing the transport.
//
//  Note: the on-VM directory is lowercase `skills`, whereas the on-device folder
//  is `Skills`.
//
//  Pure Foundation so it compiles for the iOS, macOS, and visionOS targets.
//

import Foundation
import os

private let openClawSkillLog = Logger(subsystem: "com.bhat.intel", category: "OpenClawSkills")

/// A skill read from the VM (Claude Code SKILL.md format). Browse/edit record,
/// no runtime — the VM executes its own skills. `markdown` is the full SKILL.md
/// so the editor round-trips it; `markdownRelPath` points the editor at it.
struct RemoteSkill: Equatable {
    let name: String
    let description: String
    /// Full SKILL.md contents (frontmatter + body).
    let markdown: String
    /// Workspace-relative path to the SKILL.md file (e.g. `skills/foo/SKILL.md`).
    let markdownRelPath: String
    /// Workspace-relative skill folder (e.g. `skills/foo`).
    let folderRelPath: String
}

final class OpenClawSkillStore {

    /// On-VM directory under the workspace root that holds skill folders.
    static let skillsFolderName = "skills"

    let backendID: String
    private let files: OpenClawFileStore

    init(backendID: String, config: OpenClawConfig) {
        self.backendID = backendID
        self.files = OpenClawFileStore(backendID: backendID, config: config)
    }

    /// Reuse this store's file backend for the Files tab too, so both share one
    /// listing cache and config.
    var fileStore: OpenClawFileStore { files }

    func updateConfig(_ newConfig: OpenClawConfig) {
        files.updateConfig(newConfig)
    }

    // MARK: - Operations

    /// List every skill in `<workspace>/skills` in a single SSH round trip,
    /// parsing each folder's SKILL.md frontmatter for name + description. Folders
    /// without a readable SKILL.md (tolerating lowercase `skill.md`) are skipped.
    func listSkills() async throws -> [RemoteSkill] {
        let manifests = try await files.loadManifests(
            inSubfoldersOf: Self.skillsFolderName, fileNames: ["SKILL.md", "skill.md"])

        var skills: [RemoteSkill] = manifests.map { m in
            let front = Self.parseFrontmatter(m.text)
            let folderName = (m.folderRelPath as NSString).lastPathComponent
            let name = front["name"]?.isEmpty == false ? front["name"]! : folderName
            let desc = front["description"] ?? ""
            return RemoteSkill(name: name, description: desc, markdown: m.text,
                               markdownRelPath: m.fileRelPath, folderRelPath: m.folderRelPath)
        }
        skills.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return skills
    }

    /// Delete a skill folder (recursive) by its workspace-relative path.
    func deleteSkill(folderRelPath: String) async throws {
        try await files.delete(folderRelPath)
    }

    // MARK: - Frontmatter

    /// Parse the leading `---`-delimited YAML frontmatter into a flat
    /// string→string map. Only top-level `key: value` lines are read (enough for
    /// `name`/`description`); surrounding quotes are stripped. Returns empty if
    /// the text doesn't start with a frontmatter block.
    static func parseFrontmatter(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else { return result }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            // Skip indented (nested) keys — we only want top-level fields.
            guard line.first != " ", line.first != "\t" else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
