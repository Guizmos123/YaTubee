//
//  FloatingMiniPlayerGeometryTests.swift
//  Yattee
//
//  Tests for deterministic floating mini player placement geometry.
//

import Foundation
import CoreGraphics
import Testing
@testable import YaTubee

@Suite("Floating Mini Player Geometry Tests")
struct FloatingMiniPlayerGeometryTests {
    private let phoneBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
    private let margins = FloatingMiniPlayerInsets(top: 59, leading: 16, bottom: 83, trailing: 16)

    @Test("Four corner anchors respect size and margins")
    func cornerAnchors() {
        let geometry = makeVideoGeometry()

        #expect(geometry.anchor(for: .topLeading) == CGPoint(x: 176, y: 149))
        #expect(geometry.anchor(for: .topTrailing) == CGPoint(x: 214, y: 149))
        #expect(geometry.anchor(for: .bottomLeading) == CGPoint(x: 176, y: 671))
        #expect(geometry.anchor(for: .bottomTrailing) == CGPoint(x: 214, y: 671))
    }

    @Test("Video and bubble sizes produce independent anchors")
    func differentPlayerSizes() {
        let video = makeVideoGeometry()
        let bubble = FloatingMiniPlayerGeometry(
            availableBounds: phoneBounds,
            miniPlayerSize: CGSize(width: 72, height: 72),
            margins: margins
        )

        #expect(video.anchor(for: .bottomTrailing) == CGPoint(x: 214, y: 671))
        #expect(bubble.anchor(for: .bottomTrailing) == CGPoint(x: 338, y: 725))
        #expect(bubble.anchor(for: .topLeading) == CGPoint(x: 52, y: 95))
    }

