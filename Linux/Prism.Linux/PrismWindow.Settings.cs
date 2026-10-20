using Prism.Core;

namespace Prism.Linux;

public sealed partial class PrismWindow
{
    Gtk.Widget SettingsPage()
    {
        var page = Column(22);
        page.AddCssClass("section");
        page.Append(Text("Settings", "title"));
        page.Append(Text("Choose a category to configure Prism.", "muted"));
        var cloud = Card(Text("AI & Cloud", "subtitle"), Text("Gemini handles clip selection, transcription, subtitles, framing and editor chat.", "muted"));
        cloud.Append(Text("Google AI Studio API key"));
        var keyBox = Column(10);
        cloud.Append(keyBox);
        var keyStatus = Text(session.GeminiKeyStatus, "muted");
        cloud.Append(keyStatus);
        cloud.Append(Button("Open Google AI Studio › API keys", () => LinuxPlatform.OpenExternal("https://aistudio.google.com/apikey")));
        cloud.Append(Text("The key stays in your desktop keyring, or a private configuration file when the keyring is unavailable. Audio, transcripts and sampled frames from your videos are sent to Google.", "muted"));
        cloud.Append(Text("Gemini model"));
        var models = Gemini.Models;
        var selected = Array.FindIndex(models, model => model.Id == session.GeminiModel);
        var modelPicker = Combo(models.Select(model => model.Title), Math.Max(0, selected), index =>
        { if (index >= 0) session.GeminiModel = models[index].Id; });
        cloud.Append(modelPicker);
        cloud.Append(Text("Google bills your AI Studio account for what Prism uses; the free tier works too.", "muted"));
        page.Append(cloud);
        var resources = Card(Text("System resources", "subtitle"), Text("RAM and available storage refresh at this interval.", "muted"));
        (string Title, double Seconds)[] intervals =
        [
            ("1 second", 1), ("5 seconds", 5), ("10 seconds", 10), ("30 seconds", 30), ("1 minute", 60),
            ("5 minutes", 300), ("10 minutes", 600), ("15 minutes", 900), ("30 minutes", 1800), ("45 minutes", 2700), ("60 minutes", 3600),
        ];
        resources.Append(Field("Refresh interval", Combo(intervals.Select(item => item.Title),
            Math.Max(0, Array.FindIndex(intervals, item => item.Seconds == session.Settings.ResourceRefreshSeconds)), index =>
            {
                if (index < 0) return;
                session.Settings.ResourceRefreshSeconds = intervals[index].Seconds;
                session.Settings.Save();
                RestartResourceTimer();
            })));
        var profile = MachineProfile.Detect();
        resources.Append(Text($"{profile.OS}\n{profile.Cores} CPU cores · {profile.MemoryGB} GB RAM", "mono"));
        resources.Append(Button("Refresh now", RestartResourceTimer));
        page.Append(resources);
        var appearance = Card(Text("Appearance", "subtitle"));
        appearance.Append(Combo(["Dark", "Light"], session.Settings.Appearance == "light" ? 1 : 0, index =>
        {
            session.Settings.Appearance = index == 1 ? "light" : "dark";
            session.Settings.Save();
            ApplyTheme();
        }));
        page.Append(appearance);
        string keyStructure = "";
        Gtk.Entry? keyEntry = null;
        Gtk.Button? save = null, test = null;
        updateScreen = () =>
        {
            keyStatus.SetText(session.GeminiKeyStatus);
            var structure = $"{session.IsGeminiKeySaved}:{session.IsEditingGeminiKey}:{session.IsShowingGeminiKey}";
            if (structure != keyStructure)
            {
                keyStructure = structure;
                Clear(keyBox);
                if (!session.IsGeminiKeySaved || session.IsEditingGeminiKey)
                {
                    keyEntry = Entry(session.GeminiKey, "Paste your API key", value => session.GeminiKey = value);
                    keyEntry.Visibility = false;
                    keyEntry.OnActivate += async (_, _) => await session.VerifyAndSaveGeminiKey();
                    keyBox.Append(keyEntry);
                    save = Button("Save and check key", async () => await session.VerifyAndSaveGeminiKey(), "primary");
                    var row = Row(); row.Append(save);
                    if (session.IsGeminiKeySaved) row.Append(Button("Cancel", session.CancelGeminiKeyEdit));
                    keyBox.Append(row);
                }
                else
                {
                    keyEntry = null;
                    save = null;
                    keyBox.Append(Text(session.IsShowingGeminiKey ? session.RevealedGeminiKey : "Your API key is saved securely. For security, the saved value stays hidden.", session.IsShowingGeminiKey ? "mono" : "muted"));
                    var row = Row();
                    row.Append(Button(session.IsShowingGeminiKey ? "Hide key" : "Show key", session.ToggleGeminiKeyVisibility));
                    row.Append(Button("Edit key", session.EditGeminiKey));
                    row.Append(Button("Remove key", () => Confirm("Remove saved key?", "Prism needs your Gemini API key before it can work.", "Remove key", session.RemoveGeminiKey), "danger"));
                    test = Button("Test connection", async () => await session.TestGeminiKey());
                    row.Append(test);
                    keyBox.Append(row);
                }
            }
            if (save is not null) save.Sensitive = !session.IsTestingGemini && !string.IsNullOrWhiteSpace(session.GeminiKey);
            if (keyEntry is not null) keyEntry.Sensitive = !session.IsTestingGemini;
            if (test is not null) test.Sensitive = !session.IsTestingGemini;
        };
        return Scroll(page);
    }
}
