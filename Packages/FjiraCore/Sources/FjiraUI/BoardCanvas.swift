import AppKit
import FjiraCore
import SwiftUI

public struct BoardCanvas: View {
    private let columns: [BoardColumn]
    private let lanes: [BoardLane]
    @State private var collapsedLanes = Set<Int>()
    @Namespace private var horizontalViewport
    private let images: [String: NSImage]
    private let selectedKey: String?
    private let openIssue: (JiraIssue) -> Void
    private let loadMore: (Int) -> Void
    private let loadingColumnID: Int?
    private let columnErrors: [Int: String]
    private let canLoadMore: Bool
    private let automaticallyLoadMore: Bool

    public init(columns: [BoardColumn], lanes: [BoardLane] = [], images: [String: NSImage], selectedKey: String?,
                loadingColumnID: Int? = nil, columnErrors: [Int: String] = [:],
                canLoadMore: Bool = true, automaticallyLoadMore: Bool = true,
                loadMore: @escaping (Int) -> Void = { _ in }, openIssue: @escaping (JiraIssue) -> Void) {
        self.columns = columns
        self.lanes = lanes
        self.images = images
        self.selectedKey = selectedKey
        self.openIssue = openIssue
        self.loadMore = loadMore
        self.loadingColumnID = loadingColumnID
        self.columnErrors = columnErrors
        self.canLoadMore = canLoadMore
        self.automaticallyLoadMore = automaticallyLoadMore
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = columnWidth(available: geometry.size.width)
            let headerWidth = max(0, min(geometry.size.width, canvasWidth(columnWidth: width)) - 24)
            let viewport = horizontalViewport
            let visibleLanes = lanes.filter { !$0.isEmpty }
            let expandedIndices = visibleLanes.indices.filter { !collapsedLanes.contains(visibleLanes[$0].id) }
            let fillingLane = expandedIndices.count == 1 ? expandedIndices.first : nil
            ScrollView(.horizontal) {
                if lanes.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(columns) { column in
                            columnView(column)
                                .frame(width: width, height: max(0, geometry.size.height - 24))
                        }
                    }
                    .padding(12)
                } else {
                    ScrollView(.vertical) {
                        // Keep lane containers stable while the board moves. Lazy lane layout
                        // repeatedly remeasures their nested column scroll views at the viewport edge.
                        // Individual card lists remain lazy and paginated.
                        BoardSwimlaneLayout(viewportHeight: max(0, geometry.size.height - 24), fillingLane: fillingLane) {
                            ForEach(visibleLanes) { lane in
                                VStack(alignment: .leading, spacing: 10) {
                                    Button {
                                        if collapsedLanes.contains(lane.id) { collapsedLanes.remove(lane.id) }
                                        else { collapsedLanes.insert(lane.id) }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: collapsedLanes.contains(lane.id) ? "chevron.right" : "chevron.down")
                                                .font(.system(size: 11, weight: .semibold)).frame(width: 14)
                                            Text(lane.name).font(.headline)
                                            Text(lane.total.map { "\($0) issues" } ?? "\(lane.columns.reduce(0) { $0 + $1.issues.count }) downloaded")
                                                .font(.caption).foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 4).padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: headerWidth, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .visualEffect { content, geometry in
                                        // Counter horizontal scrolling without rebuilding the board on every frame.
                                        content.offset(x: 12 - geometry.frame(in: .named(viewport)).minX)
                                    }
                                    .accessibilityValue(collapsedLanes.contains(lane.id) ? "Collapsed" : "Expanded")
                                    if !collapsedLanes.contains(lane.id) {
                                        HStack(alignment: .top, spacing: 12) {
                                            ForEach(lane.columns) { column in
                                                columnView(column)
                                                    .frame(width: width, height: fillingLane == nil ? laneHeight(lane, available: geometry.size.height) : nil)
                                            }
                                        }
                                    }
                                }
                            }
                            if lanes.allSatisfy(\.isEmpty) {
                                Text("No matching issues").foregroundStyle(.secondary).padding(24)
                            }
                        }
                        .padding(12)
                    }
                    .frame(width: canvasWidth(columnWidth: width), height: geometry.size.height)
                }
            }
            .coordinateSpace(name: viewport)
        }
    }

    private var columnCount: Int { lanes.first?.columns.count ?? columns.count }

    private func columnWidth(available: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, columnCount))
        return max(250, min(360, (available - 24 - (count - 1) * 12) / count))
    }

    private func canvasWidth(columnWidth: CGFloat) -> CGFloat {
        CGFloat(columnCount) * columnWidth + CGFloat(max(0, columnCount - 1)) * 12 + 24
    }

    private func laneHeight(_ lane: BoardLane, available: CGFloat) -> CGFloat {
        // Small lanes stay compact; larger lanes keep bounded, independently scrolling columns.
        let cards = lane.columns.map { $0.issues.count }.max() ?? 0
        return min(max(240, available * 0.72), max(150, CGFloat(min(cards, 4)) * 105 + 60))
    }

    private func columnView(_ column: BoardColumn) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(column.configuration.name.uppercased())
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(column.total.map(String.init) ?? String(column.issues.count))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(12)
            Divider().padding(.horizontal, 10)
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) { columnContents(column) }
                .padding(8)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(column.configuration.name)
    }

    @ViewBuilder
    private func columnContents(_ column: BoardColumn) -> some View {
        ForEach(column.issues) { issue in card(issue) }
        if column.hasMore {
            paginationFooter(column).id(column.issues.count)
        }
        if column.issues.isEmpty && !column.hasMore {
            Text("No issues").font(.callout).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity).padding(.vertical, 28)
        }
    }

    private func paginationFooter(_ column: BoardColumn) -> some View {
        VStack(spacing: 8) {
            Text(column.total.map { "\(column.issues.count) of \($0)" } ?? "\(column.issues.count) cards")
                .font(.caption).foregroundStyle(.secondary)
            if column.containsOlderIssues {
                Text("Includes previously downloaded cards").font(.caption2).foregroundStyle(.secondary)
            }
            if loadingColumnID == column.id {
                ProgressView().controlSize(.small)
            } else {
                Button(columnErrors[column.id] == nil ? "Load more" : "Retry loading more") { loadMore(column.id) }
                    .disabled(!canLoadMore || loadingColumnID != nil)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .onAppear {
            if automaticallyLoadMore && canLoadMore && loadingColumnID == nil && columnErrors[column.id] == nil {
                loadMore(column.id)
            }
        }
    }

    private func card(_ issue: JiraIssue) -> some View {
        Button { openIssue(issue) } label: {
            VStack(alignment: .leading, spacing: 12) {
                Text(issue.summary).font(.system(size: 13))
                    .foregroundStyle(.primary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    metadataImage(issue.fields.issuetype?.iconUrl, fallback: "square.dashed", label: issue.issueType)
                    if issue.isFlagged { IssueFlagIndicator() }
                    Text(issue.key).font(.custom("Menlo", size: 11))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    metadataImage(issue.fields.priority?.iconUrl, fallback: "minus", label: issue.priority)
                    avatar(issue)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        if issue.isFlagged { RoundedRectangle(cornerRadius: 7).fill(Color.yellow.opacity(0.14)) }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selectedKey == issue.key ? Color.accentColor : Color.primary.opacity(0.09),
                                  lineWidth: selectedKey == issue.key ? 2 : 0.5)
            }
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(issue.key), \(issue.summary), \(issue.issueType), \(issue.priority), \(issue.assignee)\(issue.isFlagged ? ", Flagged" : "")")
        .accessibilityAddTraits(selectedKey == issue.key ? [.isSelected] : [])
        .contextMenu {
            Button("Copy issue key") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(issue.key, forType: .string)
            }
        }
    }

    private func metadataImage(_ url: URL?, fallback: String, label: String) -> some View {
        Group {
            if let url, let image = images[url.absoluteString] {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: fallback).foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16).help(label).accessibilityLabel(label)
    }

    private func avatar(_ issue: JiraIssue) -> some View {
        Group {
            if let url = issue.fields.assignee?.avatarURL, let image = images[url.absoluteString] {
                Image(nsImage: image).resizable().scaledToFill().clipShape(Circle())
            } else {
                Image(systemName: PersonAvatarPlaceholder.symbolName).font(.system(size: 20)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24).help(issue.assignee).accessibilityLabel(issue.assignee)
    }
}

/// Measures folded headers first, then offers the remaining viewport to a single open lane.
/// The same eager layout is used when several lanes are open, preserving their view identities.
private struct BoardSwimlaneLayout: Layout {
    let viewportHeight: CGFloat
    let fillingLane: Int?
    private let spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = sizes(subviews, width: proposal.width)
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0,
                      height: sizes.reduce(0) { $0 + $1.height } + gaps(subviews.count))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(subviews, width: bounds.width)
        var y = bounds.minY
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                                 proposal: ProposedViewSize(width: bounds.width, height: sizes[index].height))
            y += sizes[index].height + spacing
        }
    }

    private func sizes(_ subviews: Subviews, width: CGFloat?) -> [CGSize] {
        var sizes = subviews.indices.map { index in
            index == fillingLane ? CGSize(width: width ?? 0, height: 0)
                : subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
        if let fillingLane, sizes.indices.contains(fillingLane) {
            let headers = sizes.reduce(0) { $0 + $1.height }
            // A very short window can still scroll the outer board to reach every header.
            sizes[fillingLane] = subviews[fillingLane].sizeThatFits(ProposedViewSize(
                width: width, height: max(200, viewportHeight - headers - gaps(subviews.count))))
        }
        return sizes
    }

    private func gaps(_ count: Int) -> CGFloat { CGFloat(max(0, count - 1)) * spacing }
}
