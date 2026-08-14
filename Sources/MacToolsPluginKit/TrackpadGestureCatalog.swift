import Foundation

/// Shared vocabulary for the precise gestures produced by the single multitouch listener.
public enum TipTapRegion: String, Codable, CaseIterable, Sendable {
    case left
    case middle
    case right
}

public enum TrackpadGesture: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case tipTapLeftOneFixed, tipTapRightOneFixed, tipTapLeftTwoFixed, tipTapMiddleTwoFixed, tipTapRightTwoFixed
    case threeFingerTap, fourFingerTap, fiveFingerTap
    case threeFingerLongTouch, fourFingerLongTouch, fiveFingerLongTouch
    case threeFingerDoubleTap, fourFingerDoubleTap, fiveFingerDoubleTap
    case twoFingerClick, threeFingerClick

    public var id: String { rawValue }
    public static let configurableCases: [TrackpadGesture] = [
        .tipTapLeftOneFixed,
        .tipTapRightOneFixed,
        .tipTapLeftTwoFixed,
        .tipTapMiddleTwoFixed,
        .tipTapRightTwoFixed,
        .threeFingerTap,
        .fourFingerTap,
        .fiveFingerTap,
        .threeFingerDoubleTap,
        .fourFingerDoubleTap,
        .fiveFingerDoubleTap,
        .twoFingerClick,
        .threeFingerClick,
        .threeFingerLongTouch,
        .fourFingerLongTouch,
        .fiveFingerLongTouch,
    ]

    /// Human-readable fallback for settings pages that own their own localization bundle.
    public var displayTitle: String {
        switch self {
        case .tipTapLeftOneFixed: "TipTap — left, one fixed finger"
        case .tipTapRightOneFixed: "TipTap — right, one fixed finger"
        case .tipTapLeftTwoFixed: "TipTap — left, two fixed fingers"
        case .tipTapMiddleTwoFixed: "TipTap — middle, two fixed fingers"
        case .tipTapRightTwoFixed: "TipTap — right, two fixed fingers"
        case .threeFingerTap: "Three-finger tap"
        case .fourFingerTap: "Four-finger tap"
        case .fiveFingerTap: "Five-finger tap"
        case .threeFingerLongTouch: "Three-finger long touch"
        case .fourFingerLongTouch: "Four-finger long touch"
        case .fiveFingerLongTouch: "Five-finger long touch"
        case .threeFingerDoubleTap: "Three-finger double tap"
        case .fourFingerDoubleTap: "Four-finger double tap"
        case .fiveFingerDoubleTap: "Five-finger double tap"
        case .twoFingerClick: "Two-finger click"
        case .threeFingerClick: "Three-finger click"
        }
    }

    public var tipTapConfiguration: (fixedFingerCount: Int, region: TipTapRegion)? {
        switch self {
        case .tipTapLeftOneFixed: (1, .left)
        case .tipTapRightOneFixed: (1, .right)
        case .tipTapLeftTwoFixed: (2, .left)
        case .tipTapMiddleTwoFixed: (2, .middle)
        case .tipTapRightTwoFixed: (2, .right)
        default: nil
        }
    }

    public var fingerTapCount: Int? {
        switch self { case .threeFingerTap: 3; case .fourFingerTap: 4; case .fiveFingerTap: 5; default: nil }
    }
    public var longTouchFingerCount: Int? {
        switch self { case .threeFingerLongTouch: 3; case .fourFingerLongTouch: 4; case .fiveFingerLongTouch: 5; default: nil }
    }
    public var doubleFingerTapCount: Int? {
        switch self { case .threeFingerDoubleTap: 3; case .fourFingerDoubleTap: 4; case .fiveFingerDoubleTap: 5; default: nil }
    }
    public var physicalClickFingerCount: Int? {
        switch self { case .twoFingerClick: 2; case .threeFingerClick: 3; default: nil }
    }
    public static func fingerTap(count: Int) -> TrackpadGesture {
        switch count { case 4: .fourFingerTap; case 5: .fiveFingerTap; default: .threeFingerTap }
    }
}
