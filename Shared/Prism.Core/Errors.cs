namespace Prism.Core;

public enum ShortMakerFailure { NoVideo, CannotExport, InvalidRange, DestinationExists }

public sealed class ShortMakerException(ShortMakerFailure failure, string? detail = null) : Exception(Describe(failure, detail))
{
    public ShortMakerFailure Failure { get; } = failure;

    static string Describe(ShortMakerFailure failure, string? detail) => failure switch
    {
        ShortMakerFailure.NoVideo => "No playable video track was found.",
        ShortMakerFailure.CannotExport => "The video encoder could not complete the render." + (detail is null ? "" : " " + detail),
        ShortMakerFailure.InvalidRange => "The edit contains an invalid time range. Choose a range within the source video.",
        _ => "A file already exists at the export destination. Choose another filename.",
    };
}

public enum GeminiFailure { InvalidConfiguration, Request, InvalidResponse, InvalidTiming, NoDistinctClips, NoStrongClips, AudioExport, RequestTooLarge }

public sealed class GeminiException(GeminiFailure failure, int status = 0) : Exception(Describe(failure, status))
{
    public GeminiFailure Failure { get; } = failure;
    /// <summary>The HTTP status for <see cref="GeminiFailure.Request"/>.</summary>
    public int Status { get; } = status;

    static string Describe(GeminiFailure failure, int status) => failure switch
    {
        GeminiFailure.AudioExport => "Could not prepare audio for Gemini. Your existing Shorts were kept.",
        GeminiFailure.RequestTooLarge => "This Gemini request exceeds the safe upload size. Choose a shorter source region.",
        GeminiFailure.NoDistinctClips => "No new distinct moments were found in this range. Try another region or length. Your existing clips were kept.",
        GeminiFailure.NoStrongClips => "Prism could not find a strong, self-contained Short in this part of the video. Try another part of the video or a different clip length.",
        GeminiFailure.InvalidTiming => "Gemini returned speech timestamps that could not be aligned safely.",
        GeminiFailure.InvalidConfiguration => "Add your Google AI Studio key and a valid model name in Settings.",
        GeminiFailure.Request => status switch
        {
            400 => "Gemini rejected this request. Check that the selected model supports audio, images and structured output.",
            401 or 403 => "Google rejected the API key or model access. Check your key in Settings.",
            404 => "This Gemini model is unavailable. Choose another model in Settings.",
            429 => "Google’s quota or rate limit was reached. Check your AI Studio quota before retrying.",
            503 => "Google’s servers for this Gemini model are overloaded right now (HTTP 503). This is not your quota or rate limit.",
            _ => $"Google could not complete the request (HTTP {status}). Please try again.",
        },
        _ => "Gemini returned an incomplete or invalid response. Your existing edits were kept.",
    };
}

/// A failure in one stage of a long run, kept whole so the app can tell a busy server from a bad key or an unusable range.
public sealed class StageFailure(string stage, Exception underlying) : Exception($"{stage}: {underlying.Message} Your existing clips were kept.", underlying)
{
    public string Stage { get; } = stage;
    public Exception Underlying { get; } = underlying;
}
