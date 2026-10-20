using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using Prism.Core;

namespace Prism.Linux;

/// <summary>The GTK shell keeps text controls alive while the shared session reports progress.</summary>
public sealed partial class PrismWindow : IDisposable
{
    readonly Gtk.ApplicationWindow window;
    readonly AppSession session;
    readonly LinuxEditor editor;
    readonly SynchronizationContext? ui;
    readonly Gtk.Box layout = Gtk.Box.New(Gtk.Orientation.Horizontal, 0);
    readonly Gtk.Box main = Gtk.Box.New(Gtk.Orientation.Vertical, 0);
    readonly Gtk.Box content = Gtk.Box.New(Gtk.Orientation.Vertical, 0);
    readonly Gtk.Box sidebar = Gtk.Box.New(Gtk.Orientation.Vertical, 12);
    readonly Gtk.Overlay overlay = Gtk.Overlay.New();
    readonly Gtk.Label heading = Text("Home", "subtitle");
    readonly Gtk.Label status = Text("", "muted");
    readonly Gtk.Label memoryLabel = Text("", "mono");
    readonly Gtk.Label storageLabel = Text("", "mono");
    readonly Gtk.ProgressBar memoryBar = Gtk.ProgressBar.New();
    readonly Gtk.ProgressBar storageBar = Gtk.ProgressBar.New();
    readonly Dictionary<Screen, Gtk.Button> navigation = [];
    readonly Gtk.CssProvider css = Gtk.CssProvider.New();
    System.Threading.Timer? resourceTimer;
    System.Threading.Timer? activityTimer;
    string renderedScreen = "";
    string modalKind = "";
    Gtk.Widget? modal;
    Gtk.Box? localCard;
    bool queued, disposed, showAll, showUnfinished;
    Guid? openFolder;
    int createStep;
    long homeRevision;
    string lastMessage = "";
    Action? updateScreen, updateModal;
    readonly Dictionary<string, ProjectSummary> summaries = [];

