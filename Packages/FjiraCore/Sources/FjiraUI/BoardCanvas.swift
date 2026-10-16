import AppKit
import FjiraCore
import SwiftUI

public struct BoardCanvas: View {
    private let columns: [BoardColumn]
    private let lanes: [BoardLane]
    @State private var collapsedLanes = Set<Int>()
    @Namespace private var boardViewport
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
            let viewport = boardViewport
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 16) {
                    if lanes.isEmpty {
                        columnRow(columns, width: width, viewportSize: geometry.size)
                    } else {
                        ForEach(lanes.filter { !$0.isEmpty }) { lane in
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
                                    columnRow(lane.columns, width: width, viewportSize: geometry.size)
                                }
                            }
                        }
                        if lanes.allSatisfy(\.isEmpty) {
                            Text("No matching issues").foregroundStyle(.secondary).padding(24)
                        }
                    }
                }
                .frame(width: max(0, canvasWidth(columnWidth: width) - 24), alignment: .topLeading)
                .padding(12)
            }
            .defaultScrollAnchor(.topLeading)
            .coordinateSpace(name: viewport)
        }
    }

    private func columnRow(_ columns: [BoardColumn], width: CGFloat, viewportSize: CGSize) -> some View {
        BoardColumnsLayout(columnWidth: width) {
            ForEach(columns) { column in
                columnView(column, viewportSize: viewportSize)
            }
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

    private func columnView(_ column: BoardColumn, viewportSize: CGSize) -> some View {
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
            VStack(spacing: 8) { columnContents(column, viewportSize: viewportSize) }
                .padding(8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(column.configuration.name)
    }

    @ViewBuilder
    private func columnContents(_ column: BoardColumn, viewportSize: CGSize) -> some View {
        ForEach(column.issues) { issue in card(issue) }
        if column.hasMore {
            paginationFooter(column, viewportSize: viewportSize).id(column.issues.count)
        }
        if column.issues.isEmpty && !column.hasMore {
            Text("No issues").font(.callout).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity).padding(.vertical, 28)
        }
    }

    private func paginationFooter(_ column: BoardColumn, viewportSize: CGSize) -> some View {
        let viewport = boardViewport
        return VStack(spacing: 8) {
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
        .onGeometryChange(for: Bool.self) { geometry in
            // Eager column layout measures every card, so appearance alone does not mean
            // the footer is visible. Only page when it actually enters the board viewport.
            geometry.frame(in: .named(viewport)).intersects(CGRect(origin: .zero, size: viewportSize))
        } action: { visible in
            if visible && automaticallyLoadMore && canLoadMore && loadingColumnID == nil && columnErrors[column.id] == nil {
                loadMore(column.id)
            }
        }
    }

    private func card(_ issue: JiraIssue) -> some View {
        Button { openIssue(issue) } label: {
            VStack(alignment: .leading, spacing: issue.epicLink == nil ? 12 : 6) {
                Text(issue.summary).font(.system(size: 13))
                    .foregroundStyle(.primary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let epic = issue.epicLink { EpicPill(epic: epic) }
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
        .accessibilityLabel("\(issue.key), \(issue.summary), \(issue.issueType), \(issue.priority), \(issue.assignee)\(issue.isFlagged ? ", Flagged" : "")\(issue.epicLink.map { ", Epic: " + $0.displayName } ?? "")")
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

/// Measures full column contents and gives every column the height of the tallest one.
private struct BoardColumnsLayout: Layout {
    let columnWidth: CGFloat
    private let spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        }.max() ?? 0
        return CGSize(width: CGFloat(subviews.count) * columnWidth + CGFloat(max(0, subviews.count - 1)) * spacing,
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(index) * (columnWidth + spacing), y: bounds.minY),
                                 anchor: .topLeading,
                                 proposal: ProposedViewSize(width: columnWidth, height: bounds.height))
        }
    }
}
