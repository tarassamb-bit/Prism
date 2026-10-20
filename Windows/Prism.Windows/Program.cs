using System.Windows;
using System.Windows.Threading;

namespace Prism.Windows;

public static class Program
{
    [STAThread]
    public static void Main()
    {
        var app = new Application();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
        app.Run(new PrismWindow());
    }
}
