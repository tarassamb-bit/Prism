using System.Globalization;
using Prism.Core;

namespace Prism.Linux;

/// <summary>The persistent editor surface. Refresh changes data without replacing the video or the active text fields.</summary>
public sealed class LinuxEditor : IDisposable
{
    readonly AppSession session;
    readonly Gtk.Window window;
    readonly SynchronizationContext? context = SynchronizationContext.Current;
    readonly Gtk.Box root = Box(Gtk.Orientation.Vertical, 0);
    readonly Gtk.Box media = Box(Gtk.Orientation.Vertical, 10);
    readonly Gtk.Box captions = Box(Gtk.Orientation.Vertical, 12);
    readonly Gtk.Box inspector = Box(Gtk.Orientation.Vertical, 12);
    readonly Gtk.Box chatHistory = Box(Gtk.Orientation.Vertical, 10);
    readonly Gtk.Box timelineSection = Box(Gtk.Orientation.Vertical, 6);
    readonly Gtk.Box rightPanel = Box(Gtk.Orientation.Vertical, 0);
    readonly Gtk.Notebook leftTabs = Gtk.Notebook.New();
    readonly Gtk.Notebook rightTabs = Gtk.Notebook.New();
    readonly Gtk.Paned outer = Gtk.Paned.New(Gtk.Orientation.Horizontal);
    readonly Gtk.Paned middle = Gtk.Paned.New(Gtk.Orientation.Horizontal);
    readonly Gtk.Paned vertical = Gtk.Paned.New(Gtk.Orientation.Vertical);
    readonly Gtk.Video video = Gtk.Video.New();
    readonly Gtk.Label title = Label("Editor", "subtitle");
    readonly Gtk.Label saved = Label("", "muted");
    readonly Gtk.Label status = Label("", "muted");
    readonly Gtk.Label playerNotice = Label("Import a video to begin.", "muted");
    readonly Gtk.Label playerTime = Label("00:00 / 00:00", "mono");
    readonly Gtk.Label sourceName = Label("Source video", "muted");
    readonly Gtk.Button play;
    readonly Gtk.Button undo;
    readonly Gtk.Button expand;
    readonly Gtk.Scale seek = Gtk.Scale.NewWithRange(Gtk.Orientation.Horizontal, 0, 1, 0.01);
    readonly Gtk.Entry chatInput = Gtk.Entry.New();
    readonly Gtk.EventControllerKey keys = Gtk.EventControllerKey.New();
    readonly LinuxTimeline timeline;
    readonly PreviewPlayer player;
    readonly System.Threading.Timer ticker;
    readonly Dictionary<string, byte[]> thumbnailCache = [];
    readonly Dictionary<CaptionStyle, byte[]> stylePreviews = [];
    readonly HashSet<string> loadingThumbnails = [];
    string? mediaSignature, inspectorSignature, captionSignature;
    Guid? inspectorId;
    int chatCount = -1;
    string? loadedPath, loadedIdentity;
    double pendingSeek;
    bool pendingSeekReady, resumePlayback, updatingSeek, disposed, panesInitialized, previewSuspended, chatNeedsScroll;
    Gtk.ScrolledWindow? chatScroll;
    int clockTicks;

    public Gtk.Widget Widget => root;
    public event Action<string>? Error;