    @Test("Sizing uses the default scale and clamps to product limits")
    func normalizedSizing() {
        #expect(FloatingMiniPlayerSizing.clampedScale(.nan) == 0.85)
        #expect(FloatingMiniPlayerSizing.clampedScale(0.4) == 0.70)
        #expect(FloatingMiniPlayerSizing.clampedScale(0.85) == 0.85)
        #expect(FloatingMiniPlayerSizing.clampedScale(1.4) == 1.00)

        #expect(
            FloatingMiniPlayerSizing.size(
                maximumWidth: 320,
                scale: 0.85,
                aspectRatio: 16.0 / 9.0
            ) == CGSize(width: 272, height: 153)
        )
    }

    @Test("Variable sizes remain finite in small containers")
    func adaptiveSizingSafety() {
        let zeroSize = FloatingMiniPlayerSizing.size(
            maximumWidth: -.infinity,
            scale: .infinity,
            aspectRatio: .nan
        )
        let smallSize = FloatingMiniPlayerSizing.size(
            maximumWidth: 180,
            scale: 0.70,
            aspectRatio: 16.0 / 9.0
        )
        let geometry = FloatingMiniPlayerGeometry(
            availableBounds: CGRect(x: 0, y: 0, width: 180, height: 150),
            miniPlayerSize: smallSize,
            margins: FloatingMiniPlayerInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        )

        #expect(zeroSize == .zero)
        #expect(abs(smallSize.width - 126) < 0.001)
        #expect(abs(smallSize.height - 70.875) < 0.001)
        #expect(FloatingMiniPlayerCorner.allCases.allSatisfy {
            let anchor = geometry.anchor(for: $0)
            return anchor.x.isFinite && anchor.y.isFinite
        })
    }

    @Test("Interactive drag follows the finger and constrains vertical movement")
    func interactiveDrag() {
        let geometry = makeVideoGeometry()
        let origin = geometry.anchor(for: .bottomTrailing)

        #expect(
            geometry.interactivePosition(
                origin: origin,
                translation: CGSize(width: -30, height: -120)
            ) == CGPoint(x: 184, y: 551)
        )
        #expect(
            geometry.interactivePosition(
                origin: origin,
                translation: CGSize(width: 0, height: 1_000)
            ).y == 671
        )
    }

    @Test("Release projection uses only the configured share of predicted momentum")
    func releaseProjection() {
        let geometry = makeVideoGeometry(
            tuning: .init(projectionWeight: 0.5, horizontalOverflow: 1, hidingThreshold: 0.25)
        )
        let origin = geometry.anchor(for: .topLeading)
        let projected = geometry.projectedPosition(
            origin: origin,
            translation: CGSize(width: 10, height: 20),
            predictedEndTranslation: CGSize(width: 50, height: 100)
        )

        #expect(projected == CGPoint(x: 206, y: 209))
    }

    @Test("Projected release selects the closest corner")
    func closestCornerSelection() {
        let geometry = makeVideoGeometry()
        let origin = geometry.anchor(for: .topLeading)

        #expect(
            geometry.destination(
                origin: origin,
                translation: CGSize(width: 25, height: 400),
                predictedEndTranslation: CGSize(width: 40, height: 520)
            ) == .corner(.bottomTrailing)
        )
    }

    @Test("Horizontal overflow is available for future lateral hiding")
    func horizontalOverflowAndHiding() {
        let geometry = makeVideoGeometry()
        let origin = geometry.anchor(for: .topLeading)
        let position = geometry.interactivePosition(
            origin: origin,
            translation: CGSize(width: -1_000, height: 0)
        )

        #expect(position.x == -144)
        #expect(
            geometry.destination(
                origin: origin,
                translation: CGSize(width: -100, height: 0),
                predictedEndTranslation: CGSize(width: -180, height: 0)
            ) == .hidden(.leading)
        )
        #expect(
            geometry.visibleCorner(
                origin: origin,
                translation: CGSize(width: -100, height: 400),
                predictedEndTranslation: CGSize(width: -180, height: 520)
            ) == .bottomLeading
        )
    }

    @Test("Vertical projection never escapes the usable bounds")
    func verticalConstraints() {
        let geometry = makeVideoGeometry()
        let origin = geometry.anchor(for: .topTrailing)

        #expect(
            geometry.projectedPosition(
                origin: origin,
                translation: CGSize(width: 0, height: -800),
                predictedEndTranslation: CGSize(width: 0, height: -1_600)
            ).y == 149
        )
    }

    @Test("Impossible regions collapse all corners to a finite center")
    func impossibleRegion() {
        let geometry = FloatingMiniPlayerGeometry(
            availableBounds: CGRect(x: 10, y: 20, width: 40, height: 30),
            miniPlayerSize: CGSize(width: 320, height: 180),
            margins: FloatingMiniPlayerInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
        )
        let anchors = FloatingMiniPlayerCorner.allCases.map(geometry.anchor(for:))

        #expect(Set(anchors.map(\.x)).count == 1)
        #expect(Set(anchors.map(\.y)).count == 1)
        #expect(anchors.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test("Invalid numeric input is normalized and never produces NaN")
    func numericSafety() {
        let geometry = FloatingMiniPlayerGeometry(
            availableBounds: CGRect(
                x: CGFloat.nan,
                y: CGFloat.infinity,
                width: -CGFloat.infinity,
                height: CGFloat.nan
            ),
            miniPlayerSize: CGSize(width: CGFloat.nan, height: CGFloat.infinity),
            margins: FloatingMiniPlayerInsets(top: CGFloat.nan, leading: CGFloat.infinity),
            tuning: .init(
                projectionWeight: CGFloat.nan,
                horizontalOverflow: CGFloat.infinity,
                hidingThreshold: CGFloat.nan
            )
        )
        let position = geometry.projectedPosition(
            origin: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
            translation: CGSize(width: CGFloat.nan, height: -CGFloat.infinity),
            predictedEndTranslation: CGSize(width: CGFloat.infinity, height: CGFloat.nan)
        )

        #expect(position.x.isFinite)
        #expect(position.y.isFinite)
    }

    @Test("Rebuilding with new bounds preserves semantic corner placement")
    func boundsRecalculation() {
        let portrait = makeVideoGeometry()
        let landscape = FloatingMiniPlayerGeometry(
            availableBounds: CGRect(x: 0, y: 0, width: 844, height: 390),
            miniPlayerSize: CGSize(width: 320, height: 180),
            margins: FloatingMiniPlayerInsets(top: 16, leading: 59, bottom: 21, trailing: 59)
        )

        #expect(portrait.anchor(for: .bottomTrailing) == CGPoint(x: 214, y: 671))
        #expect(landscape.anchor(for: .bottomTrailing) == CGPoint(x: 625, y: 279))
    }

    @Test("Semantic corner survives rotation and asymmetric safe areas")
    func semanticCornerWithAsymmetricSafeAreas() {
        let portrait = FloatingMiniPlayerGeometry(
            availableBounds: CGRect(x: 0, y: 59, width: 390, height: 751),
            miniPlayerSize: CGSize(width: 320, height: 180),
            margins: FloatingMiniPlayerInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        )
        let landscape = FloatingMiniPlayerGeometry(
            availableBounds: CGRect(x: 59, y: 0, width: 764, height: 369),
            miniPlayerSize: CGSize(width: 280, height: 157.5),
            margins: FloatingMiniPlayerInsets(top: 16, leading: 16, bottom: 21, trailing: 37)
        )

        #expect(portrait.anchor(for: .topLeading) == CGPoint(x: 176, y: 165))
        #expect(portrait.anchor(for: .bottomTrailing) == CGPoint(x: 214, y: 704))
        #expect(landscape.anchor(for: .topLeading) == CGPoint(x: 215, y: 94.75))
        #expect(landscape.anchor(for: .bottomTrailing) == CGPoint(x: 646, y: 269.25))
    }

    @Test("Repeated calculations are deterministic")
    func deterministicResults() {
        let geometry = makeVideoGeometry()
        let origin = geometry.anchor(for: .bottomLeading)
        let calculate = {
            geometry.destination(
                origin: origin,
                translation: CGSize(width: 45, height: -120),
                predictedEndTranslation: CGSize(width: 100, height: -240)
            )
        }

        #expect(calculate() == calculate())
    }

    private func makeVideoGeometry(
        tuning: FloatingMiniPlayerGeometry.Tuning = .init()
    ) -> FloatingMiniPlayerGeometry {
        FloatingMiniPlayerGeometry(
            availableBounds: phoneBounds,
            miniPlayerSize: CGSize(width: 320, height: 180),
            margins: margins,
            tuning: tuning
        )
    }
}
