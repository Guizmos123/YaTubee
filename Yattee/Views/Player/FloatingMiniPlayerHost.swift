//
//  FloatingMiniPlayerHost.swift
//  Yattee
//
//  Stable root overlay host for floating mini player presentations on iOS.
//

import SwiftUI

#if os(iOS)
struct FloatingMiniPlayerHost: View {
    /// Preserves the existing visual clearance above the native tab bar.
    /// SwiftUI does not expose the tab bar's effective frame, especially while minimized.
    private static let legacyTabBarClearance: CGFloat = 49
    private static let visualMargin: CGFloat = 16
    private static let maximumVideoWidth: CGFloat = 320

    let isEnabled: Bool
    let hasActiveVideo: Bool
    let isPlayerExpanded: Bool
    let style: MiniPlayerStyle

    private let cornerStore: FloatingMiniPlayerCornerStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var corner: FloatingMiniPlayerCorner
    @State private var sizeScale: CGFloat
    @State private var dragOrigin: CGPoint?
    @State private var dragPosition: CGPoint?
    @State private var magnificationOriginScale: CGFloat?

    init(
        isEnabled: Bool,
        hasActiveVideo: Bool,
        isPlayerExpanded: Bool,
        style: MiniPlayerStyle,
        cornerStore: FloatingMiniPlayerCornerStore = .init()
    ) {
        self.isEnabled = isEnabled
        self.hasActiveVideo = hasActiveVideo
        self.isPlayerExpanded = isPlayerExpanded
        self.style = style
        self.cornerStore = cornerStore
        _corner = State(initialValue: cornerStore.load())
        _sizeScale = State(initialValue: cornerStore.loadSizeScale())
    }

    var body: some View {
        GeometryReader { proxy in
            let miniPlayerSize = effectiveMiniPlayerSize(in: proxy)
            let geometry = floatingGeometry(in: proxy, miniPlayerSize: miniPlayerSize)
            miniPlayerOverlay(using: geometry, miniPlayerSize: miniPlayerSize)
        }
        .onChange(of: style) { _, _ in
            resetDragState()
            magnificationOriginScale = nil
        }
    }

    @ViewBuilder
    private func miniPlayerOverlay(
        using geometry: FloatingMiniPlayerGeometry,
        miniPlayerSize: CGSize
    ) -> some View {
        if isEnabled && hasActiveVideo && !isPlayerExpanded {
            let restingPosition = geometry.anchor(for: corner)
            let referencePosition = geometry.anchor(for: .bottomTrailing)
            let displayedPosition = style == .bar
                ? referencePosition
                : (dragPosition ?? restingPosition)

            VStack(spacing: 0) {
                Spacer()
                MiniPlayerView(
                    isFloatingDragEnabled: style != .bar,
                    floatingVideoWidth: miniPlayerSize.width,
                    isFloatingResizeEnabled: style == .video,
                    onFloatingDragChanged: { translation in
                        updateDrag(translation: translation, geometry: geometry)
                    },
                    onFloatingDragEnded: { translation, predictedEndTranslation in
                        finishDrag(
                            translation: translation,
                            predictedEndTranslation: predictedEndTranslation,
                            geometry: geometry
                        )
                    },
                    onFloatingMagnificationChanged: { magnification in
                        updateMagnification(magnification)
                    },
                    onFloatingMagnificationEnded: { magnification in
                        finishMagnification(magnification)
                    }
                )
            }
            .padding(.bottom, bottomClearance)
            .offset(
                x: displayedPosition.x - referencePosition.x,
                y: displayedPosition.y - referencePosition.y
            )
            // Use move-only transition (no opacity) to prevent thumbnail flash during collapse.
            .transition(.move(edge: .bottom))
            .animation(.spring(response: 0.3), value: hasActiveVideo)
        }
    }