    public LinuxEditor(AppSession session, Gtk.Window window)
    {
        this.session = session;
        this.window = window;
        player = new PreviewPlayer(video, ClearPlayback);
        session.Player = player;
        root.SetHexpand(true); root.SetVexpand(true);
        var header = Box(Gtk.Orientation.Horizontal, 10); Pad(header, 14); header.AddCssClass("toolbar");
        header.Append(Button("‹ Home", () => session.Screen = Screen.Home));
        var heading = Box(Gtk.Orientation.Vertical, 2); heading.SetHexpand(true); heading.Append(title); heading.Append(saved); header.Append(heading);
        header.Append(Button("Exports", session.RevealExports));
        undo = Button("Undo", session.UndoFromEditor); header.Append(undo);
        header.Append(Button("Export", () => session.ChooseExport(), "primary"));
        root.Append(header);

        Pad(media, 12); Pad(captions, 12); Pad(inspector, 14); Pad(chatHistory, 12);
        leftTabs.AppendPage(Scroll(media), Label("Shorts"));
        leftTabs.AppendPage(Scroll(captions), Label("Captions"));
        leftTabs.SetSizeRequest(200, -1);
        outer.SetStartChild(leftTabs); outer.SetEndChild(middle);
        outer.SetResizeStartChild(false); outer.SetShrinkStartChild(false); outer.SetWideHandle(true);

        var viewer = Box(Gtk.Orientation.Vertical, 8); Pad(viewer, 14); viewer.SetHexpand(true); viewer.SetVexpand(true);
        var playerHeader = Box(Gtk.Orientation.Horizontal, 8); sourceName.SetHexpand(true); playerHeader.Append(sourceName);
        expand = Button("Expand player", () => session.IsPlayerExpanded = !session.IsPlayerExpanded); playerHeader.Append(expand); viewer.Append(playerHeader);
        video.SetAutoplay(false); video.SetLoop(false); video.SetHexpand(true); video.SetVexpand(true); video.SetSizeRequest(180, 220);
        var picture = Gtk.Overlay.New(); picture.SetHexpand(true); picture.SetVexpand(true); picture.SetChild(video);
        playerNotice.SetHalign(Gtk.Align.Center); playerNotice.SetValign(Gtk.Align.Center); playerNotice.SetWrap(true); picture.AddOverlay(playerNotice); viewer.Append(picture);
        var controls = Box(Gtk.Orientation.Horizontal, 8);
        controls.Append(Button("−5 s", () => session.SeekPreviewBy(-5)));
        play = Button("Play", session.TogglePlayback); controls.Append(play);
        controls.Append(Button("+5 s", () => session.SeekPreviewBy(5)));
        seek.SetDrawValue(false); seek.SetHexpand(true);
        seek.OnValueChanged += (_, _) => { if (!updatingSeek) session.SeekPreview(seek.GetValue()); };
        controls.Append(seek); controls.Append(playerTime); viewer.Append(controls);
        middle.SetStartChild(viewer); middle.SetEndChild(rightPanel); middle.SetResizeStartChild(true); middle.SetResizeEndChild(false); middle.SetShrinkEndChild(false); middle.SetWideHandle(true);
        rightPanel.SetSizeRequest(248, -1);
        rightTabs.SetVexpand(true);
        rightTabs.AppendPage(Scroll(inspector), Label("Edit Short"));
        rightTabs.AppendPage(BuildChat(), Label("AI assistant"));
        rightPanel.Append(rightTabs);

        timeline = new LinuxTimeline(session); timeline.Widget.SetVexpand(true); timelineSection.Append(timeline.Widget);
        vertical.SetStartChild(outer); vertical.SetEndChild(timelineSection); vertical.SetResizeStartChild(true); vertical.SetResizeEndChild(false); vertical.SetShrinkEndChild(false); vertical.SetWideHandle(true); vertical.SetVexpand(true);
        root.Append(vertical); Pad(status, 10); status.SetWrap(true); root.Append(status);
        keys.SetPropagationPhase(Gtk.PropagationPhase.Capture); keys.OnKeyPressed += OnKeyPressed; window.AddController(keys);
        ticker = new System.Threading.Timer(_ => context?.Post(_ => Tick(), null), null, 100, 100);
        Refresh();
    }

