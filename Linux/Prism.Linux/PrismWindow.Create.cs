using System.Globalization;
using System.Runtime.InteropServices;
using Prism.Core;

namespace Prism.Linux;

public sealed partial class PrismWindow
{
    Gtk.Widget CreateFlow()
    {
        var video = session.ShortsSource;
        var step = video is null ? 1 : Math.Clamp(createStep + 2, 2, 4);
        var page = Column(20);
        page.AddCssClass("section");
        page.Append(Text(step switch
        {
            1 => "Step 1 of 5 · Choose video", 2 => "Step 2 of 5 · Set up Shorts",
            3 => "Step 3 of 5 · Choose captions", _ => "Step 4 of 5 · Choose content type",
        }, "muted"));
        page.Append(Text(step switch
        {
            1 => "Add your long video", 2 => "Choose your Short settings", 3 => "Choose your captions", _ => "What kind of video is it?",
        }, "title"));
        page.Append(Text(step switch
        {
            1 => "Upload a video first. Then choose clip lengths and which part to analyze.",
            2 => "Your video is ready. Choose how to turn it into Shorts.",
            3 => "Pick how speech appears on your Shorts. You can change it for each Short in the editor.",
            _ => "This tells Prism what to look for and how to lay out each Short. You can change the layout for each Short in the editor.",
        }, "muted"));
        if (video is null)
        {
            var upload = Card(Text("Drop your video here", "subtitle"), Text("MOV, MP4, M4V, AVI, MKV or WebM", "mono"),
                Button("Choose video…", async () => await ChooseVideo(), "primary"));
            upload.SetSizeRequest(-1, 220);
            AcceptVideoDrop(upload);
            page.Append(upload);
            var path = Entry(session.SourcePath, "Or paste the full path to your video", value => session.SourcePath = value);
            path.OnActivate += async (_, _) => await ImportTyped(path.GetText());
            var row = Row();
            row.Append(path);
            row.Append(Button("Import", async () => await ImportTyped(path.GetText())));
            page.Append(row);
            var importStatus = Text(session.Message, "muted");
            page.Append(importStatus);
            updateScreen = () => { importStatus.SetText(session.Message); path.Sensitive = !session.IsBusy; upload.Sensitive = !session.IsBusy; };
        }
        else if (step == 2)
        {
            page.Append(Card(Text(video.Name, "accent"), Text(string.Create(CultureInfo.InvariantCulture, $"Video duration: {Format.Clock(video.Duration)} · {video.Duration / 60:0.00} minutes"), "muted"),
                Button("Choose a different video", async () => await ChooseVideo())));
            var configuration = Column(14);
            configuration.AddCssClass("card");
            configuration.Append(Text("Shorts settings", "subtitle"));
            var choices = Row(20);
            var number = Gtk.SpinButton.NewWithRange(1, 10, 1);
            number.Value = session.ShortCount;
            number.OnValueChanged += (_, _) => session.ShortCount = (int)number.Value;
            choices.Append(Field("How many", number));
            double[] durations = [15, 30, 45, 60];
            choices.Append(Field("Approx. length", Combo(durations.Select(seconds => $"{seconds:0} seconds"), Math.Max(0, Array.IndexOf(durations, session.ShortDuration)), index =>
            { if (index >= 0) session.ShortDuration = durations[index]; })));
            var regions = Enum.GetValues<SourceRegion>();
            var custom = Row(12);
            var start = Entry(session.CustomStartMinutes, "Start (minutes)", value => session.CustomStartMinutes = value);
            var end = Entry(session.CustomEndMinutes, "End (minutes)", value => session.CustomEndMinutes = value);
            custom.Append(Field("Start (minutes)", start));
            custom.Append(Field("End (minutes)", end));
            var region = Combo(regions.Select(value => value.Title()), Array.IndexOf(regions, session.ShortSourceRegion), index =>
            { if (index >= 0) { session.ShortSourceRegion = regions[index]; custom.Visible = session.ShortSourceRegion == SourceRegion.Custom; } });
            choices.Append(Field("Take clips from", region));
            configuration.Append(choices);
            custom.Visible = session.ShortSourceRegion == SourceRegion.Custom;
            configuration.Append(custom);
            var rangeError = Text("", "warning");
            configuration.Append(rangeError);
            var explanation = Text("", "muted");
            configuration.Append(explanation);
            page.Append(configuration);
            var next = Button("Next: Choose captions", () => { createStep = 1; InvalidateScreen(); }, "primary");
            page.Append(next);
            updateScreen = () =>
            {
                rangeError.SetText(session.CustomRangeError ?? "");
                rangeError.Visible = session.CustomRangeError is not null;
                explanation.SetText($"Prism will analyze frames and available speech, then suggest up to {session.ShortCount} distinct moments of about {session.ShortDuration:0} seconds in the {session.ShortSourceRegion.Title().ToLowerInvariant()}. Review every pick before exporting.");
                next.Sensitive = !session.IsBusy && session.CustomRangeError is null;
            };
        }
        else if (step == 3)
        {
            var grid = Flow(245, 14);
            var buttons = new Dictionary<CaptionStyle, Gtk.Button>();
            foreach (var style in CaptionStyles.Choices)
            {
                var button = Gtk.Button.New();
                button.SetSizeRequest(245, 260);
                var body = Column(10);
                try { body.Append(Picture(CaptionRenderer.StylePreview(style), 230, 150)); } catch { }
                body.Append(Text(style.Title(), "subtitle"));
                body.Append(Text(style.Detail(), "muted"));
                button.Child = body;
                button.OnClicked += (_, _) => session.ShortCaptionStyle = style;
                buttons[style] = button;
                grid.Append(button);
            }
            page.Append(grid);
            page.Append(FlowButtons(Button("Back to settings", () => { createStep = 0; InvalidateScreen(); }),
                Button("Next: Choose content type", () => { createStep = 2; InvalidateScreen(); }, "primary")));
            updateScreen = () =>
            {
                foreach (var (style, button) in buttons)
                    if (session.ShortCaptionStyle == style) button.AddCssClass("selected"); else button.RemoveCssClass("selected");
            };
        }
        else
        {
            var grid = Flow(250, 14);
            var buttons = new Dictionary<VideoType, Gtk.Button>();
            foreach (var type in VideoTypes.All)
            {
                var button = Gtk.Button.New();
                button.SetSizeRequest(250, 150);
                var body = Column(12);
                body.Append(Text(type.Title(), "subtitle"));
                body.Append(Text(type.Detail(), "muted"));
                button.Child = body;
                button.OnClicked += (_, _) => session.ShortVideoType = type;
                buttons[type] = button;
                grid.Append(button);
            }
            page.Append(grid);
            var analyze = Button("Analyze and create Shorts", async () => await session.ContinueImport(), "primary");
            page.Append(FlowButtons(Button("Back to captions", () => { createStep = 1; InvalidateScreen(); }), analyze));
            updateScreen = () =>
            {
                foreach (var (type, button) in buttons)
                    if (session.ShortVideoType == type) button.AddCssClass("selected"); else button.RemoveCssClass("selected");
                analyze.Sensitive = !session.IsBusy && session.CustomRangeError is null;
            };
        }
        page.Append(Button("Back to Home", () => Navigate(Screen.Home)));
        return Scroll(page);
    }

