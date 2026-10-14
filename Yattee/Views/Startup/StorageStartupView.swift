//
//  StorageStartupView.swift
//  Yattee
//
//  Blocking startup and recovery UI for unavailable persistent storage.
//

import SwiftUI

struct StorageStartupView: View {
    let isInitializing: Bool
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(AppLocalization.string("startup.storage.title"))
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text(AppLocalization.string("startup.storage.message"))
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Text(AppLocalization.string("startup.storage.preservation"))
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if isInitializing {
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel(AppLocalization.string("startup.storage.retrying"))
                } else {
                    Button(action: retry) {
                        Text(AppLocalization.string("common.retry"))
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: 560)
            .padding(32)
            .frame(maxWidth: .infinity, minHeight: 500)
        }
        .background(.background)
    }
}

#Preview {
    StorageStartupView(isInitializing: false, retry: {})
}
