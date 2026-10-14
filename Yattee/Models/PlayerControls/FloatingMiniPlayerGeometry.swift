//
//  FloatingMiniPlayerGeometry.swift
//  Yattee
//
//  Pure geometry for placing a floating mini player within available bounds.
//

import Foundation
import CoreGraphics

// MARK: - Placement

enum FloatingMiniPlayerCorner: String, CaseIterable, Codable, Hashable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

struct FloatingMiniPlayerCornerStore {
    static let storageKey = "floatingMiniPlayerCorner"
    static let sizeScaleStorageKey = "floatingMiniPlayerSizeScale"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> FloatingMiniPlayerCorner {
        guard let rawValue = defaults.string(forKey: Self.storageKey),
              let corner = FloatingMiniPlayerCorner(rawValue: rawValue) else {
            return .bottomTrailing
        }
        return corner
    }

    func save(_ corner: FloatingMiniPlayerCorner) {
        defaults.set(corner.rawValue, forKey: Self.storageKey)
    }

    func loadSizeScale() -> CGFloat {
        guard let storedNumber = defaults.object(forKey: Self.sizeScaleStorageKey) as? NSNumber else {
            return FloatingMiniPlayerSizing.defaultScale
        }

        let storedScale = storedNumber.doubleValue
        guard storedScale.isFinite else {
            return FloatingMiniPlayerSizing.defaultScale
        }
        return FloatingMiniPlayerSizing.clampedScale(CGFloat(storedScale))
    }

    func saveSizeScale(_ scale: CGFloat) {
        defaults.set(
            Double(FloatingMiniPlayerSizing.clampedScale(scale)),
            forKey: Self.sizeScaleStorageKey
        )
    }
}

enum FloatingMiniPlayerSizing {
    static let minimumScale: CGFloat = 0.70
    static let defaultScale: CGFloat = 0.85
    static let maximumScale: CGFloat = 1.00

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return defaultScale }
        return min(maximumScale, max(minimumScale, scale))
    }

    static func size(
        maximumWidth: CGFloat,
        scale: CGFloat,
        aspectRatio: CGFloat
    ) -> CGSize {
        let finiteMaximumWidth = maximumWidth.isFinite ? max(0, maximumWidth) : 0
        let finiteAspectRatio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1
        let width = finiteMaximumWidth * clampedScale(scale)
        return CGSize(width: width, height: width / finiteAspectRatio)
    }
}

enum FloatingMiniPlayerHorizontalEdge: String, Codable, Hashable, Sendable {
    case leading
    case trailing
}

enum FloatingMiniPlayerDestination: Codable, Hashable, Sendable {
    case corner(FloatingMiniPlayerCorner)
    case hidden(FloatingMiniPlayerHorizontalEdge)
}

enum FloatingMiniPlayerVisibility: Codable, Hashable, Sendable {
    case visible
    case hidden(FloatingMiniPlayerHorizontalEdge)
}

struct FloatingMiniPlayerPlacement: Codable, Hashable, Sendable {
    let corner: FloatingMiniPlayerCorner
    let visibility: FloatingMiniPlayerVisibility

    init(
        corner: FloatingMiniPlayerCorner,
        visibility: FloatingMiniPlayerVisibility = .visible
    ) {
        self.corner = corner
        self.visibility = visibility
    }
}

// MARK: - Geometry

struct FloatingMiniPlayerInsets: Equatable, Sendable {
    let top: CGFloat
    let leading: CGFloat
    let bottom: CGFloat
    let trailing: CGFloat

    init(
        top: CGFloat = 0,
        leading: CGFloat = 0,
        bottom: CGFloat = 0,
        trailing: CGFloat = 0
    ) {
        self.top = max(0, top.finiteOrZero)
        self.leading = max(0, leading.finiteOrZero)
        self.bottom = max(0, bottom.finiteOrZero)
        self.trailing = max(0, trailing.finiteOrZero)
    }
}

struct FloatingMiniPlayerGeometry: Sendable {
    /// YaTubee-specific tuning. These values do not represent official iOS PiP constants.
    struct Tuning: Equatable, Sendable {
        let projectionWeight: CGFloat
        let horizontalOverflow: CGFloat
        let hidingThreshold: CGFloat

        init(
            projectionWeight: CGFloat = 0.35,
            horizontalOverflow: CGFloat = 1,
            hidingThreshold: CGFloat = 0.25
        ) {
            self.projectionWeight = projectionWeight.finiteOrZero.clamped(to: 0 ... 1)
            self.horizontalOverflow = max(0, horizontalOverflow.finiteOrZero)
            self.hidingThreshold = max(0, hidingThreshold.finiteOrZero)
        }
    }

    let availableBounds: CGRect
    let miniPlayerSize: CGSize
    let margins: FloatingMiniPlayerInsets
    let tuning: Tuning

    init(
        availableBounds: CGRect,
        miniPlayerSize: CGSize,
        margins: FloatingMiniPlayerInsets = .init(),
        tuning: Tuning = .init()
    ) {
        self.availableBounds = CGRect(
            x: availableBounds.origin.x.finiteOrZero,
            y: availableBounds.origin.y.finiteOrZero,
            width: max(0, availableBounds.width.finiteOrZero),
            height: max(0, availableBounds.height.finiteOrZero)
        )
        self.miniPlayerSize = CGSize(
            width: max(0, miniPlayerSize.width.finiteOrZero),
            height: max(0, miniPlayerSize.height.finiteOrZero)
        )
        self.margins = margins
        self.tuning = tuning
    }

