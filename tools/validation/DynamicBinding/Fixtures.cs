namespace RooIndustries.Optimizer.GuardFixtures;

sealed class Gadget
{
    internal int Count { get; set; }
    internal int this[int index] => index;
    internal void Connect() { }
    internal static int Twice(int value) => value * 2;
}

static class Misuse
{
    internal static object Property(dynamic value) => value.Count;
    internal static object Index(dynamic value) => value[0];
    internal static void ProductConnect(dynamic value) => value.Connect();
    internal static object Operator(dynamic value) => value + 1;
    internal static object SimpleName(dynamic value) => Gadget.Twice(value);
}
