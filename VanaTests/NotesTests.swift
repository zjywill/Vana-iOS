import Foundation
import Testing
import AgentRuntime

@testable import Vana

@Suite("Notes")
struct NotesTests {

    /// 临时目录。**不许用 `.shared`**。
    private func withStore(_ body: (NoteStore) async throws -> Void) async rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "vana-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(NoteStore(directory: directory))
    }

    private func call(_ store: NoteStore, _ name: String, _ input: String) async -> CapabilityExecutionResult {
        await NotesTools.registry(store: store).execute(CapabilityInvocation(toolCallId: "1", name: name, input: input))
    }

    @Test("saving with items makes a list, without makes a note")
    func saveKinds() async {
        await withStore { store in
            let list = await call(store, NotesTools.save, #"{"title":"购物","items":["牛奶","鸡蛋"]}"#)
            #expect(list.output.text.contains("已存成清单"))
            let note = await call(store, NotesTools.save, #"{"title":"想法","body":"周末去爬山"}"#)
            #expect(note.output.text.contains("已存成笔记"))
            let all = await store.all()
            #expect(all.count == 2)
            #expect(all.first { $0.title == "购物" }?.items.map(\.text) == ["牛奶", "鸡蛋"])
        }
    }

    @Test("items can be added, checked and removed by part of their text")
    func updateList() async throws {
        try await withStore { store in
            _ = await call(store, NotesTools.save, #"{"title":"购物","items":["全脂牛奶","鸡蛋"]}"#)
            let handle = try #require(await store.all().first?.handle)
            let result = await call(
                store, NotesTools.update,
                #"{"id":"\#(handle)","add_items":["面包"],"check_items":["牛奶"],"remove_items":["鸡蛋","香蕉"]}"#
            )
            #expect(!result.isError)
            #expect(result.output.text.contains("没找到这几条：香蕉"))
            let note = try #require(await store.find(handle))
            #expect(note.items.map(\.text) == ["全脂牛奶", "面包"])
            #expect(note.items.first?.done == true)
            let read = await call(store, NotesTools.read, #"{"id":"\#(handle)"}"#)
            #expect(read.output.text.contains("- [x] 全脂牛奶"))
            #expect(read.output.text.contains("- [ ] 面包"))
        }
    }

    @Test("item edits on a plain note are refused, and nothing changes")
    func itemsOnlyOnLists() async throws {
        try await withStore { store in
            _ = await call(store, NotesTools.save, #"{"title":"想法","body":"原文"}"#)
            let note = try #require(await store.all().first)
            let result = await call(store, NotesTools.update, #"{"id":"\#(note.handle)","add_items":["x"],"append":"新的"}"#)
            #expect(result.isError)
            #expect(await store.find(note.handle)?.body == "原文")
        }
    }

    @Test("append goes to the end; list filters by query")
    func appendAndQuery() async throws {
        try await withStore { store in
            _ = await call(store, NotesTools.save, #"{"title":"草稿","body":"第一行"}"#)
            _ = await call(store, NotesTools.save, #"{"title":"行李","items":["护照"]}"#)
            let draft = try #require(await store.all().first { $0.title == "草稿" })
            _ = await call(store, NotesTools.update, #"{"id":"\#(draft.handle)","append":"第二行"}"#)
            #expect(await store.find(draft.handle)?.body == "第一行\n第二行")
            let listed = await call(store, NotesTools.list, #"{"query":"护照"}"#)
            #expect(listed.output.text.contains("行李"))
            #expect(!listed.output.text.contains("草稿"))
        }
    }

    /// 让模型删用户留着的东西,错一次就没了。
    @Test("there is no delete tool")
    func noDeleteTool() {
        let names = NotesTools.definitions.map(\.name)
        #expect(names == [NotesTools.save, NotesTools.list, NotesTools.read, NotesTools.update])
        #expect(!names.contains { $0.contains("delete") })
    }

    @Test("unknown entries in notes.json survive a write")
    func keepsForeignEntries() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "vana-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: NoteStore.fileName)
        try Data(#"[{"future":"kind"}]"#.utf8).write(to: file)

        let store = NoteStore(directory: directory)
        _ = await store.add(Note(kind: .note, title: "新的"))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("future"))
        #expect(text.contains("新的"))
    }

    /// 笔记在前台挂,后台和不留痕的写都不挂。
    @Test("notes mount in the foreground only; private sessions only read")
    func mounting() {
        let (stores, root) = TestAssembly.freshStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = TestAssembly.environment(stores: stores, notes: stores.notes)

        let foreground = TestAssembly.toolNames(TestAssembly.engine(environment))
        #expect(foreground.contains(NotesTools.save))
        let background = TestAssembly.toolNames(TestAssembly.engine(environment, route: .background))
        #expect(!background.contains(NotesTools.list))
        let privateNames = TestAssembly.toolNames(TestAssembly.engine(environment, isPrivate: true))
        #expect(privateNames.contains(NotesTools.list))
        #expect(!privateNames.contains(NotesTools.save))
        #expect(!privateNames.contains(NotesTools.update))
    }
}
