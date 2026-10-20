using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Prism.Core;

namespace Prism.Windows;

public sealed partial class PrismWindow
{
    void RefreshModal()
    {
        var desired = localCard is not null ? "local:" + localRevision
            : !session.IsGeminiKeySaved ? "key"
            : session.GenerationProgress is not null ? "progress"
            : session.IsBusy ? "working" : session.IsTestingGemini ? "testing"
            : session.GenerationError is { } failure ? "error:" + failure.GetHashCode()
            : session.ExportSummary is { } summary ? "done:" + summary
            : session.ExportChoice is not null ? "export" : "";
        var blocked = desired.Length > 0;
        layout.IsEnabled = !blocked;
        editor.Widget.IsEnabled = !blocked;
        if (desired == modalKind) { updateModal?.Invoke(); return; }
        overlayHost.Children.Clear(); updateModal = null; modalKind = desired;
        overlayHost.Visibility = blocked ? Visibility.Visible : Visibility.Collapsed;
        if (!blocked) return;
        var card = desired switch
        {
            "key" => KeyGate(), "progress" => ProgressCard(), "working" => WorkingCard(false), "testing" => WorkingCard(true), "export" => ExportCard(),
            _ when desired.StartsWith("error:", StringComparison.Ordinal) => ErrorCard(session.GenerationError!),
            _ when desired.StartsWith("done:", StringComparison.Ordinal) => ExportDoneCard(session.ExportSummary!), _ => localCard!,
        };
        KeyboardNavigation.SetTabNavigation(card, KeyboardNavigationMode.Cycle);
        var scroll = Scroll(card); scroll.Width = 570; scroll.MaxHeight = Math.Max(300, ActualHeight - 90);
        scroll.HorizontalAlignment = HorizontalAlignment.Center; scroll.VerticalAlignment = VerticalAlignment.Center;
        var dim = new Border { Background = new SolidColorBrush(Color.FromArgb(180, 0, 0, 0)), Child = scroll };
        overlayHost.Children.Add(dim); updateModal?.Invoke();
    }

    static Border ModalCard(string title)
    {
        var card = Card(Text(title, 22, display: true));
        card.Padding = new Thickness(26); card.Margin = new Thickness(0); return card;
    }

    Border KeyGate()
    {
        var card = ModalCard("Welcome to Prism"); var body = (StackPanel)card.Child;
        body.Children.Insert(0, BrandMark());
        body.Children.Add(Text("Prism uses Google Gemini to find, cut, caption and frame your Shorts, so it needs your own Gemini API key before it can work. Google bills your AI Studio account for what Prism uses; the free tier works too.", muted: true));
        body.Children.Add(Text("1. Create a key"));
        body.Children.Add(Button("Open Google AI Studio › API keys", () => WindowsPlatform.OpenExternal("https://aistudio.google.com/apikey")));
        body.Children.Add(Text("2. Paste it here"));
        var key = new PasswordBox { Password = session.GeminiKey, Padding = new Thickness(10), Margin = new Thickness(0, 4, 0, 4), ToolTip = "Paste your API key" };
        key.PasswordChanged += (_, _) => session.GeminiKey = key.Password;
        key.KeyDown += async (_, args) =>
        {
            if (args.Key != Key.Enter || session.IsTestingGemini || string.IsNullOrWhiteSpace(session.GeminiKey)) return;
            args.Handled = true;
            try { await session.VerifyAndSaveGeminiKey(); } catch (Exception error) { ShowNotice("Could not check key", error.Message); }
        };
        body.Children.Add(key);
        var feedback = Text(session.GeminiKeyStatus, muted: true); body.Children.Add(feedback);
        body.Children.Add(Text("The key is protected with Windows Data Protection for your Windows account. Audio, transcripts and sampled frames from your videos are sent to Google.", 11, muted: true));
        var save = Button("Save and continue", () => session.VerifyAndSaveGeminiKey(), true); body.Children.Add(save);
        updateModal = () =>
        {
            feedback.Text = session.GeminiKeyStatus;
            feedback.SetResourceReference(TextBlock.ForegroundProperty, session.GeminiKeyRejected ? "Amber" : "Muted");
            key.IsEnabled = !session.IsTestingGemini;
            save.IsEnabled = !session.IsTestingGemini && !string.IsNullOrWhiteSpace(session.GeminiKey);
        };
        Dispatcher.BeginInvoke(new Action(() => { if (!disposed && modalKind == "key") key.Focus(); }));
        return card;
    }

