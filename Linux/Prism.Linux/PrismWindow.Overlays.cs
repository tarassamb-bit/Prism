using Prism.Core;

namespace Prism.Linux;

public sealed partial class PrismWindow
{
    int localRevision;

    void RefreshModal()
    {
        var desired = localCard is not null ? "local:" + localRevision
            : !session.IsGeminiKeySaved ? "key"
            : session.GenerationProgress is not null ? "progress"
            : session.IsBusy ? "working"
            : session.IsTestingGemini ? "testing"
            : session.GenerationError is { } failure ? "error:" + failure.GetHashCode()
            : session.ExportSummary is { } summary ? "done:" + summary
            : session.ExportChoice is not null ? "export" : "";
        var blocked = desired.Length > 0;
        layout.Sensitive = !blocked;
        editor.Widget.Sensitive = !blocked;
        if (desired == modalKind) { updateModal?.Invoke(); return; }
        if (modal is not null) overlay.RemoveOverlay(modal);
        modal = null;
        updateModal = null;
        modalKind = desired;
        if (!blocked) return;
        var card = desired switch
        {
            "key" => KeyGate(), "progress" => ProgressCard(), "working" => WorkingCard(), "testing" => WorkingCard(true), "export" => ExportCard(),
            _ when desired.StartsWith("error:", StringComparison.Ordinal) => ErrorCard(session.GenerationError!),
            _ when desired.StartsWith("done:", StringComparison.Ordinal) => ExportDoneCard(session.ExportSummary!),
            _ => localCard!,
        };
        var dim = Column(0);
        dim.AddCssClass("scrim");
        dim.Hexpand = true;
        dim.Vexpand = true;
        var above = Column(0); above.Vexpand = true;
        var below = Column(0); below.Vexpand = true;
        card.SetSizeRequest(510, -1);
        var viewport = Scroll(card);
        viewport.Vexpand = false;
        viewport.Hexpand = false;
        viewport.Halign = Gtk.Align.Center;
        viewport.PropagateNaturalHeight = true;
        viewport.PropagateNaturalWidth = true;
        viewport.MaxContentHeight = Math.Max(400, window.GetHeight() - 80);
        viewport.MaxContentWidth = 620;
        dim.Append(above);
        dim.Append(viewport);
        dim.Append(below);
        modal = dim;
        overlay.AddOverlay(dim);
        updateModal?.Invoke();
    }

    static Gtk.Box ModalCard(string title)
    {
        var card = Column(16);
        card.AddCssClass("modal");
        card.Append(Text(title, "subtitle"));
        return card;
    }

    Gtk.Box KeyGate()
    {
        var card = ModalCard("Welcome to Prism");
        card.Prepend(BrandMark());
        card.Append(Text("Prism uses Google Gemini to find, cut, caption and frame your Shorts, so it needs your own Gemini API key before it can work. Google bills your AI Studio account for what Prism uses; the free tier works too.", "muted"));
        card.Append(Text("1. Create a key"));
        card.Append(Button("Open Google AI Studio › API keys", () => LinuxPlatform.OpenExternal("https://aistudio.google.com/apikey")));
        card.Append(Text("2. Paste it here"));
        var key = Entry(session.GeminiKey, "Paste your API key", value => session.GeminiKey = value);
        key.Visibility = false;
        key.OnActivate += async (_, _) => { if (!session.IsTestingGemini) await session.VerifyAndSaveGeminiKey(); };
        card.Append(key);
        var feedback = Text(session.GeminiKeyStatus, "muted");
        card.Append(feedback);
        card.Append(Text("The key stays in your desktop keyring, or a private configuration file when the keyring is unavailable. Audio, transcripts and sampled frames from your videos are sent to Google.", "muted"));
        var save = Button("Save and continue", async () => await session.VerifyAndSaveGeminiKey(), "primary");
        card.Append(save);
        updateModal = () =>
        {
            feedback.SetText(session.GeminiKeyStatus);
            if (session.GeminiKeyRejected) feedback.AddCssClass("warning"); else feedback.RemoveCssClass("warning");
            save.Sensitive = !session.IsTestingGemini && !string.IsNullOrWhiteSpace(session.GeminiKey);
            key.Sensitive = !session.IsTestingGemini;
        };
        OnUI(() => { if (!disposed && modalKind == "key") key.GrabFocus(); });
        return card;
    }

