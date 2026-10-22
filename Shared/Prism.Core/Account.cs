using System.ComponentModel;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Prism.Core;

/// The optional Prism account (Supabase email + password), a port of the macOS app's Account. When signed in, each finished
/// export adds one row of stats (date, Shorts, seconds, quality) that the website shows. No video, transcript or file name
/// ever leaves the computer.
public sealed class Account : INotifyPropertyChanged
{
    /// The project's public (publishable) key: safe to ship, because Row Level Security limits every user to their own rows.
    public static readonly Uri ProjectUrl = new("https://isdplhahgggundbohmlr.supabase.co/");
    const string PublishableKey = "sb_publishable_ATTcp2-mrca0swMStHHdYQ_Le851b8l";
    public const string StatsPage = "https://tarassamb-bit.github.io/prism-website/#account";
    static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(20) };

    readonly IKeyStore store;
    string? email;
    string status = "";
    bool isWorking;

    public event PropertyChangedEventHandler? PropertyChanged;
    public string? Email { get => email; private set => Set(ref email, value); }
    public string Status { get => status; set => Set(ref status, value); }
    public bool IsWorking { get => isWorking; private set => Set(ref isWorking, value); }
    public bool IsSignedIn => Email is not null;

    public Account(IKeyStore store)
    {
        this.store = store;
        email = SavedSession()?.Email;
    }

    public Task SignIn(string email, string password) => Authenticate("auth/v1/token?grant_type=password", email, password);
    public Task SignUp(string email, string password) => Authenticate("auth/v1/signup", email, password);

    public void SignOut()
    {
        Forget();
        Status = "Signed out. Exports are no longer counted.";
    }

    /// Adds one export to the account's stats. Failures never affect the export; they only show in Settings.
    public async Task RecordExport(int shortCount, double seconds, string quality)
    {
        if (!IsSignedIn || shortCount <= 0 || await AccessToken() is not { } token) return;
        var body = new JsonObject { ["short_count"] = shortCount, ["seconds"] = seconds, ["quality"] = quality };
        var (ok, _, message) = await Send("rest/v1/exports", body, token, minimal: true);
        if (!ok) Status = $"Could not add this export to your stats: {message}";
    }

    sealed record Session(string Email, string RefreshToken);

    async Task Authenticate(string path, string address, string password)
    {
        address = address.Trim();
        if (address.Length == 0 || password.Length < 6) { Status = "Enter your email and a password of at least 6 characters."; return; }
        IsWorking = true;
        try
        {
            var (ok, reply, message) = await Send(path, new JsonObject { ["email"] = address, ["password"] = password });
            if (!ok) { Status = message; return; }
            // Sign-up without a session means Supabase sent a confirmation email first.
            if (reply?["refresh_token"] is null) { Status = "Check your inbox to confirm your email, then sign in."; return; }
            if (!Store(reply, address)) return;
            Status = "Signed in. Each export now adds to your stats.";
        }
        finally { IsWorking = false; }
    }

    /// A fresh access token from the saved refresh token. Supabase rotates refresh tokens, so the new one is saved each time.
    async Task<string?> AccessToken()
    {
        if (SavedSession() is not { } saved) { Email = null; return null; }
        var (ok, reply, message) = await Send("auth/v1/token?grant_type=refresh_token", new JsonObject { ["refresh_token"] = saved.RefreshToken });
        if (!ok)
        {
            Status = $"Your sign-in expired ({message}). Sign in again to keep counting exports.";
            Forget();
            return null;
        }
        return Store(reply, saved.Email) ? reply?["access_token"]?.GetValue<string>() : null;
    }

    void Forget()
    {
        try { store.Save(""); } catch (Exception) { }
        Email = null;
    }

    /// Saves the session from an auth response; false when the response has none.
    bool Store(JsonNode? reply, string address)
    {
        if (reply?["refresh_token"]?.GetValue<string>() is not { Length: > 0 } refresh) return false;
        try { store.Save(JsonSerializer.Serialize(new Session(address, refresh))); }
        catch (Exception error) { Status = "Could not save your sign-in: " + error.Message; return false; }
        Email = address;
        return true;
    }

    Session? SavedSession()
    {
        try
        {
            var text = store.Read();
            return text.Length == 0 ? null : JsonSerializer.Deserialize<Session>(text);
        }
        catch (Exception) { return null; }
    }

    static async Task<(bool Ok, JsonNode? Reply, string Message)> Send(string path, JsonObject body, string? token = null, bool minimal = false)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(ProjectUrl, path))
            {
                Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
            };
            request.Headers.Add("apikey", PublishableKey);
            if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            if (minimal) request.Headers.Add("Prefer", "return=minimal");
            using var response = await Client.SendAsync(request);
            var text = await response.Content.ReadAsStringAsync();
            JsonNode? reply = null;
            try { reply = text.Length > 0 ? JsonNode.Parse(text) : null; } catch (JsonException) { }
            if (response.IsSuccessStatusCode) return (true, reply, "");
            var reason = reply is JsonObject failure
                ? (failure["msg"] ?? failure["error_description"] ?? failure["message"])?.ToString()
                : null;
            return (false, reply, reason ?? $"HTTP {(int)response.StatusCode}");
        }
        catch (Exception error) { return (false, null, error.Message); }
    }

    void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        if (name == nameof(Email)) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSignedIn)));
    }
}
