using System.Reflection;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Runtime.Loader;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;

[SupportedOSPlatform("windows")]
internal static class Program
{
    private static int Main(string[] args)
    {
        var checks = new List<object>();
        var rows = new List<object>();
        void Check(bool passed, string name, object? detail = null)
        {
            checks.Add(new { passed, check = name, detail });
            if (!passed) throw new InvalidOperationException(name);
        }
        try
        {
            if (args.Length < 4) throw new ArgumentException("Assembly, PDB, production source and real directory paths required.");
            using var pe = new PEReader(File.OpenRead(args[0]));
            using var provider = MetadataReaderProvider.FromPortablePdbStream(File.OpenRead(args[1]));
            var metadata = provider.GetMetadataReader();
            var id = metadata.DebugMetadataHeader!.Id;
            var pdbId = new Guid(id.AsSpan().Slice(0, 16));
            Check(pe.ReadDebugDirectory().Any(entry => entry.Type == DebugDirectoryEntryType.CodeView && pe.ReadCodeViewDebugDirectoryData(entry).Guid == pdbId), "Production assembly and PDB identities match");
            var doc = metadata.Documents.Select(handle => metadata.GetDocument(handle)).Single(d => metadata.GetString(d.Name).EndsWith("/PolicyRootSecurity.cs", StringComparison.Ordinal) || metadata.GetString(d.Name).EndsWith("\\PolicyRootSecurity.cs", StringComparison.Ordinal));
            var algorithm = metadata.GetGuid(doc.HashAlgorithm);
            var source = File.ReadAllBytes(args[2]);
            var hash = algorithm == new Guid("8829d00f-11b8-4213-878b-770e8597ac16") ? SHA256.HashData(source) : algorithm == new Guid("ff1816ec-aa5e-4d10-87f7-6f4963833460") ? SHA1.HashData(source) : throw new InvalidOperationException("Unknown PDB source hash algorithm.");
            Check(hash.SequenceEqual(metadata.GetBlobBytes(doc.Hash)), "Executed product assembly's PolicyRootSecurity source checksum matches", Convert.ToHexString(SHA256.HashData(source)));
            var assembly = AssemblyLoadContext.Default.LoadFromAssemblyPath(Path.GetFullPath(args[0]));
            var type = assembly.GetType("RooIndustries.Optimizer.PolicyRootSecurity", true)!;
            var flags = BindingFlags.Static | BindingFlags.NonPublic;
            var entry = type.GetMethod("AdministratorOnlyEntry", flags)!;
            var trusted = type.GetMethod("Trusted", flags)!;
            var writers = type.GetMethod("Writers", flags)!;
            bool Accepted(DirectorySecurity security) => (bool)trusted.Invoke(null, new object?[] { security.GetOwner(typeof(SecurityIdentifier)) })! && writers.Invoke(null, new object[] { security }) is null;
            DirectorySecurity? template = null;
            foreach (var path in args.Skip(3))
            {
                var security = new DirectoryInfo(path).GetAccessControl();
                template ??= security;
                rows.Add(new { path, descriptor = security.GetSecurityDescriptorSddlForm(AccessControlSections.Access | AccessControlSections.Owner | AccessControlSections.Group) });
                Check((bool)entry.Invoke(null, new object[] { path, true })!, "Actual product AdministratorOnlyEntry accepts " + path);
            }
            var unprivileged = new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null);
            foreach (var inheritOnly in new[] { false, true })
            {
                var descriptor = new RawSecurityDescriptor(template!.GetSecurityDescriptorBinaryForm(), 0);
                var aceFlags = inheritOnly ? AceFlags.ContainerInherit | AceFlags.ObjectInherit | AceFlags.InheritOnly : AceFlags.None;
                descriptor.DiscretionaryAcl!.InsertAce(0, new CommonAce(aceFlags, AceQualifier.AccessAllowed, 0x10000000, unprivileged, false, null));
                var bytes = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(bytes, 0);
                var security = new DirectorySecurity(); security.SetSecurityDescriptorBinaryForm(bytes);
                Check(!Accepted(security) && (string?)writers.Invoke(null, new object[] { security }) == unprivileged.Value, inheritOnly ? "Product refuses non-admin inherit-only GA that is not CREATOR OWNER" : "Product refuses non-admin effective write ACE", security.GetSecurityDescriptorSddlForm(AccessControlSections.Access | AccessControlSections.Owner | AccessControlSections.Group));
            }
            var user = WindowsIdentity.GetCurrent().User!;
            var userOwned = new DirectorySecurity(); userOwned.SetSecurityDescriptorBinaryForm(template!.GetSecurityDescriptorBinaryForm()); userOwned.SetOwner(user);
            Check(!Accepted(userOwned) && !(bool)trusted.Invoke(null, new object[] { user })!, "Product refuses user SID owner", user.Value);
        }
        catch (Exception error)
        {
            Console.WriteLine(JsonSerializer.Serialize(new { phase = "product-installed-directory-trust", machine = Environment.MachineName, passed = false, checks, rows, error = error.ToString() }));
            return 1;
        }
        Console.WriteLine(JsonSerializer.Serialize(new { phase = "product-installed-directory-trust", machine = Environment.MachineName, passed = true, checks, rows, productAssemblySha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(args[0]))) }));
        return 0;
    }
}