    Gtk.Box ProgressCard()
    {
        var card = ModalCard(session.IsExporting ? "Exporting" : "Creating Shorts");
        var stage = Text(session.GenerationStage);
        var progress = Gtk.ProgressBar.New();
        progress.ShowText = true;
        var detail = Text("", "mono");
        card.Append(stage);
        card.Append(progress);
        card.Append(detail);
        card.Append(Text(session.IsExporting ? "Your files are being prepared for export." : "Gemini finds complete moments, aligns speech and follows the subject.", "muted"));
        var cancel = Button("Cancel", session.CancelGeneration);
        card.Append(cancel);
        updateModal = () =>
        {
            stage.SetText(session.GenerationStage);
            progress.Fraction = Math.Clamp(session.GenerationProgress ?? 0, 0, 1);
            progress.Text = $"{progress.Fraction * 100:0}%";
            detail.SetText($"Elapsed {Format.Clock((DateTime.Now - session.GenerationStartedAt).TotalSeconds)}");
            cancel.Sensitive = session.GenerationStage != "Cancelling…";
        };
        return card;
    }

    Gtk.Box WorkingCard(bool testing = false)
    {
        var card = ModalCard(testing ? "Checking Gemini…" : "Working…");
        var spinner = Gtk.Spinner.New();
        spinner.Start();
        spinner.Halign = Gtk.Align.Center;
        card.Append(spinner);
        var message = Text(session.Message);
        card.Append(message);
        updateModal = () => message.SetText(testing ? session.GeminiKeyStatus : session.Message);
        return card;
    }

    Gtk.Box ErrorCard(GenerationFailure failure)
    {
        var title = failure.IsExport ? "Export failed" : failure.Kind switch
        {
            GenerationFailureKind.NoMoments => "No Shorts found", GenerationFailureKind.Settings => "Check your Gemini settings",
            GenerationFailureKind.Temporary => "Gemini is unavailable right now", _ => "Couldn’t make Shorts",
        };
        var card = ModalCard(title);
        card.Append(Text(failure.Message));
        if (!failure.IsExport && failure.Kind == GenerationFailureKind.NoMoments)
            card.Append(Text("Change the clip length or which part of the video Prism looks in, then try again.", "muted"));
        if (!failure.IsExport && failure.Kind == GenerationFailureKind.Temporary)
            card.Append(Text("This is a temporary problem on Google’s side, not with your video or its range. Prism already retried for about a minute and tried the other Gemini models too. Wait a little, then try again.", "muted"));
        var buttons = Row();
        buttons.Append(Button("Close", () => session.GenerationError = null));
        if (failure.IsExport)
            buttons.Append(Button("Export options", () => { session.GenerationError = null; session.ChooseExport(); }, "primary"));
        else
        {
            if (failure.Kind == GenerationFailureKind.Temporary)
                buttons.Append(Button("Change model", () => { session.GenerationError = null; Navigate(Screen.Settings); }));
            buttons.Append(Button("Try again", async () => { session.GenerationError = null; await session.MakeConfiguredShorts(); },
                failure.Kind is GenerationFailureKind.Temporary or GenerationFailureKind.Other ? "primary" : null));
            if (failure.Kind is GenerationFailureKind.Settings or GenerationFailureKind.NoMoments)
                buttons.Append(Button(failure.Kind == GenerationFailureKind.Settings ? "Open Settings" : "Change clip length or range", () =>
                {
                    session.GenerationError = null;
                    Navigate(failure.Kind == GenerationFailureKind.Settings ? Screen.Settings : Screen.ImportSource);
                }, "primary"));
        }
        card.Append(buttons);
        return card;
    }

    Gtk.Box ExportDoneCard(string summary)
    {
        var card = ModalCard(summary.StartsWith("Export cancelled", StringComparison.Ordinal) ? "Export cancelled" : "Export finished");
        card.Append(Text(summary));
        if (session.LastExportShortCount > 0)
            card.Append(Text($"Shorts: {session.LastExportQuality.Resolution()} · 30 fps · {session.LastExportQuality.Codec()} MP4, ready to upload.", "muted"));
        card.Append(FlowButtons(Button("Done", () => session.ExportSummary = null), Button("Show in file manager", () =>
        { session.ExportSummary = null; session.RevealExports(); }, "primary")));
        return card;
    }

