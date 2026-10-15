import SwiftUI
import FaciendaCompanion

struct TaskListView: View {
    let title: String
    let items: [CompanionItem]
    let allItems: [CompanionItem]
    let emptyTitle: String
    let emptyDetail: String
    let symbol: String

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: symbol, description: Text(emptyDetail))
            } else {
                List(items) { item in TaskRow(item: item) }.listStyle(.insetGrouped)
            }
        }
        .background(PhoneStyle.canvas)
        .navigationTitle(title)
        .navigationDestination(for: String.self) { id in
            if let item = allItems.first(where: { $0.id == id }) { TaskReadView(item: item) }
        }
    }
}

struct TaskBrowserView: View {
    let items: [CompanionItem]
    @State private var search = ""
    private var visibleItems: [CompanionItem] {
        items.filter {
            $0.category != .processing && (search.isEmpty || $0.title.localizedStandardContains(search)
                || $0.detail.localizedStandardContains(search) || $0.status.localizedStandardContains(search))
        }
    }

    var body: some View {
        List {
            ForEach(CompanionSection.allCases.filter { $0 != .processing }) { category in
                let matches = visibleItems.filter { $0.category == category }
                if !matches.isEmpty {
                    Section { ForEach(matches) { item in TaskRow(item: item) } }
                    header: { Label(category.title, systemImage: category.symbol) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if visibleItems.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("Nothing to check yet.", systemImage: "tray", description: Text("Tasks ready for review, waiting, scheduled, and done appear here."))
                } else { ContentUnavailableView.search(text: search) }
            }
        }
        .searchable(text: $search, prompt: "Search tasks")
        .background(PhoneStyle.canvas)
        .navigationTitle("Tasks")
        .navigationDestination(for: String.self) { id in
            if let item = items.first(where: { $0.id == id }) { TaskReadView(item: item) }
        }
    }
}

private struct TaskRow: View {
    let item: CompanionItem
    var body: some View {
        NavigationLink(value: item.id) {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(3)
                Label(item.status, systemImage: item.category.symbol)
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 10)
        }
    }
}

private struct TaskReadView: View {
    let item: CompanionItem
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Label(item.status, systemImage: item.category.symbol)
                    .font(.callout).foregroundStyle(PhoneStyle.accent)
                if !item.detail.isEmpty { Text(item.detail).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("Continue this task in Facienda on your Mac.").font(.footnote).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .background(PhoneStyle.canvas)
        .navigationTitle("Task").navigationBarTitleDisplayMode(.inline)
    }
}
