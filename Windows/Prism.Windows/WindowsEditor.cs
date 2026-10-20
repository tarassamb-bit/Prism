using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Prism.Core;

namespace Prism.Windows;

/// <summary>A persistent native editor: only selection-dependent panels change; text entry and playback survive status updates.</summary>
public sealed class WindowsEditor : IDisposable
{
    readonly AppSession session;
    readonly Window window;
    readonly Grid root = new();
    readonly Grid panes = new();
    readonly StackPanel media = Column(), captions = Column(), inspector = Column(), chatHistory = Column();
    readonly TabControl leftTabs = new(), rightTabs = new();
    readonly MediaElement video = new() { LoadedBehavior = MediaState.Manual, UnloadedBehavior = MediaState.Manual, ScrubbingEnabled = true, Stretch = Stretch.Uniform };
    readonly TextBlock title = Text("Editor", 20), saved = Text("", 11, true), status = Text("", 12, true), playerTime = Text("00:00 / 00:00", 11, true), sourceName = Text("Source video", 12, true);
    readonly TextBlock playerNotice = Text("Import a video to begin.", 14, true);
    readonly Button play, undo, expand;
    readonly Slider seek = new() { Minimum = 0, Maximum = 1, SmallChange = 0.1, LargeChange = 5, VerticalAlignment = VerticalAlignment.Center, MinWidth = 80 };
    readonly TextBox chatInput = new() { MinHeight = 36, Margin = new Thickness(0, 8, 0, 0) };
    readonly ScrollViewer chatScroll;
    readonly WindowsTimeline timeline;
    readonly PreviewPlayer player;
    readonly DispatcherTimer ticker = new() { Interval = TimeSpan.FromMilliseconds(100) };
    readonly Dictionary<string, byte[]> thumbnails = [];
    readonly Dictionary<CaptionStyle, byte[]> stylePreviews = [];
    readonly HashSet<string> loadingThumbnails = [];
    readonly GridSplitter leftSplitter, rightSplitter, timelineSplitter;
    string? mediaSignature, inspectorSignature, captionSignature;
    Guid? inspectorId;
    string? loadedPath, loadedIdentity;
    int chatCount = -1;
    double pendingSeek;
    bool resumePlayback, previewSuspended, updatingSeek, disposed, expanded;

    public UIElement Widget => root;
    public event Action<string>? Error;

