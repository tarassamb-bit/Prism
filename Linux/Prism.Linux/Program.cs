namespace Prism.Linux;

public static class Program
{
    public static int Main(string[] args)
    {
        var app = Gtk.Application.New("app.prism.linux", Gio.ApplicationFlags.FlagsNone);
        PrismWindow? shell = null;
        app.OnActivate += (_, _) =>
        {
            shell ??= new PrismWindow(app);
            shell.Present();
        };
        return app.RunWithSynchronizationContext(args);
    }
}
