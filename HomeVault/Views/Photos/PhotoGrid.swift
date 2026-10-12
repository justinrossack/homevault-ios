import SwiftUI

/// Raster aus Vorschaubildern, optional nach Monaten gruppiert.
struct PhotoGrid: View {
    @Binding var entries: [Entry]
    var sectioned: Bool
    var onReachEnd: (() -> Void)?

    @State private var viewing: Viewing?

    struct Viewing: Identifiable {
        let index: Int
        var id: Int { index }
    }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 2)]

    private struct Section: Identifiable {
        let id: String
        let title: String
        let indices: Range<Int>
    }

    private var sections: [Section] {
        guard sectioned else {
            return [Section(id: "all", title: "", indices: entries.indices)]
        }
        var out: [Section] = []
        var start = 0
        var key = ""
        let cal = Calendar.current
        for (i, e) in entries.enumerated() {
            let c = cal.dateComponents([.year, .month], from: e.date)
            let k = "\(c.year ?? 0)-\(c.month ?? 0)"
            if k != key {
                if i > start {
                    out.append(Section(id: key, title: Format.monthYear.string(from: entries[start].date), indices: start..<i))
                }
                key = k
                start = i
            }
        }
        if start < entries.count {
            out.append(Section(id: key, title: Format.monthYear.string(from: entries[start].date), indices: start..<entries.count))
        }
        return out
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2, pinnedViews: sectioned ? [.sectionHeaders] : []) {
                ForEach(sections) { section in
                    SwiftUI.Section {
                        ForEach(section.indices, id: \.self) { i in
                            cell(entries[i])
                                .onTapGesture { viewing = Viewing(index: i) }
                                .onAppear {
                                    if i == entries.count - 1 { onReachEnd?() }
                                }
                        }
                    } header: {
                        if sectioned {
                            Text(section.title)
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                .background(.bar)
                        }
                    }
                }
            }
        }
        .fullScreenCover(item: $viewing) { v in
            PhotoViewer(entries: $entries, index: v.index)
        }
    }

    private func cell(_ e: Entry) -> some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay { RemoteImage(path: e.path) }
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if e.isVideo { Image(systemName: "play.fill") }
                    if e.isLive { Image(systemName: "livephoto") }
                    Spacer()
                    if e.isFavorite { Image(systemName: "heart.fill") }
                }
                .font(.caption2)
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .padding(5)
            }
    }
}
