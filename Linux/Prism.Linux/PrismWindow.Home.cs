using Prism.Core;

namespace Prism.Linux;

public sealed partial class PrismWindow
{
    Gtk.Widget Home()
    {
        var page = Column(22);
        page.AddCssClass("section");
        var start = Card(Text("One in. Many out.", "title"), Text("Choose a video and Prism finds the moments worth sharing.", "muted"),
            Button("Create Shorts", StartCreate, "primary"));
        start.AddCssClass("start-card");
        page.Append(start);
        var folderHeader = Row();
        var folderTitle = Text("Folders", "subtitle");
        folderTitle.Hexpand = true;
        folderHeader.Append(folderTitle);
        folderHeader.Append(Button("New folder", () => Prompt("New folder", "Folder name", "", name => { session.CreateFolder(name); InvalidateScreen(); })));
        folderHeader.Append(Button("Open project…", async () =>
        {
            var path = await ChooseFolder("Open a Prism project (.relio)");
            if (path is not null) session.Open(path);
        }));
        page.Append(folderHeader);
        var folders = Flow(170, 8);
        var all = Button("Projects", () => { openFolder = null; InvalidateScreen(); }, openFolder is null ? "selected" : null);
        AcceptProjectDrop(all, null);
        folders.Append(all);
        foreach (var folder in session.ProjectFolders)
        {
            var row = Row();
            var open = Button($"▣  {folder.Name}  ({folder.ProjectPaths.Count})", () => { openFolder = folder.Id; InvalidateScreen(); }, openFolder == folder.Id ? "selected" : null);
            row.Append(open);
            AcceptProjectDrop(row, folder.Id);
            AttachMenu(row, [
                ("Rename", () => Prompt("Rename folder", "Folder name", folder.Name, name => { session.RenameFolder(folder.Id, name); InvalidateScreen(); })),
                ("Remove folder", () => Confirm("Remove folder?", "Projects in this folder will go back to Home.", "Remove folder", () => { session.DeleteFolder(folder.Id); openFolder = null; InvalidateScreen(); }))]);
            folders.Append(row);
        }
        page.Append(folders);
        var paths = session.RecentProjectPaths.Where(path => openFolder is null
            ? !session.ProjectFolders.Any(folder => folder.ProjectPaths.Contains(path))
            : session.ProjectFolders.FirstOrDefault(f => f.Id == openFolder)?.ProjectPaths.Contains(path) == true).ToList();
        var counts = ProjectInfo.ShortCounts(paths);
        var completed = paths.Where(path => counts.GetValueOrDefault(path) > 0).ToList();
        var unfinished = paths.Where(path => counts.GetValueOrDefault(path) == 0).ToList();
        var header = Row();
        var title = Text(openFolder is { } id ? session.ProjectFolders.FirstOrDefault(f => f.Id == id)?.Name ?? "Projects" : "Your projects", "subtitle");
        title.Hexpand = true;
        header.Append(title);
        if (completed.Count > 6) header.Append(Button(showAll ? "Show fewer" : "Show all", () => { showAll = !showAll; InvalidateScreen(); }));
        page.Append(header);
        if (completed.Count == 0) page.Append(Text("Your finished Shorts projects will appear here.", "muted"));
        else
        {
            var projects = Flow(240, 12);
            foreach (var path in completed.Take(showAll ? int.MaxValue : 6)) projects.Append(ProjectTile(path, counts.GetValueOrDefault(path)));
            page.Append(projects);
        }
        if (unfinished.Count > 0)
        {
            page.Append(Button($"{(showUnfinished ? "▾" : "▸")} Unfinished projects ({unfinished.Count})", () => { showUnfinished = !showUnfinished; InvalidateScreen(); }));
            if (showUnfinished)
            {
                var grid = Flow(240, 12);
                foreach (var path in unfinished) grid.Append(ProjectTile(path, 0));
                page.Append(grid);
            }
        }
        return Scroll(page);
    }

    static Gtk.FlowBox Flow(int width, uint spacing)
    {
        var flow = Gtk.FlowBox.New();
        flow.SelectionMode = Gtk.SelectionMode.None;
        flow.MinChildrenPerLine = 1;
        flow.MaxChildrenPerLine = 6;
        flow.ColumnSpacing = spacing;
        flow.RowSpacing = spacing;
        flow.Homogeneous = true;
        flow.Hexpand = true;
        return flow;
    }

