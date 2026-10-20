import SwiftUI

struct LibraryPane: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            if app.documents.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("文書がありません")
                        .font(.headline)
                    Text("画像や PDF をここにドロップするか、\n取り込みボタンから追加してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("取り込み…") { app.importFromPanel() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(selection: $app.selectedDocumentID) {
                    Section("最近の文書") {
                        ForEach(app.documents) { document in
                            LibraryRow(document: document)
                                .tag(document.id)
                                .contextMenu {
                                    Button("この文書を削除", role: .destructive) {
                                        app.selectedDocumentID = document.id
                                        app.deleteSelectedDocument()
                                    }
                                }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            HStack {
                Button {
                    app.importFromPanel()
                } label: {
                    Label("取り込み", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("\(app.documents.count) 文書")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

private struct LibraryRow: View {
    let document: DocumentRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: document.kind == "pdf" ? "doc.richtext" : "photo")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .lineLimit(2)
                    .font(.body)
                HStack(spacing: 6) {
                    Text("\(document.pageCount) ページ")
                    if document.hasResults {
                        Text("・ \(document.completedPages)/\(document.pageCount) 完了")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}