    public WindowsEditor(AppSession session, Window window)
    {
        this.session = session; this.window = window;
        player = new PreviewPlayer(video, ClearPlayback); session.Player = player;
        root.SetResourceReference(Panel.BackgroundProperty, "Surface0");
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 180 });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(5) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(session.Settings.TimelineHeight), MinHeight = 260 });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var header = new DockPanel { Margin = new Thickness(16, 10, 16, 10), LastChildFill = true };
        var home = Button("‹ Home", () => session.Screen = Screen.Home); DockPanel.SetDock(home, Dock.Left); header.Children.Add(home);
        var actions = Row(); DockPanel.SetDock(actions, Dock.Right);
        actions.Children.Add(Button("Exports", session.RevealExports)); undo = Button("Undo", session.UndoFromEditor); actions.Children.Add(undo);
        actions.Children.Add(Button("Export", () => session.ChooseExport(), primary: true)); header.Children.Add(actions);
        var heading = Column(); heading.Margin = new Thickness(12, 0, 12, 0); heading.Children.Add(title); heading.Children.Add(saved); header.Children.Add(heading); Add(root, header, 0);

        panes.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(session.Settings.LeftSidebarWidth), MinWidth = 200 });
        panes.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(5) });
        panes.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 200 });
        panes.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(5) });
        panes.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(session.Settings.RightSidebarWidth), MinWidth = 248 });
        StyleTabs(leftTabs); StyleTabs(rightTabs);
        leftTabs.Items.Add(Tab("Shorts", Scroll(media))); leftTabs.Items.Add(Tab("Captions", Scroll(captions)));
        Add(panes, leftTabs, 0, 0); leftSplitter = Splitter(); Add(panes, leftSplitter, 0, 1);
        var viewer = new Grid { Margin = new Thickness(14) };
        viewer.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); viewer.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); viewer.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var viewerHead = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        expand = Button("Expand player", () => session.IsPlayerExpanded = !session.IsPlayerExpanded); DockPanel.SetDock(expand, Dock.Right); viewerHead.Children.Add(expand); viewerHead.Children.Add(sourceName); Add(viewer, viewerHead, 0);
        var picture = new Grid { Background = Brushes.Black, MinHeight = 140, ClipToBounds = true }; picture.Children.Add(video);
        playerNotice.HorizontalAlignment = HorizontalAlignment.Center; playerNotice.VerticalAlignment = VerticalAlignment.Center; playerNotice.MaxWidth = 360; playerNotice.Margin = new Thickness(20); picture.Children.Add(playerNotice); Add(viewer, picture, 1);
        var controls = new Grid { Margin = new Thickness(0, 8, 0, 0) };
        foreach (var width in new[] { GridLength.Auto, GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto }) controls.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        Add(controls, Button("−5 s", () => session.SeekPreviewBy(-5)), 0, 0);
        play = Button("Play", session.TogglePlayback); Add(controls, play, 0, 1); Add(controls, Button("+5 s", () => session.SeekPreviewBy(5)), 0, 2);
        seek.ValueChanged += (_, _) => { if (!updatingSeek) session.SeekPreview(seek.Value); }; Add(controls, seek, 0, 3); playerTime.Margin = new Thickness(8); Add(controls, playerTime, 0, 4); Add(viewer, controls, 2);
        Add(panes, viewer, 0, 2); rightSplitter = Splitter(); Add(panes, rightSplitter, 0, 3);
        rightTabs.Items.Add(Tab("Edit Short", Scroll(inspector)));
        var chat = new DockPanel { Margin = new Thickness(10) };
        var composer = Column(); DockPanel.SetDock(composer, Dock.Bottom);
        foreach (var suggestion in new[] { "Make a 30 second Short", "Add subtitles", "Make it 20 seconds" })
            composer.Children.Add(AsyncButton(suggestion, () => session.SendChat(suggestion)));
        chatInput.ToolTip = "Ask Gemini to edit this Short…";
        chatInput.TextChanged += (_, _) => session.ChatInput = chatInput.Text;
        chatInput.KeyDown += async (_, args) => { if (args.Key == Key.Enter && !Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) { args.Handled = true; await Safe(() => session.SendChat()); } };
        composer.Children.Add(chatInput); composer.Children.Add(AsyncButton("Send", () => session.SendChat(), primary: true)); chat.Children.Add(composer);
        chatScroll = Scroll(chatHistory); chat.Children.Add(chatScroll);
        rightTabs.Items.Add(Tab("AI assistant", chat)); Add(panes, rightTabs, 0, 4); Add(root, panes, 1);
        timelineSplitter = new GridSplitter { Height = 5, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch, ResizeDirection = GridResizeDirection.Rows, ResizeBehavior = GridResizeBehavior.PreviousAndNext, ShowsPreview = true };
        timelineSplitter.SetResourceReference(Control.BackgroundProperty, "Line"); Add(root, timelineSplitter, 2);
        timeline = new WindowsTimeline(session); Add(root, timeline.Widget, 3);
        status.Margin = new Thickness(12, 6, 12, 6); Add(root, status, 4);
        leftSplitter.DragCompleted += (_, _) => SavePaneSizes(); rightSplitter.DragCompleted += (_, _) => SavePaneSizes(); timelineSplitter.DragCompleted += (_, _) => SavePaneSizes();
        video.MediaOpened += MediaOpened; video.MediaEnded += (_, _) => player.Pause();
        video.MediaFailed += (_, args) => { player.Pause(); SignalError("Could not play this video: " + args.ErrorException.Message); };
        window.PreviewKeyDown += OnKeyDown; ticker.Tick += Tick; ticker.Start(); Refresh();
    }

    public void Refresh()
    {
        if (disposed) return;
        if (session.Screen != Screen.Editor) { player.Pause(); return; }
        if (!ReferenceEquals(session.Player, player)) session.Player = player;
        title.Text = session.Project?.DisplayTitle ?? "Editor"; saved.Text = session.LastSavedAt is { } time ? "Saved " + time.ToString("HH:mm", CultureInfo.CurrentCulture) : "";
        status.Text = session.Message; undo.IsEnabled = session.CanUndo && !session.IsBusy;
        play.IsEnabled = seek.IsEnabled = session.PreviewPath is not null && !session.IsPreviewLoading;
        sourceName.Text = session.ActiveSegment?.SuggestedTitle ?? session.Project?.Media.FirstOrDefault(m => m.Id == session.Selection)?.Name ?? "Source video";
        expand.Content = session.IsPlayerExpanded ? "Close expanded player" : "Expand player";
        if (expanded != session.IsPlayerExpanded)
        {
            expanded = session.IsPlayerExpanded;
            if (expanded) SavePaneSizes();
            leftTabs.Visibility = rightTabs.Visibility = leftSplitter.Visibility = rightSplitter.Visibility = timelineSplitter.Visibility = timeline.Widget.Visibility = expanded ? Visibility.Collapsed : Visibility.Visible;
            panes.ColumnDefinitions[0].MinWidth = expanded ? 0 : 200; panes.ColumnDefinitions[4].MinWidth = expanded ? 0 : 248;
            panes.ColumnDefinitions[0].Width = new GridLength(expanded ? 0 : session.Settings.LeftSidebarWidth);
            panes.ColumnDefinitions[4].Width = new GridLength(expanded ? 0 : session.Settings.RightSidebarWidth);
            panes.ColumnDefinitions[1].Width = panes.ColumnDefinitions[3].Width = new GridLength(expanded ? 0 : 5);
            root.RowDefinitions[3].MinHeight = expanded ? 0 : 260; root.RowDefinitions[2].Height = new GridLength(expanded ? 0 : 5); root.RowDefinitions[3].Height = new GridLength(expanded ? 0 : session.Settings.TimelineHeight);
        }
        SyncPlayer();
        var signature = session.Project is null ? "" : session.Project.Id + "|" + string.Join("|", session.Project.Media.Select(m => $"{m.Id}:{m.Thumbnail}:{m.Path}"))
            + string.Join("|", session.Project.Segments.Select(s => $"{s.Id}:{s.Start}:{s.Duration}:{s.SuggestedTitle}")) + session.PreviewShortId;
        if (signature != mediaSignature) { mediaSignature = signature; BuildMedia(); }
        var selected = session.ActiveSegment; var clipSignature = selected is null ? "source" : PrismJson.Serialize(selected);
        if (inspectorId != selected?.Id || inspectorSignature != clipSignature && !TextEditingInside(inspector))
        { inspectorId = selected?.Id; inspectorSignature = clipSignature; BuildInspector(); }
        if (captionSignature != clipSignature && !TextEditingInside(captions)) { captionSignature = clipSignature; BuildCaptions(); }
        if (chatCount != session.ChatMessages.Count) { chatCount = session.ChatMessages.Count; BuildChatHistory(); }
        if (!FocusInside(chatInput) && chatInput.Text != session.ChatInput) chatInput.Text = session.ChatInput;
        timeline.Refresh();
    }

    void SyncPlayer()
    {
        var identity = session.PreviewShortId?.ToString() ?? "source:" + session.Selection;
        if (session.PreviewPath is null)
        {
            if (loadedPath is not null && !previewSuspended)
            {
                pendingSeek = loadedIdentity == identity ? player.CurrentTime : 0; resumePlayback = loadedIdentity == identity && player.IsPlaying;
                player.Pause(); previewSuspended = true;
            }
            playerNotice.Visibility = Visibility.Visible; playerNotice.Text = session.IsPreviewLoading ? "Preparing preview…" : session.PreviewError ?? "Import a video to begin.";
            return;
        }
        playerNotice.Visibility = Visibility.Collapsed;
        var wasSuspended = previewSuspended; previewSuspended = false;
        if (loadedPath == session.PreviewPath) { if (wasSuspended) RestorePlayback(); return; }
        if (loadedIdentity != identity) { pendingSeek = 0; resumePlayback = false; }
        else if (!wasSuspended) { pendingSeek = player.CurrentTime; resumePlayback = player.IsPlaying; }
        player.Pause(); loadedIdentity = identity; loadedPath = session.PreviewPath;
        video.Source = new Uri(Path.GetFullPath(loadedPath)); seek.Maximum = Math.Max(0.01, session.PreviewLength);
        // Manual media must be opened to make paused scrubbing and MediaOpened reliable.
        video.Play(); video.Pause();
    }

    void ClearPlayback()
    {
        video.Close();
        loadedPath = loadedIdentity = null;
        pendingSeek = 0;
        resumePlayback = previewSuspended = false;
    }

    void MediaOpened(object? sender, RoutedEventArgs args)
    {
        try { RestorePlayback(); }
        catch (Exception error) { SignalError("Could not play this video: " + error.Message); }
    }
    void RestorePlayback()
    {
        player.Seek(Math.Clamp(pendingSeek, 0, Math.Max(0, session.PreviewLength)));
        if (resumePlayback) player.Play(); pendingSeek = 0; resumePlayback = false;
    }
    void Tick(object? sender, EventArgs args)
    {
        if (disposed || session.Screen != Screen.Editor) return;
        updatingSeek = true; seek.Value = player.CurrentTime; updatingSeek = false;
        playerTime.Text = Format.Clock(player.CurrentTime) + " / " + Format.Clock(session.PreviewLength);
        play.Content = player.IsPlaying ? "Pause" : "Play";
    }

    void BuildMedia()
    {
        media.Children.Clear(); var bar = Row(); bar.Children.Add(Text("Project media", 15)); bar.Children.Add(AsyncButton("Import", ImportVideo)); media.Children.Add(bar);
        if (session.Project is not { } project) { media.Children.Add(Text("Import a long video to make your first Short.", muted: true)); return; }
        foreach (var item in project.Media.Where(m => m.Kind == "video"))
        {
            var card = Column();
            if (item.Thumbnail is { } path && File.Exists(path)) card.Children.Add(Picture(path));
            card.Children.Add(Text(item.Name)); card.Children.Add(Text(Format.Duration(item.Duration) + " · Source video", 11, true));
            var button = Button("", () => { session.Selection = item.Id; session.SelectPreview(null); }); button.Content = card; media.Children.Add(button);
        }
        media.Children.Add(Text($"Shorts · {project.Segments.Count}", 15));
        if (project.Segments.Count == 0) media.Children.Add(Text("No Shorts yet. Create Shorts or add a clip from the timeline.", muted: true));
        for (var index = 0; index < project.Segments.Count; index++)
        {
            var clip = project.Segments[index]; var number = index + 1; var card = Column();
            var source = project.Media.FirstOrDefault(m => m.Id == clip.MediaId);
            if (source is not null)
            {
                var key = source.Id + ":" + clip.Start.ToString("R", CultureInfo.InvariantCulture);
                var image = new Image { Height = 88, Stretch = Stretch.UniformToFill, ClipToBounds = true, Margin = new Thickness(0, 0, 0, 6) }; card.Children.Add(image);
                if (thumbnails.TryGetValue(key, out var bytes)) image.Source = Bitmap(bytes);
                else if (source.Thumbnail is { } path && File.Exists(path)) image.Source = Picture(path).Source;
                if (!thumbnails.ContainsKey(key) && loadingThumbnails.Add(key)) _ = LoadThumbnail(key, source.Path, clip.Start + Math.Min(0.2, clip.Duration / 2), image);
            }
            card.Children.Add(Text(clip.SuggestedTitle ?? $"Short {number}")); card.Children.Add(Text(Format.Clock(clip.Duration) + " · " + Format.Clock(clip.Start), 11, true));
            var select = Button("", () => session.SelectPreview(clip.Id)); select.Content = card;
            if (clip.Id == session.PreviewShortId) { select.SetResourceReference(Control.BorderBrushProperty, "Accent"); select.BorderThickness = new Thickness(2); }
            var menu = new ContextMenu(); var export = new MenuItem { Header = "Export this Short" }; export.Click += (_, _) => session.ChooseExport(clip.Id); menu.Items.Add(export);
            var remove = new MenuItem { Header = "Remove Short" }; remove.Click += (_, _) => session.RemoveShort(clip.Id); menu.Items.Add(remove); select.ContextMenu = menu;
            media.Children.Add(select);
            var actions = Row(); actions.Children.Add(Button("Export", () => session.ChooseExport(clip.Id))); actions.Children.Add(Button("Remove", () => session.RemoveShort(clip.Id), danger: true)); media.Children.Add(actions);
        }
    }

    async Task LoadThumbnail(string key, string path, double at, Image image)
    {
        try
        {
            var bytes = await FFmpeg.FrameJpeg(path, at, 360);
            if (disposed || bytes is null) return; thumbnails[key] = bytes; image.Source = Bitmap(bytes);
        }
        catch (Exception) { }
        finally { loadingThumbnails.Remove(key); }
    }

    async Task ImportVideo()
    {
        var picker = new OpenFileDialog { Title = "Import video", Filter = "Video files|*.mov;*.mp4;*.m4v;*.avi;*.mkv;*.webm|All files|*.*" };
        if (picker.ShowDialog(window) == true) await session.ImportSource(picker.FileName);
    }

    void BuildInspector()
    {
        inspector.Children.Clear();
        if (session.ActiveSegment is not { } clip)
        {
            inspector.Children.Add(Text("Select a Short", 17)); inspector.Children.Add(Text("Choose a Short to edit its timing, framing and text overlay.", muted: true)); inspector.Children.Add(Button("Add clip", session.AddManualClip)); return;
        }
        inspector.Children.Add(Text(clip.SuggestedTitle ?? "Edit Short", 17));
        if (clip.SelectionReason is { Length: > 0 } reason) inspector.Children.Add(Text(reason, muted: true));
        var start = NumberBox(clip.Start); var duration = NumberBox(clip.Duration); inspector.Children.Add(Field("Source start · seconds", start)); inspector.Children.Add(Field("Duration · seconds", duration));
        var overlay = new TextBox { Text = clip.Caption, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 36 }; inspector.Children.Add(Field("Text overlay", overlay));
        var textStart = NumberBox(clip.CaptionStart ?? 0); var textDuration = NumberBox(clip.CaptionDuration ?? clip.Duration); inspector.Children.Add(Field("Text start · seconds", textStart)); inspector.Children.Add(Field("Text duration · seconds", textDuration));
        var zoom = NumberBox(clip.CropZoom ?? 1.08); var position = NumberBox(clip.CropPosition ?? 0.5); inspector.Children.Add(Field("Zoom · 1 to 1.5", zoom)); inspector.Children.Add(Field("Horizontal position · 0 to 1", position));
        inspector.Children.Add(Button("Save changes", () =>
        {
            if (new[] { start, duration, textStart, textDuration, zoom, position }.Any(box => Value(box) is null)) { SignalError("Choose valid clip and text ranges within the source and clip duration."); return; }
            session.UpdateSelectedEdit(Value(start)!.Value, Value(duration)!.Value, overlay.Text, Value(textStart)!.Value, Value(textDuration)!.Value, Value(zoom)!.Value, Value(position)!.Value);
        }, primary: true));
        inspector.Children.Add(Text("Layout", 15)); var layouts = Row(); layouts.Children.Add(Button("Fill", () => session.SetFraming(false))); layouts.Children.Add(Button("Fit", () => session.SetFraming(true))); layouts.Children.Add(AsyncButton("Split", session.SetSplitScreen)); inspector.Children.Add(layouts);
        inspector.Children.Add(Text(clip.SplitScreen == true ? "Two speakers, captions in the middle." : clip.FitToFrame == true ? "The full source frame stays visible." : "Vertical crop follows the focus path.", muted: true));
        inspector.Children.Add(Button("Center and hold", session.HoldFramingAtCenter)); inspector.Children.Add(Button("Re-track subject", session.RetrackSelectedSubject));
        inspector.Children.Add(Button(clip.IsMuted == true ? "Restore audio" : "Mute audio", session.ToggleSelectedAudio)); inspector.Children.Add(AsyncButton("Transcribe", session.RegenerateSelectedSubtitles));
        if (clip.CaptionNotice is { } notice) inspector.Children.Add(Text(notice, muted: true));
        inspector.Children.Add(Button("Export this Short", () => session.ChooseExport(clip.Id))); inspector.Children.Add(Button("Remove Short", () => session.RemoveShort(clip.Id), danger: true));
    }

    void BuildCaptions()
    {
        captions.Children.Clear();
        if (session.ActiveSegment is not { } clip) { captions.Children.Add(Text("Select a Short to edit its subtitles.", muted: true)); return; }
        captions.Children.Add(Text("Caption style", 17));
        foreach (var style in CaptionStyles.Choices)
        {
            var card = Column();
            if (!stylePreviews.TryGetValue(style, out var bytes)) stylePreviews[style] = bytes = CaptionRenderer.StylePreview(style);
            card.Children.Add(new Image { Source = Bitmap(bytes), Height = 38, Stretch = Stretch.Uniform, Margin = new Thickness(0, 0, 0, 4) }); card.Children.Add(Text(style.Title()));
            var button = Button("", () => session.SetSelectedCaptionStyle(style)); button.Content = card;
            if ((clip.CaptionStyle ?? CaptionStyle.Classic).Resolved() == style.Resolved()) { button.SetResourceReference(Control.BorderBrushProperty, "Accent"); button.BorderThickness = new Thickness(2); }
            captions.Children.Add(button);
        }
        var position = Combo(Enum.GetValues<CaptionPosition>().Select(p => p.Title()).ToArray(), (int)(clip.CaptionPosition ?? CaptionPosition.Bottom)); position.SelectionChanged += (_, _) => session.SetSelectedCaptionLayout(position: (CaptionPosition)position.SelectedIndex); captions.Children.Add(Field("Position", position));
        var size = Combo(Enum.GetValues<CaptionSize>().Select(s => s.Title()).ToArray(), (int)(clip.CaptionSize ?? CaptionSize.Medium)); size.SelectionChanged += (_, _) => session.SetSelectedCaptionLayout(size: (CaptionSize)size.SelectedIndex); captions.Children.Add(Field("Size", size));
        var animation = Combo(["Off", "Pop in"], clip.CaptionAnimated == true ? 1 : 0); animation.SelectionChanged += (_, _) => session.SetSelectedCaptionLayout(animated: animation.SelectedIndex == 1); captions.Children.Add(Field("Animation", animation));
        captions.Children.Add(Text("Subtitle text", 15)); var editors = new List<TextBox>();
        foreach (var cue in clip.Captions ?? [])
        {
            captions.Children.Add(Text(Format.Clock(cue.Start) + " — " + Format.Clock(cue.Start + cue.Duration), 11, true));
            var entry = new TextBox { Text = cue.Text, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, MinHeight = 36, ToolTip = "Clear this line to remove the caption." }; captions.Children.Add(entry); editors.Add(entry);
        }
        if (editors.Count > 0) captions.Children.Add(Button("Save caption text", () => session.UpdateSelectedCaptionTexts(editors.Select(e => e.Text).ToArray()), primary: true));
        else captions.Children.Add(Text("No generated speech subtitles yet.", muted: true));
        captions.Children.Add(AsyncButton("Transcribe", session.RegenerateSelectedSubtitles)); if (clip.CaptionNotice is { } notice) captions.Children.Add(Text(notice, muted: true));
    }

    void BuildChatHistory()
    {
        chatHistory.Children.Clear();
        foreach (var message in session.ChatMessages)
        {
            var body = Column(); body.Children.Add(Text(message.IsUser ? "You" : "Gemini", 14)); body.Children.Add(Text(message.Text)); chatHistory.Children.Add(Card(body));
        }
        chatScroll.Dispatcher.BeginInvoke(() => chatScroll.ScrollToEnd(), DispatcherPriority.Loaded);
    }

    void SavePaneSizes()
    {
        if (session.IsPlayerExpanded || panes.ActualWidth <= 0 || root.RowDefinitions[3].ActualHeight <= 0) return;
        session.Settings.LeftSidebarWidth = Math.Clamp(panes.ColumnDefinitions[0].ActualWidth, 200, 700);
        session.Settings.RightSidebarWidth = Math.Clamp(panes.ColumnDefinitions[4].ActualWidth, 248, 700);
        session.Settings.TimelineHeight = Math.Clamp(root.RowDefinitions[3].ActualHeight, 260, 700); session.Settings.Save();
    }
    void OnKeyDown(object sender, KeyEventArgs args)
    {
        if (disposed || session.Screen != Screen.Editor || !root.IsEnabled || !session.IsGeminiKeySaved || session.IsBusy
            || session.ExportChoice is not null || session.ExportSummary is not null || session.GenerationError is not null || Typing()) return;
        try
        {
            var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
            switch (args.Key)
            {
                case Key.Space: session.TogglePlayback(); break;
                case Key.Left: session.SeekPreviewBy(shift ? -5 : -1); break;
                case Key.Right: session.SeekPreviewBy(shift ? 5 : 1); break;
                case Key.Delete: if (session.PreviewShortId is { } id) session.RemoveShort(id); break;
                case Key.Z when Keyboard.Modifiers.HasFlag(ModifierKeys.Control): session.UndoFromEditor(); break;
                case Key.Escape when session.IsPlayerExpanded: session.IsPlayerExpanded = false; break;
                default: return;
            }
            args.Handled = true;
        }
        catch (Exception error) { SignalError(error.Message); }
    }
    static bool Typing()
    {
        for (var focused = Keyboard.FocusedElement as DependencyObject; focused is not null; focused = Parent(focused))
            if (focused is TextBoxBase or PasswordBox or ComboBox) return true;
        return false;
    }
    static DependencyObject? Parent(DependencyObject node) => node is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node);
    static bool FocusInside(DependencyObject ancestor)
    {
        for (var focused = Keyboard.FocusedElement as DependencyObject; focused is not null; focused = Parent(focused)) if (ReferenceEquals(focused, ancestor)) return true;
        return false;
    }
    static bool TextEditingInside(DependencyObject ancestor)
    {
        var editing = false;
        for (var focused = Keyboard.FocusedElement as DependencyObject; focused is not null; focused = Parent(focused))
        {
            if (focused is TextBoxBase or PasswordBox) editing = true;
            if (ReferenceEquals(focused, ancestor)) return editing;
        }
        return false;
    }
    void SignalError(string message) { session.Message = message; Error?.Invoke(message); }
    async Task Safe(Func<Task> action) { try { await action(); } catch (Exception error) { SignalError(error.Message); } }
    Button Button(string title, Action action, bool primary = false, bool danger = false)
    {
        var button = NewButton(title, primary, danger); button.Click += (_, _) => { try { action(); } catch (Exception error) { SignalError(error.Message); } }; return button;
    }
    Button AsyncButton(string title, Func<Task> action, bool primary = false)
    {
        var button = NewButton(title, primary); button.Click += async (_, _) => await Safe(action); return button;
    }
    static Button NewButton(string title, bool primary, bool danger = false)
    {
        var button = new Button { Content = title, Margin = new Thickness(0, 3, 5, 3), Padding = new Thickness(10, 7, 10, 7), HorizontalContentAlignment = HorizontalAlignment.Center };
        if (primary) { button.SetResourceReference(Control.BackgroundProperty, "Action"); button.Foreground = Brushes.Black; }
        if (danger) button.SetResourceReference(Control.ForegroundProperty, "Coral"); return button;
    }
    static TextBlock Text(string value, double size = 13, bool muted = false)
    {
        var text = new TextBlock { Text = value, FontSize = size, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 3), VerticalAlignment = VerticalAlignment.Center };
        text.SetResourceReference(TextBlock.ForegroundProperty, muted ? "Muted" : "Ink"); if (size >= 15) text.SetResourceReference(TextBlock.FontFamilyProperty, "DisplayFont"); return text;
    }
    static StackPanel Column() => new() { Orientation = Orientation.Vertical, Margin = new Thickness(8) };
    static StackPanel Row() => new() { Orientation = Orientation.Horizontal };
    static ScrollViewer Scroll(UIElement child) => new() { Content = child, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    static Border Card(UIElement child)
    {
        var border = new Border { Child = child, Padding = new Thickness(10), CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Margin = new Thickness(0, 5, 0, 5) };
        border.SetResourceReference(Border.BackgroundProperty, "Surface1"); border.SetResourceReference(Border.BorderBrushProperty, "Line"); return border;
    }
    static FrameworkElement Field(string title, FrameworkElement control)
    { var panel = Column(); panel.Margin = new Thickness(0, 4, 0, 4); panel.Children.Add(Text(title, 11, true)); panel.Children.Add(control); return panel; }
    static TextBox NumberBox(double value) => new() { Text = value.ToString("0.###", CultureInfo.InvariantCulture), MinHeight = 30 };
    static double? Value(TextBox box) => double.TryParse(box.Text.Trim().Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out var value) && double.IsFinite(value) ? value : null;
    static ComboBox Combo(string[] values, int selected) => new() { ItemsSource = values, SelectedIndex = selected, MinHeight = 32 };
    static void StyleTabs(TabControl tabs)
    {
        tabs.SetResourceReference(Control.BackgroundProperty, "Surface0"); tabs.SetResourceReference(Control.ForegroundProperty, "Ink"); tabs.SetResourceReference(Control.BorderBrushProperty, "Line");
    }
    static TabItem Tab(string title, UIElement content)
    {
        var tab = new TabItem { Header = title, Content = content, Padding = new Thickness(10, 8, 10, 8) };
        tab.SetResourceReference(Control.BackgroundProperty, "Surface1"); tab.SetResourceReference(Control.ForegroundProperty, "Ink"); tab.SetResourceReference(Control.BorderBrushProperty, "Line"); return tab;
    }
    static GridSplitter Splitter() { var splitter = new GridSplitter { Width = 5, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch, ResizeDirection = GridResizeDirection.Columns, ResizeBehavior = GridResizeBehavior.PreviousAndNext, ShowsPreview = true }; splitter.SetResourceReference(Control.BackgroundProperty, "Line"); return splitter; }
    static void Add(Grid grid, UIElement child, int row, int column = 0) { Grid.SetRow(child, row); Grid.SetColumn(child, column); grid.Children.Add(child); }
    static Image Picture(string path)
    {
        var image = new Image { Height = 88, Stretch = Stretch.UniformToFill, ClipToBounds = true, Margin = new Thickness(0, 0, 0, 6) };
        try { image.Source = Bitmap(File.ReadAllBytes(path)); } catch (Exception) { }
        return image;
    }
    static BitmapImage Bitmap(byte[] bytes)
    {
        using var stream = new MemoryStream(bytes); var image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.StreamSource = stream; image.EndInit(); image.Freeze(); return image;
    }
    public void Dispose()
    {
        if (disposed) return; SavePaneSizes(); disposed = true; ticker.Stop(); window.PreviewKeyDown -= OnKeyDown; video.MediaOpened -= MediaOpened; ClearPlayback();
        if (ReferenceEquals(session.Player, player)) session.Player = null; timeline.Dispose();
    }
    sealed class PreviewPlayer(MediaElement element, Action clear) : IPreviewPlayer
    {
        public bool IsPlaying { get; private set; }
        public double CurrentTime => element.Position.TotalSeconds;
        public void Seek(double seconds) { if (double.IsFinite(seconds)) element.Position = TimeSpan.FromSeconds(Math.Max(0, seconds)); }
        public void Play() { element.Play(); IsPlaying = true; }
        public void Pause() { element.Pause(); IsPlaying = false; }
        public void Clear() { IsPlaying = false; clear(); }
        public void TogglePlayback() { if (IsPlaying) Pause(); else Play(); }
    }
}
