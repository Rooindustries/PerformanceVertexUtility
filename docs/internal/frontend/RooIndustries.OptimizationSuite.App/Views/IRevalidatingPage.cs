using System.Threading.Tasks;

namespace RooIndustries.OptimizationSuite.Views;

public interface IRevalidatingPage
{
    Task RevalidateAsync();
}
