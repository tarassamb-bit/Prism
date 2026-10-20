namespace Prism.Linux;

public sealed partial class PrismWindow
{
    void ApplyTheme()
    {
        var light = session.Settings.Appearance == "light";
        var background = light ? "#F6F3EC" : "#0E0F14";
        var surface = light ? "#FFFFFF" : "#171920";
        var inset = light ? "#EDE9E0" : "#20232B";
        var border = light ? "#E2DED4" : "#2C2F37";
        var text = light ? "#0E0F14" : "#F6F3EC";
        var muted = light ? "#5C6068" : "#8A8F98";
        var accent = light ? "#0B6CB5" : "#3FA9F5";
        if (Gtk.Settings.GetDefault() is { } settings) settings.GtkApplicationPreferDarkTheme = !light;
        css.LoadFromString($$"""
            window, .background { background: {{background}}; color: {{text}}; font-family: Sora, sans-serif; font-size: 13px; font-weight: 400; }
            label { color: {{text}}; }
            .title { font-family: 'Space Grotesk'; font-size: 32px; font-weight: 500; }
            .brand { font-family: 'Space Grotesk'; font-size: 29px; font-weight: 500; margin-bottom: 28px; }
            .subtitle { font-family: 'Space Grotesk'; font-size: 20px; font-weight: 500; }
            .muted { color: {{muted}}; font-size: 12px; }
            .mono { font-family: 'JetBrains Mono', monospace; font-size: 11px; color: {{muted}}; }
            .card { padding: 20px; background: {{surface}}; border: 1px solid {{border}}; border-radius: 16px; }
            .start-card { background: #3FA9F5; border-color: #3FA9F5; }
            .start-card label { color: #0E0F14; }
            .start-card button { color: #F6F3EC; background: #0E0F14; border-color: #0E0F14; }
            .section { padding: 30px; }
            .sidebar { padding: 26px 20px; background: {{surface}}; border-right: 1px solid {{border}}; }
            .toolbar { padding: 14px 20px; border-bottom: 1px solid {{border}}; background: {{surface}}; }
            button { color: {{text}}; background: {{inset}}; border: 1px solid {{border}}; border-radius: 8px; padding: 10px 14px; box-shadow: none; font-weight: 400; }
            button:hover { border-color: {{accent}}; }
            button:disabled { opacity: 0.45; }
            button.primary { color: #0E0F14; background: #3FA9F5; border-color: #3FA9F5; font-weight: 500; }
            button.nav { background: transparent; border-color: transparent; }
            button.nav-active, button.selected { background: {{inset}}; border-color: {{accent}}; }
            button.danger, .danger { color: #FF6B57; }
            .warning { color: {{(light ? "#8F5E00" : "#FFC233")}}; }
            .accent { color: {{accent}}; }
            entry, spinbutton, combobox { background: {{inset}}; color: {{text}}; border: 1px solid {{border}}; border-radius: 8px; padding: 7px; }
            entry:focus { border-color: {{accent}}; }
            .scrim { background: rgba(0,0,0,0.68); }
            .modal { padding: 26px; background: {{surface}}; border: 1px solid {{border}}; border-radius: 16px; }
            .pill { background: {{inset}}; border-radius: 6px; padding: 4px 8px; font-size: 11px; }
            .bordered { border: 1px solid {{border}}; }
            progressbar trough { background: {{inset}}; border-radius: 5px; min-height: 5px; }
            progressbar progress { background: #3FA9F5; border-radius: 5px; min-height: 5px; }
            flowboxchild { padding: 0; background: transparent; }
            popover contents { background: {{surface}}; border: 1px solid {{border}}; border-radius: 12px; padding: 6px; }
            textview, textview text { background: {{inset}}; color: {{text}}; }
            separator { background: {{border}}; min-height: 1px; }
            """);
        Gtk.StyleContext.AddProviderForDisplay(window.GetDisplay(), css, 800);
    }
}
