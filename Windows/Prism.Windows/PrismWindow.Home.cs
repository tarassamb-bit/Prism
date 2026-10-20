using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Prism.Core;

namespace Prism.Windows;

public sealed partial class PrismWindow
{
    UIElement Home()
    {
        var page = Column(); page.Margin = new Thickness(30);
        var start = Card(Text("One in. Many out.", 32, display: true), Text("Choose a video and Prism finds the moments worth sharing."), Button("Create Shorts", StartCreate));
        start.Background = new SolidColorBrush(Color.FromRgb(63, 169, 245));
        foreach (var label in ((StackPanel)start.Child).Children.OfType<TextBlock>()) label.Foreground = new SolidColorBrush(Color.FromRgb(14, 15, 20));
        page.Children.Add(start);
        page.Children.Add(SplitRow(Text("Folders", 20, display: true), Row(
            Button("New folder", () => Prompt("New folder", "Folder name", "", name => { session.CreateFolder(name); InvalidateScreen(); })),
            Button("Open project…", () => { if (ChooseFolder("Open a Prism project (.relio)") is { } path) session.Open(path); }))));
        var folders = new WrapPanel { Margin = new Thickness(0, 8, 0, 18) };
        var all = Button("Projects", () => { openFolder = null; InvalidateScreen(); });
        AcceptProjectDrop(all, null); folders.Children.Add(all);
        foreach (var folder in session.ProjectFolders)
        {
            var button = Button($"▣  {folder.Name} ({folder.ProjectPaths.Count})", () => { openFolder = folder.Id; InvalidateScreen(); });
            if (openFolder == folder.Id) button.SetResourceReference(Control.BorderBrushProperty, "Accent");
            button.ContextMenu = Menu(
                ("Rename", () => Prompt("Rename folder", "Folder name", folder.Name, name => { session.RenameFolder(folder.Id, name); InvalidateScreen(); })),
                ("Remove folder", () => Confirm("Remove folder?", "Projects in this folder will go back to Home.", "Remove folder", () => { session.DeleteFolder(folder.Id); openFolder = null; InvalidateScreen(); })));
            AcceptProjectDrop(button, folder.Id); folders.Children.Add(button);
        }
        page.Children.Add(folders);
        var paths = session.RecentProjectPaths.Where(path => openFolder is null
            ? !session.ProjectFolders.Any(folder => folder.ProjectPaths.Contains(path))
            : session.ProjectFolders.FirstOrDefault(folder => folder.Id == openFolder)?.ProjectPaths.Contains(path) == true).ToList();
        var counts = ProjectInfo.ShortCounts(paths);
        var finished = paths.Where(path => counts.GetValueOrDefault(path) > 0).ToList();
        var unfinished = paths.Where(path => counts.GetValueOrDefault(path) == 0).ToList();
        var title = Text(openFolder is { } id ? session.ProjectFolders.FirstOrDefault(folder => folder.Id == id)?.Name ?? "Projects" : "Your projects", 20, display: true);
        page.Children.Add(SplitRow(title, finished.Count > 6 ? Button(showAll ? "Show fewer" : "Show all", () => { showAll = !showAll; InvalidateScreen(); }) : new Border()));
        if (finished.Count == 0) page.Children.Add(Text("Your finished Shorts projects will appear here.", muted: true));
        else
        {
            var grid = new WrapPanel();
            foreach (var path in finished.Take(showAll ? int.MaxValue : 6)) grid.Children.Add(ProjectTile(path, counts.GetValueOrDefault(path)));
            page.Children.Add(grid);
        }
        if (unfinished.Count > 0)
        {
            page.Children.Add(Button($"{(showUnfinished ? "▾" : "▸")} Unfinished projects ({unfinished.Count})", () => { showUnfinished = !showUnfinished; InvalidateScreen(); }));
            if (showUnfinished)
            {
                var grid = new WrapPanel();
                foreach (var path in unfinished) grid.Children.Add(ProjectTile(path, 0));
                page.Children.Add(grid);
            }
        }
        return Scroll(page);
    }