    public void Refresh()
    {
        if (disposed) return;
        if (session.Screen != Screen.Editor) { video.GetMediaStream()?.Pause(); return; }
        if (!ReferenceEquals(session.Player, player)) session.Player = player;
        title.SetText(session.Project?.DisplayTitle ?? "Editor");
        saved.SetText(session.LastSavedAt is { } time ? "Saved " + time.ToString("HH:mm", CultureInfo.CurrentCulture) : "");
        status.SetText(session.Message);
        undo.SetSensitive(session.CanUndo && !session.IsBusy);
        expand.SetLabel(session.IsPlayerExpanded ? "Close expanded player" : "Expand player");
        leftTabs.SetVisible(!session.IsPlayerExpanded); rightPanel.SetVisible(!session.IsPlayerExpanded); timelineSection.SetVisible(!session.IsPlayerExpanded);
        sourceName.SetText(session.ActiveSegment?.SuggestedTitle ?? session.Project?.Media.FirstOrDefault(m => m.Id == session.Selection)?.Name ?? "Source video");
        SyncPlayer();
        var currentMedia = session.Project is null ? "" : session.Project.Id + "|" + string.Join("|", session.Project.Media.Select(m => $"{m.Id}:{m.Thumbnail}:{m.Path}"))
            + string.Join("|", session.Project.Segments.Select(s => $"{s.Id}:{s.Start}:{s.Duration}:{s.SuggestedTitle}")) + session.PreviewShortId;
        if (mediaSignature != currentMedia) { mediaSignature = currentMedia; BuildMedia(); }
        var selected = session.ActiveSegment;
        var signature = selected is null ? "source" : PrismJson.Serialize(selected);
        if (inspectorId != selected?.Id || inspectorSignature != signature && !TextEditingInside(inspector))
        { inspectorId = selected?.Id; inspectorSignature = signature; BuildInspector(); }
        if (captionSignature != signature && !TextEditingInside(captions)) { captionSignature = signature; BuildCaptions(); }
        if (chatCount != session.ChatMessages.Count) { chatCount = session.ChatMessages.Count; BuildChatHistory(); }
        if (!FocusInside(chatInput) && chatInput.GetText() != session.ChatInput) chatInput.SetText(session.ChatInput);
        timeline.Refresh();
    }

    void SyncPlayer()
    {
        var identity = session.PreviewShortId?.ToString() ?? "source:" + session.Selection;
        if (session.PreviewPath is null)
        {
            if (loadedPath is not null && !previewSuspended)
            {
                pendingSeek = loadedIdentity == identity ? player.CurrentTime : 0;
                resumePlayback = loadedIdentity == identity && video.GetMediaStream()?.GetPlaying() == true;
                pendingSeekReady = false;
                video.GetMediaStream()?.Pause();
                previewSuspended = true;
            }
            playerNotice.SetVisible(true);
            playerNotice.SetText(session.IsPreviewLoading ? "Preparing preview…" : session.PreviewError ?? "Import a video to begin.");
            return;
        }
        playerNotice.SetVisible(false);
        var wasSuspended = previewSuspended;
        previewSuspended = false;
        if (loadedPath == session.PreviewPath)
        {
            if (wasSuspended) pendingSeekReady = true;
            return;
        }
        if (loadedIdentity != identity) { pendingSeek = 0; resumePlayback = false; }
        else if (!wasSuspended)
        { pendingSeek = player.CurrentTime; resumePlayback = video.GetMediaStream()?.GetPlaying() == true; }
        loadedIdentity = identity; loadedPath = session.PreviewPath;
        video.SetFilename(loadedPath); pendingSeekReady = true;
        seek.SetRange(0, Math.Max(0.01, session.PreviewLength));
    }

    void ClearPlayback()
    {
        video.GetMediaStream()?.Pause();
        video.SetMediaStream(null!);
        loadedPath = loadedIdentity = null;
        pendingSeek = 0;
        pendingSeekReady = resumePlayback = previewSuspended = false;
    }

