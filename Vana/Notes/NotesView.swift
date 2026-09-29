import SwiftUI

/// 界面手里那一份笔记。盘上一写(工具、编辑器)就跟着重读。
@MainActor
@Observable
final class NoteBoard {
    let store: NoteStore
    private(set) var notes: [Note] = []
    private(set) var isLoaded = false
    private var observer: (any NSObjectProtocol)?

    init(store: NoteStore) {
        self.store = store
        let file = store.fileURL
        observer = NotificationCenter.default.addObserver(forName: .vanaNotesDidChange, object: nil, queue: .main) { [weak self] note in
            guard (note.object as? URL) == file else { return }
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        Task {
            notes = await store.all()
            isLoaded = true
        }
    }
}

/// 笔记与清单。自己写,或者在对话里让 Vana 记;这些内容只在需要时才会被读进对话。
struct NotesView: View {
    @State private var board: NoteBoard
    @State private var editing: Note?

    init(store: NoteStore = .shared) {
        _board = State(initialValue: NoteBoard(store: store))
    }

    var body: some View {
        List {
            if board.isLoaded && board.notes.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有笔记").font(.headline)
                        Text("在对话里说「帮我记一个购物清单：牛奶、鸡蛋」，Vana 会存在这里；也可以点右上角的加号自己写。这些内容只在需要时才会被读进对话。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            ForEach(board.notes) { note in
                Button {
                    editing = note
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).foregroundStyle(.primary)
                        Text([note.kind == .list ? String(localized: "清单") : String(localized: "笔记"), note.preview]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await board.store.delete(note.id) }
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("笔记与清单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新笔记", systemImage: "note.text") { create(.note) }
                    Button("新清单", systemImage: "checklist") { create(.list) }
                } label: {
                    Label("添加", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { note in
            NavigationStack {
                NoteEditor(note: note, store: board.store)
            }
        }
    }

    private func create(_ kind: Note.Kind) {
        let note = Note(kind: kind, title: kind == .list ? String(localized: "新清单") : String(localized: "新笔记"))
        Task {
            if let created = await board.store.add(note) { editing = created }
        }
    }
}

/// 一条笔记或清单的编辑器。关掉就存。
private struct NoteEditor: View {
    let note: Note
    let store: NoteStore

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: String
    @State private var items: [Note.Item]
    @State private var newItem = ""
    @State private var confirmDelete = false
    @State private var deleted = false

    init(note: Note, store: NoteStore) {
        self.note = note
        self.store = store
        _title = State(initialValue: note.title)
        _bodyText = State(initialValue: note.body)
        _items = State(initialValue: note.items)
    }

    var body: some View {
        Form {
            Section {
                TextField("标题", text: $title)
                    .font(.headline)
            }
            if note.kind == .list {
                Section {
                    ForEach($items) { $item in
                        HStack {
                            Button {
                                item.done.toggle()
                            } label: {
                                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.done ? Color.accentColor : .secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.done ? Text("取消勾选") : Text("勾选"))
                            TextField("条目", text: $item.text)
                                .strikethrough(item.done)
                                .foregroundStyle(item.done ? .secondary : .primary)
                        }
                    }
                    .onDelete { items.remove(atOffsets: $0) }
                    HStack {
                        Image(systemName: "plus").foregroundStyle(.secondary)
                        TextField("加一条", text: $newItem)
                            .onSubmit(addItem)
                            .submitLabel(.done)
                    }
                }
            }
            Section(note.kind == .list ? "备注" : "内容") {
                TextField("写点什么…", text: $bodyText, axis: .vertical)
                    .lineLimit(note.kind == .list ? 2...6 : 8...40)
            }
        }
        .navigationTitle(note.kind == .list ? "清单" : "笔记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .alert(note.kind == .list ? "删除这条清单？" : "删除这条笔记？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                deleted = true
                Task { await store.delete(note.id) }
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
        .onDisappear(perform: save)
    }

    private func addItem() {
        let text = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, items.count < Note.maxItems else { return }
        items.append(Note.Item(text: String(text.prefix(Note.maxItemCharacters))))
        newItem = ""
    }

    private func save() {
        guard !deleted else { return }
        if !newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addItem() }
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Note.maxTitle))
        let body = String(bodyText.prefix(Note.maxBody))
        let items = Array(items.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(Note.maxItems))
        guard title != note.title || body != note.body || items != note.items || title.isEmpty else { return }
        Task {
            await store.update(note.id) {
                if !title.isEmpty { $0.title = title }
                $0.body = body
                $0.items = items
            }
        }
    }
}
