using System.Windows;

namespace Prism.Windows;

public static class Program
{
    [STAThread]
    public static void Main()
    {
        var app = new Application();
        app.Run(new Window { Title = "Prism", Width = 1280, Height = 800 });
    }
}