    public PrismWindow(Gtk.Application application)
    {
        ui = SynchronizationContext.Current;
        LinuxPlatform.RegisterFonts();
        session = new AppSession(new LinuxPlatform());
        session.RefreshGeminiKeyState();
        window = Gtk.ApplicationWindow.New(application);
        window.Title = "Prism";
        window.SetDefaultSize(1440, 920);
        window.SetSizeRequest(900, 620);
        editor = new LinuxEditor(session, window);
        editor.Error += message => ShowNotice("Could not complete action", message);
        ApplyTheme();
        BuildSidebar();
        var top = Row(12);
        top.AddCssClass("toolbar");
        heading.Hexpand = true;
        status.Ellipsize = Pango.EllipsizeMode.End;
        status.MaxWidthChars = 70;
        top.Append(heading);
        top.Append(status);
        top.Append(Button("☀ / ☾", () =>
        {
            session.Settings.Appearance = session.Settings.Appearance == "light" ? "dark" : "light";
            session.Settings.Save();
            ApplyTheme();
        }));
        main.Hexpand = true;
        main.Vexpand = true;
        content.Hexpand = true;
        content.Vexpand = true;
        main.Append(top);
        main.Append(content);
        layout.Append(sidebar);
        layout.Append(main);
        overlay.Child = layout;
        window.Child = overlay;
        session.PropertyChanged += SessionChanged;
        window.OnCloseRequest += (_, _) => { Dispose(); return false; };
        RestartResourceTimer();
        activityTimer = new System.Threading.Timer(_ => OnUI(() =>
        {
            if (!disposed && modalKind is "progress" or "working" or "testing") updateModal?.Invoke();
        }), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
        Refresh();
    }

    public void Present() => window.Present();

    void SessionChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(AppSession.ProjectListRevision) or nameof(AppSession.RecentProjectPaths) or nameof(AppSession.ProjectFolders) or nameof(AppSession.Project))
        { homeRevision++; summaries.Clear(); }
        if (queued || disposed) return;
        queued = true;
        OnUI(() => { queued = false; if (!disposed) Refresh(); });
    }

    void OnUI(Action action)
    {
        if (ui is null) action();
        else ui.Post(_ => action(), null);
    }

    void Refresh()
    {
        heading.SetText(session.Screen switch
        {
            Screen.Home => "Home", Screen.Settings => "Settings", Screen.Create or Screen.ImportSource => "Create Shorts",
            _ => session.Project?.DisplayTitle ?? "Editor",
        });
        status.SetText(session.Message);
        sidebar.Visible = session.Screen != Screen.Editor;
        foreach (var (screen, button) in navigation)
        {
            if (session.Screen == screen) button.AddCssClass("nav-active"); else button.RemoveCssClass("nav-active");
            button.Sensitive = !session.IsBusy;
        }
        var key = session.Screen switch
        {
            Screen.Home => $"home:{homeRevision}:{showAll}:{showUnfinished}:{openFolder}",
            Screen.Create or Screen.ImportSource => $"create:{createStep}:{session.ShortsSource?.Id}",
            Screen.Settings => "settings",
            _ => "editor",
        };
        if (key != renderedScreen)
        {
            renderedScreen = key;
            updateScreen = null;
            Clear(content);
            var child = session.Screen switch
            {
                Screen.Home => Home(),
                Screen.Create or Screen.ImportSource => CreateFlow(),
                Screen.Settings => SettingsPage(),
                _ => editor.Widget,
            };
            content.Append(child);
        }
        updateScreen?.Invoke();
        editor.Refresh();
        if (lastMessage != session.Message)
        {
            lastMessage = session.Message;
            if (!session.IsBusy && session.GenerationError is null && session.ExportChoice is null && session.ExportSummary is null
                && (lastMessage.StartsWith("Could not", StringComparison.Ordinal) || lastMessage.StartsWith("Choose valid", StringComparison.Ordinal)
                    || lastMessage.StartsWith("No file exists", StringComparison.Ordinal) || lastMessage.Contains("could not be opened", StringComparison.Ordinal)))
                ShowNotice("Could not complete action", lastMessage);
        }
        RefreshModal();
    }

    void Navigate(Screen screen)
    {
        if (session.IsBusy) return;
        createStep = 0;
        session.Screen = screen;
        Refresh();
    }

    void StartCreate()
    {
        createStep = 0;
        session.StartLongVideoToShort();
        Refresh();
    }

    void InvalidateScreen() { renderedScreen = ""; Refresh(); }

    void BuildSidebar()
    {
        sidebar.WidthRequest = 238;
        sidebar.AddCssClass("sidebar");
        sidebar.Append(BrandMark());
        AddNavigation("Home", Screen.Home, () => Navigate(Screen.Home));
        AddNavigation("Create Shorts", Screen.ImportSource, StartCreate, true);
        AddNavigation("Editor", Screen.Editor, () => Navigate(Screen.Editor));
        AddNavigation("Settings", Screen.Settings, () => Navigate(Screen.Settings));
        sidebar.Append(Spacer());
        sidebar.Append(Button("Open library", session.RevealLibrary));
        sidebar.Append(Text("RAM used", "muted"));
        sidebar.Append(memoryLabel);
        sidebar.Append(memoryBar);
        sidebar.Append(Text("Storage free", "muted"));
        sidebar.Append(storageLabel);
        sidebar.Append(storageBar);
        sidebar.Append(Text("One in. Many out.", "muted"));
    }

    void AddNavigation(string title, Screen screen, Action action, bool primary = false)
    {
        var button = Button(title, action, primary ? "primary" : "nav");
        navigation[screen] = button;
        sidebar.Append(button);
    }

    void RestartResourceTimer()
    {
        resourceTimer?.Dispose();
        var seconds = Math.Clamp(session.Settings.ResourceRefreshSeconds, 1, 3600);
        resourceTimer = new System.Threading.Timer(_ =>
        {
            var profile = MachineProfile.Detect();
            OnUI(() =>
            {
                if (disposed) return;
                memoryLabel.SetText(string.Create(CultureInfo.InvariantCulture, $"{profile.MemoryUsedGB:0.0} / {profile.MemoryGB} GB"));
                storageLabel.SetText($"{profile.FreeGB} / {profile.StorageGB} GB");
                memoryBar.Fraction = profile.MemoryUsage;
                storageBar.Fraction = profile.FreeStorageRatio;
            });
        }, null, TimeSpan.Zero, TimeSpan.FromSeconds(seconds));
    }

    async Task ChooseVideo()
    {
        if (session.IsBusy) return;
        try
        {
            var dialog = Gtk.FileDialog.New();
            dialog.Title = "Choose your long video";
            var file = await dialog.OpenAsync(window);
            if (file?.GetPath() is { } path) { createStep = 0; await session.ImportSource(path); Refresh(); }
        }
        catch (Exception error) when (error.Message.Contains("dismiss", StringComparison.OrdinalIgnoreCase) || error.Message.Contains("cancel", StringComparison.OrdinalIgnoreCase)) { }
        catch (Exception error) { ShowNotice("Could not open video", error.Message); }
    }

    async Task<string?> ChooseFolder(string title)
    {
        try
        {
            var dialog = Gtk.FileDialog.New();
            dialog.Title = title;
            var file = await dialog.SelectFolderAsync(window);
            return file?.GetPath();
        }
        catch (Exception error) when (error.Message.Contains("dismiss", StringComparison.OrdinalIgnoreCase) || error.Message.Contains("cancel", StringComparison.OrdinalIgnoreCase)) { return null; }
        catch (Exception error) { session.Message = error.Message; return null; }
    }

    static Gtk.Box Column(int spacing = 12) => Gtk.Box.New(Gtk.Orientation.Vertical, spacing);
    static Gtk.Box Row(int spacing = 8) => Gtk.Box.New(Gtk.Orientation.Horizontal, spacing);
    static Gtk.Box Spacer() { var box = Column(0); box.Hexpand = true; box.Vexpand = true; return box; }
    static Gtk.Label Text(string text, string? cssClass = null)
    {
        var label = Gtk.Label.New(text);
        label.Xalign = 0;
        label.Wrap = true;
        label.MaxWidthChars = 70;
        if (cssClass is not null) label.AddCssClass(cssClass);
        return label;
    }
    Gtk.Button Button(string title, Action action, string? cssClass = null)
    {
        var button = Gtk.Button.NewWithLabel(title);
        if (cssClass is not null) button.AddCssClass(cssClass);
        button.OnClicked += (_, _) =>
        {
            try { action(); }
            catch (Exception error) { ShowNotice("Could not complete action", error.Message); }
        };
        return button;
    }
    Gtk.Button Button(string title, Func<Task> action, string? cssClass = null)
    {
        var button = Gtk.Button.NewWithLabel(title);
        if (cssClass is not null) button.AddCssClass(cssClass);
        button.OnClicked += async (_, _) =>
        {
            try { await action(); }
            catch (Exception error) { ShowNotice("Could not complete action", error.Message); }
        };
        return button;
    }
    static Gtk.Entry Entry(string value, string placeholder, Action<string>? changed = null)
    {
        var entry = Gtk.Entry.New();
        entry.SetText(value);
        entry.PlaceholderText = placeholder;
        entry.Hexpand = true;
        if (changed is not null) entry.OnChanged += (_, _) => changed(entry.GetText());
        return entry;
    }
    static Gtk.Box Card(params Gtk.Widget[] children)
    {
        var card = Column(12);
        card.AddCssClass("card");
        foreach (var child in children) card.Append(child);
        return card;
    }
    static Gtk.ScrolledWindow Scroll(Gtk.Widget child)
    {
        var scrolled = Gtk.ScrolledWindow.New();
        scrolled.Child = child;
        scrolled.Hexpand = true;
        scrolled.Vexpand = true;
        scrolled.SetPolicy(Gtk.PolicyType.Never, Gtk.PolicyType.Automatic);
        return scrolled;
    }
    static void Clear(Gtk.Box box) { while (box.GetFirstChild() is { } child) box.Remove(child); }
    static Gtk.ComboBoxText Combo(IEnumerable<string> values, int selected, Action<int> changed)
    {
        var combo = Gtk.ComboBoxText.New();
        foreach (var value in values) combo.AppendText(value);
        combo.Active = selected;
        combo.OnChanged += (_, _) => changed(combo.Active);
        return combo;
    }
    static Gtk.Picture Picture(byte[] bytes, int width, int height)
    {
        using var data = GLib.Bytes.New(bytes);
        var texture = Gdk.Texture.NewFromBytes(data);
        var picture = Gtk.Picture.NewForPaintable(texture);
        picture.SetSizeRequest(width, height);
        picture.CanShrink = true;
        picture.ContentFit = Gtk.ContentFit.Cover;
        return picture;
    }
    static Gtk.Widget BrandMark()
    {
        var row = Row(10);
        var path = Path.Combine(AppContext.BaseDirectory, "Brand", "Prism.png");
        if (File.Exists(path))
        {
            var mark = Gtk.Picture.NewForFilename(path);
            mark.SetSizeRequest(34, 34);
            row.Append(mark);
        }
        row.Append(Text("Prism", "brand"));
        return row;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        resourceTimer?.Dispose();
        activityTimer?.Dispose();
        session.PropertyChanged -= SessionChanged;
        editor.Dispose();
        session.Dispose();
    }
}
