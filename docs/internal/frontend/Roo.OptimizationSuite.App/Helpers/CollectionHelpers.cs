using System.Collections.Generic;
using System.Collections.ObjectModel;

namespace Roo.OptimizationSuite.Helpers;

public static class CollectionHelpers
{
    public static void ResetWith<T>(this ObservableCollection<T> collection, IEnumerable<T>? items)
    {
        collection.Clear();
        if (items is null)
        {
            return;
        }

        foreach (var item in items)
        {
            collection.Add(item);
        }
    }
}
