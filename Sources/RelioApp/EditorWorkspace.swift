import SwiftUI
import AVKit
import AppKit

private enum EditorStyle {
    static let canvas = Prism.surface0
    static let panel = Prism.surface1
    static let inset = Prism.surface2
    static let accent = Prism.accent
    static let line = Prism.border
}

extension ContentView {
    var editorHeader: some View {
        HStack(spacing: 18) {
            Button { model.player?.pause(); model.screen = .home } label: {
                Label("Home", systemImage: "chevron.left")
            }.buttonStyle(.plain).help("Back to projects").disabled(model.isBusy)
            Rectangle().fill(EditorStyle.line).frame(width: 1, height: 20)
            PrismMark().frame(height: 20)
            Text("Prism").font(Prism.display(20)).tracking(-0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.project?.displayTitle ?? "Untitled project").font(Prism.text(12, .medium)).lineLimit(1)
                Text("Step 4 · Review and export").font(Prism.text(10)).foregroundStyle(Prism.textSecondary)
            }
            Spacer(minLength: 12)
            if model.isBusy { ProgressView().controlSize(.small) }
            Label(model.isBusy ? model.generationStage : (model.useGemini ? "Gemini cloud" : "On-device AI"),
                  systemImage: model.isBusy ? "clock" : (model.useGemini ? "cloud" : "desktopcomputer"))
                .font(Prism.text(12)).foregroundStyle(Prism.textSecondary).lineLimit(1)
            Button { model.revealExports() } label: {
                Label("Exports", systemImage: "folder")
                    .font(Prism.text(11, .medium))
            }
            .buttonStyle(.plain)
            .disabled(model.projectURL == nil || model.isBusy)
            .help(model.exportedFiles.isEmpty ? "Open this project's Exports folder" : "Show the exported video files in Finder")
            AppearanceSwitch(selection: $appearance)
            Button { model.undoFromEditor() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain).disabled(model.editHistory.isEmpty || model.isBusy).help("Undo edit")
                .accessibilityLabel("Undo edit")
            Button { model.export() } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(Prism.text(12, .medium))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .foregroundStyle(Prism.ink).background(Prism.action, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(model.project?.segments.isEmpty != false || model.isBusy)
                .accessibilityLabel("Export all Shorts")
        }.padding(.horizontal, 20).frame(height: 54)
            .background(EditorStyle.panel)
            .overlay(alignment: .bottom) { EditorStyle.line.frame(height: 1) }
    }

    var editingWorkspace: some View {
        VStack(spacing: 1) {
            HStack(spacing: 1) {
                EditorMediaBin(model: model)
                    .frame(width: leftSidebarWidth)
                EditorSidebarDivider {
                    leftSidebarWidth = min(440, max(200, leftSidebarWidth + $0))
                }
                EditorPlayer(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                EditorSidebarDivider {
                    rightSidebarWidth = min(460, max(220, rightSidebarWidth - $0))
                }
                EditorInspector(model: model).frame(width: rightSidebarWidth)
            }.frame(maxHeight: .infinity)
            if let progress = model.generationProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.generationStage)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                        Button("Cancel") { model.cancelGeneration() }
                            .disabled(model.generationStage == "Cancelling…")
                    }.font(Prism.text(12))
                    PrismProgressLine(value: progress)
                }.padding(12).background(EditorStyle.panel)
            }
            EditorTimeline(model: model).frame(height: 278)
            HStack(spacing: 8) {
                if model.isBusy || model.isPreviewLoading { ProgressView().controlSize(.mini) }
                Text(model.message).font(Prism.text(11)).lineLimit(1).textSelection(.enabled)
                Spacer()
                Text("1080 × 1920 · 30 fps · MP4").font(Prism.mono(10)).foregroundStyle(Prism.textSecondary)
            }.padding(.horizontal, 16).frame(height: 28).background(EditorStyle.panel)
        }.background(EditorStyle.line)
    }
}

private struct EditorSidebarDivider: View {
    let onDrag: (CGFloat) -> Void
    @State private var lastTranslation: CGFloat = 0
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? EditorStyle.accent.opacity(0.75) : EditorStyle.line)
            .frame(width: 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        onDrag(value.translation.width - lastTranslation)
                        lastTranslation = value.translation.width
                    }
                    .onEnded { _ in lastTranslation = 0 }
            )
            .onHover { isHovering = $0 }
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .help("Drag to resize sidebar")
            .accessibilityLabel("Resize sidebar")
    }
}

/// Approximates exported captions: heavy white text, black outline, and a yellow spoken word for Viral.
struct CaptionStyleSample: View {
    let highlight: Bool
    var size: CGFloat = 30
    var body: some View {
        let outline = max(1, size / 20)
        (Text("Hello ").foregroundStyle(highlight ? Color.yellow : .white) + Text("everyone").foregroundStyle(.white))
            .font(.system(size: size, weight: .heavy))
            // Hard shadows on four sides stand in for the stroked outline drawn in exports.
            .shadow(color: .black, radius: 0, x: outline, y: outline)
            .shadow(color: .black, radius: 0, x: -outline, y: -outline)
            .shadow(color: .black, radius: 0, x: outline, y: -outline)
            .shadow(color: .black, radius: 0, x: -outline, y: outline)
    }
}

