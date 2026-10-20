using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Prism.Core;

namespace Prism.Windows;

public sealed partial class PrismWindow : Window
{
    readonly AppSession session;
    readonly WindowsEditor editor;
    readonly Grid layout = new();
    readonly Grid overlayHost = new();
    readonly StackPanel navigation = new() { Margin = new Thickness(20, 24, 20, 18) };
    readonly ContentControl content = new();
    readonly Border sidePanel;
    readonly TextBlock heading = Text("Home", 20, display: true);
    readonly TextBlock status = Text("", muted: true);
    readonly TextBlock memory = Text("", 11, muted: true, mono: true);
    readonly TextBlock storage = Text("", 11, muted: true, mono: true);
    readonly ProgressBar memoryBar = new() { Height = 5, Maximum = 1 };
    readonly ProgressBar storageBar = new() { Height = 5, Maximum = 1 };
    readonly Dictionary<Screen, Button> navButtons = [];
    readonly DispatcherTimer resourceTimer = new();
    readonly DispatcherTimer activityTimer = new();
    readonly Dictionary<string, ProjectSummary> summaries = [];
    string renderedScreen = "", modalKind = "", lastMessage = "";
    bool queued, disposed, showAll, showUnfinished;
    int createStep, localRevision;
    long homeRevision;
    Guid? openFolder;
    Border? localCard;
    Action? updateScreen, updateModal;