    static Gtk.Box Field(string label, Gtk.Widget widget)
    {
        var box = Column(8);
        box.Hexpand = true;
        box.Append(Text(label, "muted"));
        box.Append(widget);
        return box;
    }

    static Gtk.Box FlowButtons(Gtk.Widget back, Gtk.Widget next)
    {
        var row = Row();
        row.Append(back);
        var spacer = Column(0); spacer.Hexpand = true; row.Append(spacer);
        row.Append(next);
        return row;
    }

    async Task ImportTyped(string text)
    {
        var path = text.Trim().Trim('"');
        if (path.StartsWith('~')) path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), path[1..].TrimStart('/'));
        if (Uri.TryCreate(path, UriKind.Absolute, out var uri) && uri.IsFile) path = uri.LocalPath;
        if (!File.Exists(path)) { ShowNotice("Could not import video", "No file exists at that path."); return; }
        createStep = 0;
        await session.ImportSource(path);
        if (session.Message.StartsWith("Could not", StringComparison.Ordinal) || session.Message.Contains("could not be opened", StringComparison.Ordinal))
            ShowNotice("Could not import video", session.Message);
        Refresh();
    }

    void AcceptVideoDrop(Gtk.Widget widget)
    {
        var files = Gtk.DropTarget.New(Gdk.FileList.GetGType(), Gdk.DragAction.Copy);
        files.OnDrop += (sender, args) =>
        {
            if (session.IsBusy) return false;
            var list = gdk_file_list_get_files(args.Value.GetBoxed());
            if (list == IntPtr.Zero) return false;
            var item = Marshal.ReadIntPtr(list);
            var pointer = g_file_get_path(item);
            if (pointer == IntPtr.Zero) return false;
            var path = Marshal.PtrToStringUTF8(pointer);
            g_free(pointer);
            if (path is null) return false;
            _ = ImportTyped(path);
            return true;
        };
        widget.AddController(files);
        var strings = Gtk.DropTarget.New(GObject.Type.String, Gdk.DragAction.Copy);
        strings.OnDrop += (sender, args) =>
        {
            if (session.IsBusy) return false;
            var path = args.Value.GetString()?.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim();
            if (path is null) return false;
            _ = ImportTyped(path);
            return true;
        };
        widget.AddController(strings);
    }

    [DllImport("libgtk-4.so.1")] static extern IntPtr gdk_file_list_get_files(IntPtr fileList);
    [DllImport("libgio-2.0.so.0")] static extern IntPtr g_file_get_path(IntPtr file);
    [DllImport("libglib-2.0.so.0")] static extern void g_free(IntPtr memory);
}
