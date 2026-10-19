namespace Prism.Linux;

public static class Program
{
    public static int Main(string[] args)
    {
        var app = Gtk.Application.New("app.prism.linux", Gio.ApplicationFlags.FlagsNone);
        app.OnActivate += (_, _) =>
        {
            var window = Gtk.ApplicationWindow.New(app);
            window.Title = "Prism";
            window.SetDefaultSize(1280, 800);
            window.Present();
        };
        return app.RunWithSynchronizationContext(args);
    }
}