    private func updateDrag(
        translation: CGSize,
        geometry: FloatingMiniPlayerGeometry
    ) {
        guard style != .bar else { return }
        let origin = dragOrigin ?? geometry.anchor(for: corner)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if dragOrigin == nil {
                dragOrigin = origin
            }
            dragPosition = geometry.interactivePosition(origin: origin, translation: translation)
        }
    }

    private func finishDrag(
        translation: CGSize,
        predictedEndTranslation: CGSize,
        geometry: FloatingMiniPlayerGeometry
    ) {
        guard style != .bar else {
            resetDragState()
            return
        }

        let origin = dragOrigin ?? geometry.anchor(for: corner)
        let destination = geometry.visibleCorner(
            origin: origin,
            translation: translation,
            predictedEndTranslation: predictedEndTranslation
        )
        let shouldPersistDestination = destination != corner
        dragOrigin = nil

        if reduceMotion {
            corner = destination
            dragPosition = nil
        } else {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                corner = destination
                dragPosition = nil
            }
        }

        if shouldPersistDestination {
            cornerStore.save(destination)
        }
    }

    private func resetDragState() {
        dragOrigin = nil
        dragPosition = nil
    }

    private func updateMagnification(_ magnification: CGFloat) {
        guard style == .video else { return }
        let originScale = magnificationOriginScale ?? sizeScale

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if magnificationOriginScale == nil {
                magnificationOriginScale = originScale
                resetDragState()
            }
            sizeScale = FloatingMiniPlayerSizing.clampedScale(originScale * magnification)
        }
    }

    private func finishMagnification(_ magnification: CGFloat) {
        guard style == .video else {
            magnificationOriginScale = nil
            return
        }

        let originScale = magnificationOriginScale ?? sizeScale
        let finalScale = FloatingMiniPlayerSizing.clampedScale(originScale * magnification)
        magnificationOriginScale = nil
        sizeScale = finalScale

        if finalScale != originScale {
            cornerStore.saveSizeScale(finalScale)
        }
    }

    /// Measures the root container and its safe area without changing current placement.
    /// Native tab bar occlusion remains intentionally unresolved until a public, reliable
    /// measurement is available; the legacy clearance above preserves the current UI.
    private var bottomClearance: CGFloat {
        guard style == .video else { return Self.legacyTabBarClearance }
        return Self.legacyTabBarClearance + Self.visualMargin
    }

    /// Returns the persisted, container-adapted size used by layout and placement.
    private func effectiveMiniPlayerSize(in proxy: GeometryProxy) -> CGSize {
        if style == .bubble {
            let diameter = MiniPlayerStyleMetrics.recommendedBubbleDiameter
            return CGSize(width: diameter, height: diameter)
        }

        let safeAreaInsets = proxy.safeAreaInsets
        let safeWidth = max(
            0,
            proxy.size.width - safeAreaInsets.leading - safeAreaInsets.trailing
        )
        let maximumWidth = min(
            Self.maximumVideoWidth,
            max(0, safeWidth - Self.visualMargin * 2)
        )
        return FloatingMiniPlayerSizing.size(
            maximumWidth: maximumWidth,
            scale: sizeScale,
            aspectRatio: MiniPlayerStyleMetrics.videoAspectRatio
        )
    }

    private func floatingGeometry(
        in proxy: GeometryProxy,
        miniPlayerSize: CGSize
    ) -> FloatingMiniPlayerGeometry {
        let safeAreaInsets = proxy.safeAreaInsets
        let safeWidth = max(
            0,
            proxy.size.width - safeAreaInsets.leading - safeAreaInsets.trailing
        )
        let safeHeight = max(
            0,
            proxy.size.height - safeAreaInsets.top - safeAreaInsets.bottom
        )
        let safeBounds = CGRect(
            x: safeAreaInsets.leading,
            y: safeAreaInsets.top,
            width: safeWidth,
            height: safeHeight
        )

        return FloatingMiniPlayerGeometry(
            availableBounds: safeBounds,
            miniPlayerSize: miniPlayerSize,
            margins: FloatingMiniPlayerInsets(
                top: Self.visualMargin,
                leading: Self.visualMargin,
                bottom: Self.visualMargin,
                trailing: Self.visualMargin
            )
        )
    }
}
#endif
