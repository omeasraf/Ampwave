//
//  LastFMSettingsView.swift
//  Ampwave
//
//  Last.fm account and scrobbling settings.
//

import SwiftData
internal import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

struct LastFMSettingsView: View {
  @Environment(ThemeManager.self) private var themeManager
  @Environment(\.openURL) private var openURL

  @State private var scrobbler = LastFMScrobbler.shared
  @State private var showingSignOutConfirmation = false

  var body: some View {
    Form {
      if !scrobbler.isConfigured {
        Section {
          Label("Last.fm isn't configured in this build.", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        } footer: {
          Text(
            "Add LAST_FM_API_KEY and LAST_FM_SHARED_SECRET to .env, then run Scripts/generate-lastfm-secrets.sh and rebuild."
          )
        }
        .listRowBackground(themeManager.cardBackgroundColor)
      } else {
        accountSection
        if scrobbler.isSignedIn {
          scrobblingSection
        }
      }
    }
    .background(themeManager.backgroundColor)
    .scrollContentBackground(.hidden)
    .navigationTitle("Last.fm")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .confirmationDialog(
      "Sign out of Last.fm?",
      isPresented: $showingSignOutConfirmation,
      titleVisibility: .visible
    ) {
      Button("Sign Out", role: .destructive) { scrobbler.signOut() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Queued scrobbles that haven't been sent yet will stay queued.")
    }
    .task { await scrobbler.refreshProfile() }
  }

  // MARK: - Account

  @ViewBuilder
  private var accountSection: some View {
    switch scrobbler.state {
    case .signedIn(let username):
      Section("Profile") {
        profileRow(username: username)

        if let url = scrobbler.profile?.profileURL {
          Button {
            openURL(url)
          } label: {
            Label("View Profile on Last.fm", systemImage: "arrow.up.right.square")
          }
        }

        Button(role: .destructive) {
          showingSignOutConfirmation = true
        } label: {
          Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
        }
      }
      .listRowBackground(themeManager.cardBackgroundColor)

    case .awaitingAuthorization:
      Section {
        Text("Approve Ampwave in the browser, then come back and tap Complete Sign In.")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        Button {
          Task { await scrobbler.completeSignIn() }
        } label: {
          HStack {
            Label("Complete Sign In", systemImage: "checkmark.circle")
            if scrobbler.isBusy {
              Spacer()
              ProgressView().controlSize(.small)
            }
          }
        }
        .disabled(scrobbler.isBusy)

        Button("Cancel", role: .cancel) { scrobbler.cancelSignIn() }
      } header: {
        Text("Waiting for Approval")
      } footer: {
        if let error = scrobbler.lastError {
          Text(error).foregroundStyle(.orange)
        }
      }
      .listRowBackground(themeManager.cardBackgroundColor)

    case .signedOut:
      Section {
        Button {
          Task {
            if let url = await scrobbler.beginSignIn() {
              openURL(url)
            }
          }
        } label: {
          HStack {
            Label("Sign In with Last.fm", systemImage: "person.crop.circle.badge.plus")
            if scrobbler.isBusy {
              Spacer()
              ProgressView().controlSize(.small)
            }
          }
        }
        .disabled(scrobbler.isBusy)
      } header: {
        Text("Account")
      } footer: {
        if let error = scrobbler.lastError {
          Text(error).foregroundStyle(.orange)
        } else {
          Text(
            "Scrobbling records what you listen to on your Last.fm profile. You'll approve Ampwave in your browser."
          )
        }
      }
      .listRowBackground(themeManager.cardBackgroundColor)
    }
  }

  private func profileRow(username: String) -> some View {
    HStack(spacing: 14) {
      avatar

      VStack(alignment: .leading, spacing: 3) {
        Text(scrobbler.profile?.realName ?? username)
          .font(.headline)
        if scrobbler.profile?.realName != nil {
          Text(username)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        if let plays = scrobbler.profile?.playCount {
          Text("\(plays.formatted()) scrobbles")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var avatar: some View {
    if let url = scrobbler.profile?.imageURL {
      AsyncImage(url: url) { phase in
        switch phase {
        case .success(let image):
          image.resizable().aspectRatio(contentMode: .fill)
        default:
          placeholderAvatar
        }
      }
      .frame(width: 56, height: 56)
      .clipShape(Circle())
    } else {
      placeholderAvatar
        .frame(width: 56, height: 56)
    }
  }

  private var placeholderAvatar: some View {
    Circle()
      .fill(.secondary.opacity(0.2))
      .overlay {
        Image(systemName: "person.fill")
          .font(.system(size: 22))
          .foregroundStyle(.secondary)
      }
  }

  /// Grounds the percentage in something concrete using a typical track
  /// length, including the four-minute cap where it bites.
  private var exampleThresholdText: String {
    let sampleDuration: TimeInterval = 210  // a 3:30 track
    let seconds = LastFMScrobbler.threshold(
      duration: sampleDuration,
      percent: scrobbler.scrobbleThresholdPercent
    )
    let minutes = Int(seconds) / 60
    let remainder = Int(seconds) % 60
    return String(
      format: "A 3:30 track scrobbles after %d:%02d of listening.", minutes, remainder)
  }

  // MARK: - Scrobbling

  private var scrobblingSection: some View {
    Section {
      Toggle(
        "Scrobble Plays",
        isOn: Binding(
          get: { scrobbler.isScrobblingEnabled },
          set: { scrobbler.isScrobblingEnabled = $0 }
        )
      )

      Toggle(
        "Sync Favorites as Loved",
        isOn: Binding(
          get: { scrobbler.syncLovedTracks },
          set: { scrobbler.syncLovedTracks = $0 }
        )
      )

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Scrobble Threshold")
          Spacer()
          Text("\(scrobbler.scrobbleThresholdPercent)%")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }

        Slider(
          value: Binding(
            get: { Double(scrobbler.scrobbleThresholdPercent) },
            set: { scrobbler.scrobbleThresholdPercent = Int($0.rounded()) }
          ),
          in: 1...100,
          step: 1
        )
        .disabled(!scrobbler.isScrobblingEnabled)

        Text(exampleThresholdText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if scrobbler.pendingCount > 0 {
        HStack {
          Label(
            "\(scrobbler.pendingCount) waiting to send",
            systemImage: "arrow.triangle.2.circlepath"
          )
          .foregroundStyle(.secondary)
          Spacer()
          Button("Retry") {
            Task { await scrobbler.flushQueue() }
          }
          .font(.caption)
          .buttonStyle(.bordered)
        }
      }
    } header: {
      Text("Scrobbling")
    } footer: {
      Text(
        "A track is scrobbled once you've played the threshold above, or four minutes — whichever comes first, without waiting for it to end. Last.fm's own rule is 50%. Tracks under 30 seconds are never scrobbled. Plays made offline are sent later. Favoriting a song marks it loved on Last.fm."
      )
    }
    .listRowBackground(themeManager.cardBackgroundColor)
  }
}
