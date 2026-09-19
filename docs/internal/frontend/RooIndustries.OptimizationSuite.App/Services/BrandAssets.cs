using System;
using System.IO;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace RooIndustries.OptimizationSuite.Services;

public static class BrandAssets
{
    public static ImageSource? TryGetLogo()
    {
        var brandDir = new BackendLocator().BrandDirectory;
        if (brandDir is null)
        {
            return null;
        }

        foreach (var fileName in new[] { "favicon-96x96.png", "web-app-manifest-192x192.png", "embed_logo.png" })
        {
            var path = Path.Combine(brandDir, fileName);
            if (File.Exists(path))
            {
                return new BitmapImage(new Uri(path));
            }
        }

        return null;
    }
}
