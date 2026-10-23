namespace Microsoft.UI.Windowing
{
    public enum OverlappedPresenterState { Restored, Minimized }
    public sealed class OverlappedPresenter { public OverlappedPresenterState State { get; set; } }
    public sealed class AppWindowChangedEventArgs : EventArgs
    {
        public bool DidPresenterChange { get; init; }
        public bool DidSizeChange { get; init; }
        public bool DidVisibilityChange { get; init; }
    }
    public sealed class AppWindow
    {
        private readonly OverlappedPresenter _presenter = new();
        public bool IsVisible => true;
        public object Presenter => _presenter;
        public event Action<AppWindow, AppWindowChangedEventArgs>? Changed;
        public void Minimize(bool minimized)
        {
            _presenter.State = minimized ? OverlappedPresenterState.Minimized : OverlappedPresenterState.Restored;
            Changed?.Invoke(this, new() { DidPresenterChange = true });
        }
    }
}

namespace Microsoft.UI.Xaml
{
    public enum WindowActivationState { CodeActivated, Deactivated }
    public sealed class WindowActivatedEventArgs : EventArgs { public WindowActivationState WindowActivationState { get; init; } }
    public sealed class Window
    {
        public Microsoft.UI.Windowing.AppWindow AppWindow { get; } = new();
        public event Action<object, WindowActivatedEventArgs>? Activated;
        public void Raise(WindowActivationState state) => Activated?.Invoke(this, new() { WindowActivationState = state });
    }
    public sealed class DispatcherTimer
    {
        public TimeSpan Interval { get; set; }
        public bool IsEnabled { get; private set; }
        public event EventHandler<object>? Tick;
        public void Start() => IsEnabled = true;
        public void Stop() => IsEnabled = false;
        public void Fire() { if (IsEnabled) Tick?.Invoke(this, EventArgs.Empty); }
    }
}
