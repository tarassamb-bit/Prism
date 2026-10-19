import SwiftUI

/// README images in the Prism brand: Ink ground, Space Grotesk 500 headlines, Sora 400/500 text, JetBrains Mono timecodes,
/// Sky only for actions, and the spectrum together only in the mark or as the progress line's found clips.
enum Brand {
    static let ink = Color(brandHex: 0x0E0F14), paper = Color(brandHex: 0xF6F3EC)
    static let surface1 = Color(brandHex: 0x171920), surface2 = Color(brandHex: 0x20232B), border = Color(brandHex: 0x2C2F37)
    static let secondary = Color(brandHex: 0x8A8F98)
    static let sky = Color(brandHex: 0x3FA9F5), coral = Color(brandHex: 0xFF6B57), amber = Color(brandHex: 0xFFC233)

    static func display(_ size: CGFloat) -> Font { .custom("SpaceGrotesk-Medium", fixedSize: size) }
    static func text(_ size: CGFloat, medium: Bool = false) -> Font { .custom(medium ? "Sora-Medium" : "Sora-Regular", fixedSize: size) }
    static func mono(_ size: CGFloat) -> Font { .custom("JetBrainsMono-Regular", fixedSize: size) }
}

extension Color {
    init(brandHex hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The brand's Tag: a pill on Surface 2 in Sora 500.
struct BrandTag: View {
    let label: String
    var mono = false
    var body: some View {
        Text(label).font(mono ? Brand.mono(14) : Brand.text(15, medium: true)).foregroundStyle(Brand.paper)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(Brand.surface2))
    }
}

/// The brand's Card: Surface 1, 1px Border, 12pt radius.
struct BrandCard<Content: View>: View {
    var padding: CGFloat = 24
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(padding)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.surface1))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.border, lineWidth: 1))
    }
}

/// The signature progress line: one Paper line that splits into colored segments where clips were found.
struct ProgressSignature: View {
    /// Found clips as fractions of the source: start and length.
    let clips: [(start: Double, length: Double)]
    var thickness: CGFloat = 3
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.paper).frame(height: thickness)
                ForEach(clips.indices, id: \.self) { index in
                    Capsule().fill([Brand.coral, Brand.amber, Brand.sky][index % 3])
                        .frame(width: max(thickness * 6, geometry.size.width * clips[index].length), height: thickness * 2.4)
                        .offset(x: geometry.size.width * clips[index].start)
                }
            }.frame(maxHeight: .infinity)
        }.frame(height: thickness * 2.4)
    }
}

/// An image filling a fixed size, with the card radius and a 1px Border.
struct FramedImage: View {
    let image: NSImage
    let width: CGFloat
    let height: CGFloat
    var radius: CGFloat = 12
    var body: some View {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            .frame(width: width, height: height).clipped()
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Brand.border, lineWidth: 1))
    }
}