private struct EditorCaptionsPanel: View {
    @Bindable var model: AppModel
    @State private var drafts: [String] = []

    var body: some View {
        Group {
            if let clip = model.activeSegment {
                content(clip)
            } else {
                Text("Select a Short to change its captions.")
                    .font(Prism.text(12)).foregroundStyle(Prism.textSecondary).padding(.vertical, 28)
            }
        }
        .onAppear(perform: loadDrafts)
        .onChange(of: model.activeSegment?.captions ?? []) { _, _ in loadDrafts() }
    }

    @ViewBuilder
    func content(_ clip: EditSegment) -> some View {
        let current: CaptionStyle = clip.captionStyle == .viral ? .viral : .classic
        let hasAudio = model.project?.media.first(where: { $0.id == clip.mediaID })?.hasAudio == true
        let cues = clip.captions ?? []
        VStack(alignment: .leading, spacing: 10) {
            Text("Caption style").font(Prism.text(14, .medium))
            styleButton(.classic, title: "Simple", detail: "White text, black outline", selected: current == .classic)
            styleButton(.viral, title: "Viral", detail: "Spoken word turns yellow", selected: current == .viral)
            if current == .viral && clip.speechWords?.isEmpty != false {
                Text("Yellow highlights need word timing, which this Short doesn't have yet. Transcribe it to add timing; until then captions show without highlights.")
                    .font(Prism.text(10)).foregroundStyle(Prism.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Caption text").font(Prism.text(14, .medium))
                Spacer()
                Button { model.regenerateSelectedSubtitles() } label: {
                    Label("Transcribe", systemImage: "waveform").font(Prism.text(10, .medium))
                }
                .buttonStyle(.plain).foregroundStyle(EditorStyle.accent)
                .disabled(model.isBusy || !hasAudio)
                .accessibilityLabel("Transcribe speech into captions")
                .help(hasAudio
                      ? (model.useGemini ? "Transcribe with Gemini in the cloud. Google API usage may incur charges." : "Transcribe on this Mac. Audio stays on this Mac.")
                      : "This source video has no audio track.")
            }
            if cues.isEmpty {
                Text(hasAudio ? "No captions yet. Transcribe this Short to create them." : "This source has no audio, so there is no speech to caption.")
                    .font(Prism.text(12)).foregroundStyle(Prism.textSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(cues.enumerated()), id: \.offset) { index, cue in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(editorTime(cue.start)).font(Prism.mono(9)).foregroundStyle(Prism.textSecondary)
                        TextField("Caption line", text: Binding(
                            get: { drafts.indices.contains(index) ? drafts[index] : cue.text },
                            set: { if drafts.indices.contains(index) { drafts[index] = $0 } }))
                            .textFieldStyle(.plain).font(Prism.text(12)).padding(7)
                            .background(EditorStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Caption at \(editorTime(cue.start))")
                    }
                }
                Text("Clear a line to remove it. Changing a line's words turns off its yellow highlight.")
                    .font(Prism.text(10)).foregroundStyle(Prism.textSecondary).fixedSize(horizontal: false, vertical: true)
                Button { model.updateSelectedCaptionTexts(drafts) } label: {
                    Text("Save captions").font(Prism.text(12, .medium)).frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(Prism.ink).background(Prism.action, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy || drafts == cues.map(\.text))
            }
        }
        .disabled(model.isBusy)
    }

    func styleButton(_ style: CaptionStyle, title: String, detail: String, selected: Bool) -> some View {
        Button { model.setSelectedCaptionStyle(style) } label: {
            HStack(spacing: 10) {
                CaptionStyleSample(highlight: style == .viral, size: 13)
                    .frame(width: 112, height: 34)
                    .background(Color.gray.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Prism.text(12, .medium))
                    Text(detail).font(Prism.text(10)).foregroundStyle(Prism.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? EditorStyle.accent : Prism.textSecondary)
            }
            .padding(8)
            .background(selected ? EditorStyle.accent.opacity(0.12) : EditorStyle.inset, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? EditorStyle.accent : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy || selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    func loadDrafts() {
        drafts = (model.activeSegment?.captions ?? []).map(\.text)
    }
}

private struct EditorMediaBin: View {
    @Bindable var model: AppModel
    @State private var tab = "Shorts"
    @State private var shortPosters: [UUID: NSImage] = [:]
    private let columns = [GridItem(.adaptive(minimum: 112), spacing: 10)]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tool("Shorts", "play.rectangle")
                tool("Captions", "captions.bubble")
            }.padding(.top, 12).padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if tab == "Shorts" {
                        if let clips = model.project?.segments, !clips.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Shorts").font(Prism.text(14, .medium))
                                    Text("\(clips.count)").font(Prism.text(10, .medium)).foregroundStyle(Prism.textSecondary)
                                    Spacer()
                                    Button { model.makeConfiguredShorts() } label: {
                                        Label("Create more", systemImage: "sparkles").font(Prism.text(10, .medium)).foregroundStyle(EditorStyle.accent)
                                    }.buttonStyle(.plain).help("Analyze this video's unused moments for more Shorts").disabled(model.isBusy)
                                }
                                LazyVGrid(columns: columns, spacing: 10) {
                                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                                        ZStack(alignment: .topTrailing) {
                                            Button {
                                                model.selection = clip.mediaID
                                                model.selectPreview(clip.id)
                                            } label: {
                                                VStack(alignment: .leading, spacing: 5) {
                                                    ZStack(alignment: .bottomLeading) {
                                                        GeometryReader { geometry in
                                                            if let poster = shortPosters[clip.id] {
                                                                Image(nsImage: poster).resizable().scaledToFill()
                                                                    .frame(width: geometry.size.width, height: 82).clipped()
                                                            } else if let media = model.project?.media.first(where: { $0.id == clip.mediaID }) {
                                                                mediaPoster(media).frame(width: geometry.size.width, height: 82).clipped()
                                                            } else {
                                                                Rectangle().fill(EditorStyle.inset)
                                                            }
                                                        }.frame(height: 82)
                                                        LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                                                        HStack(spacing: 4) {
                                                            Image(systemName: "play.fill")
                                                            Text("Short \(index + 1)").lineLimit(1)
                                                            Spacer(minLength: 0)
                                                            Text(editorTime(clip.duration)).monospacedDigit()
                                                        }.font(Prism.text(9, .medium)).padding(5)
                                                    }.clipShape(RoundedRectangle(cornerRadius: 4))
                                                    if let title = clip.suggestedTitle, !title.isEmpty {
                                                        Text(title).font(Prism.text(10, .medium)).lineLimit(2)
                                                    }
                                                    Text("Starts at \(editorTime(clip.start))")
                                                        .font(Prism.text(9)).foregroundStyle(Prism.textSecondary).lineLimit(1)
                                                }.padding(5).frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(model.previewShortID == clip.id ? EditorStyle.accent.opacity(0.14) : EditorStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.previewShortID == clip.id ? EditorStyle.accent : .clear, lineWidth: 1))
                                            }.buttonStyle(.plain).accessibilityLabel("Preview Short \(index + 1)")
                                            Button { model.removeShort(clip.id) } label: {
                                                Image(systemName: "xmark")
                                                    .font(Prism.text(9, .medium))
                                                    .foregroundStyle(.white)
                                                    .frame(width: 22, height: 22)
                                                    .background(.black.opacity(0.78), in: Circle())
                                            }
                                            .buttonStyle(.plain)
                                            .padding(9)
                                            .disabled(model.isBusy)
                                            .help("Remove Short · Undo available")
                                            .accessibilityLabel("Remove Short \(index + 1)")
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                        HStack {
                            Text("Main video").font(Prism.text(14, .medium))
                            Spacer()
                            Button { model.importVideo() } label: { Image(systemName: "plus") }
                                .buttonStyle(.plain).help("Import video").accessibilityLabel("Import video")
                                .disabled(model.isBusy)
                        }
                        Button { model.importVideo() } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                                .font(Prism.text(12, .medium)).frame(maxWidth: .infinity).padding(.vertical, 9)
                                .background(Prism.surface2, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(model.isBusy)
                        if model.project?.media.isEmpty != false {
                            Text("Import a video to begin editing.").font(Prism.text(12)).foregroundStyle(Prism.textSecondary).padding(.vertical, 28)
                        } else {
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(model.project?.media ?? []) { media in
                                    Button {
                                        model.selection = media.id
                                        model.selectPreview(nil)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            ZStack(alignment: .bottomTrailing) {
                                                mediaPoster(media)
                                                    .frame(height: 70)
                                                    .clipped()
                                                    .background(EditorStyle.inset)
                                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                                Text(editorTime(media.duration)).font(Prism.mono(9))
                                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 3)).padding(4)
                                            }
                                            Text(media.name).font(Prism.text(10)).lineLimit(1)
                                            Text("\(media.width) × \(media.height)").font(Prism.text(9)).foregroundStyle(Prism.textSecondary)
                                        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(EditorStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.previewShortID == nil && model.selection == media.id ? EditorStyle.accent : .clear, lineWidth: 1))
                                    }.buttonStyle(.plain).accessibilityLabel("Source video \(media.name)")
                                }
                            }
                        }
                        if model.project?.media.isEmpty == false {
                            Button { model.addManualClip() } label: {
                                Label("Add clip to timeline", systemImage: "plus.rectangle.on.rectangle")
                                    .font(Prism.text(11, .medium)).foregroundStyle(EditorStyle.accent)
                            }.buttonStyle(.plain).disabled(model.isBusy)
                        }
                    } else {
                        EditorCaptionsPanel(model: model)
                    }
                }.padding(14)
            }
            .task(id: model.project?.segments ?? []) { await loadShortPosters() }
            Divider()
            Button { model.screen = .importSource } label: {
                Label("Auto Shorts settings", systemImage: "sparkles").font(Prism.text(11, .medium))
                    .frame(maxWidth: .infinity).padding(14)
            }.buttonStyle(.plain).disabled(model.isBusy)
        }.background(EditorStyle.panel)
    }
    func tool(_ title: String, _ icon: String) -> some View {
        Button { tab = title } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(Prism.text(17))
                Text(title).font(Prism.text(11, .medium))
            }.foregroundStyle(tab == title ? Prism.text : Prism.textSecondary).frame(maxWidth: .infinity).frame(height: 52)
                .overlay(alignment: .bottom) { if tab == title { Prism.accent.frame(height: 2) } }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityAddTraits(tab == title ? .isSelected : [])
    }

    @ViewBuilder
    func mediaPoster(_ media: MediaItem) -> some View {
        if let path = media.thumbnail, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                EditorStyle.inset
                Image(systemName: "film").font(Prism.text(16)).foregroundStyle(Prism.textSecondary)
            }
        }
    }

    @MainActor
    func loadShortPosters() async {
        let entries = model.project?.segments.compactMap { clip -> (UUID, URL, Double)? in
            guard let media = model.project?.media.first(where: { $0.id == clip.mediaID }) else { return nil }
            return (clip.id, URL(fileURLWithPath: media.path), min(max(0.1, clip.start + clip.duration * 0.45), max(0.1, media.duration - 0.1)))
        } ?? []
        for (id, url, seconds) in entries where shortPosters[id] == nil {
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                return try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
            }.value
            if let image { shortPosters[id] = NSImage(cgImage: image, size: .zero) }
        }
        let validIDs = Set(entries.map(\.0))
        shortPosters = shortPosters.filter { validIDs.contains($0.key) }
    }
}