    Border ProgressCard()
    {
        var card = ModalCard(session.IsExporting ? "Exporting" : "Creating Shorts"); var body = (StackPanel)card.Child;
        var stage = Text(session.GenerationStage);
        var progress = new ProgressBar { Minimum = 0, Maximum = 1, Height = 8, Margin = new Thickness(0, 12, 0, 10) };
        var detail = Text("", 11, muted: true, mono: true);
        var cancel = Button("Cancel", session.CancelGeneration);
        body.Children.Add(stage); body.Children.Add(progress); body.Children.Add(detail);
        body.Children.Add(Text(session.IsExporting ? "Your files are being prepared for export." : "Gemini finds complete moments, aligns speech and follows the subject.", muted: true));
        body.Children.Add(cancel);
        updateModal = () =>
        {
            stage.Text = session.GenerationStage; progress.Value = Math.Clamp(session.GenerationProgress ?? 0, 0, 1);
            detail.Text = $"{progress.Value * 100:0}% · Elapsed {Format.Clock((DateTime.Now - session.GenerationStartedAt).TotalSeconds)}";
            cancel.IsEnabled = session.GenerationStage != "Cancelling…";
        };
        return card;
    }

    Border WorkingCard(bool testing)
    {
        var card = ModalCard(testing ? "Checking Gemini…" : "Working…"); var body = (StackPanel)card.Child;
        body.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 6, Margin = new Thickness(0, 14, 0, 14) });
        var message = Text(""); body.Children.Add(message);
        updateModal = () => message.Text = testing ? session.GeminiKeyStatus : session.Message;
        return card;
    }

    Border ErrorCard(GenerationFailure failure)
    {
        var title = failure.IsExport ? "Export failed" : failure.Kind switch
        {
            GenerationFailureKind.NoMoments => "No Shorts found", GenerationFailureKind.Settings => "Check your Gemini settings",
            GenerationFailureKind.Temporary => "Gemini is unavailable right now", _ => "Couldn’t make Shorts",
        };
        var card = ModalCard(title); var body = (StackPanel)card.Child;
        body.Children.Add(Text(failure.Message));
        if (!failure.IsExport && failure.Kind == GenerationFailureKind.NoMoments) body.Children.Add(Text("Change the clip length or which part of the video Prism looks in, then try again.", muted: true));
        if (!failure.IsExport && failure.Kind == GenerationFailureKind.Temporary) body.Children.Add(Text("This is a temporary problem on Google’s side, not with your video or its range. Prism already retried for about a minute and tried the other Gemini models too. Wait a little, then try again.", muted: true));
        var buttons = new WrapPanel(); buttons.Children.Add(Button("Close", () => session.GenerationError = null));
        if (failure.IsExport) buttons.Children.Add(Button("Export options", () => { session.GenerationError = null; session.ChooseExport(); }, true));
        else
        {
            if (failure.Kind == GenerationFailureKind.Temporary) buttons.Children.Add(Button("Change model", () => { session.GenerationError = null; Navigate(Screen.Settings); }));
            buttons.Children.Add(Button("Try again", async () => { session.GenerationError = null; await session.MakeConfiguredShorts(); }, failure.Kind is GenerationFailureKind.Temporary or GenerationFailureKind.Other));
            if (failure.Kind is GenerationFailureKind.Settings or GenerationFailureKind.NoMoments)
                buttons.Children.Add(Button(failure.Kind == GenerationFailureKind.Settings ? "Open Settings" : "Change clip length or range", () =>
                { session.GenerationError = null; Navigate(failure.Kind == GenerationFailureKind.Settings ? Screen.Settings : Screen.ImportSource); }, true));
        }
        body.Children.Add(buttons); return card;
    }

    Border ExportDoneCard(string summary)
    {
        var card = ModalCard(summary.StartsWith("Export cancelled", StringComparison.Ordinal) ? "Export cancelled" : "Export finished"); var body = (StackPanel)card.Child;
        body.Children.Add(Text(summary));
        if (session.LastExportShortCount > 0) body.Children.Add(Text($"Shorts: {session.LastExportQuality.Resolution()} · 30 fps · {session.LastExportQuality.Codec()} MP4, ready to upload.", 12, muted: true));
        body.Children.Add(SplitRow(Button("Done", () => session.ExportSummary = null), Button("Show in Explorer", () => { session.ExportSummary = null; session.RevealExports(); }, true)));
        return card;
    }

    Border ExportCard()
    {
        var initial = session.ExportChoice!; var card = ModalCard("Export"); var body = (StackPanel)card.Child;
        var clips = session.Project?.Segments ?? []; var selected = initial.ShortIds.ToHashSet();
        var checks = new Dictionary<Guid, CheckBox>();
        var all = Button("Select all", () => { var active = checks.Values.Any(check => check.IsChecked != true); foreach (var check in checks.Values) check.IsChecked = active; });
        body.Children.Add(SplitRow(Text("Shorts", muted: true), all));
        var rows = Column();
        if (clips.Count == 0) rows.Children.Add(Text("No Shorts yet. You can still export the main video.", muted: true));
        foreach (var (clip, index) in clips.Select((clip, index) => (clip, index)))
        {
            var check = new CheckBox { Content = $"Short {index + 1} · {clip.SuggestedTitle} · {Format.Clock(clip.Duration)}", IsChecked = selected.Contains(clip.Id) };
            void Toggled()
            {
                if (check.IsChecked == true) selected.Add(clip.Id); else selected.Remove(clip.Id);
                if (session.ExportChoice is { } choice) session.ExportChoice = choice with { ShortIds = selected.ToHashSet(), Error = null };
            }
            check.Checked += (_, _) => Toggled(); check.Unchecked += (_, _) => Toggled();
            rows.Children.Add(check); checks[clip.Id] = check;
        }
        var list = Scroll(rows); list.MaxHeight = 210; body.Children.Add(list);
        var videos = session.Project?.Media.Count(media => media.Kind == "video") ?? 0;
        var source = new CheckBox { Content = videos > 1 ? $"Main videos ({videos})" : "Main video", IsChecked = initial.IncludeSource };
        void SourceToggled() { if (session.ExportChoice is { } choice) session.ExportChoice = choice with { IncludeSource = source.IsChecked == true, Error = null }; }
        source.Checked += (_, _) => SourceToggled(); source.Unchecked += (_, _) => SourceToggled(); body.Children.Add(source);
        body.Children.Add(Text("The original long video, copied as is.", 11, muted: true));
        var qualities = Enum.GetValues<ExportQuality>();
        body.Children.Add(Field("Quality", Combo(qualities.Select(quality => quality.Title()), Array.IndexOf(qualities, initial.Quality), index =>
        { if (index >= 0 && session.ExportChoice is { } choice) session.ExportChoice = choice with { Quality = qualities[index], Error = null }; })));
        var qualityDetail = Text("", 11, muted: true); body.Children.Add(qualityDetail);
        var folder = Entry(initial.Folder, "Export folder", value => { if (session.ExportChoice is { } choice) session.ExportChoice = choice with { Folder = value, Error = null }; });
        body.Children.Add(Field("Save to", SplitRow(folder, Button("Change…", () => { if (ChooseFolder("Export here") is { } path) folder.Text = path; }))));
        var error = Text(""); error.SetResourceReference(TextBlock.ForegroundProperty, "Amber"); body.Children.Add(error);
        var export = Button("Export", async () => { if (session.ExportChoice is { } choice) await session.Export(choice); }, true);
        body.Children.Add(SplitRow(Button("Cancel", () => session.ExportChoice = null), export));
        updateModal = () =>
        {
            if (session.ExportChoice is not { } choice) return;
            error.Text = choice.Error ?? ""; error.Visibility = choice.Error is null ? Visibility.Collapsed : Visibility.Visible;
            var count = choice.ShortIds.Count + (choice.IncludeSource ? videos : 0);
            export.Content = count == 1 ? "Export 1 file" : $"Export {count} files";
            export.IsEnabled = count > 0 && !string.IsNullOrWhiteSpace(choice.Folder);
            all.Content = checks.Values.All(check => check.IsChecked == true) ? "Select none" : "Select all"; all.IsEnabled = checks.Count > 0;
            qualityDetail.Text = choice.Quality.Detail() + " Applies to Shorts; the main video keeps its original quality.";
        };
        return card;
    }

    void ShowLocal(Border card) { localCard = card; localRevision++; RefreshModal(); }
    void CloseLocal() { localCard = null; RefreshModal(); }
    void ShowNotice(string title, string message)
    {
        var card = ModalCard(title); var body = (StackPanel)card.Child;
        body.Children.Add(Text(message)); body.Children.Add(Button("Close", CloseLocal, true)); ShowLocal(card);
    }
    void Prompt(string title, string placeholder, string initial, Action<string> accepted)
    {
        var card = ModalCard(title); var body = (StackPanel)card.Child; var entry = Entry(initial, placeholder);
        void Submit() { var value = entry.Text.Trim(); if (value.Length == 0) return; CloseLocal(); accepted(value); }
        entry.KeyDown += (_, args) => { if (args.Key == Key.Enter) { args.Handled = true; try { Submit(); } catch (Exception error) { ShowNotice("Could not complete action", error.Message); } } };
        body.Children.Add(entry); body.Children.Add(SplitRow(Button("Cancel", CloseLocal), Button("Save", Submit, true)));
        ShowLocal(card); entry.Focus(); entry.SelectAll();
    }
    void Confirm(string title, string message, string confirm, Action action)
    {
        var card = ModalCard(title); var body = (StackPanel)card.Child;
        body.Children.Add(Text(message)); body.Children.Add(SplitRow(Button("Cancel", CloseLocal), Button(confirm, () => { CloseLocal(); action(); }, danger: true))); ShowLocal(card);
    }
}