    void Tick()
    {
        if (disposed || session.Screen != Screen.Editor) return;
        if (chatNeedsScroll && chatScroll is not null)
        {
            chatNeedsScroll = false;
            var adjustment = chatScroll.GetVadjustment();
            adjustment.SetValue(Math.Max(0, adjustment.GetUpper() - adjustment.GetPageSize()));
        }
        var stream = video.GetMediaStream();
        if (stream is not null)
        {
            if (pendingSeekReady && stream.IsPrepared())
            {
                pendingSeekReady = false;
                stream.Seek((long)(Math.Clamp(pendingSeek, 0, Math.Max(0, session.PreviewLength)) * 1_000_000));
                if (resumePlayback) stream.Play();
                pendingSeek = 0; resumePlayback = false;
            }
            updatingSeek = true; seek.SetValue(player.CurrentTime); updatingSeek = false;
            playerTime.SetText(Format.Clock(player.CurrentTime) + " / " + Format.Clock(session.PreviewLength));
            play.SetLabel(stream.GetPlaying() ? "Pause" : "Play");
            if (stream.GetError() is { } error) { playerNotice.SetVisible(true); playerNotice.SetText("Could not play this video. Check the GStreamer MP4 plugins. " + error.Message); }
        }
        if (!panesInitialized && vertical.GetHeight() > 300 && middle.GetWidth() > 400)
        {
            panesInitialized = true;
            outer.SetPosition((int)session.Settings.LeftSidebarWidth);
            middle.SetPosition(Math.Max(180, middle.GetWidth() - (int)session.Settings.RightSidebarWidth));
            vertical.SetPosition(Math.Max(160, vertical.GetHeight() - (int)session.Settings.TimelineHeight));
        }
        if (++clockTicks % 10 == 0 && panesInitialized && !session.IsPlayerExpanded)
        {
            session.Settings.LeftSidebarWidth = Math.Clamp(outer.GetPosition(), 200, 700);
            session.Settings.RightSidebarWidth = Math.Clamp(middle.GetWidth() - middle.GetPosition(), 248, 700);
            session.Settings.TimelineHeight = Math.Clamp(vertical.GetHeight() - vertical.GetPosition(), 150, 700);
            session.Settings.Save();
        }
    }

