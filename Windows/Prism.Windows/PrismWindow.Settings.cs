using System.Windows;
using System.Windows.Controls;
using Prism.Core;

namespace Prism.Windows;

public sealed partial class PrismWindow
{
    UIElement SettingsPage()
    {
        var page = Column(Text("Settings", 32, display: true), Text("Choose a category to configure Prism.", muted: true)); page.Margin = new Thickness(30);
        var keyBox = Column(); var feedback = Text(session.GeminiKeyStatus, muted: true);
        var models = Gemini.Models;
        page.Children.Add(Card(Text("AI & Cloud", 20, display: true), Text("Gemini handles clip selection, transcription, subtitles, framing and editor chat.", muted: true),
            Text("Google AI Studio API key"), keyBox, feedback,
            Button("Open Google AI Studio › API keys", () => WindowsPlatform.OpenExternal("https://aistudio.google.com/apikey")),
            Text("The key is protected with Windows Data Protection for your Windows account. Audio, transcripts and sampled frames from your videos are sent to Google.", muted: true),
            Field("Gemini model", Combo(models.Select(model => model.Title), Math.Max(0, Array.FindIndex(models, model => model.Id == session.GeminiModel)), index => { if (index >= 0) session.GeminiModel = models[index].Id; })),
            Text("Google bills your AI Studio account for what Prism uses; the free tier works too.", muted: true)));
        (string Title, double Seconds)[] intervals = [("1 second", 1), ("5 seconds", 5), ("10 seconds", 10), ("30 seconds", 30), ("1 minute", 60), ("5 minutes", 300), ("10 minutes", 600), ("15 minutes", 900), ("30 minutes", 1800), ("45 minutes", 2700), ("60 minutes", 3600)];
        var profile = MachineProfile.Detect();
        page.Children.Add(Card(Text("System resources", 20, display: true), Text("RAM and available storage refresh at this interval.", muted: true),
            Field("Refresh interval", Combo(intervals.Select(item => item.Title), Math.Max(0, Array.FindIndex(intervals, item => item.Seconds == session.Settings.ResourceRefreshSeconds)), index =>
            { if (index >= 0) { session.Settings.ResourceRefreshSeconds = intervals[index].Seconds; session.Settings.Save(); RestartResourceTimer(); } })),
            Text($"{profile.OS}\n{profile.Cores} CPU cores · {profile.MemoryGB} GB RAM", 11, muted: true, mono: true), Button("Refresh now", RefreshResources)));
        page.Children.Add(Card(Text("Appearance", 20, display: true), Combo(["Dark", "Light"], session.Settings.Appearance == "light" ? 1 : 0, index =>
        { session.Settings.Appearance = index == 1 ? "light" : "dark"; session.Settings.Save(); ApplyTheme(); })));
        string structure = ""; PasswordBox? typed = null; Button? save = null, test = null;
        updateScreen = () =>
        {
            feedback.Text = session.GeminiKeyStatus;
            var desired = $"{session.IsGeminiKeySaved}:{session.IsEditingGeminiKey}:{session.IsShowingGeminiKey}";
            if (structure != desired)
            {
                structure = desired; keyBox.Children.Clear();
                if (!session.IsGeminiKeySaved || session.IsEditingGeminiKey)
                {
                    typed = new PasswordBox { Password = session.GeminiKey, Padding = new Thickness(10), Margin = new Thickness(0, 4, 0, 4) };
                    var currentEntry = typed;
                    currentEntry.PasswordChanged += (_, _) => session.GeminiKey = currentEntry.Password;
                    keyBox.Children.Add(typed); save = Button("Save and check key", () => session.VerifyAndSaveGeminiKey(), true);
                    keyBox.Children.Add(Row(save, Button("Cancel", session.CancelGeminiKeyEdit)));
                }
                else
                {
                    typed = null; save = null;
                    if (session.IsShowingGeminiKey) keyBox.Children.Add(new TextBox { Text = session.RevealedGeminiKey, IsReadOnly = true, Padding = new Thickness(8), Margin = new Thickness(0, 4, 0, 4) });
                    else keyBox.Children.Add(Text("Your API key is saved securely. For security, the saved value stays hidden.", muted: true));
                    test = Button("Test connection", () => session.TestGeminiKey());
                    keyBox.Children.Add(Row(Button(session.IsShowingGeminiKey ? "Hide key" : "Show key", session.ToggleGeminiKeyVisibility), Button("Edit key", session.EditGeminiKey),
                        Button("Remove key", () => Confirm("Remove saved key?", "Prism needs your Gemini API key before it can work.", "Remove key", session.RemoveGeminiKey), danger: true), test));
                }
            }
            if (typed is not null) typed.IsEnabled = !session.IsTestingGemini;
            if (save is not null) save.IsEnabled = !session.IsTestingGemini && !string.IsNullOrWhiteSpace(session.GeminiKey);
            if (test is not null) test.IsEnabled = !session.IsTestingGemini;
        };
        return Scroll(page);
    }
}
