using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class BugReportPage : Page
{
    public BugReportViewModel ViewModel { get; } = new();

    public BugReportPage()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            ResizeContent();
            await ViewModel.LoadAsync();
            ResizeContent();
        };
        SizeChanged += (_, _) => ResizeContent();
    }

    private void ResizeContent() => ResponsiveContentSizer.Apply(this, ReportContent, 1100);
    private async void Attach_Click(object sender, RoutedEventArgs e) => await ViewModel.AttachAsync();
    private async void Send_Click(object sender, RoutedEventArgs e) => await ViewModel.SendAsync();
    private async void Save_Click(object sender, RoutedEventArgs e) => await ViewModel.SaveAsync();
    private void OpenFolder_Click(object sender, RoutedEventArgs e) => ViewModel.OpenFolder();
}