    void BuildMedia()
    {
        Clear(media);
        var bar = Box(Gtk.Orientation.Horizontal, 6); bar.Append(Label("Project media", "subtitle")); bar.Append(Button("Import", () => _ = ImportVideo())); media.Append(bar);
        if (session.Project is not { } project) { media.Append(Label("Import a long video to make your first Short.", "muted")); return; }
        foreach (var item in project.Media.Where(m => m.Kind == "video"))
        {
            var row = Box(Gtk.Orientation.Vertical, 5); row.AddCssClass("card"); Pad(row, 8);
            if (item.Thumbnail is { } path && File.Exists(path)) { var image = Gtk.Picture.NewForFilename(path); image.SetSizeRequest(160, 88); image.SetCanShrink(true); row.Append(image); }
            row.Append(Label(item.Name)); row.Append(Label(Format.Duration(item.Duration) + " · Source video", "muted"));
            var button = Gtk.Button.New(); button.SetChild(row); button.OnClicked += (_, _) => { session.Selection = item.Id; session.SelectPreview(null); }; media.Append(button);
        }
        media.Append(Label($"Shorts · {project.Segments.Count}", "subtitle"));
        if (project.Segments.Count == 0) media.Append(Label("No Shorts yet. Create Shorts or add a clip from the timeline.", "muted"));
        for (var index = 0; index < project.Segments.Count; index++)
        {
            var segment = project.Segments[index]; var number = index + 1;
            var row = Box(Gtk.Orientation.Vertical, 5); row.AddCssClass("card"); Pad(row, 8);
            if (segment.Id == session.PreviewShortId) row.AddCssClass("bordered");
            var source = project.Media.FirstOrDefault(m => m.Id == segment.MediaId);
            if (source is not null)
            {
                var key = source.Id + ":" + segment.Start.ToString("R", CultureInfo.InvariantCulture);
                var image = Gtk.Picture.New(); image.SetSizeRequest(160, 86); image.SetCanShrink(true); row.Append(image);
                if (thumbnailCache.TryGetValue(key, out var bytes)) SetImage(image, bytes);
                else if (source.Thumbnail is { } poster && File.Exists(poster)) image.SetFilename(poster);
                if (!thumbnailCache.ContainsKey(key) && loadingThumbnails.Add(key)) _ = LoadThumbnail(key, source.Path, segment.Start + Math.Min(0.2, segment.Duration / 2), image);
            }
            row.Append(Label(segment.SuggestedTitle ?? $"Short {number}"));
            row.Append(Label(Format.Clock(segment.Duration) + " · " + Format.Clock(segment.Start), "mono"));
            var select = Gtk.Button.New(); select.SetChild(row);
            if (segment.Id == session.PreviewShortId) select.AddCssClass("selected");
            select.OnClicked += (_, _) => session.SelectPreview(segment.Id); media.Append(select);
            var actions = Box(Gtk.Orientation.Horizontal, 5); actions.Append(Button("Export", () => session.ChooseExport(segment.Id))); actions.Append(Button("Remove", () => session.RemoveShort(segment.Id), "danger")); media.Append(actions);
            var menu = Gtk.GestureClick.New(); menu.SetButton(3);
            menu.OnPressed += (_, _) =>
            {
                var popup = Gtk.Popover.New(); popup.SetParent(select); var options = Box(Gtk.Orientation.Vertical, 4); Pad(options, 8);
                options.Append(Button("Export this Short", () => { popup.Popdown(); session.ChooseExport(segment.Id); }));
                options.Append(Button("Remove Short", () => { popup.Popdown(); session.RemoveShort(segment.Id); }, "danger")); popup.SetChild(options); popup.OnClosed += (_, _) => popup.Unparent(); popup.Popup();
            };
            select.AddController(menu);
        }
    }

    async Task LoadThumbnail(string key, string path, double at, Gtk.Picture image)
    {
        try
        {
            var bytes = await FFmpeg.FrameJpeg(path, at, 360);
            if (disposed || bytes is null) return;
            thumbnailCache[key] = bytes;
            SetImage(image, bytes);
        }
        catch (Exception) { }
        finally { loadingThumbnails.Remove(key); }
    }

    async Task ImportVideo()
    {
        try
        {
            var dialog = Gtk.FileDialog.New(); dialog.SetTitle("Import video");
            var file = await dialog.OpenAsync(window);
            if (file?.GetPath() is { } path) await session.ImportSource(path);
        }
        catch (Exception) { }
    }

