using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class IconChecks
{
    public static void Run(string repo, TweakCatalog catalog, Action<bool, string> check)
    {
        var app = Path.Combine(repo, "docs/internal/frontend/RooIndustries.OptimizationSuite.App");
        var icons = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(Path.Combine(app, "Assets/Tweaks/icons.json")))!;
        check(icons.Keys.ToHashSet().SetEquals(catalog.Settings.Select(setting => setting.Id)), "Every catalog setting has an explicit icon mapping without extra IDs");
        var palette = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "#E8B94A", "#FFF3CD", "#C9962E", "#191E26", "#F1F4F8" };
        var elements = new HashSet<string> { "svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon" };
        foreach (var asset in icons.Values.Distinct())
        {
            if (!Regex.IsMatch(asset, "^[a-z0-9-]+\\.svg$")) throw new InvalidDataException("Invalid icon asset name: " + asset);
            var path = Path.Combine(app, "Assets/Icons/Settings", asset);
            var text = File.ReadAllText(path);
            var svg = XDocument.Parse(text).Root!;
            if (svg.Name.LocalName != "svg" || (string?)svg.Attribute("viewBox") != "0 0 32 32"
                || svg.DescendantsAndSelf().Any(element => !elements.Contains(element.Name.LocalName))
                || svg.DescendantsAndSelf().Attributes().Any(attribute => attribute.Name.LocalName.StartsWith("on", StringComparison.OrdinalIgnoreCase) || attribute.Name.LocalName is "href" or "style")
                || text.Contains("url(", StringComparison.OrdinalIgnoreCase)
                || Regex.Matches(text, "#[0-9a-fA-F]{3,8}").Any(match => !palette.Contains(match.Value)))
                throw new InvalidDataException("Icon geometry or palette is outside the app theme: " + asset);
        }
        check(true, "Every setting SVG exists, parses, uses the gold palette, and contains only local vector geometry");
        check(catalog.Settings.All(setting => WindowsTweakPresentation.Icon(setting) == "ms-appx:///Assets/Icons/Settings/" + icons[setting.Id]),
            "Every row resolves its own catalog icon through the compiled resource");
        var imported = catalog.Settings[0] with { Id = "imported.fixture-setting", Category = "Network" };
        check(WindowsTweakPresentation.Icon(imported) == "ms-appx:///Assets/Icons/tweak-network.svg", "New imported settings retain a category icon until assigned their own");
    }
}
