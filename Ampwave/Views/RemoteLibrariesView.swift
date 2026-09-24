//
//  RemoteLibrariesView.swift
//  Ampwave
//

import SwiftData
internal import SwiftUI

struct RemoteLibrariesSettingsView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager
  @State private var service = RemoteLibraryService.shared
  @State private var addingProvider: ProviderSelection?
  @State private var sourceToDisconnect: RemoteMusicSource?

  var body: some View {
    List {
      Section {
        if service.sources.isEmpty {
          ContentUnavailableView {
            Label("No Media Servers", systemImage: "server.rack")
          } description: {
            Text("Connect Jellyfin or Plex to stream its music library in Ampwave.")
          }
        } else {
          ForEach(service.sources) { source in
            sourceRow(source)
              .swipeActions {
                Button("Disconnect", role: .destructive) {
                  sourceToDisconnect = source
                }
              }
          }
        }
      } header: {
        Text("Connected Servers")
      } footer: {
        Text(
          "Stream-only songs are shown while their server is reachable. Downloads stay available offline. Adding a remote song to any playlist automatically requests a download."
        )
      }

      Section {
        Button {
          addingProvider = ProviderSelection(provider: .jellyfin)
        } label: {
          Label("Add Jellyfin Server", systemImage: "plus.circle")
        }

        Button {
          addingProvider = ProviderSelection(provider: .plex)
        } label: {
          Label("Add Plex Server", systemImage: "plus.circle")
        }
      } header: {
        Text("Add Server")
      }

      if let lastError = service.lastError {
        Section("Last Sync Error") {
          Text(lastError)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
    .background(themeManager.backgroundColor)
    .scrollContentBackground(.hidden)
    .navigationTitle("Media Servers")
    .tint(themeManager.accentColor)
    .sheet(item: $addingProvider) { selection in
      NavigationStack {
        RemoteSourceConnectionView(provider: selection.provider)
      }
      .environment(themeManager)
    }
    .confirmationDialog(
      "Disconnect \(sourceToDisconnect?.name ?? "server")?",
      isPresented: Binding(
        get: { sourceToDisconnect != nil },
        set: { if !$0 { sourceToDisconnect = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) {
        guard let source = sourceToDisconnect else { return }
        sourceToDisconnect = nil
        Task { try? await service.disconnect(source) }
      }
      Button("Cancel", role: .cancel) { sourceToDisconnect = nil }
    } message: {
      Text(
        "Stream-only songs from this server will be removed. Songs already downloaded into Ampwave will remain as local music."
      )
    }
    .task {
      service.setModelContext(modelContext)
      await service.refreshAll(syncIfNeeded: false)
    }
  }

  private func sourceRow(_ source: RemoteMusicSource) -> some View {
    HStack(spacing: 12) {
      Image(systemName: source.provider == .jellyfin ? "play.tv" : "play.rectangle.on.rectangle")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 38, height: 38)
        .background(
          source.provider == .jellyfin ? Color.purple : Color.orange,
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )

      VStack(alignment: .leading, spacing: 3) {
        Text(source.name)
          .font(.headline)
        HStack(spacing: 5) {
          Circle()
            .fill(service.isSourceAvailable(source.id) ? Color.green : Color.secondary)
            .frame(width: 7, height: 7)
          Text(service.isSourceAvailable(source.id) ? "Available" : "Unavailable")
          if let lastSync = source.lastSyncedAt {
            Text("• Synced \(lastSync, style: .relative) ago")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      if service.syncingSourceIDs.contains(source.id) {
        ProgressView()
      } else {
        Button {
          Task { await service.syncNow(sourceID: source.id) }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Sync \(source.name)")
      }
    }
    .padding(.vertical, 4)
  }
}

private struct ProviderSelection: Identifiable {
  let provider: RemoteMusicProvider
  var id: String { provider.rawValue }
}

private struct RemoteSourceConnectionView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager

  let provider: RemoteMusicProvider

  @State private var serverURL = ""
  @State private var displayName = ""
  @State private var username = ""
  @State private var password = ""
  @State private var plexToken = ""
  @State private var isConnecting = false
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Section {
        VStack(spacing: 10) {
          Image(systemName: provider == .jellyfin ? "play.tv.fill" : "play.rectangle.fill")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(provider == .jellyfin ? Color.purple : Color.orange)
          Text("Connect to \(provider.displayName)")
            .font(.title3.weight(.semibold))
          Text(providerDescription)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
      }

      Section("Server") {
        TextField(provider == .jellyfin ? "http://server:8096" : "http://server:32400", text: $serverURL)
          .textContentType(.URL)
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          #endif
        TextField("Display name (optional)", text: $displayName)
      }

      if provider == .jellyfin {
        Section("Account") {
          TextField("Username", text: $username)
            .textContentType(.username)
          SecureField("Password", text: $password)
            .textContentType(.password)
        }
      } else {
        Section {
          SecureField("X-Plex-Token", text: $plexToken)
            .textContentType(.password)
          Link(
            "How to find your Plex token",
            destination: URL(
              string: "https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/"
            )!
          )
        } header: {
          Text("Plex Access Token")
        } footer: {
          Text("The token is stored in Keychain and is never saved in the music catalog.")
        }
      }

      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }

      Section {
        Button {
          connect()
        } label: {
          HStack {
            Text("Connect and Sync")
            Spacer()
            if isConnecting { ProgressView() }
          }
        }
        .disabled(isConnecting || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .navigationTitle(provider.displayName)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
    }
    .tint(themeManager.accentColor)
  }

  private var providerDescription: String {
    switch provider {
    case .jellyfin:
      return "Ampwave imports your music catalog and streams original audio directly from your Jellyfin server."
    case .plex:
      return "Ampwave imports music libraries and streams their media files directly from your Plex Media Server."
    }
  }

  private func connect() {
    isConnecting = true
    errorMessage = nil
    RemoteLibraryService.shared.setModelContext(modelContext)
    Task {
      do {
        switch provider {
        case .jellyfin:
          _ = try await RemoteLibraryService.shared.connectJellyfin(
            serverURL: serverURL,
            username: username,
            password: password,
            displayName: displayName
          )
        case .plex:
          _ = try await RemoteLibraryService.shared.connectPlex(
            serverURL: serverURL,
            accessToken: plexToken,
            displayName: displayName
          )
        }
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
        isConnecting = false
      }
    }
  }
}
