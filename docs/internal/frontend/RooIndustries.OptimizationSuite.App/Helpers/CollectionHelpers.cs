using System.Collections.Generic;
using System.Collections.ObjectModel;

namespace RooIndustries.OptimizationSuite.Helpers;

public static class CollectionHelpers
{
    public static void SyncWith<T>(this ObservableCollection<T> collection, IEnumerable<T> items)
    {
        var index = 0;
        foreach (var item in items)
        {
            if (index < collection.Count) { if (!EqualityComparer<T>.Default.Equals(collection[index], item)) collection[index] = item; }
            else collection.Add(item);
            index++;
        }
        while (collection.Count > index) collection.RemoveAt(collection.Count - 1);
    }

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