    public PrismWindow()
    {
        Title = "Prism";
        Width = 1440; Height = 920;
        MinWidth = 900; MinHeight = 620;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        session = new AppSession(new WindowsPlatform());
        session.RefreshGeminiKeyState();
        InstallStyles();
        ApplyTheme();
        SetResourceReference(BackgroundProperty, "Surface0");
        SetResourceReference(ForegroundProperty, "Ink");
        SetResourceReference(FontFamilyProperty, "UiFont");
        editor = new WindowsEditor(session, this);
        editor.Error += message => ShowNotice("Could not complete action", message);
        var root = new Grid();
        root.Children.Add(layout);
        root.Children.Add(overlayHost);
        overlayHost.Visibility = Visibility.Collapsed;
        Content = root;
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(238) });
        layout.ColumnDefinitions.Add(new ColumnDefinition());
        BuildSidebar();
        sidePanel = new Border { Child = navigation, BorderThickness = new Thickness(0, 0, 1, 0) };
        sidePanel.SetResourceReference(Border.BackgroundProperty, "Surface1");
        sidePanel.SetResourceReference(Border.BorderBrushProperty, "Line");
        layout.Children.Add(sidePanel);
        var main = new Grid();
        main.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        main.RowDefinitions.Add(new RowDefinition());
        Grid.SetColumn(main, 1);
        layout.Children.Add(main);
        var header = new DockPanel { Margin = new Thickness(20, 12, 20, 12), LastChildFill = true };
        var theme = Button("☀ / ☾", () =>
        {
            session.Settings.Appearance = session.Settings.Appearance == "light" ? "dark" : "light";
            session.Settings.Save(); ApplyTheme();
        });
        DockPanel.SetDock(theme, Dock.Right); header.Children.Add(theme);
        DockPanel.SetDock(heading, Dock.Left); heading.Margin = new Thickness(0, 6, 20, 0); header.Children.Add(heading);
        status.TextTrimming = TextTrimming.CharacterEllipsis;
        status.TextWrapping = TextWrapping.NoWrap;
        status.VerticalAlignment = VerticalAlignment.Center;
        header.Children.Add(status);
        var top = new Border { Child = header, BorderThickness = new Thickness(0, 0, 0, 1) };
        top.SetResourceReference(Border.BackgroundProperty, "Surface1");
        top.SetResourceReference(Border.BorderBrushProperty, "Line");
        main.Children.Add(top);
        Grid.SetRow(content, 1); main.Children.Add(content);
        session.PropertyChanged += SessionChanged;
        Closed += (_, _) => DisposeSession();
        SizeChanged += (_, _) => { if (overlayHost.Children.Count > 0 && overlayHost.Children[0] is Border { Child: ScrollViewer scroll }) scroll.MaxHeight = Math.Max(300, ActualHeight - 90); };
        resourceTimer.Tick += (_, _) => RefreshResources();
        activityTimer.Interval = TimeSpan.FromSeconds(1);
        activityTimer.Tick += (_, _) => { if (modalKind is "progress" or "working" or "testing") updateModal?.Invoke(); };
        activityTimer.Start();
        RestartResourceTimer();
        Refresh();
    }

    void SessionChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(AppSession.ProjectListRevision) or nameof(AppSession.ProjectFolders) or nameof(AppSession.RecentProjectPaths) or nameof(AppSession.Project))
        { homeRevision++; summaries.Clear(); }
        if (queued || disposed) return;
        queued = true;
        Dispatcher.BeginInvoke(DispatcherPriority.DataBind, new Action(() => { queued = false; if (!disposed) Refresh(); }));
    }

    void Refresh()
    {
        heading.Text = session.Screen switch
        {
            Screen.Home => "Home", Screen.Settings => "Settings", Screen.Create or Screen.ImportSource => "Create Shorts",
            _ => session.Project?.DisplayTitle ?? "Editor",
        };
        status.Text = session.Message;
        layout.ColumnDefinitions[0].Width = new GridLength(session.Screen == Screen.Editor ? 0 : 238);
        sidePanel.Visibility = session.Screen == Screen.Editor ? Visibility.Collapsed : Visibility.Visible;
        foreach (var (screen, button) in navButtons)
        {
            button.IsEnabled = !session.IsBusy;
            button.SetResourceReference(Control.BorderBrushProperty, session.Screen == screen ? "Accent" : "Line");
        }
        var key = session.Screen switch
        {
            Screen.Home => $"home:{homeRevision}:{showAll}:{showUnfinished}:{openFolder}",
            Screen.Create or Screen.ImportSource => $"create:{createStep}:{session.ShortsSource?.Id}",
            Screen.Settings => "settings", _ => "editor",
        };
        if (renderedScreen != key)
        {
            renderedScreen = key; updateScreen = null;
            content.Content = null;
            content.Content = session.Screen switch
            {
                Screen.Home => Home(), Screen.Settings => SettingsPage(),
                Screen.Create or Screen.ImportSource => CreateFlow(), _ => editor.Widget,
            };
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

    void InvalidateScreen() { renderedScreen = ""; Refresh(); }
    void Navigate(Screen screen)
    {
        if (session.IsBusy) return;
        createStep = 0; session.Screen = screen; Refresh();
    }
    void StartCreate() { createStep = 0; session.StartLongVideoToShort(); Refresh(); }

    void BuildSidebar()
    {
        navigation.Children.Add(BrandMark());
        navigation.Children.Add(new Border { Height = 24 });
        AddNavigation("Home", Screen.Home, () => Navigate(Screen.Home));
        AddNavigation("Create Shorts", Screen.ImportSource, StartCreate, true);
        AddNavigation("Editor", Screen.Editor, () => Navigate(Screen.Editor));
        AddNavigation("Settings", Screen.Settings, () => Navigate(Screen.Settings));
        navigation.Children.Add(new Border { Height = 34 });
        navigation.Children.Add(Button("Open library", session.RevealLibrary));
        navigation.Children.Add(Text("RAM used", 11, muted: true)); navigation.Children.Add(memory); navigation.Children.Add(memoryBar);
        navigation.Children.Add(new Border { Height = 12 });
        navigation.Children.Add(Text("Storage free", 11, muted: true)); navigation.Children.Add(storage); navigation.Children.Add(storageBar);
        navigation.Children.Add(new Border { Height = 24 });
        navigation.Children.Add(Text("One in. Many out.", muted: true));
    }
    void AddNavigation(string title, Screen screen, Action action, bool primary = false)
    {
        var button = Button(title, action, primary);
        button.HorizontalContentAlignment = HorizontalAlignment.Left;
        navButtons[screen] = button; navigation.Children.Add(button);
    }
    void RestartResourceTimer()
    {
        resourceTimer.Stop();
        resourceTimer.Interval = TimeSpan.FromSeconds(Math.Clamp(session.Settings.ResourceRefreshSeconds, 1, 3600));
        resourceTimer.Start(); RefreshResources();
    }
    void RefreshResources()
    {
        var profile = MachineProfile.Detect();
        memory.Text = string.Create(CultureInfo.InvariantCulture, $"{profile.MemoryUsedGB:0.0} / {profile.MemoryGB} GB");
        storage.Text = $"{profile.FreeGB} / {profile.StorageGB} GB";
        memoryBar.Value = profile.MemoryUsage; storageBar.Value = profile.FreeStorageRatio;
    }

    Task ChooseVideo()
    {
        if (session.IsBusy) return Task.CompletedTask;
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = "Choose your long video", Filter = "Video files|*.mov;*.mp4;*.m4v;*.avi;*.mkv;*.webm|All files|*.*" };
        return dialog.ShowDialog(this) == true ? ImportTyped(dialog.FileName) : Task.CompletedTask;
    }
    string? ChooseFolder(string title)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = title, Multiselect = false };
        return dialog.ShowDialog(this) == true ? dialog.FolderName : null;
    }

    static StackPanel Column(params UIElement[] children)
    {
        var panel = new StackPanel(); foreach (var child in children) panel.Children.Add(child); return panel;
    }
    static StackPanel Row(params UIElement[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal }; foreach (var child in children) panel.Children.Add(child); return panel;
    }
    static TextBlock Text(string text, double size = 13, bool muted = false, bool display = false, bool mono = false)
    {
        var label = new TextBlock { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 5), VerticalAlignment = VerticalAlignment.Center };
        label.SetResourceReference(TextBlock.ForegroundProperty, muted ? "Muted" : "Ink");
        label.SetResourceReference(TextBlock.FontFamilyProperty, display ? "DisplayFont" : mono ? "MonoFont" : "UiFont");
        label.FontWeight = display ? FontWeights.Medium : FontWeights.Normal;
        return label;
    }
    Button Button(string title, Action action, bool primary = false, bool danger = false)
    {
        var button = NewButton(title, primary, danger);
        button.Click += (_, _) => { try { action(); } catch (Exception error) { ShowNotice("Could not complete action", error.Message); } };
        return button;
    }
    Button Button(string title, Func<Task> action, bool primary = false, bool danger = false)
    {
        var button = NewButton(title, primary, danger);
        button.Click += async (_, _) => { try { await action(); } catch (Exception error) { ShowNotice("Could not complete action", error.Message); } };
        return button;
    }
    static Button NewButton(string title, bool primary, bool danger)
    {
        var button = new Button { Content = title, Margin = new Thickness(0, 4, 8, 4), Padding = new Thickness(13, 10, 13, 10), MinHeight = 36 };
        if (primary) { button.SetResourceReference(Control.BackgroundProperty, "Action"); button.Foreground = new SolidColorBrush(Color.FromRgb(14, 15, 20)); }
        if (danger) button.SetResourceReference(Control.ForegroundProperty, "Coral");
        return button;
    }
    static TextBox Entry(string value, string placeholder, Action<string>? changed = null)
    {
        var entry = new TextBox { Text = value, ToolTip = placeholder, MinWidth = 80, Margin = new Thickness(0, 4, 8, 4), Padding = new Thickness(10) };
        if (changed is not null) entry.TextChanged += (_, _) => changed(entry.Text);
        return entry;
    }
    static Border Card(params UIElement[] children)
    {
        var border = new Border { Child = Column(children), CornerRadius = new CornerRadius(16), BorderThickness = new Thickness(1), Padding = new Thickness(20), Margin = new Thickness(0, 0, 0, 16) };
        border.SetResourceReference(Border.BackgroundProperty, "Surface1"); border.SetResourceReference(Border.BorderBrushProperty, "Line");
        return border;
    }
    static ScrollViewer Scroll(UIElement child) => new() { Content = child, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    static StackPanel Field(string title, UIElement child) => Column(Text(title, muted: true), child);
    static Grid SplitRow(UIElement left, UIElement right)
    {
        var row = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(left); Grid.SetColumn(right, 1); row.Children.Add(right); return row;
    }
    static ComboBox Combo(IEnumerable<string> values, int selected, Action<int> changed)
    {
        var combo = new ComboBox { Margin = new Thickness(0, 4, 8, 4), MinWidth = 130, Padding = new Thickness(8) };
        foreach (var value in values) combo.Items.Add(value);
        combo.SelectedIndex = selected;
        combo.SelectionChanged += (_, _) => changed(combo.SelectedIndex);
        return combo;
    }
    static Image Picture(byte[] bytes, double width, double height)
    {
        var image = new BitmapImage();
        using (var stream = new MemoryStream(bytes)) { image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.StreamSource = stream; image.EndInit(); }
        image.Freeze();
        return new Image { Source = image, Width = width, Height = height, Stretch = Stretch.UniformToFill };
    }
    static UIElement BrandMark()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Brand", "Prism.png");
        return File.Exists(path) ? Row(new Image { Source = new BitmapImage(new Uri(path)), Width = 34, Height = 34, Margin = new Thickness(0, 0, 10, 0) }, Text("Prism", 29, display: true)) : Text("Prism", 29, display: true);
    }
    void DisposeSession()
    {
        if (disposed) return; disposed = true;
        resourceTimer.Stop(); activityTimer.Stop(); session.PropertyChanged -= SessionChanged; editor.Dispose(); session.Dispose();
    }
}