private struct EditorPlayer: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
            Text(model.activeSegment == nil ? "Source video" : "Short preview").font(Prism.text(12, .medium))
                Spacer()
                Text(model.activeSegment == nil ? "Original" : "Vertical · 9:16").font(Prism.text(10)).foregroundStyle(Prism.textSecondary)
                Button { model.selectPreview(nil) } label: { Image(systemName: "rectangle.on.rectangle") }
                    .buttonStyle(.plain).help("Preview original source").accessibilityLabel("Preview original source")
            }.padding(.horizontal, 16).frame(height: 40)
            ZStack {
                if let player = model.player {
                    RelioPlayerView(player: player, captionSegment: model.previewSegment)
                } else if model.isPreviewLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Rendering preview…").font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
                    }
                } else if let error = model.previewError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Prism.amber)
                        Text(error).font(Prism.text(12)).multilineTextAlignment(.center)
                        Button("Retry preview") { model.selectPreview(model.previewShortID) }
                    }.padding(24)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "play.rectangle").font(Prism.text(36)).foregroundStyle(Prism.textSecondary)
                        Text("Your video goes here").font(Prism.text(13, .medium))
                        Button("Import video") { model.importVideo() }.disabled(model.isBusy)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black).padding(.horizontal, 16)
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                HStack(spacing: 12) {
                    Text(editorTime(model.player?.currentTime().seconds ?? 0))
                        .foregroundStyle(EditorStyle.accent)
                    Text("/ \(editorTime(model.activeSegment?.duration ?? model.project?.media.first(where: { $0.id == model.selection })?.duration ?? 0))")
                        .foregroundStyle(Prism.textSecondary)
                    Spacer()
                    Button { model.seekPreview(to: 0) } label: { Image(systemName: "backward.end.fill") }
                        .help("Go to start").accessibilityLabel("Go to start")
                    Button {
                        guard let player = model.player else { return }
                        if player.rate != 0 { player.pause() }
                        else {
                            let length = model.activeSegment?.duration ?? model.project?.media.first(where: { $0.id == model.selection })?.duration ?? 0
                            if player.currentTime().seconds >= length - 0.1 { model.seekPreview(to: 0) }
                            player.play()
                        }
                    } label: { Image(systemName: model.player?.rate == 0 ? "play.fill" : "pause.fill") }
                        .help("Play or pause").accessibilityLabel("Play or pause preview")
                    Spacer()
                    Text("30 fps").foregroundStyle(Prism.textSecondary)
                    Button { model.isPlayerExpanded = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("Fill the window · press Esc to exit").accessibilityLabel("Expand preview to fill the window")
                }.font(Prism.mono(11)).buttonStyle(.plain)
                    .disabled(model.player == nil).padding(.horizontal, 18).frame(height: 44)
            }
        }.background(EditorStyle.canvas)
    }
}

