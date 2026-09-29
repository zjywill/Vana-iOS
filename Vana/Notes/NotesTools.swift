import Foundation
import AgentRuntime

/// 笔记和清单的四个工具。**没有删除**:让模型删用户留着的东西,错一次就没了;删除只在界面上做。
/// 读是按需的(`list_notes` / `read_note`),不往 system 段里塞——他有一百条笔记也不该每次都背着。
enum NotesTools {
    static let save = "save_note"
    static let list = "list_notes"
    static let read = "read_note"
    static let update = "update_note"

    static let readTools: Set<String> = [list, read]

    private static func stringProperty(_ description: String) -> RuntimeJSONValue {
        .object(["type": "string", "description": .string(description)])
    }

    private static func stringList(_ description: String) -> RuntimeJSONValue {
        .object(["type": "array", "description": .string(description), "items": .object(["type": "string"])])
    }

    private static func schema(_ properties: [String: RuntimeJSONValue], required: [String] = []) -> RuntimeJSONValue {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false)
        ])
    }

    static let definitions: [CapabilityDefinition] = [
        CapabilityDefinition(
            name: save,
            description: "把用户要留着的一段文字或一张清单存成笔记（购物单、行李单、想法、草稿）。"
                + "给 items 就是清单（逐条可勾），否则是一段文字（body）。只在用户要你记下这类内容时用；"
                + "关于他这个人的长期事实（偏好、家人、习惯）不是笔记，用记忆。",
            inputSchema: schema([
                "title": stringProperty("标题，短一点"),
                "body": stringProperty("一段文字的内容，可选"),
                "items": stringList("清单的条目，可选；给了就存成清单")
            ], required: ["title"])
        ),
        CapabilityDefinition(
            name: list,
            description: "列出笔记和清单（最近动过的在前），带短编号。给 query 就只列标题或内容里含它的。要读或改某一条之前先用它拿编号。",
            inputSchema: schema(["query": stringProperty("只看含这个词的，可选")])
        ),
        CapabilityDefinition(
            name: read,
            description: "读一条笔记或清单的全部内容。按 list_notes 给的短编号指到那一条。",
            inputSchema: schema(["id": stringProperty("短编号")], required: ["id"])
        ),
        CapabilityDefinition(
            name: update,
            description: "改一条笔记或清单：改标题、整段改写（body）、在末尾追加一段（append）；"
                + "清单可以加条目、勾掉、取消勾、去掉条目（写条目原文的一部分即可）。按 list_notes 给的短编号指到那一条。",
            inputSchema: schema([
                "id": stringProperty("短编号"),
                "title": stringProperty("新标题，可选"),
                "body": stringProperty("整段改写成这段文字，可选（会覆盖原文）"),
                "append": stringProperty("在原文末尾追加的一段，可选"),
                "add_items": stringList("清单要加的条目"),
                "check_items": stringList("清单里要勾掉的条目"),
                "uncheck_items": stringList("清单里要取消勾选的条目"),
                "remove_items": stringList("清单里要去掉的条目")
            ], required: ["id"])
        )
    ]

    static func registry(store: NoteStore) -> CapabilityRegistry {
        CapabilityRegistry(definitions: definitions) { invocation in
            let input = try? RuntimeJSONValue.decode(from: invocation.input)
            switch invocation.name {
            case save: return await saveNote(store, input)
            case list: return await listNotes(store, input)
            case read: return await readNote(store, input)
            case update: return await updateNote(store, input)
            default: return .failure("不支持名为 \(invocation.name) 的工具。")
            }
        }
    }

    private static func string(_ input: RuntimeJSONValue?, _ key: String) -> String? {
        input?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strings(_ input: RuntimeJSONValue?, _ key: String) -> [String] {
        (input?[key]?.arrayValue ?? []).compactMap {
            $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    private static func saveNote(_ store: NoteStore, _ input: RuntimeJSONValue?) async -> CapabilityExecutionResult {
        let title = string(input, "title") ?? ""
        guard !title.isEmpty else { return .failure("save_note 需要标题 title。") }
        guard title.count <= Note.maxTitle else { return .failure("标题太长了，短一点。") }
        let items = strings(input, "items")
        let body = string(input, "body") ?? ""
        guard body.count <= Note.maxBody else { return .failure("内容太长了（最多 \(Note.maxBody) 字）。") }
        let note: Note
        if !items.isEmpty {
            guard items.count <= Note.maxItems else { return .failure("清单最多 \(Note.maxItems) 条。") }
            note = Note(kind: .list, title: title, body: body, items: items.map { Note.Item(text: String($0.prefix(Note.maxItemCharacters))) })
        } else {
            note = Note(kind: .note, title: title, body: body)
        }
        guard let saved = await store.add(note) else {
            return .failure("笔记已经有 \(Note.maxNotes) 条了，先让用户清理一些。")
        }
        return .success("已存成\(saved.kindWord)「\(title)」（编号 \(saved.handle)）。")
    }

    private static func listNotes(_ store: NoteStore, _ input: RuntimeJSONValue?) async -> CapabilityExecutionResult {
        let query = string(input, "query") ?? ""
        let notes = await store.all().filter { note in
            query.isEmpty
                || note.title.localizedCaseInsensitiveContains(query)
                || note.body.localizedCaseInsensitiveContains(query)
                || note.items.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
        guard !notes.isEmpty else {
            return .success(query.isEmpty ? "还没有笔记或清单。" : "没有含「\(query)」的笔记或清单。")
        }
        let lines = notes.prefix(30).map { note in
            "- \(note.handle) · \(note.kindWord) · \(note.title)" + (note.preview.isEmpty ? "" : " · \(note.preview)")
        }.joined(separator: "\n")
        let more = notes.count > 30 ? "\n（还有 \(notes.count - 30) 条没列出，用 query 缩小范围。）" : ""
        return .success(lines + more)
    }

    private static func readNote(_ store: NoteStore, _ input: RuntimeJSONValue?) async -> CapabilityExecutionResult {
        let handle = string(input, "id") ?? ""
        guard let note = await store.find(handle) else {
            return .failure("没有找到编号为 \(handle) 的笔记。先用 list_notes 拿编号。")
        }
        return .success(render(note))
    }

    static func render(_ note: Note) -> String {
        var lines = ["\(note.kindWord)：\(note.title)"]
        if !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append(note.body) }
        lines += note.items.map { "- [\($0.done ? "x" : " ")] \($0.text)" }
        return lines.joined(separator: "\n")
    }

    private static func updateNote(_ store: NoteStore, _ input: RuntimeJSONValue?) async -> CapabilityExecutionResult {
        let handle = string(input, "id") ?? ""
        guard let note = await store.find(handle) else {
            return .failure("没有找到编号为 \(handle) 的笔记。先用 list_notes 拿编号。")
        }
        let title = string(input, "title")?.nilIfEmpty
        if let title, title.count > Note.maxTitle { return .failure("标题太长了，短一点。") }
        let body = input?["body"]?.stringValue
        let append = string(input, "append")?.nilIfEmpty
        let add = strings(input, "add_items")
        let check = strings(input, "check_items")
        let uncheck = strings(input, "uncheck_items")
        let remove = strings(input, "remove_items")
        if !(add + check + uncheck + remove).isEmpty, note.kind != .list {
            return .failure("「\(note.title)」是一段文字，不是清单；改条目只能用在清单上。")
        }

        // 先在副本上算好,超了就一个字都不改。
        var next = note
        var missed: [String] = []
        next.items += add.map { Note.Item(text: String($0.prefix(Note.maxItemCharacters))) }
        func change(_ keys: [String], _ apply: (inout [Note.Item], Int) -> Void) {
            for key in keys {
                let lowered = key.lowercased()
                if let index = next.items.firstIndex(where: { $0.text.contains(key) || $0.id.uuidString.lowercased().hasPrefix(lowered) }) {
                    apply(&next.items, index)
                } else {
                    missed.append(key)
                }
            }
        }
        change(check) { $0[$1].done = true }
        change(uncheck) { $0[$1].done = false }
        change(remove) { $0.remove(at: $1) }
        var nextBody = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? note.body
        if let append { nextBody = nextBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? append : nextBody + "\n" + append }
        next.body = nextBody
        if let title { next.title = title }
        guard nextBody.count <= Note.maxBody, next.items.count <= Note.maxItems else {
            return .failure("这样改会超过长度上限（内容 \(Note.maxBody) 字、清单 \(Note.maxItems) 条），没有改。")
        }
        let planned = next
        guard let updated = await store.update(note.id, { $0 = planned }) else {
            return .failure("没有找到编号为 \(handle) 的笔记。先用 list_notes 拿编号。")
        }
        let tail = missed.isEmpty ? "" : "（没找到这几条：\(missed.joined(separator: "、"))）"
        return .success("已更新「\(updated.title)」\(tail)")
    }
}
