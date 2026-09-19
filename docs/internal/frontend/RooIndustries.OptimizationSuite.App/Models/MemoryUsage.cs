using System;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RooIndustries.OptimizationSuite.Models;

public static class MemoryUsage
{
    public static int? UsedPercent(long? totalBytes, long? availableBytes)
    {
        if (totalBytes is not > 0 || availableBytes is null || availableBytes < 0 || availableBytes > totalBytes) return null;
        return (int)Math.Round(100d * (totalBytes.Value - availableBytes.Value) / totalBytes.Value);
    }
}

public sealed class MemoryByteCountConverter : JsonConverter<long?>
{
    public override long? Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Number && reader.TryGetInt64(out var number)) return number;
        if (reader.TokenType == JsonTokenType.String && long.TryParse(reader.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out number)) return number;
        reader.Skip();
        return null;
    }
    public override void Write(Utf8JsonWriter writer, long? value, JsonSerializerOptions options)
    {
        if (value is { } number) writer.WriteNumberValue(number);
        else writer.WriteNullValue();
    }
}