private struct EditorInspector: View {
    @Bindable var model: AppModel
    @State private var tab = "Clip"
    @State private var start = 0.0
    @State private var duration = 30.0
    @State private var caption = ""
    @State private var captionStart = 0.0
    @State private var captionDuration = 30.0
    @State private var cropZoom = 1.08
    @State private var cropPosition = 0.5
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                inspectorTab("Edit Short")
                inspectorTab("AI assistant")
                Spacer()
            }.padding(.horizontal, 16).frame(height: 40)
            Divider()
            if tab == "AI assistant" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.useGemini ? "Gemini · Cloud" : model.aiModelName == "Not installed" ? "Built-in editing commands" : "\(model.aiModelName) · Local")
                            .font(Prism.text(10)).foregroundStyle(EditorStyle.accent)
                        ForEach(model.chatMessages) { item in
                            Text(item.text).font(Prism.text(12)).padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(item.isUser ? EditorStyle.accent.opacity(0.10) : Prism.surface1, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }.padding(14)
                }
                HStack {
                    TextField("Describe an edit…", text: $model.chatInput).textFieldStyle(.plain).onSubmit { model.sendChat() }
                        .accessibilityLabel("Editing instruction")
                    Button { model.sendChat() } label: { Image(systemName: "arrow.up.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(EditorStyle.accent).accessibilityLabel("Send editing instruction")
                }.font(Prism.text(12)).padding(12).background(EditorStyle.inset).padding(12).disabled(model.isBusy)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let clip = model.activeSegment {
                            Text(clip.suggestedTitle ?? "Video").font(Prism.text(13, .medium))
                            if let reason = clip.selectionReason, !reason.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Why suggested").font(Prism.text(10, .medium))
                                    Text(reason).font(Prism.text(11)).foregroundStyle(Prism.textSecondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if let notice = clip.captionNotice, !notice.isEmpty {
                                Label(notice, systemImage: "info.circle").font(Prism.text(11)).foregroundStyle(Prism.amber)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("Clip range").font(Prism.text(10, .medium)).foregroundStyle(Prism.textSecondary)
                            numberField("Start (seconds)", value: $start)
                            numberField(clip.speechWords?.isEmpty == false ? "Target duration (seconds)" : "Duration (seconds)", value: $duration)
                            if clip.speechWords?.isEmpty == false {
                                Text("Cuts move slightly to keep the first and last spoken words whole.")
                                    .font(Prism.text(10)).foregroundStyle(Prism.textSecondary)
                            }
                            Divider()
                            Text("Video layout").font(Prism.text(10, .medium)).foregroundStyle(Prism.textSecondary)
                            HStack(spacing: 6) {
                                framingButton("Fit", fit: true, selected: clip.fitToFrame == true)
                                framingButton("Fill", fit: false, selected: clip.fitToFrame != true)
                            }
                            if clip.fitToFrame != true {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(clip.cropKeyframes == nil ? "Horizontal framing" : "Tracking offset")
                                            .font(Prism.text(11)).foregroundStyle(Prism.textSecondary)
                                        Spacer()
                                        Text(cropPosition < 0.34 ? "Left" : cropPosition > 0.66 ? "Right" : "Center")
                                            .font(Prism.mono(10)).foregroundStyle(Prism.textSecondary)
                                    }
                                    Slider(value: $cropPosition, in: 0...1, step: 0.01)
                                        .tint(Prism.accent)
                                        .accessibilityLabel(clip.cropKeyframes == nil ? "Horizontal crop position" : "Subject tracking offset")
                                    HStack {
                                        Text("Left"); Spacer(); Text("Center"); Spacer(); Text("Right")
                                    }.font(Prism.text(9)).foregroundStyle(Prism.textSecondary)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Crop zoom").font(Prism.text(11)).foregroundStyle(Prism.textSecondary)
                                        Spacer()
                                        Text("\(Int(cropZoom * 100))%")
                                            .font(Prism.mono(10)).foregroundStyle(Prism.textSecondary)
                                    }
                                    Slider(value: $cropZoom, in: 1...1.5, step: 0.05)
                                        .tint(Prism.accent)
                                        .accessibilityLabel("Crop zoom")
                                }
                            }
                            Text(clip.fitToFrame == true
                                 ? "Show the complete source over a blurred background."
                                 : clip.cropKeyframes == nil
                                    ? "Manually added clips glide across wide footage. Zoom trims source edges."
                                    : clip.cropKeyframes?.isEmpty == false
                                        ? "Auto framing follows the main subject, holds steady while it is framed, and resets on scene cuts. Adjust tracking offset here. Zoom trims source edges."
                                        : "No clear subject was detected in this Short, so its crop holds steady. Adjust the framing offset here.")
                                .font(Prism.text(11)).foregroundStyle(Prism.textSecondary)
                            if clip.fitToFrame != true {
                                HStack(spacing: 14) {
                                    Button { model.holdFramingAtCenter() } label: {
                                        Label("Center & hold", systemImage: "pause.circle")
                                            .font(Prism.text(11, .medium))
                                    }
                                    Button { model.retrackSelectedSubject() } label: {
                                        Label("Re-track", systemImage: "viewfinder")
                                            .font(Prism.text(11, .medium))
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(EditorStyle.accent)
                                .disabled(model.isBusy)
                                .help("Center the crop and hold it, or re-analyze to follow the subject")
                            }
                            Divider()
                            Text("On-screen text").font(Prism.text(10, .medium)).foregroundStyle(Prism.textSecondary)
                            TextEditor(text: $caption).font(Prism.text(12)).scrollContentBackground(.hidden)
                                .frame(height: 70).padding(6).background(EditorStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("Clip text")
                            Text("Speech captions are edited in the Captions tab.")
                                .font(Prism.text(10)).foregroundStyle(Prism.textSecondary)
                            numberField("Text starts at", value: $captionStart)
                            numberField("Text duration", value: $captionDuration)
                            Text("Times are relative to this Short.").font(Prism.text(10)).foregroundStyle(Prism.textSecondary)
                            Button {
                                model.updateSelectedEdit(start: start, duration: duration, caption: caption, captionStart: captionStart,
                                    captionDuration: min(captionDuration, max(0, duration - captionStart)), cropZoom: cropZoom,
                                    cropPosition: cropPosition)
                            } label: {
                                Text("Apply changes").font(Prism.text(12, .medium)).frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .foregroundStyle(Prism.ink).background(Prism.action, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                            Divider()
                            Toggle("Mute source audio", isOn: Binding(get: { model.activeSegment?.isMuted == true }, set: { _ in model.toggleSelectedAudio() }))
                                .font(Prism.text(12)).toggleStyle(.switch).controlSize(.small)
                        } else {
                            Image(systemName: "slider.horizontal.3").font(Prism.text(25)).foregroundStyle(Prism.textSecondary).padding(.top, 35)
                            Text("Select a clip to edit").font(Prism.text(13, .medium))
                            Text("Choose a Short from the media bin, or add a clip to the timeline.").font(Prism.text(12)).foregroundStyle(Prism.textSecondary)
                            if model.selection != nil {
                                Button("Add clip to timeline") { model.addManualClip() }
                            }
                        }
                    }.padding(16).disabled(model.isBusy)
                }
            }
        }.background(EditorStyle.panel)
            .onAppear { loadDraft() }
            .onChange(of: model.activeSegment) { oldValue, newValue in
                reconcileDraft(from: oldValue, to: newValue)
            }
            .onChange(of: model.previewShortID) { _, _ in loadDraft() }
    }

    func reconcileDraft(from oldValue: EditSegment?, to newValue: EditSegment?) {
        guard let oldValue, let newValue, oldValue.id == newValue.id else {
            loadDraft()
            return
        }
        if start == oldValue.start { start = newValue.start }
        if duration == oldValue.duration { duration = newValue.duration }
        if caption == oldValue.caption { caption = newValue.caption }
        if captionStart == (oldValue.captionStart ?? 0) { captionStart = newValue.captionStart ?? 0 }
        let oldCaptionDuration = min(oldValue.captionDuration ?? oldValue.duration, oldValue.duration - (oldValue.captionStart ?? 0))
        let newCaptionDuration = min(newValue.captionDuration ?? newValue.duration, newValue.duration - (newValue.captionStart ?? 0))
        if captionDuration == oldCaptionDuration { captionDuration = newCaptionDuration }
        let oldCropZoom = min(1.5, max(1, oldValue.cropZoom ?? 1.08))
        let newCropZoom = min(1.5, max(1, newValue.cropZoom ?? 1.08))
        if cropZoom == oldCropZoom { cropZoom = newCropZoom }
        let oldCropPosition = min(1, max(0, oldValue.cropPosition ?? 0.5))
        let newCropPosition = min(1, max(0, newValue.cropPosition ?? 0.5))
        if cropPosition == oldCropPosition { cropPosition = newCropPosition }
    }
    func loadDraft() {
        guard let clip = model.activeSegment else { return }
        start = clip.start; duration = clip.duration; caption = clip.caption
        captionStart = clip.captionStart ?? 0
        captionDuration = min(clip.captionDuration ?? clip.duration, clip.duration - captionStart)
        cropZoom = min(1.5, max(1, clip.cropZoom ?? 1.08))
        cropPosition = min(1, max(0, clip.cropPosition ?? 0.5))
    }
    func inspectorTab(_ title: String) -> some View {
        Button { tab = title } label: {
            Text(title).font(Prism.text(12, .medium)).foregroundStyle(tab == title ? Prism.text : Prism.textSecondary)
                .frame(height: 40).overlay(alignment: .bottom) { if tab == title { Prism.accent.frame(height: 2) } }
        }.buttonStyle(.plain)
        .accessibilityAddTraits(tab == title ? .isSelected : [])
    }
    func numberField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(Prism.text(11)).foregroundStyle(Prism.textSecondary)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.plain).multilineTextAlignment(.trailing).font(Prism.mono(11))
                .frame(width: 74).padding(7).background(EditorStyle.inset, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel(title)
        }
    }
    func framingButton(_ title: String, fit: Bool, selected: Bool) -> some View {
        Button {
            model.setFraming(fit: fit)
            if fit { cropZoom = 1 }
        } label: {
            Label(title, systemImage: fit ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(Prism.text(11)).frame(maxWidth: .infinity).padding(8)
                .foregroundStyle(selected ? EditorStyle.accent : Prism.textSecondary)
                .background(selected ? EditorStyle.accent.opacity(0.1) : Prism.surface1, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? EditorStyle.accent.opacity(0.5) : .clear))
        }.buttonStyle(.plain).accessibilityLabel(fit ? "Fit entire video" : "Fill vertical frame")
    }
}