    Gtk.Widget ProjectTile(string path, int count)
    {
        var project = ProjectStore.ReadProject(path);
        var name = project?.DisplayTitle ?? Path.GetFileNameWithoutExtension(path);
        var card = Column(10);
        card.AddCssClass("card");
        card.SetSizeRequest(240, 240);
        var imageBox = Column(0);
        imageBox.SetSizeRequest(220, 130);
        imageBox.AddCssClass("bordered");
        imageBox.Append(Text("◩", "title"));
        var title = Text(name);
        title.Ellipsize = Pango.EllipsizeMode.End;
        title.Lines = 2;
        title.MaxWidthChars = 27;
        var details = Text($"{count} {(count == 1 ? "Short" : "Shorts")} · {project?.Created.ToLocalTime():d}", "muted");
        var open = Gtk.Button.New();
        var body = Column(8);
        body.Append(imageBox);
        body.Append(title);
        body.Append(details);
        open.Child = body;
        open.HasFrame = false;
        open.OnClicked += (_, _) => session.Open(path);
        card.Append(open);
        var footer = Row();
        var duration = Text(project?.Media.FirstOrDefault(m => m.Kind == "video") is { } video ? Format.Clock(video.Duration) : "", "pill");
        duration.Hexpand = true;
        footer.Append(duration);
        card.Append(footer);
        var actions = new List<(string, Action)>
        {
            ("Rename", () => Prompt("Rename project", "Project title", name, value => { session.RenameProject(path, value); InvalidateScreen(); })),
            ("Move to folder…", () => MoveProjectCard(path)),
            ("Stats", () => ShowStats(path)),
            ("Move to Trash", () => Confirm("Move project to Trash?", $"“{name}” will be moved to the Trash, where it can still be restored.", "Move to Trash", () => { session.DeleteProject(path); InvalidateScreen(); })),
        };
        if (session.ProjectFolders.Any(folder => folder.ProjectPaths.Contains(path)))
            actions.Insert(2, ("Remove from folder", () => { session.MoveProject(path, null); InvalidateScreen(); }));
        AttachMenu(card, actions.ToArray(), footer);
        var drag = Gtk.DragSource.New();
        drag.Actions = Gdk.DragAction.Move;
        drag.OnPrepare += (_, _) =>
        {
            using var value = new GObject.Value();
            value.Init(GObject.Type.String);
            value.SetString(path);
            return Gdk.ContentProvider.NewForValue(value);
        };
        card.AddController(drag);
        _ = LoadPoster(path, imageBox, title, details);
        return card;
    }

    async Task LoadPoster(string path, Gtk.Box image, Gtk.Label title, Gtk.Label details)
    {
        var revision = homeRevision;
        try
        {
            var summary = summaries.GetValueOrDefault(path) ?? await Task.Run(() => ProjectInfo.Summary(path));
            OnUI(() =>
            {
                if (disposed || revision != homeRevision || image.GetParent() is null) return;
                summaries[path] = summary;
                title.SetText(summary.Title);
                details.SetText($"{summary.ShortCount} {(summary.ShortCount == 1 ? "Short" : "Shorts")} · {summary.Created?.ToLocalTime():d}");
                if (summary.Poster is not null)
                {
                    Clear(image);
                    image.Append(Picture(summary.Poster, 220, 130));
                }
            });
        }
        catch (Exception) { }
    }

    void AttachMenu(Gtk.Widget target, (string Title, Action Action)[] actions, Gtk.Box? footer = null)
    {
        var menu = Gtk.MenuButton.New();
        menu.Label = "⋮";
        menu.TooltipText = "Project actions";
        var popover = Gtk.Popover.New();
        var entries = Column(4);
        foreach (var (title, action) in actions)
            entries.Append(Button(title, () => { popover.Popdown(); action(); }, title.Contains("Trash") ? "danger" : null));
        popover.Child = entries;
        menu.Popover = popover;
        if (footer is not null) footer.Append(menu);
        else if (target is Gtk.Box box) box.Append(menu);
        var click = Gtk.GestureClick.New();
        click.Button = 3;
        click.OnPressed += (_, _) => menu.Popup();
        target.AddController(click);
    }

    void AcceptProjectDrop(Gtk.Widget widget, Guid? folderId)
    {
        var drop = Gtk.DropTarget.New(GObject.Type.String, Gdk.DragAction.Move);
        drop.OnDrop += (_, args) =>
        {
            var path = args.Value.GetString();
            if (session.IsBusy || path is null || !session.RecentProjectPaths.Contains(path)) return false;
            session.MoveProject(path, folderId);
            InvalidateScreen();
            return true;
        };
        widget.AddController(drop);
    }

    void MoveProjectCard(string path)
    {
        var card = ModalCard("Move to folder");
        foreach (var folder in session.ProjectFolders)
            card.Append(Button(folder.Name, () => { session.MoveProject(path, folder.Id); CloseLocal(); InvalidateScreen(); }));
        card.Append(Button("New folder…", () => Prompt("New folder", "Folder name", "", name =>
        {
            if (session.CreateFolder(name) is { } id) session.MoveProject(path, id);
            InvalidateScreen();
        })));
        card.Append(Button("Cancel", CloseLocal));
        ShowLocal(card);
    }

    void ShowStats(string path)
    {
        if (ProjectInfo.Stats(path) is not { } stats) { ShowNotice("Project stats", "This project could not be read."); return; }
        var card = ModalCard("Project stats");
        card.Append(Text(stats.Title, "subtitle"));
        card.Append(Text($"Created {stats.Created.ToLocalTime():f}", "muted"));
        card.Append(Text($"{stats.ShortCount} Shorts · {Format.Clock(stats.ShortsSeconds)} total · {stats.ExportCount} exports"));
        if (stats.SourceName is not null) card.Append(Text($"Source: {stats.SourceName}\n{Format.Clock(stats.SourceSeconds ?? 0)} · {stats.Resolution}", "muted"));
        card.Append(Text($"Library size: {Format.Bytes(stats.Bytes)}", "mono"));
        card.Append(Button("Done", CloseLocal, "primary"));
        ShowLocal(card);
    }
}