    /// Center position for one of the four semantic corners.
    func anchor(for corner: FloatingMiniPlayerCorner) -> CGPoint {
        let horizontal = horizontalRange
        let vertical = verticalRange

        switch corner {
        case .topLeading:
            return CGPoint(x: horizontal.lowerBound, y: vertical.lowerBound)
        case .topTrailing:
            return CGPoint(x: horizontal.upperBound, y: vertical.lowerBound)
        case .bottomLeading:
            return CGPoint(x: horizontal.lowerBound, y: vertical.upperBound)
        case .bottomTrailing:
            return CGPoint(x: horizontal.upperBound, y: vertical.upperBound)
        }
    }

    /// Position during a direct drag. Vertical movement remains inside the usable region,
    /// while horizontal overflow is allowed for the future hide-to-edge interaction.
    func interactivePosition(origin: CGPoint, translation: CGSize) -> CGPoint {
        constrainedPosition(
            CGPoint(
                x: origin.x.finiteOrZero + translation.width.finiteOrZero,
                y: origin.y.finiteOrZero + translation.height.finiteOrZero
            )
        )
    }

    /// Projected position used to decide the release destination.
    func projectedPosition(
        origin: CGPoint,
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> CGPoint {
        let additionalPrediction = CGSize(
            width: predictedEndTranslation.width.finiteOrZero - translation.width.finiteOrZero,
            height: predictedEndTranslation.height.finiteOrZero - translation.height.finiteOrZero
        )
        let projectedTranslation = CGSize(
            width: translation.width.finiteOrZero + additionalPrediction.width * tuning.projectionWeight,
            height: translation.height.finiteOrZero + additionalPrediction.height * tuning.projectionWeight
        )

        return interactivePosition(origin: origin, translation: projectedTranslation)
    }

    /// Chooses a visible corner or a future lateral hiding destination.
    func destination(
        origin: CGPoint,
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> FloatingMiniPlayerDestination {
        let position = projectedPosition(
            origin: origin,
            translation: translation,
            predictedEndTranslation: predictedEndTranslation
        )
        let hidingDistance = miniPlayerSize.width * tuning.hidingThreshold

        if position.x < horizontalRange.lowerBound - hidingDistance {
            return .hidden(.leading)
        }
        if position.x > horizontalRange.upperBound + hidingDistance {
            return .hidden(.trailing)
        }

        return .corner(closestVisibleCorner(to: position))
    }

    /// Chooses one of the four visible corners, ignoring lateral hiding destinations.
    /// Used until the hide-to-edge interaction and recall handle are implemented.
    func visibleCorner(
        origin: CGPoint,
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> FloatingMiniPlayerCorner {
        let position = projectedPosition(
            origin: origin,
            translation: translation,
            predictedEndTranslation: predictedEndTranslation
        )
        return closestVisibleCorner(to: position)
    }

    private func closestVisibleCorner(to position: CGPoint) -> FloatingMiniPlayerCorner {
        let closestCorner = FloatingMiniPlayerCorner.allCases.min { first, second in
            squaredDistance(from: position, to: anchor(for: first))
                < squaredDistance(from: position, to: anchor(for: second))
        }
        return closestCorner ?? .bottomTrailing
    }

    // MARK: - Bounds

    private var horizontalRange: ClosedRange<CGFloat> {
        collapsedRange(
            minimum: availableBounds.minX + margins.leading + miniPlayerSize.width / 2,
            maximum: availableBounds.maxX - margins.trailing - miniPlayerSize.width / 2,
            fallbackMinimum: availableBounds.minX + margins.leading,
            fallbackMaximum: availableBounds.maxX - margins.trailing
        )
    }

    private var verticalRange: ClosedRange<CGFloat> {
        collapsedRange(
            minimum: availableBounds.minY + margins.top + miniPlayerSize.height / 2,
            maximum: availableBounds.maxY - margins.bottom - miniPlayerSize.height / 2,
            fallbackMinimum: availableBounds.minY + margins.top,
            fallbackMaximum: availableBounds.maxY - margins.bottom
        )
    }

    private var horizontalDragRange: ClosedRange<CGFloat> {
        let overflow = miniPlayerSize.width * tuning.horizontalOverflow
        return (horizontalRange.lowerBound - overflow) ... (horizontalRange.upperBound + overflow)
    }

    private func constrainedPosition(_ position: CGPoint) -> CGPoint {
        CGPoint(
            x: position.x.finiteOrZero.clamped(to: horizontalDragRange),
            y: position.y.finiteOrZero.clamped(to: verticalRange)
        )
    }

    private func collapsedRange(
        minimum: CGFloat,
        maximum: CGFloat,
        fallbackMinimum: CGFloat,
        fallbackMaximum: CGFloat
    ) -> ClosedRange<CGFloat> {
        guard minimum <= maximum else {
            let lowerFallback = min(fallbackMinimum, fallbackMaximum)
            let upperFallback = max(fallbackMinimum, fallbackMaximum)
            let midpoint = (lowerFallback + upperFallback) / 2
            return midpoint ... midpoint
        }
        return minimum ... maximum
    }

    private func squaredDistance(from first: CGPoint, to second: CGPoint) -> CGFloat {
        let deltaX = first.x - second.x
        let deltaY = first.y - second.y
        return deltaX * deltaX + deltaY * deltaY
    }
}

// MARK: - Numeric Safety

private extension CGFloat {
    var finiteOrZero: CGFloat {
        isFinite ? self : 0
    }

    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
