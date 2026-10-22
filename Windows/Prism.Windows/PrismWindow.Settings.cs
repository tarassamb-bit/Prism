using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Prism.Core;

namespace Prism.Windows;

public sealed partial class PrismWindow
{
    UIElement SettingsPage()
    {
        var page = Column(Text("Settings", 32, display: true), Text("Choose a category to configure Prism.", muted: true));
        page.Margin = new Thickness(32); page.MaxWidth = 1064; page.HorizontalAlignment = HorizontalAlignment.Left;
        var tiles = Row(
            CategoryTile(0, "", "AI & Cloud", "Provider, key, and model"),
            CategoryTile(2, "\uE77B", "Account", session.Account.Email ?? "Sign in to track your stats"),
            CategoryTile(1, "", "System resources", "RAM and storage updates"));
        tiles.Margin = new Thickness(0, 16, 0, 20); page.Children.Add(tiles);
        page.Children.Add(settingsCategory switch { 0 => AiSettings(), 2 => AccountSettings(), _ => ResourceSettings() });
        return Scroll(page);
    }

    Button CategoryTile(int category, string glyph, string title, string detail)
    {
        var selected = settingsCategory == category;
        var tile = Button("", () => { settingsCategory = category; InvalidateScreen(); });
        tile.SetResourceReference(StyleProperty, "Tile"); tile.Width = 190; tile.Height = 136; tile.Padding = new Thickness(14); tile.Margin = new Thickness(0, 0, 14, 0);
        tile.SetResourceReference(BackgroundProperty, selected ? "AccentWash" : "Surface1");
        tile.SetResourceReference(BorderBrushProperty, selected ? "Accent" : "Surface2"); tile.BorderThickness = new Thickness(selected ? 2 : 1);
        var box = new Border { Width = 38, Height = 38, CornerRadius = new CornerRadius(12), Child = Glyph(glyph, 18, "Accent") };
        box.SetResourceReference(Border.BackgroundProperty, "Surface2");
        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 11) };
        if (selected) { var check = Glyph("", 16, "Accent"); DockPanel.SetDock(check, Dock.Right); top.Children.Add(check); }
        top.Children.Add(WithLeft(box));
        var name = Text(title, 14); name.FontWeight = FontWeights.Medium; name.Margin = new Thickness(0, 0, 0, 4);
        var note = Text(detail, 10, muted: true); note.MaxHeight = 28; note.TextTrimming = TextTrimming.CharacterEllipsis; note.Margin = new Thickness(0);
        tile.Content = Column(top, name, note);
        AutomationProperties.SetName(tile, title);
        return tile;
    }

    static StackPanel SectionTitle(string glyph, string title)
    {
        var mark = Glyph(glyph, 18, "Ink"); mark.Margin = new Thickness(0, 0, 10, 0);
        return Row(mark, Text(title, 20, display: true));
    }

    UIElement AiSettings()
    {
        var section = Column(SectionTitle("", "AI & Cloud"), Text("Gemini handles clip selection, transcription, subtitles, framing and editor chat.", muted: true), Divider(new Thickness(0, 14, 0, 14)));
        var keyTitle = Text("Google AI Studio API key", 14); keyTitle.FontWeight = FontWeights.Medium; section.Children.Add(keyTitle);
        var stateIcon = Glyph("", 14); stateIcon.Margin = new Thickness(0, 0, 10, 0);
        var stateText = Text("", 13); stateText.FontWeight = FontWeights.Medium; stateText.Margin = new Thickness(0);
        var hidden = Text("Hidden for security", 12, muted: true); hidden.Margin = new Thickness(0);
        var state = new DockPanel(); DockPanel.SetDock(hidden, Dock.Right); state.Children.Add(hidden); state.Children.Add(Row(stateIcon, stateText));
        var stateRow = Surface(state, 12, 12); stateRow.Margin = new Thickness(0, 8, 0, 10); section.Children.Add(stateRow);
        var keyRow = new Border { CornerRadius = new CornerRadius(12), Padding = new Thickness(11, 5, 6, 5), MinHeight = 46 };
        keyRow.SetResourceReference(Border.BackgroundProperty, "Surface2"); section.Children.Add(keyRow);
        var test = Button("Test connection", () => session.TestGeminiKey());
        var remove = Button("Remove saved key", () => Confirm("Remove saved key?", "Prism needs your Gemini API key before it can work.", "Remove key", session.RemoveGeminiKey), danger: true);
        var actions = Row(test, remove); actions.Margin = new Thickness(0, 10, 0, 0); section.Children.Add(actions);
        var feedback = Text(session.GeminiKeyStatus, 12, muted: true); section.Children.Add(feedback);
        var link = Link(Button("Get a key from Google AI Studio", () => WindowsPlatform.OpenExternal("https://aistudio.google.com/apikey")));
        link.SetResourceReference(ForegroundProperty, "Accent"); link.Margin = new Thickness(-8, 0, 0, 0); section.Children.Add(link);
        section.Children.Add(Divider(new Thickness(0, 14, 0, 14)));
        var models = Gemini.Models;
        var modelTitle = Text("Gemini model", 14); modelTitle.FontWeight = FontWeights.Medium;
        var model = Combo(models.Select(item => item.Title), Math.Max(0, Array.FindIndex(models, item => item.Id == session.GeminiModel)), index => { if (index >= 0) session.GeminiModel = models[index].Id; });
        model.MinWidth = 300; model.Margin = new Thickness(18, 0, 0, 0); model.VerticalAlignment = VerticalAlignment.Center;
        section.Children.Add(SplitRow(Column(modelTitle, Text("The default is recommended. Change it if you prefer.", 12, muted: true)), model));
        section.Children.Add(Text("Cloud AI sends audio, transcripts and sampled frames to Google. Chat sends your request, recent conversation and edit summary. Google API charges may apply. Video rendering and subject tracking run on your PC. Your key is protected with Windows Data Protection for your Windows account.", 12, muted: true));

        string structure = ""; PasswordBox? typed = null; Button? save = null;
        updateScreen = () =>
        {
            var saved = session.IsGeminiKeySaved;
            stateIcon.Text = saved ? "" : ""; stateIcon.SetResourceReference(TextBlock.ForegroundProperty, saved ? "Accent" : "Muted");
            stateText.Text = saved ? "API key saved securely" : "No API key saved";
            hidden.Visibility = remove.Visibility = saved ? Visibility.Visible : Visibility.Collapsed;
            feedback.Text = session.GeminiKeyStatus;
            test.Content = session.IsTestingGemini ? "Testing…" : "Test connection";
            var desired = $"{saved}:{session.IsEditingGeminiKey}:{session.IsShowingGeminiKey}";
            if (structure != desired)
            {
                structure = desired; typed = null; save = null;
                var row = new DockPanel();
                var lead = Glyph(saved && !session.IsEditingGeminiKey ? "" : "", 14, "Muted"); lead.Margin = new Thickness(0, 0, 10, 0);
                DockPanel.SetDock(lead, Dock.Left); row.Children.Add(lead);
                var trailing = Row(); DockPanel.SetDock(trailing, Dock.Right); row.Children.Add(trailing);
                if (!saved || session.IsEditingGeminiKey)
                {
                    typed = new PasswordBox { Password = session.GeminiKey, Padding = new Thickness(2, 6, 2, 6), Background = Brushes.Transparent, BorderThickness = new Thickness(0), VerticalAlignment = VerticalAlignment.Center };
                    AutomationProperties.SetName(typed, saved ? "Enter a new API key" : "Paste your API key");
                    var entry = typed;
                    entry.PasswordChanged += (_, _) => session.GeminiKey = entry.Password;
                    entry.KeyDown += async (_, args) =>
                    {
                        if (args.Key != Key.Enter || session.IsTestingGemini || string.IsNullOrWhiteSpace(session.GeminiKey)) return;
                        args.Handled = true;
                        try { await session.VerifyAndSaveGeminiKey(); } catch (Exception error) { ShowNotice("Could not check key", error.Message); }
                    };
                    if (saved) trailing.Children.Add(Link(Button("Cancel", session.CancelGeminiKeyEdit)));
                    save = Button(saved ? "Save" : "Save key", () => session.VerifyAndSaveGeminiKey(), true); save.Margin = new Thickness(6, 0, 0, 0);
                    trailing.Children.Add(save);
                    row.Children.Add(entry);
                }
                else
                {
                    if (session.IsShowingGeminiKey)
                        row.Children.Add(new TextBox { Text = session.RevealedGeminiKey, IsReadOnly = true, Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0, 6, 0, 6), FontFamily = (FontFamily)FindResource("MonoFont") });
                    else row.Children.Add(Text(new string('•', 24), 13, muted: true, mono: true));
                    trailing.Children.Add(KeyIcon(session.IsShowingGeminiKey ? "" : "", session.IsShowingGeminiKey ? "Hide API key" : "Show API key", session.ToggleGeminiKeyVisibility));
                    trailing.Children.Add(KeyIcon("", "Edit API key", session.EditGeminiKey));
                }
                keyRow.Child = row;
            }
            if (typed is not null) typed.IsEnabled = !session.IsTestingGemini;
            if (save is not null) save.IsEnabled = !session.IsTestingGemini && !string.IsNullOrWhiteSpace(session.GeminiKey);
            test.IsEnabled = !session.IsTestingGemini;
            remove.IsEnabled = !session.IsTestingGemini && !session.IsEditingGeminiKey;
            section.IsEnabled = !session.IsBusy;
        };
        return section;
    }

    /// The optional Prism account, as on the Mac: sign in, and each export adds to your stats on the website.
    UIElement AccountSettings()
    {
        var section = Column(SectionTitle("\uE77B", "Account"),
            Text("Optional. When you're signed in, each export adds its date, number of Shorts, length and quality to your stats on the Prism website. Videos, transcripts and file names stay on your PC.", muted: true),
            Divider(new Thickness(0, 14, 0, 14)));
        var account = session.Account;
        if (account.Email is { } email)
        {
            var check = Glyph("\uE930", 16, "Accent"); check.Margin = new Thickness(0, 0, 10, 0);
            var who = Text($"Signed in as {email}", 13); who.FontWeight = FontWeights.Medium; who.Margin = new Thickness(0);
            var signOut = Button("Sign out", account.SignOut, danger: true); signOut.Margin = new Thickness(0);
            var row = new DockPanel(); DockPanel.SetDock(signOut, Dock.Right); row.Children.Add(signOut); row.Children.Add(Row(check, who));
            section.Children.Add(Surface(row, 12, 12));
            var stats = Link(Button("See your stats in the browser", () => WindowsPlatform.OpenExternal(Account.StatsPage)));
            stats.SetResourceReference(ForegroundProperty, "Accent"); stats.Margin = new Thickness(-8, 8, 0, 0); section.Children.Add(stats);
        }
        else
        {
            var address = Entry("", "Email"); address.Margin = new Thickness(0, 0, 0, 8);
            var password = new PasswordBox { Padding = new Thickness(10), Margin = new Thickness(0, 0, 0, 8) };
            AutomationProperties.SetName(password, "Password (at least 6 characters)");
            var hint = Text("Password (at least 6 characters)", 12, muted: true); hint.Margin = new Thickness(0, 0, 0, 4);
            var signIn = Button("Sign in", async () => { await account.SignIn(address.Text, password.Password); if (account.IsSignedIn) password.Clear(); }, true);
            var create = Button("Create account", async () => { await account.SignUp(address.Text, password.Password); password.Clear(); });
            void Enable() => signIn.IsEnabled = create.IsEnabled = !account.IsWorking && address.Text.Trim().Length > 0 && password.Password.Length > 0;
            address.TextChanged += (_, _) => Enable(); password.PasswordChanged += (_, _) => Enable();
            password.KeyDown += async (_, args) => { if (args.Key == Key.Enter && signIn.IsEnabled) { args.Handled = true; await account.SignIn(address.Text, password.Password); if (account.IsSignedIn) password.Clear(); } };
            section.Children.Add(address); section.Children.Add(hint); section.Children.Add(password); section.Children.Add(Row(signIn, create));
            Enable();
            updateScreen = Enable;
        }
        var status = Text(account.Status, 12, muted: true);
        section.Children.Add(status);
        var inner = updateScreen;
        updateScreen = () => { inner?.Invoke(); status.Text = account.Status; status.Visibility = account.Status.Length > 0 ? Visibility.Visible : Visibility.Collapsed; };
        return section;
    }

    Button KeyIcon(string glyph, string title, Action action)
    {
        var button = Link(Button("", action)); button.Content = Glyph(glyph, 14); button.Width = 34; button.Height = 34; button.Padding = new Thickness(0);
        button.HorizontalContentAlignment = HorizontalAlignment.Center; button.ToolTip = title; AutomationProperties.SetName(button, title);
        return button;
    }

    UIElement ResourceSettings()
    {
        var profile = MachineProfile.Detect();
        (string Title, double Seconds)[] intervals = [("1 second", 1), ("5 seconds", 5), ("10 seconds", 10), ("30 seconds", 30), ("1 minute", 60), ("5 minutes", 300), ("10 minutes", 600), ("15 minutes", 900), ("30 minutes", 1800), ("45 minutes", 2700), ("60 minutes", 3600)];
        var tiles = new Grid { Margin = new Thickness(0, 18, 0, 0) };
        tiles.ColumnDefinitions.Add(new ColumnDefinition()); tiles.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) }); tiles.ColumnDefinitions.Add(new ColumnDefinition());
        tiles.Children.Add(ResourceTile("Memory used", string.Create(CultureInfo.InvariantCulture, $"{profile.MemoryUsedGB:0.0} / {profile.MemoryGB} GB"), profile.MemoryUsage, Color.FromRgb(175, 82, 222)));
        var free = ResourceTile("Storage available", $"{profile.FreeGB} / {profile.StorageGB} GB", profile.FreeStorageRatio, Color.FromRgb(31, 199, 230));
        Grid.SetColumn(free, 2); tiles.Children.Add(free);
        var frequency = Text("Sidebar update frequency", 14); frequency.FontWeight = FontWeights.Medium;
        var interval = Combo(intervals.Select(item => item.Title), Math.Max(0, Array.FindIndex(intervals, item => item.Seconds == session.Settings.ResourceRefreshSeconds)), index =>
        { if (index >= 0) { session.Settings.ResourceRefreshSeconds = intervals[index].Seconds; session.Settings.Save(); RestartResourceTimer(); } });
        interval.Margin = new Thickness(18, 0, 0, 0); interval.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(interval, "System resource refresh interval");
        var machine = Text($"{profile.OS} · {profile.Cores} CPU cores · {profile.MemoryGB} GB RAM", 11, muted: true, mono: true); machine.Margin = new Thickness(0, 14, 0, 0);
        return Surface(Column(SectionTitle("", "System resources"), Text("Monitor this PC and choose how often the sidebar refreshes.", muted: true), tiles,
            Divider(new Thickness(0, 20, 0, 16)), SplitRow(Column(frequency, Text("Choose from 1 second to 60 minutes.", 12, muted: true)), interval), machine), padding: 24);
    }

    static Border ResourceTile(string title, string value, double fraction, Color tint)
    {
        var bar = new ProgressBar { Height = 7, Maximum = 1, Value = Math.Clamp(fraction, 0, 1), Foreground = Frozen(tint), Margin = new Thickness(0, 8, 0, 0) };
        bar.SetResourceReference(BackgroundProperty, "Surface2");
        var tile = new Border { CornerRadius = new CornerRadius(12), Padding = new Thickness(16), Child = Column(Text(title, muted: true), Text(value, 20, display: true), bar) };
        tile.SetResourceReference(Border.BackgroundProperty, "Surface0");
        return tile;
    }
}