    void BuildInspector()
    {
        Clear(inspector);
        if (session.ActiveSegment is not { } clip)
        {
            inspector.Append(Label("Select a Short", "subtitle")); inspector.Append(Label("Choose a Short to edit its timing, framing and text overlay.", "muted"));
            inspector.Append(Button("Add clip", session.AddManualClip)); return;
        }
        var source = session.Project?.Media.FirstOrDefault(m => m.Id == clip.MediaId);
        inspector.Append(Label(clip.SuggestedTitle ?? "Edit Short", "subtitle"));
        if (clip.SelectionReason is { Length: > 0 } reason) inspector.Append(Label(reason, "muted"));
        var start = Spin(clip.Start, 0, source?.Duration ?? clip.Start + clip.Duration);
        var duration = Spin(clip.Duration, 0.05, source?.Duration ?? clip.Duration);
        inspector.Append(Field("Source start · seconds", start)); inspector.Append(Field("Duration · seconds", duration));
        var overlay = Gtk.Entry.New(); overlay.SetText(clip.Caption); overlay.SetPlaceholderText("Text overlay"); inspector.Append(Field("Text overlay", overlay));
        var textStart = Spin(clip.CaptionStart ?? 0, 0, clip.Duration);
        var textDuration = Spin(clip.CaptionDuration ?? clip.Duration, 0.05, clip.Duration);
        inspector.Append(Field("Text start · seconds", textStart)); inspector.Append(Field("Text duration · seconds", textDuration));
        var zoom = Spin(clip.CropZoom ?? 1.08, 1, 1.5, 0.01);
        var position = Spin(clip.CropPosition ?? 0.5, 0, 1, 0.01);
        inspector.Append(Field("Zoom", zoom)); inspector.Append(Field("Horizontal position", position));
        inspector.Append(Button("Save changes", () => session.UpdateSelectedEdit(start.GetValue(), duration.GetValue(), overlay.GetText(), textStart.GetValue(), textDuration.GetValue(), zoom.GetValue(), position.GetValue()), "primary"));
        inspector.Append(Label("Layout", "subtitle"));
        var layouts = Box(Gtk.Orientation.Horizontal, 4); layouts.Append(Button("Fill", () => session.SetFraming(false))); layouts.Append(Button("Fit", () => session.SetFraming(true))); layouts.Append(Button("Split", () => _ = session.SetSplitScreen())); inspector.Append(layouts);
        inspector.Append(Label(clip.SplitScreen == true ? "Two speakers, captions in the middle." : clip.FitToFrame == true ? "The full source frame stays visible." : "Vertical crop follows the focus path.", "muted"));
        inspector.Append(Button("Center and hold", session.HoldFramingAtCenter));
        inspector.Append(Button("Re-track subject", session.RetrackSelectedSubject));
        inspector.Append(Button(clip.IsMuted == true ? "Restore audio" : "Mute audio", session.ToggleSelectedAudio));
        inspector.Append(Button("Transcribe", () => _ = session.RegenerateSelectedSubtitles()));
        if (clip.CaptionNotice is { } notice) inspector.Append(Label(notice, "muted"));
        inspector.Append(Button("Export this Short", () => session.ChooseExport(clip.Id)));
        inspector.Append(Button("Remove Short", () => session.RemoveShort(clip.Id), "danger"));
    }

    void BuildCaptions()
    {
        Clear(captions);
        if (session.ActiveSegment is not { } clip) { captions.Append(Label("Select a Short to edit its subtitles.", "muted")); return; }
        captions.Append(Label("Caption style", "subtitle"));
        foreach (var style in CaptionStyles.Choices)
        {
            var body = Box(Gtk.Orientation.Vertical, 6); Pad(body, 8);
            var image = Gtk.Picture.New(); image.SetSizeRequest(150, 38); image.SetCanShrink(true);
            try
            {
                if (!stylePreviews.TryGetValue(style, out var preview)) stylePreviews[style] = preview = CaptionRenderer.StylePreview(style);
                SetImage(image, preview);
            }
            catch (Exception) { }
            body.Append(image); body.Append(Label(style.Title()));
            var button = Gtk.Button.New(); button.SetChild(body);
            if ((clip.CaptionStyle ?? CaptionStyle.Classic).Resolved() == style.Resolved()) button.AddCssClass("selected");
            button.OnClicked += (_, _) => session.SetSelectedCaptionStyle(style); captions.Append(button);
        }
        var captionPosition = Combo(Enum.GetValues<CaptionPosition>().Select(p => p.Title()).ToArray(), (int)(clip.CaptionPosition ?? CaptionPosition.Bottom));
        captionPosition.OnChanged += (_, _) => session.SetSelectedCaptionLayout(position: (CaptionPosition)captionPosition.GetActive());
        captions.Append(Field("Position", captionPosition));
        var size = Combo(Enum.GetValues<CaptionSize>().Select(s => s.Title()).ToArray(), (int)(clip.CaptionSize ?? CaptionSize.Medium));
        size.OnChanged += (_, _) => session.SetSelectedCaptionLayout(size: (CaptionSize)size.GetActive()); captions.Append(Field("Size", size));
        var animation = Combo(["Off", "Pop in"], clip.CaptionAnimated == true ? 1 : 0);
        animation.OnChanged += (_, _) => session.SetSelectedCaptionLayout(animated: animation.GetActive() == 1); captions.Append(Field("Animation", animation));
        captions.Append(Label("Subtitle text", "subtitle"));
        var editors = new List<Gtk.Entry>();
        foreach (var cue in clip.Captions ?? [])
        {
            captions.Append(Label(Format.Clock(cue.Start) + " — " + Format.Clock(cue.Start + cue.Duration), "mono"));
            var entry = Gtk.Entry.New(); entry.SetText(cue.Text); entry.SetTooltipText("Clear this line to remove the caption."); captions.Append(entry); editors.Add(entry);
        }
        if (editors.Count > 0) captions.Append(Button("Save caption text", () => session.UpdateSelectedCaptionTexts(editors.Select(e => e.GetText()).ToArray()), "primary"));
        else captions.Append(Label("No generated speech subtitles yet.", "muted"));
        captions.Append(Button("Transcribe", () => _ = session.RegenerateSelectedSubtitles()));
        if (clip.CaptionNotice is { } notice) captions.Append(Label(notice, "muted"));
    }

