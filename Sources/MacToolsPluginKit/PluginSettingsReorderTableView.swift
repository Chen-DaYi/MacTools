import AppKit

/// Shared AppKit table configuration for settings lists that support drag-to-reorder.
///
/// Both the host's Installed list and plugin settings use this so they present the same native
/// drag preview and insertion-gap feedback.
public final class PluginSettingsReorderTableView: NSTableView {
    /// Lets a consumer restrict dragging to rows that are actually reorderable.
    /// The Installed list keeps its default behavior; plugin lists can opt out for status rows.
    public var canBeginDrag: ((IndexSet) -> Bool)?

    public init(dragType: NSPasteboard.PasteboardType) {
        super.init(frame: .zero)

        headerView = nil
        backgroundColor = .clear
        selectionHighlightStyle = .none
        focusRingType = .none
        usesAlternatingRowBackgroundColors = false
        allowsColumnReordering = false
        allowsColumnResizing = false
        allowsEmptySelection = true
        allowsTypeSelect = false
        columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        draggingDestinationFeedbackStyle = .gap
        verticalMotionCanBeginDrag = true
        setDraggingSourceOperationMask(.move, forLocal: true)
        registerForDraggedTypes([dragType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        guard canBeginDrag?(rowIndexes) ?? true else { return false }
        return super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }
}