    Gtk.Box ExportCard()
    {
        var initial = session.ExportChoice!;
        var card = ModalCard("Export");
        var clips = session.Project?.Segments ?? [];
        var selected = initial.ShortIds.ToHashSet();
        var checks = new Dictionary<Guid, Gtk.CheckButton>();
        var all = Button("Select all", () =>
        {
            var active = checks.Values.Any(check => !check.Active);
            foreach (var check in checks.Values) check.Active = active;
        });
        card.Append(FlowButtons(Text("Shorts", "muted"), all));
        var rows = Column(8);
        if (clips.Count == 0) rows.Append(Text("No Shorts yet. You can still export the main video.", "muted"));
        foreach (var (clip, index) in clips.Select((clip, index) => (clip, index)))
        {
            var checkbox = Gtk.CheckButton.NewWithLabel($"Short {index + 1} · {clip.SuggestedTitle} · {Format.Clock(clip.Duration)}");
            checkbox.Active = selected.Contains(clip.Id);
            checkbox.OnToggled += (_, _) =>
            {
                if (checkbox.Active) selected.Add(clip.Id); else selected.Remove(clip.Id);
                if (session.ExportChoice is { } choice) session.ExportChoice = choice with { ShortIds = selected.ToHashSet(), Error = null };
            };
            checks[clip.Id] = checkbox;
            rows.Append(checkbox);
        }
        var list = Scroll(rows);
        list.Vexpand = false;
        list.SetSizeRequest(-1, Math.Min(210, Math.Max(40, clips.Count * 34)));
        card.Append(list);
        var videos = session.Project?.Media.Count(media => media.Kind == "video") ?? 0;
        var source = Gtk.CheckButton.NewWithLabel(videos > 1 ? $"Main videos ({videos})" : "Main video");
        source.Active = initial.IncludeSource;
        source.OnToggled += (_, _) =>
        { if (session.ExportChoice is { } choice) session.ExportChoice = choice with { IncludeSource = source.Active, Error = null }; };
        card.Append(source);
        card.Append(Text("The original long video, copied as is.", "muted"));
        var qualities = Enum.GetValues<ExportQuality>();
        card.Append(Field("Quality", Combo(qualities.Select(quality => quality.Title()), Array.IndexOf(qualities, initial.Quality), index =>
        { if (index >= 0 && session.ExportChoice is { } choice) session.ExportChoice = choice with { Quality = qualities[index], Error = null }; })));
        var qualityDetail = Text("", "muted");
        card.Append(qualityDetail);
        var folder = Entry(initial.Folder, "Export folder", text =>
        { if (session.ExportChoice is { } choice) session.ExportChoice = choice with { Folder = text, Error = null }; });
        var folderRow = Row();
        folderRow.Append(folder);
        folderRow.Append(Button("Change…", async () =>
        {
            var picked = await ChooseFolder("Export here");
            if (picked is not null) folder.SetText(picked);
        }));
        card.Append(Field("Save to", folderRow));
        var error = Text("", "warning");
        card.Append(error);
        var export = Button("Export", async () => { if (session.ExportChoice is { } choice) await session.Export(choice); }, "primary");
        card.Append(FlowButtons(Button("Cancel", () => session.ExportChoice = null), export));
        updateModal = () =>
        {
            if (session.ExportChoice is not { } choice) return;
            error.SetText(choice.Error ?? "");
            error.Visible = choice.Error is not null;
            var count = choice.ShortIds.Count + (choice.IncludeSource ? videos : 0);
            export.Label = count == 1 ? "Export 1 file" : $"Export {count} files";
            export.Sensitive = count > 0 && !string.IsNullOrWhiteSpace(choice.Folder);
            all.Label = checks.Values.All(check => check.Active) ? "Select none" : "Select all";
            all.Sensitive = checks.Count > 0;
            qualityDetail.SetText(choice.Quality.Detail() + " Applies to Shorts; the main video keeps its original quality.");
        };
        return card;
    }

    void ShowLocal(Gtk.Box card) { localCard = card; localRevision++; RefreshModal(); }
    void CloseLocal() { localCard = null; RefreshModal(); }

    void ShowNotice(string title, string message)
    {
        var card = ModalCard(title);
        card.Append(Text(message));
        card.Append(Button("Close", CloseLocal, "primary"));
        ShowLocal(card);
    }

    void Prompt(string title, string placeholder, string initial, Action<string> accepted)
    {
        var card = ModalCard(title);
        var entry = Entry(initial, placeholder);
        void Submit()
        {
            var value = entry.GetText().Trim();
            if (value.Length == 0) return;
            CloseLocal();
            accepted(value);
        }
        entry.OnActivate += (_, _) => Submit();
        card.Append(entry);
        card.Append(FlowButtons(Button("Cancel", CloseLocal), Button("Save", Submit, "primary")));
        ShowLocal(card);
        entry.GrabFocus();
    }

    void Confirm(string title, string message, string confirm, Action action)
    {
        var card = ModalCard(title);
        card.Append(Text(message));
        card.Append(FlowButtons(Button("Cancel", CloseLocal), Button(confirm, () => { CloseLocal(); action(); }, "danger")));
        ShowLocal(card);
    }
}
