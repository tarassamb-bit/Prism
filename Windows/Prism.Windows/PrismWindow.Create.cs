using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Prism.Core;

namespace Prism.Windows;

public sealed partial class PrismWindow
{
    UIElement CreateFlow()
    {
        var video = session.ShortsSource;
        var step = video is null ? 1 : Math.Clamp(createStep + 2, 2, 4);
        var page = Column(); page.Margin = new Thickness(30);
        page.Children.Add(Text(step switch
        {
            1 => "Step 1 of 5 · Choose video", 2 => "Step 2 of 5 · Set up Shorts", 3 => "Step 3 of 5 · Choose captions", _ => "Step 4 of 5 · Choose content type",
        }, 12, muted: true));
        page.Children.Add(Text(step switch
        {
            1 => "Add your long video", 2 => "Choose your Short settings", 3 => "Choose your captions", _ => "What kind of video is it?",
        }, 32, display: true));
        page.Children.Add(Text(step switch
        {
            1 => "Upload a video first. Then choose clip lengths and which part to analyze.", 2 => "Your video is ready. Choose how to turn it into Shorts.",
            3 => "Pick how speech appears on your Shorts. You can change it for each Short in the editor.",
            _ => "This tells Prism what to look for and how to lay out each Short. You can change the layout for each Short in the editor.",
        }, muted: true));
        page.Children.Add(new Border { Height = 16 });
        if (video is null)
        {
            var upload = Card(Text("Drop your video here", 20, display: true), Text("MOV, MP4, M4V, AVI, MKV or WebM", 11, muted: true, mono: true), Button("Choose video…", ChooseVideo, true));
            upload.MinHeight = 220; upload.AllowDrop = true;
            upload.DragOver += (_, args) => { args.Effects = !session.IsBusy && args.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None; args.Handled = true; };
            upload.Drop += async (_, args) =>
            {
                if (session.IsBusy || args.Data.GetData(DataFormats.FileDrop) is not string[] { Length: > 0 } files) return;
                args.Handled = true;
                try { await ImportTyped(files[0]); } catch (Exception error) { ShowNotice("Could not import video", error.Message); }
            };
            page.Children.Add(upload);
            var path = Entry(session.SourcePath, "Or paste the full path to your video", value => session.SourcePath = value);
            path.KeyDown += async (_, args) => { if (args.Key == Key.Enter) { args.Handled = true; try { await ImportTyped(path.Text); } catch (Exception error) { ShowNotice("Could not import video", error.Message); } } };
            page.Children.Add(SplitRow(path, Button("Import", () => ImportTyped(path.Text))));
            var feedback = Text(session.Message, muted: true); page.Children.Add(feedback);
            updateScreen = () => { feedback.Text = session.Message; path.IsEnabled = upload.IsEnabled = !session.IsBusy; };
        }
        else if (step == 2)
        {
            page.Children.Add(Card(Text(video.Name), Text(string.Create(CultureInfo.InvariantCulture, $"Video duration: {Format.Clock(video.Duration)} · {video.Duration / 60:0.00} minutes"), muted: true), Button("Choose a different video", ChooseVideo)));
            var number = Combo(Enumerable.Range(1, 10).Select(count => $"{count} Shorts"), session.ShortCount - 1, index => { if (index >= 0) session.ShortCount = index + 1; });
            double[] lengths = [15, 30, 45, 60];
            var length = Combo(lengths.Select(seconds => $"{seconds:0} seconds"), Math.Max(0, Array.IndexOf(lengths, session.ShortDuration)), index => { if (index >= 0) session.ShortDuration = lengths[index]; });
            var custom = Row(Field("Start (minutes)", Entry(session.CustomStartMinutes, "Start (minutes)", value => session.CustomStartMinutes = value)),
                Field("End (minutes)", Entry(session.CustomEndMinutes, "End (minutes)", value => session.CustomEndMinutes = value)));
            var regions = Enum.GetValues<SourceRegion>();
            var region = Combo(regions.Select(value => value.Title()), Array.IndexOf(regions, session.ShortSourceRegion), index =>
            { if (index >= 0) { session.ShortSourceRegion = regions[index]; custom.Visibility = session.ShortSourceRegion == SourceRegion.Custom ? Visibility.Visible : Visibility.Collapsed; } });
            custom.Visibility = session.ShortSourceRegion == SourceRegion.Custom ? Visibility.Visible : Visibility.Collapsed;
            var error = Text(""); error.SetResourceReference(TextBlock.ForegroundProperty, "Amber");
            var explanation = Text("", muted: true);
            page.Children.Add(Card(Text("Shorts settings", 20, display: true), Row(Field("How many", number), Field("Approx. length", length), Field("Take clips from", region)), custom, error, explanation));
            var next = Button("Next: Choose captions", () => { createStep = 1; InvalidateScreen(); }, true); page.Children.Add(next);
            updateScreen = () =>
            {
                error.Text = session.CustomRangeError ?? ""; error.Visibility = session.CustomRangeError is null ? Visibility.Collapsed : Visibility.Visible;
                explanation.Text = $"Prism will analyze frames and available speech, then suggest up to {session.ShortCount} distinct moments of about {session.ShortDuration:0} seconds in the {session.ShortSourceRegion.Title().ToLowerInvariant()}. Review every pick before exporting.";
                next.IsEnabled = !session.IsBusy && session.CustomRangeError is null;
            };
        }
        else if (step == 3)
        {
            var grid = new WrapPanel(); var buttons = new Dictionary<CaptionStyle, Button>();
            foreach (var style in CaptionStyles.Choices)
            {
                var button = Button("", () => session.ShortCaptionStyle = style); button.Width = 260;
                var body = Column();
                try { body.Children.Add(Picture(CaptionRenderer.StylePreview(style), 230, 150)); } catch { }
                body.Children.Add(Text(style.Title(), 20, display: true)); body.Children.Add(Text(style.Detail(), muted: true));
                button.Content = body; buttons[style] = button; grid.Children.Add(button);
            }
            page.Children.Add(grid);
            page.Children.Add(SplitRow(Button("Back to settings", () => { createStep = 0; InvalidateScreen(); }), Button("Next: Choose content type", () => { createStep = 2; InvalidateScreen(); }, true)));
            updateScreen = () => { foreach (var (style, button) in buttons) button.SetResourceReference(Control.BorderBrushProperty, session.ShortCaptionStyle == style ? "Accent" : "Line"); };
        }
        else
        {
            var grid = new WrapPanel(); var buttons = new Dictionary<VideoType, Button>();
            foreach (var type in VideoTypes.All)
            {
                var button = Button("", () => session.ShortVideoType = type); button.Width = 270; button.MinHeight = 150;
                button.Content = Column(Text(type.Title(), 20, display: true), Text(type.Detail(), muted: true));
                buttons[type] = button; grid.Children.Add(button);
            }
            page.Children.Add(grid);
            var analyze = Button("Analyze and create Shorts", () => session.ContinueImport(), true);
            page.Children.Add(SplitRow(Button("Back to captions", () => { createStep = 1; InvalidateScreen(); }), analyze));
            updateScreen = () =>
            {
                foreach (var (type, button) in buttons) button.SetResourceReference(Control.BorderBrushProperty, session.ShortVideoType == type ? "Accent" : "Line");
                analyze.IsEnabled = !session.IsBusy && session.CustomRangeError is null;
            };
        }
        page.Children.Add(Button("Back to Home", () => Navigate(Screen.Home)));
        return Scroll(page);
    }

    async Task ImportTyped(string text)
    {
        var path = text.Trim().Trim('"');
        if (path.StartsWith('~')) path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), path[1..].TrimStart('/', '\\'));
        if (Uri.TryCreate(path, UriKind.Absolute, out var uri) && uri.IsFile) path = uri.LocalPath;
        if (!File.Exists(path)) { ShowNotice("Could not import video", "No file exists at that path."); return; }
        createStep = 0; await session.ImportSource(path); Refresh();
    }
}
