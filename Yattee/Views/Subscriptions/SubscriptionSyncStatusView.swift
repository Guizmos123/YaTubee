//
//  SubscriptionSyncStatusView.swift
//  Yattee
//
//  Displays the last recorded subscription feed synchronization diagnostics.
//

import Foundation
import SwiftUI

#if !os(tvOS)

struct SubscriptionSyncStatusView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @State private var feedCache = SubscriptionFeedCache.shared
    @State private var isInstanceDetailsExpanded = false
    @State private var areChannelDetailsExpanded = false

    private enum Availability {
        case available(SubscriptionSyncSnapshot, Instance)
        case noSnapshot
        case unsupported
        case unavailable
    }

    var body: some View {
        Group {
            switch availability {
            case .available(let snapshot, let instance):
                statusList(snapshot: snapshot, instance: instance)
            case .noSnapshot:
                unavailableContent(
                    title: "subscriptions.syncStatus.empty.title",
                    description: "subscriptions.syncStatus.empty.description",
                    systemImage: "clock.badge.questionmark"
                )
            case .unsupported:
                unavailableContent(
                    title: "subscriptions.syncStatus.unsupported.title",
                    description: "subscriptions.syncStatus.unsupported.description",
                    systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                )
            case .unavailable:
                unavailableContent(
                    title: "subscriptions.syncStatus.unavailable.title",
                    description: "subscriptions.syncStatus.unavailable.description",
                    systemImage: "network.slash"
                )
            }
        }
        .reactiveNavigationTitle(AppLocalization.string("subscriptions.syncStatus.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var availability: Availability {
        guard let appEnvironment else { return .unavailable }
        if appEnvironment.settingsManager.subscriptionAccount.type == .piped {
            return .unsupported
        }

        let source = LocalFeedSource.resolve(
            from: appEnvironment.instancesManager.instances,
            preference: appEnvironment.settingsManager.localFeedSourcePreference
        )
        let expected: (SubscriptionSyncSnapshot.Source.Kind, Instance)
        switch source {
        case .yatteeServer(let instance):
            expected = (.yatteeServer, instance)
        case .invidious(let instance):
            expected = (.invidious, instance)
        case .unavailable:
            return .unavailable
        }

        guard let snapshot = feedCache.syncSnapshot else { return .noSnapshot }
        guard snapshot.source.kind == expected.0,
              snapshot.source.instanceID == expected.1.id else {
            return .noSnapshot
        }
        return .available(snapshot.normalizedForCurrentSemantics, expected.1)
    }

    private func statusList(snapshot: SubscriptionSyncSnapshot, instance: Instance) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(sourceName(snapshot.source.kind)) · \(instance.displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(snapshot.successfulChannelCount)/\(snapshot.totalChannelCount)")
                            .font(.largeTitle.monospacedDigit().bold())
                            .foregroundStyle(summaryCountColor(snapshot))
                        Text(primaryCountLabel(snapshot.source.kind))
                            .font(.headline)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(summaryAccessibilityLabel(snapshot))
                }

                if snapshot.pendingChannelCount > 0 {
                    countRow("subscriptions.syncStatus.pending", count: snapshot.pendingChannelCount)
                }
                if snapshot.failedChannelCount > 0 {
                    countRow("subscriptions.syncStatus.failed", count: snapshot.failedChannelCount)
                }
                if snapshot.unknownChannelCount > 0 {
                    countRow("subscriptions.syncStatus.unknown", count: snapshot.unknownChannelCount)
                }
            }

            Section {
                LabeledContent(
                    AppLocalization.string("subscriptions.syncStatus.feedUpdated"),
                    value: formatted(snapshot.refreshFinishedAt)
                )

                if snapshot.source.kind == .yatteeServer {
                    if let lastCollection = snapshot.channels.compactMap(\.lastFetchedAt).max() {
                        LabeledContent(
                            AppLocalization.string("subscriptions.syncStatus.lastServerCollection"),
                            value: formatted(lastCollection)
                        )
                    }
                    if let interval = snapshot.serverFeedFetchIntervalSeconds,
                       let intervalDescription = formattedInterval(interval) {
                        LabeledContent(
                            AppLocalization.string("subscriptions.syncStatus.collectionInterval"),
                            value: intervalDescription
                        )
                    }
                    if snapshot.serverInformationObservedAt == nil || snapshot.observationError != nil {
                        Label(
                            AppLocalization.string("subscriptions.syncStatus.serverUnavailable"),
                            systemImage: "info.circle"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(AppLocalization.string("subscriptions.syncStatus.information"))
            } footer: {
                if snapshot.source.kind == .yatteeServer,
                   let interval = snapshot.serverFeedFetchIntervalSeconds,
                   formattedInterval(interval) != nil {
                    Text(AppLocalization.string("subscriptions.syncStatus.collectionInterval.footer"))
                }
            }

            Section {
                DisclosureGroup(isExpanded: $isInstanceDetailsExpanded) {
                    LabeledContent(
                        AppLocalization.string("subscriptions.syncStatus.instanceName"),
                        value: instance.displayName
                    )
                    LabeledContent(
                        AppLocalization.string("subscriptions.syncStatus.instanceURL"),
                        value: instance.displayURL
                    )
                    if let observedAt = snapshot.serverInformationObservedAt {
                        LabeledContent(
                            AppLocalization.string("subscriptions.syncStatus.serverObserved"),
                            value: formatted(observedAt)
                        )
                    }
                } label: {
                    Label(
                        AppLocalization.string("subscriptions.syncStatus.instanceDetails"),
                        systemImage: "server.rack"
                    )
                }
            }

            Section {
                DisclosureGroup(isExpanded: $areChannelDetailsExpanded) {
                    ForEach(sortedChannels(snapshot.channels), id: \.self) { channel in
                        channelRow(channel, source: snapshot.source.kind)
                    }
                } label: {
                    LabeledContent(
                        AppLocalization.string("subscriptions.syncStatus.channelDetails"),
                        value: snapshot.totalChannelCount.formatted()
                    )
                }
            }
        }
        .task(id: snapshotPresentationID(snapshot)) {
            isInstanceDetailsExpanded = false
            areChannelDetailsExpanded = snapshot.pendingChannelCount > 0
                || snapshot.failedChannelCount > 0
                || snapshot.unknownChannelCount > 0
        }
    }

    @ViewBuilder
    private func countRow(_ key: String.LocalizationValue, count: Int) -> some View {
        LabeledContent(AppLocalization.string(key), value: count.formatted())
    }

    private func channelRow(
        _ channel: SubscriptionSyncSnapshot.Channel,
        source: SubscriptionSyncSnapshot.Source.Kind
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon(channel.state))
                .foregroundStyle(statusColor(channel.state))
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(channel.channelName)
                    .font(.body)

                if channel.state != .success {
                    Text(stateName(channel.state, source: source))
                        .font(.caption)
                        .foregroundStyle(statusColor(channel.state))
                }

                if let collectionDate = channel.lastFetchedAt ?? channel.requestCompletedAt {
                    Text(dateLabel(collectionDate, source: source))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = channel.errorDescription, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(channelAccessibilityLabel(channel, source: source))
    }

    private func sortedChannels(
        _ channels: [SubscriptionSyncSnapshot.Channel]
    ) -> [SubscriptionSyncSnapshot.Channel] {
        channels.sorted { lhs, rhs in
            let lhsPriority = statePriority(lhs.state)
            let rhsPriority = statePriority(rhs.state)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.channelName.localizedCaseInsensitiveCompare(rhs.channelName) == .orderedAscending
        }
    }

    private func statePriority(_ state: SubscriptionSyncSnapshot.Channel.State) -> Int {
        switch state {
        case .failure: 0
        case .pending: 1
        case .unknown: 2
        case .success: 3
        }
    }

    private func sourceName(_ source: SubscriptionSyncSnapshot.Source.Kind) -> String {
        switch source {
        case .yatteeServer: AppLocalization.string("instances.type.yatteeServer")
        case .invidious: AppLocalization.string("instances.type.invidious")
        }
    }

    private func primaryCountLabel(_ source: SubscriptionSyncSnapshot.Source.Kind) -> String {
        switch source {
        case .yatteeServer: AppLocalization.string("subscriptions.syncStatus.collected")
        case .invidious: AppLocalization.string("subscriptions.syncStatus.synchronized")
        }
    }

    private func stateName(
        _ state: SubscriptionSyncSnapshot.Channel.State,
        source: SubscriptionSyncSnapshot.Source.Kind
    ) -> String {
        switch state {
        case .success:
            source == .yatteeServer
                ? AppLocalization.string("subscriptions.syncStatus.state.collected")
                : AppLocalization.string("subscriptions.syncStatus.state.success")
        case .pending: AppLocalization.string("subscriptions.syncStatus.state.pending")
        case .failure: AppLocalization.string("subscriptions.syncStatus.state.failure")
        case .unknown: AppLocalization.string("subscriptions.syncStatus.state.unknown")
        }
    }

    private func dateLabel(
        _ date: Date,
        source: SubscriptionSyncSnapshot.Source.Kind
    ) -> String {
        let value = formatted(date)
        switch source {
        case .yatteeServer:
            return AppLocalization.string("subscriptions.syncStatus.lastCollectionAt \(value)")
        case .invidious:
            return AppLocalization.string("subscriptions.syncStatus.collectedAt \(value)")
        }
    }

    private func statusIcon(_ state: SubscriptionSyncSnapshot.Channel.State) -> String {
        switch state {
        case .success: "checkmark.circle.fill"
        case .pending: "clock.fill"
        case .failure: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private func statusColor(_ state: SubscriptionSyncSnapshot.Channel.State) -> Color {
        switch state {
        case .success: .green
        case .pending: .orange
        case .failure: .red
        case .unknown: .secondary
        }
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(appEnvironment?.settingsManager.appLanguage.locale ?? AppLanguage.english.locale)
        )
    }

    private func formattedInterval(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        var calendar = Calendar.current
        calendar.locale = appEnvironment?.settingsManager.appLanguage.locale ?? AppLanguage.english.locale
        formatter.calendar = calendar
        guard let formattedDuration = formatter.string(from: seconds) else { return nil }
        let duration = formattedDuration
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
        return AppLocalization.string("subscriptions.syncStatus.every \(duration)")
    }

    private func summaryCountColor(_ snapshot: SubscriptionSyncSnapshot) -> Color {
        guard snapshot.totalChannelCount > 0 else { return .primary }
        if snapshot.successfulChannelCount == snapshot.totalChannelCount { return .green }
        if snapshot.successfulChannelCount > 0 { return .orange }
        return .red
    }

    private func summaryAccessibilityLabel(_ snapshot: SubscriptionSyncSnapshot) -> String {
        let stateKey: String.LocalizationValue
        if snapshot.totalChannelCount == 0 {
            stateKey = "subscriptions.syncStatus.summaryState.empty"
        } else if snapshot.successfulChannelCount == snapshot.totalChannelCount {
            stateKey = "subscriptions.syncStatus.summaryState.complete"
        } else if snapshot.successfulChannelCount > 0 {
            stateKey = "subscriptions.syncStatus.summaryState.partial"
        } else {
            stateKey = "subscriptions.syncStatus.summaryState.none"
        }
        return [
            "\(snapshot.successfulChannelCount)/\(snapshot.totalChannelCount)",
            primaryCountLabel(snapshot.source.kind),
            AppLocalization.string(stateKey)
        ].joined(separator: ", ")
    }

    private func snapshotPresentationID(_ snapshot: SubscriptionSyncSnapshot) -> String {
        "\(snapshot.source.kind.rawValue):\(snapshot.source.instanceID.uuidString):\(snapshot.refreshFinishedAt.timeIntervalSinceReferenceDate)"
    }

    private func channelAccessibilityLabel(
        _ channel: SubscriptionSyncSnapshot.Channel,
        source: SubscriptionSyncSnapshot.Source.Kind
    ) -> String {
        var components = [channel.channelName, stateName(channel.state, source: source)]
        if let date = channel.lastFetchedAt ?? channel.requestCompletedAt {
            components.append(dateLabel(date, source: source))
        }
        if let error = channel.errorDescription, !error.isEmpty {
            components.append(error)
        }
        return components.joined(separator: ", ")
    }

    private func unavailableContent(
        title: String.LocalizationValue,
        description: String.LocalizationValue,
        systemImage: String
    ) -> some View {
        ContentUnavailableView {
            Label(AppLocalization.string(title), systemImage: systemImage)
        } description: {
            Text(AppLocalization.string(description))
        }
    }
}

#endif
