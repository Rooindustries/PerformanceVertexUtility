#nullable enable
namespace RooIndustries.Optimizer;

public sealed record CleanupAuthority
{
    public required string AppId { get; init; }
    public required string ProviderIdentityHash { get; init; }
    public required OperationOwner Owner { get; init; }
    public required bool? ProviderQueryComplete { get; init; }
    public required bool? RegistrationPresent { get; init; }
    public required bool? RebootPending { get; init; }
    public required bool? RemoverRunning { get; init; }
    public required bool? RemovalResolved { get; init; }
    public string[] Errors { get; init; } = [];

    public void Verify(string appId, string providerIdentityHash)
    {
        Owner.Verify();
        if (Errors.Length != 0) throw new InvalidOperationException(string.Join(Environment.NewLine, Errors));
        if (string.IsNullOrWhiteSpace(AppId) || AppId != appId || ProviderIdentityHash != providerIdentityHash)
            throw new InvalidDataException("Cleanup evidence belongs to another installed-app identity.");
        if (ProviderQueryComplete != true || RegistrationPresent != false)
            throw new InvalidOperationException("The app registration is present or its current absence is unknown.");
        if (RemoverRunning == true)
            throw new InvalidOperationException("The app's remover is still running. Let it finish, then scan its leftovers again.");
        if (RebootPending == true)
            throw new InvalidOperationException("Restart Windows to finish removing this app, then scan its leftovers again.");
        if (RebootPending != false || RemoverRunning != false || RemovalResolved != true)
            throw new InvalidOperationException("Removal, process lifetime or restart requirements remain unresolved.");
    }
}
