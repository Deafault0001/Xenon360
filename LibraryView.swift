// LibraryView.swift
// Xenon360 — Game Library Browser

import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var emulator: Emulator
    @State private var isImporting = false
    @State private var games: [GameEntry] = []
    @State private var searchText = ""
    @State private var selectedGame: GameEntry?
    @State private var showGameDetail = false

    // Simulated library entries for UI demo
    struct GameEntry: Identifiable {
        let id = UUID()
        let title: String
        let titleID: String
        let region: String
        let url: URL?
        var isLoaded: Bool = false
    }

    var filteredGames: [GameEntry] {
        if searchText.isEmpty { return games }
        return games.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color(red: 0.07, green: 0.07, blue: 0.09)
                    .ignoresSafeArea()

                if games.isEmpty {
                    emptyState
                } else {
                    gameGrid
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search games…")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { isImporting = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [
                    UTType(filenameExtension: "xex") ?? .data,
                    UTType(filenameExtension: "iso") ?? .diskImage,
                    .data
                ],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: "opticaldisc")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 8) {
                Text("No Games Yet")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Add Xbox 360 XEX files to get started.\nRoms are not provided — dump your own discs.")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            }

            Button(action: { isImporting = true }) {
                Label("Import XEX File", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Color.green)
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
            }
        }
        .padding(32)
    }

    // MARK: - Game Grid

    var gameGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)
            ], spacing: 16) {
                ForEach(filteredGames) { game in
                    GameCard(game: game)
                        .onTapGesture {
                            selectedGame = game
                            showGameDetail = true
                        }
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $showGameDetail) {
            if let game = selectedGame {
                GameDetailSheet(game: game, isPresented: $showGameDetail)
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Import Handler

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let entry = GameEntry(
                title:   url.deletingPathExtension().lastPathComponent,
                titleID: "????????",
                region:  "NTSC-U",
                url:     url
            )
            games.append(entry)

            // Auto-load
            Task {
                await emulator.loadXEX(url: url)
            }

        case .failure(let error):
            print("Import error: \(error)")
        }
    }
}

// MARK: - Game Card

struct GameCard: View {
    let game: LibraryView.GameEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover art placeholder
            ZStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hue: Double.random(in: 0...1), saturation: 0.6, brightness: 0.3),
                                Color(hue: Double.random(in: 0...1), saturation: 0.6, brightness: 0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                VStack(spacing: 6) {
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(game.title)
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                }
            }
            .frame(height: 140)

            // Info bar
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(game.region)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(10)
            .background(Color(white: 0.12))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Game Detail Sheet

struct GameDetailSheet: View {
    let game: LibraryView.GameEntry
    @Binding var isPresented: Bool
    @EnvironmentObject var emulator: Emulator

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Cover
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(white: 0.15))
                        .frame(width: 120, height: 120)
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                }

                VStack(spacing: 6) {
                    Text(game.title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("Title ID: \(game.titleID)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .fontDesign(.monospaced)
                    Text(game.region)
                        .font(.caption)
                        .foregroundStyle(.green.opacity(0.8))
                }

                HStack(spacing: 16) {
                    Button(action: {
                        if let url = game.url {
                            Task { await emulator.loadXEX(url: url) }
                        }
                        isPresented = false
                    }) {
                        Label("Boot Game", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.green)
                            .foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button(action: { isPresented = false }) {
                        Label("Cancel", systemImage: "xmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(white: 0.2))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 24)
            .background(Color(red: 0.07, green: 0.07, blue: 0.09))
            .navigationTitle("Game Details")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationBackground(Color(red: 0.07, green: 0.07, blue: 0.09))
    }
}