    Gtk.Widget BuildChat()
    {
        var chat = Box(Gtk.Orientation.Vertical, 8); Pad(chat, 10);
        chatScroll = Scroll(chatHistory); chatScroll.SetVexpand(true); chat.Append(chatScroll);
        var suggestions = Box(Gtk.Orientation.Vertical, 4);
        foreach (var suggestion in new[] { "Make a 30 second Short", "Add subtitles", "Make it 20 seconds" })
            suggestions.Append(Button(suggestion, () => _ = session.SendChat(suggestion)));
        chat.Append(suggestions);
        chatInput.SetPlaceholderText("Ask Gemini to edit this Short…");
        chatInput.OnChanged += (_, _) => session.ChatInput = chatInput.GetText();
        chatInput.OnActivate += (_, _) => _ = session.SendChat(); chat.Append(chatInput);
        chat.Append(Button("Send", () => _ = session.SendChat(), "primary"));
        return chat;
    }

    void BuildChatHistory()
    {
        Clear(chatHistory);
        chatNeedsScroll = true;
        foreach (var item in session.ChatMessages)
        {
            var card = Box(Gtk.Orientation.Vertical, 4); card.AddCssClass("card"); Pad(card, 10);
            card.Append(Label(item.IsUser ? "You" : "Gemini", "subtitle")); var text = Label(item.Text); text.SetSelectable(true); card.Append(text); chatHistory.Append(card);
        }
    }

    bool OnKeyPressed(Gtk.EventControllerKey sender, Gtk.EventControllerKey.KeyPressedSignalArgs args)
    {
        if (disposed || session.Screen != Screen.Editor || !root.IsSensitive() || !session.IsGeminiKeySaved || session.IsBusy
            || session.ExportChoice is not null || session.ExportSummary is not null || session.GenerationError is not null || Typing()) return false;
        var control = (args.State & Gdk.ModifierType.ControlMask) != 0;
        var shift = (args.State & Gdk.ModifierType.ShiftMask) != 0;
        switch (args.Keyval)
        {
            case 32: session.TogglePlayback(); return true;
            case 0xff51: session.SeekPreviewBy(shift ? -5 : -1); return true;
            case 0xff53: session.SeekPreviewBy(shift ? 5 : 1); return true;
            case 0xffff: if (session.PreviewShortId is { } id) session.RemoveShort(id); return true;
            case 0x7a or 0x5a when control: session.UndoFromEditor(); return true;
            case 0xff1b when session.IsPlayerExpanded: session.IsPlayerExpanded = false; return true;
            default: return false;
        }
    }