/// The panel every README image sits on: Ink with the large-panel radius.
struct InkPanel<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content
    var body: some View {
        content.frame(width: width).background(Brand.ink).clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct HeroArt: View {
    let editor: NSImage
    let clips: [(start: Double, length: Double)]
    var body: some View {
        ZStack(alignment: .topLeading) {
            Brand.ink
            FramedImage(image: editor, width: 820, height: 512).offset(x: 580, y: 156)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    PrismMark().frame(height: 40)
                    Text("Prism").font(Brand.display(40)).tracking(-1.2).foregroundStyle(Brand.paper)
                }
                Spacer().frame(height: 64)
                Text("One in.\nMany out.").font(Brand.display(84)).tracking(-2.5).lineSpacing(-6).foregroundStyle(Brand.paper)
                    .fixedSize()
                Spacer().frame(height: 24)
                Text("Choose a video and Prism finds the moments worth sharing, then cuts, captions and frames each one as a vertical Short.")
                    .font(Brand.text(20)).lineSpacing(9).foregroundStyle(Brand.secondary).frame(width: 450, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer().frame(height: 40)
                VStack(alignment: .leading, spacing: 10) {
                    ProgressSignature(clips: clips)
                    HStack {
                        Text("00:00:00")
                        Spacer()
                        Text("5 Shorts found")
                        Spacer()
                        Text("00:42:18")
                    }.font(Brand.mono(13)).foregroundStyle(Brand.secondary)
                }.frame(width: 450)
                Spacer().frame(height: 36)
                HStack(spacing: 8) {
                    ForEach(["macOS 14+", "Gemini", "Swift 6", "MIT"], id: \.self) { BrandTag(label: $0) }
                }
            }.padding(64)
        }
        .frame(width: 1280, height: 660)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct ScreenArt: View {
    let screen: NSImage
    var body: some View {
        FramedImage(image: screen, width: 1440, height: 900, radius: 16)
    }
}

struct LayoutsArt: View {
    let shorts: [(image: NSImage, name: String, duration: String, detail: String)]
    var body: some View {
        InkPanel(width: 1280) {
            HStack(alignment: .top, spacing: 32) {
                ForEach(shorts.indices, id: \.self) { index in
                    BrandCard {
                        VStack(alignment: .leading, spacing: 0) {
                            FramedImage(image: shorts[index].image, width: 300, height: 533, radius: 8)
                                .overlay(alignment: .topTrailing) { BrandTag(label: shorts[index].duration, mono: true).padding(12) }
                            Spacer().frame(height: 20)
                            Text(shorts[index].name).font(Brand.display(26)).tracking(-0.3).foregroundStyle(Brand.paper)
                            Spacer().frame(height: 8)
                            Text(shorts[index].detail).font(Brand.text(15)).lineSpacing(6).foregroundStyle(Brand.secondary)
                                .frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }.padding(.vertical, 56)
        }
    }
}

struct CaptionsArt: View {
    let tiles: [(image: NSImage, name: String, detail: String)]
    var body: some View {
        InkPanel(width: 1280) {
            Grid(horizontalSpacing: 24, verticalSpacing: 32) {
                ForEach([0, 4], id: \.self) { row in
                    GridRow(alignment: .top) {
                        ForEach(row..<row + 4, id: \.self) { index in
                            if index < tiles.count { tile(tiles[index]) } else { note }
                        }
                    }
                }
            }.padding(56)
        }
    }
    private func tile(_ tile: (image: NSImage, name: String, detail: String)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FramedImage(image: tile.image, width: 270, height: 200, radius: 8)
            Spacer().frame(height: 14)
            Text(tile.name).font(Brand.text(16, medium: true)).foregroundStyle(Brand.paper)
            Spacer().frame(height: 4)
            Text(tile.detail).font(Brand.text(13)).lineSpacing(4).foregroundStyle(Brand.secondary)
                .frame(width: 270, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var note: some View {
        BrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Word timing").font(Brand.text(16, medium: true)).foregroundStyle(Brand.paper)
                Text("Styles that follow each word use Gemini's word timing. When it can't be verified, captions fall back to whole phrases instead of guessing.")
                    .font(Brand.text(13)).lineSpacing(4).foregroundStyle(Brand.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(width: 230, height: 190, alignment: .topLeading)
        }
    }
}

struct PipelineArt: View {
    let filmstrip: [NSImage]
    let clips: [(start: Double, length: Double)]
    let shorts: [NSImage]
    let steps = [
        ("01", "Transcribe", "Gemini writes a sentence transcript of the whole range and keeps it for next time."),
        ("02", "Score", "Every overlapping window gets a 0–100 score for its hook, story and payoff."),
        ("03", "Refine", "The best windows become exact clips with a title, a reason and a layout."),
        ("04", "Final cut", "One editor pass keeps distinct stories. Runner-ups wait as backups."),
        ("05", "Cut and frame", "Edges land on whole sentences, filler goes, and the crop follows the subject.")
    ]
    var body: some View {
        InkPanel(width: 1280) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(filmstrip.indices, id: \.self) { index in
                        Image(nsImage: filmstrip[index]).resizable().interpolation(.high).aspectRatio(16 / 9, contentMode: .fill)
                            .frame(width: (1168 - 4 * CGFloat(filmstrip.count - 1)) / CGFloat(filmstrip.count), height: 64).clipped()
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 8))
                Spacer().frame(height: 18)
                ProgressSignature(clips: clips, thickness: 3)
                Spacer().frame(height: 10)
                HStack {
                    Text("00:00:00"); Spacer(); Text("Source · 42 minutes"); Spacer(); Text("00:42:18")
                }.font(Brand.mono(13)).foregroundStyle(Brand.secondary)
                Spacer().frame(height: 40)
                HStack(alignment: .top, spacing: 14) {
                    ForEach(steps, id: \.0) { step in
                        BrandCard(padding: 20) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(step.0).font(Brand.display(28)).tracking(-0.5).foregroundStyle(Brand.secondary)
                                Text(step.1).font(Brand.text(17, medium: true)).foregroundStyle(Brand.paper)
                                Text(step.2).font(Brand.text(13)).lineSpacing(4).foregroundStyle(Brand.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(width: 182, height: 170, alignment: .topLeading)
                        }
                    }
                }
                Spacer().frame(height: 40)
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Out").font(Brand.display(28)).tracking(-0.5).foregroundStyle(Brand.paper)
                        Text("Vertical 1080 × 1920 MP4s with captions, rendered on your Mac. Review each one before export.")
                            .font(Brand.text(14)).lineSpacing(5).foregroundStyle(Brand.secondary)
                            .frame(width: 330, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    ForEach(shorts.indices, id: \.self) { index in
                        FramedImage(image: shorts[index], width: 135, height: 240, radius: 8)
                    }
                }
            }.padding(56)
        }
    }
}

struct PaletteArt: View {
    let swatches: [(name: String, hex: String, color: Color, role: String)] = [
        ("Ink", "#0E0F14", Brand.ink, "The ground. About 80% of every surface."),
        ("Paper", "#F6F3EC", Brand.paper, "Text on Ink, the ground in light mode."),
        ("Sky", "#3FA9F5", Brand.sky, "Actions and selection only."),
        ("Coral", "#FF6B57", Brand.coral, "Status and clip categories."),
        ("Amber", "#FFC233", Brand.amber, "Status and warnings.")
    ]
    var body: some View {
        InkPanel(width: 1280) {
            VStack(alignment: .leading, spacing: 40) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(swatches, id: \.name) { swatch in
                        BrandCard(padding: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                Rectangle().fill(swatch.color).frame(height: 96)
                                    .overlay(alignment: .bottom) { Rectangle().fill(Brand.border).frame(height: 1) }
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(swatch.name).font(Brand.text(16, medium: true)).foregroundStyle(Brand.paper)
                                        Spacer()
                                        Text(swatch.hex).font(Brand.mono(13)).foregroundStyle(Brand.secondary)
                                    }
                                    Text(swatch.role).font(Brand.text(13)).lineSpacing(4).foregroundStyle(Brand.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.padding(18)
                            }.frame(width: 217, height: 196, alignment: .top)
                        }.clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 56) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Space Grotesk").font(Brand.display(40)).tracking(-1.2).foregroundStyle(Brand.paper)
                        Text("500 · headlines, numbers, the wordmark").font(Brand.text(13)).foregroundStyle(Brand.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sora").font(Brand.text(36)).foregroundStyle(Brand.paper)
                        Text("400 and 500 · interface and body text").font(Brand.text(13)).foregroundStyle(Brand.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("00:42:18").font(Brand.mono(36)).foregroundStyle(Brand.paper)
                        Text("JetBrains Mono · timecodes").font(Brand.text(13)).foregroundStyle(Brand.secondary)
                    }
                }
            }.padding(56)
        }
    }
}
