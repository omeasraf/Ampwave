import SwiftData
internal import SwiftUI

struct WebDAVSettingsView: View {
  @Environment(ThemeManager.self) private var themeManager

  @State private var serverURL: String
  @State private var username: String
  @State private var password: String
  @State private var isTesting = false
  @State private var statusMessage: String?
  @State private var statusIsSuccess = false
  @State private var showingClearConfirmation = false

  init() {
    _serverURL = State(initialValue: WebDAVSettingsStore.serverURLString)
    _username = State(initialValue: WebDAVSettingsStore.username)
    _password = State(initialValue: WebDAVSettingsStore.password)
  }

  var body: some View {
    ZStack {
      themeManager.backgroundColor.ignoresSafeArea()

      ScrollView {
        VStack(spacing: 18) {
          VStack(spacing: 10) {
            Image(systemName: "externaldrive.connected.to.line.below")
              .font(.system(size: 34, weight: .semibold))
              .foregroundStyle(themeManager.accentColor)
              .frame(width: 72, height: 72)
              .background(
                themeManager.accentColor.opacity(0.14),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
              )

            Text("Your music, wherever it lives")
              .font(.title3.weight(.semibold))

            Text("Connect a WebDAV folder to browse and import tracks directly into Ampwave.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          .padding(.horizontal)

          VStack(alignment: .leading, spacing: 14) {
            Label("Connection", systemImage: "network")
              .font(.headline)
              .foregroundStyle(themeManager.accentColor)

            VStack(alignment: .leading, spacing: 6) {
              Text("Server URL")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
              TextField(
                "https://cloud.example.com/remote.php/dav/files/name/",
                text: $serverURL
              )
              .textContentType(.URL)
              .textFieldStyle(.plain)
              .padding(12)
              .background(
                themeManager.backgroundColor.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
              )
              .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .stroke(themeManager.accentColor.opacity(0.16), lineWidth: 1)
              }
            }

            VStack(alignment: .leading, spacing: 6) {
              Text("Username")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
              TextField("Username", text: $username)
                .textContentType(.username)
                .textFieldStyle(.plain)
                .padding(12)
                .background(
                  themeManager.backgroundColor.opacity(0.72),
                  in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(themeManager.accentColor.opacity(0.16), lineWidth: 1)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
              Text("Password or app password")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
              SecureField("Password or app password", text: $password)
                .textContentType(.password)
                .textFieldStyle(.plain)
                .padding(12)
                .background(
                  themeManager.backgroundColor.opacity(0.72),
                  in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(themeManager.accentColor.opacity(0.16), lineWidth: 1)
                }
            }

            Label(
              "Your password is stored securely in Keychain.",
              systemImage: "lock.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .padding(18)
          .background(
            themeManager.cardBackgroundColor,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
              .stroke(themeManager.accentColor.opacity(0.12), lineWidth: 1)
          }

          VStack(spacing: 12) {
            Button {
              save()
            } label: {
              Label("Save Connection", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
              Task { await testConnection() }
            } label: {
              HStack {
                Label("Test Connection", systemImage: "network")
                Spacer()
                if isTesting {
                  ProgressView()
                    .controlSize(.small)
                }
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isTesting)

            NavigationLink {
              WebDAVBrowserView()
            } label: {
              Label("Browse and Import Music", systemImage: "music.note.list")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!WebDAVSettingsStore.isConfigured)

            if let statusMessage {
              Label(
                statusMessage,
                systemImage: statusIsSuccess
                  ? "checkmark.circle.fill"
                  : "exclamationmark.triangle.fill"
              )
              .font(.caption)
              .foregroundStyle(statusIsSuccess ? .green : .red)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 2)
            }
          }
          .padding(18)
          .background(
            themeManager.cardBackgroundColor,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
          )

          Text(
            "Use the full WebDAV folder URL. HTTPS is recommended; local HTTP servers are supported. For Nextcloud, use an app password when two-factor authentication is enabled."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4)

          if WebDAVSettingsStore.isConfigured {
            Button("Remove WebDAV Connection", role: .destructive) {
              showingClearConfirmation = true
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
          }
        }
        .frame(maxWidth: 620)
        .padding()
      }
    }
    .navigationTitle("WebDAV")
    .tint(themeManager.accentColor)
    .confirmationDialog(
      "Remove WebDAV Connection?",
      isPresented: $showingClearConfirmation,
      titleVisibility: .visible
    ) {
      Button("Remove Connection", role: .destructive) {
        WebDAVSettingsStore.clear()
        serverURL = ""
        username = ""
        password = ""
        statusMessage = "Connection removed."
        statusIsSuccess = true
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes the saved server address, username, and Keychain password.")
    }
  }

  private func save() {
    do {
      try WebDAVSettingsStore.save(
        serverURL: serverURL,
        username: username,
        password: password
      )
      serverURL = WebDAVSettingsStore.serverURLString
      statusMessage = "Connection saved securely."
      statusIsSuccess = true
    } catch {
      statusMessage = error.localizedDescription
      statusIsSuccess = false
    }
  }

  private func testConnection() async {
    statusMessage = nil
    statusIsSuccess = false
    isTesting = true
    defer { isTesting = false }

    guard let url = WebDAVSettingsStore.normalizedURL(from: serverURL) else {
      statusMessage = WebDAVError.invalidServerURL.localizedDescription
      return
    }

    do {
      let client = WebDAVClient(
        configuration: WebDAVConfiguration(
          baseURL: url,
          username: username.trimmingCharacters(in: .whitespacesAndNewlines),
          password: password
        )
      )
      try await client.testConnection()
      statusMessage = "Connected successfully."
      statusIsSuccess = true
    } catch {
      statusMessage = error.localizedDescription
    }
  }
}

struct WebDAVBrowserView: View {
  @Environment(ThemeManager.self) private var themeManager
  @State private var configuration: WebDAVConfiguration?

  var body: some View {
    Group {
      if let configuration {
        WebDAVDirectoryView(
          configuration: configuration,
          directoryURL: configuration.baseURL,
          title: "WebDAV"
        )
      } else {
        ContentUnavailableView {
          Label("WebDAV Not Configured", systemImage: "externaldrive.badge.xmark")
        } description: {
          Text("Add your WebDAV server before browsing remote music.")
        } actions: {
          NavigationLink("Configure WebDAV") {
            WebDAVSettingsView()
          }
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .navigationTitle("WebDAV Music")
    .background(themeManager.backgroundColor.ignoresSafeArea())
    .tint(themeManager.accentColor)
    .onAppear {
      configuration = WebDAVSettingsStore.configuration()
    }
  }
}

private struct WebDAVDirectoryView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(ThemeManager.self) private var themeManager

  let configuration: WebDAVConfiguration
  let directoryURL: URL
  let title: String
  @State private var client: WebDAVClient

  @State private var items: [WebDAVItem] = []
  @State private var selectedItems: Set<WebDAVItem> = []
  @State private var isLoading = false
  @State private var isImporting = false
  @State private var activityMessage: String?
  @State private var errorMessage: String?
  @State private var searchText = ""

  init(configuration: WebDAVConfiguration, directoryURL: URL, title: String) {
    self.configuration = configuration
    self.directoryURL = directoryURL
    self.title = title
    _client = State(initialValue: WebDAVClient(configuration: configuration))
  }

  private var filteredItems: [WebDAVItem] {
    guard !searchText.isEmpty else { return items }
    return items.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
    }
  }

  private var directories: [WebDAVItem] {
    filteredItems.filter(\.isDirectory)
  }

  private var audioFiles: [WebDAVItem] {
    filteredItems.filter { !$0.isDirectory && $0.isAudioFile }
  }

  var body: some View {
    List {
      if isLoading && items.isEmpty {
        HStack {
          Spacer()
          ProgressView("Loading folder…")
          Spacer()
        }
        .listRowBackground(themeManager.cardBackgroundColor)
      } else if !isLoading && filteredItems.isEmpty {
        if searchText.isEmpty {
          ContentUnavailableView(
            "No Music Here",
            systemImage: "music.note",
            description: Text("This folder has no supported audio files or subfolders.")
          )
          .listRowBackground(themeManager.cardBackgroundColor)
        } else {
          ContentUnavailableView.search(text: searchText)
            .listRowBackground(themeManager.cardBackgroundColor)
        }
      }

      if !directories.isEmpty {
        Section("Folders") {
          ForEach(directories) { directory in
            NavigationLink {
              WebDAVDirectoryView(
                configuration: configuration,
                directoryURL: directory.url,
                title: directory.name
              )
            } label: {
              Label(directory.name, systemImage: "folder.fill")
            }
            .listRowBackground(themeManager.cardBackgroundColor)
          }
        }
      }

      if !audioFiles.isEmpty {
        Section("Music") {
          ForEach(audioFiles) { item in
            Button {
              toggleSelection(item)
            } label: {
              HStack(spacing: 12) {
                Image(
                  systemName: selectedItems.contains(item)
                    ? "checkmark.circle.fill"
                    : "circle"
                )
                .foregroundStyle(
                  selectedItems.contains(item) ? themeManager.accentColor : Color.secondary
                )

                VStack(alignment: .leading, spacing: 3) {
                  Text(item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                  if let contentLength = item.contentLength {
                    Text(ByteCountFormatter.string(fromByteCount: contentLength, countStyle: .file))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                Spacer()
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isImporting)
            .listRowBackground(themeManager.cardBackgroundColor)
          }
        }
      }

      if let activityMessage {
        Section {
          HStack(spacing: 10) {
            if isImporting {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
            Text(activityMessage)
              .font(.callout)
          }
          .listRowBackground(themeManager.cardBackgroundColor)
        }
      }
    }
    .navigationTitle(title)
    .scrollContentBackground(.hidden)
    .background(themeManager.backgroundColor)
    .tint(themeManager.accentColor)
    .searchable(text: $searchText, prompt: "Search this folder")
    .refreshable {
      await loadDirectory()
    }
    .task(id: directoryURL) {
      await loadDirectory()
    }
    .toolbar {
      if !audioFiles.isEmpty {
        ToolbarItem(placement: .secondaryAction) {
          Button(
            selectedItems.count == audioFiles.count ? "Deselect All" : "Select All"
          ) {
            if selectedItems.count == audioFiles.count {
              selectedItems.removeAll()
            } else {
              selectedItems = Set(audioFiles)
            }
          }
          .disabled(isImporting)
        }
      }

      if !selectedItems.isEmpty {
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await importSelection() }
          } label: {
            Label(
              "Import \(selectedItems.count)",
              systemImage: "square.and.arrow.down"
            )
          }
          .disabled(isImporting)
        }
      }
    }
    .alert(
      "WebDAV Error",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func toggleSelection(_ item: WebDAVItem) {
    HapticManager.shared.select()
    if selectedItems.contains(item) {
      selectedItems.remove(item)
    } else {
      selectedItems.insert(item)
    }
  }

  private func loadDirectory() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      items = try await client.listDirectory(at: directoryURL)
      selectedItems = selectedItems.intersection(Set(items))
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func importSelection() async {
    let selection = selectedItems.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    guard !selection.isEmpty else { return }

    isImporting = true
    errorMessage = nil
    let downloadDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Ampwave-WebDAV-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: downloadDirectory)
      isImporting = false
    }

    do {
      var localFiles: [URL] = []
      for (index, item) in selection.enumerated() {
        activityMessage = "Downloading \(index + 1) of \(selection.count)…"
        localFiles.append(try await client.download(item, to: downloadDirectory))
      }

      activityMessage = "Adding music to your library…"
      let library = SongLibrary.shared
      if library.modelContext == nil {
        library.setModelContext(modelContext)
      }
      await library.importFiles(localFiles, forceCopy: true)

      selectedItems.removeAll()
      activityMessage =
        selection.count == 1
        ? "Finished importing 1 track."
        : "Finished importing \(selection.count) tracks."
    } catch {
      activityMessage = nil
      errorMessage = error.localizedDescription
    }
  }
}