    UIElement ProjectTile(string path, int count)
    {
        var project = ProjectStore.ReadProject(path);
        var name = project?.DisplayTitle ?? Path.GetFileNameWithoutExtension(path);
        var poster = new ContentControl { Width = 218, Height = 130, Content = Text("◩", 40, display: true) };
        var title = Text(name); title.MaxHeight = 46; title.TextTrimming = TextTrimming.CharacterEllipsis;
        var details = Text($"{count} {(count == 1 ? "Short" : "Shorts")} · {project?.Created.ToLocalTime():d}", 11, muted: true);
        var open = Button("", () => session.Open(path));
        open.Content = Column(poster, title, details); open.BorderThickness = new Thickness(0); open.Background = Brushes.Transparent;
        open.Padding = new Thickness(0); open.Margin = new Thickness(0);
        var duration = Text(project?.Media.FirstOrDefault(media => media.Kind == "video") is { } video ? Format.Clock(video.Duration) : "", 11, muted: true, mono: true);
        var card = Card(open, duration); card.Width = 258; card.Margin = new Thickness(0, 8, 14, 8);
        var actions = new List<(string, Action)>
        {
            ("Rename", () => Prompt("Rename project", "Project title", name, value => { session.RenameProject(path, value); InvalidateScreen(); })),
            ("Move to folder…", () => MoveProjectCard(path)), ("Stats", () => ShowStats(path)),
            ("Move to Recycle Bin", () => Confirm("Move project to Recycle Bin?", $"“{name}” will be moved to the Recycle Bin, where it can still be restored.", "Move to Recycle Bin", () => { session.DeleteProject(path); InvalidateScreen(); })),
        };
        if (session.ProjectFolders.Any(folder => folder.ProjectPaths.Contains(path))) actions.Insert(2, ("Remove from folder", () => { session.MoveProject(path, null); InvalidateScreen(); }));
        card.ContextMenu = Menu(actions.ToArray());
        var menu = Button("⋮", () => { card.ContextMenu.PlacementTarget = card; card.ContextMenu.IsOpen = true; });
        ((StackPanel)card.Child).Children.Add(menu);
        Point down = default;
        card.PreviewMouseLeftButtonDown += (_, args) => down = args.GetPosition(card);
        card.PreviewMouseMove += (_, args) =>
        {
            if (args.LeftButton != MouseButtonState.Pressed || session.IsBusy) return;
            var here = args.GetPosition(card);
            if (Math.Abs(here.X - down.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(here.Y - down.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            DragDrop.DoDragDrop(card, new DataObject("PrismProject", path), DragDropEffects.Move);
        };
        _ = LoadPoster(path, poster, title, details);
        return card;
    }

    async Task LoadPoster(string path, ContentControl picture, TextBlock title, TextBlock details)
    {
        var revision = homeRevision;
        try
        {
            var summary = summaries.GetValueOrDefault(path) ?? await Task.Run(() => ProjectInfo.Summary(path));
            if (disposed || revision != homeRevision) return;
            summaries[path] = summary; title.Text = summary.Title;
            details.Text = $"{summary.ShortCount} {(summary.ShortCount == 1 ? "Short" : "Shorts")} · {summary.Created?.ToLocalTime():d}";
            if (summary.Poster is not null) picture.Content = Picture(summary.Poster, 218, 130);
        }
        catch (Exception) { }
    }

    ContextMenu Menu(params (string Title, Action Action)[] actions)
    {
        var menu = new ContextMenu();
        foreach (var (title, action) in actions)
        {
            var item = new MenuItem { Header = title };
            item.Click += (_, _) => { try { action(); } catch (Exception error) { ShowNotice("Could not complete action", error.Message); } };
            menu.Items.Add(item);
        }
        return menu;
    }

    void AcceptProjectDrop(FrameworkElement widget, Guid? folderId)
    {
        widget.AllowDrop = true;
        widget.DragOver += (_, args) => { args.Effects = !session.IsBusy && args.Data.GetDataPresent("PrismProject") ? DragDropEffects.Move : DragDropEffects.None; args.Handled = true; };
        widget.Drop += (_, args) =>
        {
            if (session.IsBusy || args.Data.GetData("PrismProject") is not string path || !session.RecentProjectPaths.Contains(path)) return;
            session.MoveProject(path, folderId); InvalidateScreen(); args.Handled = true;
        };
    }

    void MoveProjectCard(string path)
    {
        var card = ModalCard("Move to folder"); var body = (StackPanel)card.Child;
        foreach (var folder in session.ProjectFolders) body.Children.Add(Button(folder.Name, () => { session.MoveProject(path, folder.Id); CloseLocal(); InvalidateScreen(); }));
        body.Children.Add(Button("New folder…", () => Prompt("New folder", "Folder name", "", name =>
        { if (session.CreateFolder(name) is { } id) session.MoveProject(path, id); InvalidateScreen(); })));
        body.Children.Add(Button("Cancel", CloseLocal)); ShowLocal(card);
    }

    void ShowStats(string path)
    {
        if (ProjectInfo.Stats(path) is not { } stats) { ShowNotice("Project stats", "This project could not be read."); return; }
        var card = ModalCard("Project stats"); var body = (StackPanel)card.Child;
        body.Children.Add(Text(stats.Title, 20, display: true)); body.Children.Add(Text($"Created {stats.Created.ToLocalTime():f}", muted: true));
        body.Children.Add(Text($"{stats.ShortCount} Shorts · {Format.Clock(stats.ShortsSeconds)} total · {stats.ExportCount} exports"));
        if (stats.SourceName is not null) body.Children.Add(Text($"Source: {stats.SourceName}\n{Format.Clock(stats.SourceSeconds ?? 0)} · {stats.Resolution}", muted: true));
        body.Children.Add(Text($"Library size: {Format.Bytes(stats.Bytes)}", 11, muted: true, mono: true));
        body.Children.Add(Button("Done", CloseLocal, true)); ShowLocal(card);
    }
}
