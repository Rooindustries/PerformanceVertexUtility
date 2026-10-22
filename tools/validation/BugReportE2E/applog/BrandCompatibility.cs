namespace RooIndustries.Optimizer;
public static class BrandCompatibility
{
    public static string LocalDataRoot => Roo70Fixture.Boundary.Root ?? throw new InvalidOperationException("Owned log root not bound.");
}