    bool Typing()
    {
        for (var focused = window.GetFocus(); focused is not null; focused = focused.GetParent())
            if (focused is Gtk.Entry or Gtk.TextView or Gtk.SpinButton || focused is Gtk.Editable) return true;
        return false;
    }

    bool FocusInside(Gtk.Widget ancestor)
    {
        for (var focused = window.GetFocus(); focused is not null; focused = focused.GetParent())
            if (ReferenceEquals(focused, ancestor) || focused.Handle.DangerousGetHandle() == ancestor.Handle.DangerousGetHandle()) return true;
        return false;
    }

    bool TextEditingInside(Gtk.Widget ancestor) => FocusInside(ancestor) && Typing();

    static Gtk.Box Box(Gtk.Orientation orientation, int spacing) => Gtk.Box.New(orientation, spacing);
    static Gtk.Label Label(string text, string? css = null)
    {
        var label = Gtk.Label.New(text); label.SetXalign(0); label.SetWrap(true); label.SetWrapMode(Pango.WrapMode.WordChar);
        if (css is not null) label.AddCssClass(css);
        return label;
    }
    Gtk.Button Button(string text, Action action, string? css = null)
    {
        var button = Gtk.Button.NewWithLabel(text); if (css is not null) button.AddCssClass(css);
        button.OnClicked += (_, _) =>
        {
            try { action(); }
            catch (Exception error) { session.Message = error.Message; Error?.Invoke(error.Message); }
        };
        return button;
    }
    static Gtk.ScrolledWindow Scroll(Gtk.Widget child)
    {
        var scroll = Gtk.ScrolledWindow.New(); scroll.SetPolicy(Gtk.PolicyType.Never, Gtk.PolicyType.Automatic); scroll.SetChild(child); scroll.SetVexpand(true); return scroll;
    }
    static Gtk.Widget Field(string title, Gtk.Widget editor)
    {
        var box = Box(Gtk.Orientation.Vertical, 4); box.Append(Label(title, "muted")); box.Append(editor); return box;
    }
    static Gtk.SpinButton Spin(double value, double min, double max, double step = 0.1)
    {
        var spin = Gtk.SpinButton.NewWithRange(min, Math.Max(min, max), step); spin.SetDigits(2); spin.SetValue(value); spin.SetNumeric(true); return spin;
    }
    static Gtk.ComboBoxText Combo(string[] values, int selected)
    {
        var combo = Gtk.ComboBoxText.New(); foreach (var value in values) combo.AppendText(value); combo.SetActive(selected); return combo;
    }
    static void SetImage(Gtk.Picture image, byte[] bytes)
    {
        using var data = GLib.Bytes.New(bytes.AsSpan()); image.SetPaintable(Gdk.Texture.NewFromBytes(data));
    }
    static void Pad(Gtk.Widget widget, int value)
    { widget.SetMarginTop(value); widget.SetMarginBottom(value); widget.SetMarginStart(value); widget.SetMarginEnd(value); }
    static void Clear(Gtk.Box box)
    { while (box.GetFirstChild() is { } child) box.Remove(child); }

    public void Dispose()
    {
        if (disposed) return; disposed = true; ticker.Dispose(); ClearPlayback();
        if (ReferenceEquals(session.Player, player)) session.Player = null;
        window.RemoveController(keys); timeline.Dispose();
    }

    sealed class PreviewPlayer(Gtk.Video video, Action clear) : IPreviewPlayer
    {
        public double CurrentTime => (video.GetMediaStream()?.GetTimestamp() ?? 0) / 1_000_000.0;
        public void Seek(double seconds) { if (double.IsFinite(seconds)) video.GetMediaStream()?.Seek((long)(Math.Max(0, seconds) * 1_000_000)); }
        public void Clear() => clear();
        public void TogglePlayback()
        {
            if (video.GetMediaStream() is not { } stream) return;
            if (stream.GetPlaying()) stream.Pause(); else stream.Play();
        }
    }
}