private struct EditorTimeline: View {
    @Bindable var model: AppModel
    var media: MediaItem? { model.project?.media.first(where: { $0.id == model.selection }) }
    var length: Double { max(0.1, model.activeSegment?.duration ?? media?.duration ?? 1) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button { model.undoFromEditor() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo edit").disabled(model.editHistory.isEmpty || model.isBusy)
                Button { model.toggleSelectedAudio() } label: { Image(systemName: model.activeSegment?.isMuted == true ? "speaker.slash" : "speaker.wave.2") }
                    .help("Toggle clip audio").disabled(model.activeSegment == nil || model.isBusy)
                    .accessibilityLabel("Toggle clip audio")
                Rectangle().fill(EditorStyle.line).frame(width: 1, height: 16)
                Text(model.activeSegment == nil ? "Source timeline" : "Short timeline").font(Prism.text(11, .medium))
                Spacer()
                Button("Add clip") { model.addManualClip() }.disabled(media == nil || model.isBusy)
                Button { model.makeConfiguredShorts() } label: { Label("Auto Shorts", systemImage: "sparkles") }
                    .disabled(media == nil || model.isBusy)
                Button { model.screen = .importSource } label: { Image(systemName: "gearshape") }
                    .help("Auto Shorts settings").accessibilityLabel("Auto Shorts settings").disabled(model.isBusy)
            }.font(Prism.text(12)).buttonStyle(.plain).padding(.horizontal, 18).frame(height: 42)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 28)
                    trackLabel("Video", "film", height: 68)
                    trackLabel("Focus L↕R", "viewfinder", height: 28)
                    trackLabel("Text", "textformat", height: 38)
                    trackLabel("Audio", "waveform", height: 38)
                    Spacer(minLength: 0)
                }.frame(width: 100).background(EditorStyle.inset)
                GeometryReader { geometry in
                    let width = max(1, geometry.size.width - 24)
                    VStack(spacing: 8) {
                        HStack {
                            ForEach(0..<7, id: \.self) { index in
                                Text(editorTime(length * Double(index) / 6)).font(Prism.mono(10)).foregroundStyle(Prism.textSecondary)
                                if index != 6 { Spacer(minLength: 0) }
                            }
                        }.frame(height: 20)
                        videoTrack(width: width).frame(height: 60)
                        focusTrack(width: width).frame(height: 22)
                        textTrack(width: width).frame(height: 30)
                        HStack {
                            Image(systemName: model.activeSegment?.isMuted == true ? "speaker.slash.fill" : "waveform")
                            Text(model.activeSegment?.isMuted == true ? "Muted" : media?.hasAudio == true ? "Source audio" : "No audio")
                            Spacer()
                        }.font(Prism.text(10)).foregroundStyle(Prism.text).padding(.horizontal, 10)
                            .frame(height: 30).background(media?.hasAudio == true && model.activeSegment?.isMuted != true ? Prism.sky.opacity(0.22) : Prism.surface1, in: RoundedRectangle(cornerRadius: 4))
                    }.padding(.horizontal, 12).padding(.top, 4)
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        let time = model.player?.currentTime().seconds ?? 0
                        let x = 12 + width * max(0, min(1, (time.isFinite ? time : 0) / length))
                        ZStack(alignment: .top) {
                            Rectangle().fill(.white).frame(width: 1, height: 173)
                            Image(systemName: "arrowtriangle.down.fill").font(Prism.text(10)).foregroundStyle(Prism.text).offset(y: -1)
                        }.position(x: x, y: 100).allowsHitTesting(false)
                    }
                    Color.clear.contentShape(Rectangle()).frame(height: 25)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            model.seekPreview(to: (value.location.x - 12) / width * length)
                        })
                        .accessibilityLabel("Timeline seek ruler")
                }
            }
        }.background(EditorStyle.panel)
    }
    func trackLabel(_ title: String, _ icon: String, height: CGFloat) -> some View {
        Label(title, systemImage: icon).font(Prism.text(10)).foregroundStyle(Prism.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 15).frame(height: height)
    }
    func videoTrack(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8).fill(Prism.surface2)
            if let media {
                TimelineFilmstrip(media: media, width: width, height: 60)
                    .opacity(0.82)
                Text(media.name).font(Prism.text(10, .medium)).lineLimit(1)
                    .padding(5).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3)).padding(6)
                if model.activeSegment == nil {
                    ForEach(model.project?.segments.filter { $0.mediaID == media.id } ?? []) { clip in
                        Button { model.selectPreview(clip.id) } label: {
                            RoundedRectangle(cornerRadius: 4).fill(EditorStyle.accent.opacity(0.3))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(EditorStyle.accent, lineWidth: 2))
                        }.buttonStyle(.plain).frame(width: max(6, width * clip.duration / length), height: 60)
                            .offset(x: width * clip.start / length).accessibilityLabel("Select clip at \(editorTime(clip.start))")
                    }
                }
            } else {
                Text("Add a video to start your timeline").font(Prism.text(12)).foregroundStyle(Prism.textSecondary).padding(.leading, 12)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.activeSegment == nil ? Prism.surface2 : EditorStyle.accent, lineWidth: model.activeSegment == nil ? 1 : 2))
    }
    func textTrack(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(Prism.surface1)
            if let clip = model.activeSegment {
                let subtitles = clip.captions ?? []
                if !clip.caption.isEmpty {
                    let start = max(0, min(length, clip.captionStart ?? 0))
                    let duration = max(0, min(length - start, clip.captionDuration ?? clip.duration))
                    Text(clip.caption).font(Prism.text(9, .medium)).lineLimit(1).padding(.horizontal, 8)
                        .frame(width: max(1, width * duration / length), height: 30, alignment: .leading)
                        .background(Prism.amber.opacity(0.32), in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: width * start / length)
                        .accessibilityLabel("Text overlay from \(editorTime(start)) for \(editorTime(duration))")
                }
                ForEach(Array(subtitles.enumerated()), id: \.offset) { _, cue in
                    let start = max(0, min(length, cue.start))
                    let duration = max(0, min(length - start, cue.duration))
                    RoundedRectangle(cornerRadius: 3).fill(EditorStyle.accent.opacity(0.78))
                        .frame(width: max(2, width * duration / length), height: 9)
                        .offset(x: width * start / length, y: 8)
                        .accessibilityLabel("Subtitle \(cue.text) at \(editorTime(start))")
                }
                if clip.caption.isEmpty && subtitles.isEmpty {
                    Text("No text or subtitles").font(Prism.text(10)).foregroundStyle(Prism.textSecondary).padding(.leading, 10)
                }
            } else {
                Text("Select a Short to edit text and subtitles").font(Prism.text(10)).foregroundStyle(Prism.textSecondary).padding(.leading, 10)
            }
        }
    }

    func focusTrack(width: CGFloat) -> some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let points = model.activeSegment?.cropKeyframes ?? []
            let offset = (model.activeSegment?.cropPosition ?? 0.5) - 0.5
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(EditorStyle.accent.opacity(0.06))
                if points.count > 1, let clip = model.activeSegment {
                    Path { path in
                        for (index, point) in points.enumerated() {
                            let x = width * min(1, max(0, point.time / max(0.1, clip.duration)))
                            let y = 2 + (1 - min(1, max(0, point.position + offset))) * max(1, height - 4)
                            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else if point.isSceneCut == true { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }.stroke(EditorStyle.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        Circle().fill(.white).frame(width: 4, height: 4)
                            .position(x: width * min(1, max(0, point.time / max(0.1, clip.duration))),
                                      y: 2 + (1 - min(1, max(0, point.position + offset))) * max(1, height - 4))
                    }
                } else if let point = points.first {
                    Path { path in
                        let y = 2 + (1 - min(1, max(0, point.position + offset))) * max(1, height - 4)
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: width, y: y))
                    }.stroke(EditorStyle.accent.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                } else {
                    Text(model.activeSegment == nil ? "Select a Short to view its focus path" : "Click or drag to set focus")
                        .font(Prism.text(9)).foregroundStyle(Prism.textSecondary).padding(.leading, 8)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onEnded { value in
                    guard let clip = model.activeSegment else { return }
                    let sourceTime = min(clip.duration, max(0, value.startLocation.x / max(1, width) * clip.duration))
                    let targetTime = min(clip.duration, max(0, value.location.x / max(1, width) * clip.duration))
                    let position = min(1, max(0, 1 - value.location.y / max(1, height)))
                    let moved = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y) > 4
                    model.adjustCropKeyframe(from: sourceTime, to: targetTime, position: position, insert: !moved)
                })
            .help("Click to add a focus point or drag an existing point. The crop follows the line over time.")
            .accessibilityLabel("Subject focus path. Click to add or drag a focus point.")
        }
        .frame(width: width, height: 22)
    }
}

private struct TimelineFilmstrip: View {
    let media: MediaItem
    let width: CGFloat
    let height: CGFloat
    @State private var frames: [NSImage] = []

    private var sampleCount: Int { max(1, min(120, Int(ceil(media.duration / 60)))) }

    var body: some View {
        HStack(spacing: 0) {
            if frames.isEmpty {
                if let path = media.thumbnail, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: width, height: height).clipped()
                }
            } else {
                ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                    Image(nsImage: frame).resizable().scaledToFill()
                        .frame(width: width / CGFloat(frames.count), height: height).clipped()
                }
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
        .task(id: "\(media.path)-\(sampleCount)") { await makeFrames() }
    }

    @MainActor
    private func makeFrames() async {
        let path = media.path
        let duration = media.duration
        let count = sampleCount
        let images = await Task.detached(priority: .utility) { () -> [CGImage] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 140)
            return (0..<count).compactMap { index in
                let seconds = min(Double(index) * 60 + 30, max(0, duration - 0.1))
                return try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
            }
        }.value
        frames = images.map { NSImage(cgImage: $0, size: .zero) }
    }
}

private func editorTime(_ value: Double) -> String {
    let seconds = Int(max(0, value.isFinite ? value : 0))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
