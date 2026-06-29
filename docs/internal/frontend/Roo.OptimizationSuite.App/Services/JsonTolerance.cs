using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Roo.OptimizationSuite.Services;

internal sealed class TolerantStringListConverter : JsonConverter<List<string>>
{
    public override List<string>? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.Null:
                return null;
            case JsonTokenType.String:
                return new List<string> { reader.GetString() ?? string.Empty };
            case JsonTokenType.StartArray:
                var list = new List<string>();
                while (reader.Read())
                {
                    if (reader.TokenType == JsonTokenType.EndArray) break;
                    if (reader.TokenType == JsonTokenType.String) list.Add(reader.GetString() ?? string.Empty);
                    else reader.Skip();
                }
                return list;
            default:
                reader.Skip();
                return null;
        }
    }

    public override void Write(Utf8JsonWriter writer, List<string> value, JsonSerializerOptions options)
    {
        writer.WriteStartArray();
        foreach (var s in value) writer.WriteStringValue(s);
        writer.WriteEndArray();
    }
}

internal sealed class TolerantDoubleConverter : JsonConverter<double>
{
    public override double Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => reader.TokenType switch
    {
        JsonTokenType.Null => 0d,
        JsonTokenType.String => double.TryParse(reader.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var v) ? v : 0d,
        _ => reader.GetDouble(),
    };

    public override void Write(Utf8JsonWriter writer, double value, JsonSerializerOptions options) => writer.WriteNumberValue(value);
}

internal sealed class TolerantInt64Converter : JsonConverter<long>
{
    public override long Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => reader.TokenType switch
    {
        JsonTokenType.Null => 0L,
        JsonTokenType.String => long.TryParse(reader.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var v) ? v : 0L,
        _ => reader.GetInt64(),
    };

    public override void Write(Utf8JsonWriter writer, long value, JsonSerializerOptions options) => writer.WriteNumberValue(value);
}

internal sealed class TolerantInt32Converter : JsonConverter<int>
{
    public override int Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => reader.TokenType switch
    {
        JsonTokenType.Null => 0,
        JsonTokenType.String => int.TryParse(reader.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var v) ? v : 0,
        _ => reader.GetInt32(),
    };

    public override void Write(Utf8JsonWriter writer, int value, JsonSerializerOptions options) => writer.WriteNumberValue(value);
}

internal static class JsonTolerance
{
    public static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            NumberHandling = JsonNumberHandling.AllowReadingFromString,
        };
        options.Converters.Add(new TolerantDoubleConverter());
        options.Converters.Add(new TolerantInt64Converter());
        options.Converters.Add(new TolerantInt32Converter());
        options.Converters.Add(new TolerantStringListConverter());
        return options;
    }
}
