param([Parameter(Mandatory=$true)][string]$Frame,[Parameter(Mandatory=$true)][string]$Repo,[Parameter(Mandatory=$true)][string]$Dotnet,[Parameter(Mandatory)][string]$ExpectedMachine,[Parameter(Mandatory)][string]$ExpectedUserSid)
$ErrorActionPreference='Stop'
$i=[Security.Principal.WindowsIdentity]::GetCurrent()
if($env:COMPUTERNAME -cne $ExpectedMachine -or $i.User.Value -cne $ExpectedUserSid -or -not[Security.Principal.WindowsPrincipal]::new($i).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Native target identity differs'}
if($Frame -notmatch '^C:\\RooBuild\\fixture-registry-[a-f0-9]{32}$'){throw 'Fresh private fixture frame required'}
$project=Join-Path $Frame 'RegistryCheck.csproj'
if(Test-Path -LiteralPath $project){throw 'Prior fixture retained'}
$core=[Security.SecurityElement]::Escape((Join-Path $Repo 'backend\native\Optimizer.Core\Optimizer.Core.csproj'))
$helper=[Security.SecurityElement]::Escape((Join-Path $Repo 'tools\validation\ProtectedSessions\FixtureOwnership.cs'))
@"
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0-windows</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable><TreatWarningsAsErrors>true</TreatWarningsAsErrors></PropertyGroup><ItemGroup><ProjectReference Include="$core"/><Compile Include="$helper" Link="FixtureOwnership.cs"/></ItemGroup></Project>
"@ | Set-Content -LiteralPath $project
@'
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;

static class Program
{
    [DllImport("advapi32.dll")] static extern int RegOverridePredefKey(IntPtr key, IntPtr replacement);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegOpenKeyEx(IntPtr key,string path,int options,int desired,out IntPtr opened);
    [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr key);
    static void Native(int code) { if(code!=0)throw new Win32Exception(code); }
    static string Snapshot(RegistryKey key)=>JsonSerializer.Serialize(key.GetValueNames().Order().Select(name=>new{name,kind=key.GetValueKind(name),value=key.GetValue(name,null,RegistryValueOptions.DoNotExpandEnvironmentNames)}));
    static string Access(RegistrySecurity security)=>JsonSerializer.Serialize(security.GetAccessRules(true,true,typeof(SecurityIdentifier)).Cast<RegistryAccessRule>().Select(rule=>new{sid=rule.IdentityReference.Value,rule.AccessControlType,rule.RegistryRights,rule.InheritanceFlags,rule.PropagationFlags,rule.IsInherited}).OrderBy(rule=>rule.sid).ThenBy(rule=>rule.AccessControlType));
    static int Main(string[] args)
    {
        try{Run(args);return 0;}catch(Exception error){File.WriteAllText(Path.Combine(args[0],"failure.txt"),error.ToString());Console.Error.WriteLine(error);return 1;}
    }
    static void Run(string[] args)
    {
        var frame=args[0];var checks=new List<string>();
        void Check(bool value,string text){if(!value)throw new InvalidOperationException(text);checks.Add(text);Console.WriteLine("PASS "+text);}
        using var identity=WindowsIdentity.GetCurrent();var sid=identity.User!;
        using var real=Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey)??throw new InvalidOperationException("Expected real marker key absent");
        var before=Snapshot(real);File.WriteAllText(Path.Combine(frame,"real-before.json"),before);
        var privateName="Software\\RooIndustriesFixture-"+Guid.NewGuid().ToString("N");
        if(Registry.CurrentUser.OpenSubKey(privateName)!=null)throw new InvalidOperationException("Private hive collision");
        using var hive=Registry.CurrentUser.CreateSubKey(privateName,true);var mapped=false;var cleaned=false;
        File.WriteAllText(Path.Combine(frame,"scope.json"),JsonSerializer.Serialize(new{privateName,sid=sid.Value,helper=typeof(FixtureScope).Assembly.Location}));
        try
        {
            Native(RegOverridePredefKey(new IntPtr(unchecked((int)0x80000002)),hive.Handle.DangerousGetHandle()));mapped=true;
            using(Registry.LocalMachine.CreateSubKey(PolicyRootSecurity.MarkerKey,true)){}
            using var marker=Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey,RegistryKeyPermissionCheck.ReadWriteSubTree,RegistryRights.FullControl)!;
            marker.SetValue("unrelated-sibling",new byte[]{0,255,1},RegistryValueKind.Binary);
            var root=Path.Combine(frame,"owned-root");var scope=new FixtureScope(root,Path.Combine(frame,"evidence"));
            scope.Secure(()=>{Directory.CreateDirectory(root);typeof(PolicyRootSecurity).GetMethod("Mark",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Static)!.Invoke(null,[PolicyRootSecurity.MarkerName(root),sid]);});
            var original=marker.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.Access);var originalAccess=Access(marker.GetAccessControl());var blocked=marker.GetAccessControl();blocked.AddAccessRule(new RegistryAccessRule(sid,RegistryRights.SetValue,AccessControlType.Deny));
            File.WriteAllText(Path.Combine(frame,"original-acl.json"),JsonSerializer.Serialize(new{sddl=original,rules=originalAccess}));
            var expected=Snapshot(marker);File.WriteAllText(Path.Combine(frame,"private-before.json"),expected);
            marker.SetAccessControl(blocked);
            try
            {
                var nativeCode=RegOpenKeyEx(new IntPtr(unchecked((int)0x80000002)),PolicyRootSecurity.MarkerKey,0,2,out var deniedHandle);
                if(deniedHandle!=IntPtr.Zero)Native(RegCloseKey(deniedHandle));
                Check(nativeCode==5,"Native registry KEY_SET_VALUE open returns Win32 access denied");
                Exception? failure=null;try{scope.Cleanup(true);}catch(Exception error){failure=error;}
                File.WriteAllText(Path.Combine(frame,"denial.txt"),failure?.ToString()??"No failure");
                Check(failure?.GetBaseException() is System.Security.SecurityException or UnauthorizedAccessException,"Native registry access denial propagates from actual cleanup");
                Check(Snapshot(marker)==expected && Directory.Exists(root),"Denied cleanup retains both exact typed fields, sibling and root");
                using var receipt=JsonDocument.Parse(File.ReadAllText(Directory.GetFiles(Path.Combine(frame,"evidence"),"cleanup-*.json").Single()));
                Check(receipt.RootElement.GetProperty("status").GetString()=="retained" && receipt.RootElement.GetProperty("fields").GetArrayLength()==2,"Denied cleanup retains its exact recovery receipt");
            }
            finally{var restored=new RegistrySecurity();restored.SetSecurityDescriptorSddlForm(original,AccessControlSections.Access);marker.SetAccessControl(restored);}
            File.WriteAllText(Path.Combine(frame,"restored-acl.json"),JsonSerializer.Serialize(new{sddl=marker.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.Access),rules=Access(marker.GetAccessControl())}));
            Check(Access(marker.GetAccessControl())==originalAccess,"Private registry access rules are restored exactly before retry");
            scope.Cleanup(true);
            Check(!Directory.Exists(root) && marker.GetValueNames().SequenceEqual(new[]{"unrelated-sibling"}) && ((byte[])marker.GetValue("unrelated-sibling")!).SequenceEqual(new byte[]{0,255,1}),"Retry removes only its two fields and root after access returns");
            Check(Snapshot(real)==before,"Real HKLM markers remain byte-for-byte unchanged through private override");cleaned=true;
        }
        finally
        {
            if(mapped)Native(RegOverridePredefKey(new IntPtr(unchecked((int)0x80000002)),IntPtr.Zero));
            if(cleaned){hive.Dispose();Registry.CurrentUser.DeleteSubKeyTree(privateName,true);}
            File.WriteAllText(Path.Combine(frame,"real-after.json"),Snapshot(real));
        }
        Check(Registry.CurrentUser.OpenSubKey(privateName)==null,"Exact private hive is absent after successful cleanup");
        Check(Snapshot(real)==before,"Real marker snapshot is unchanged after restoring HKLM mapping");
        File.WriteAllText(Path.Combine(frame,"proof.json"),JsonSerializer.Serialize(new{completed=true,checks,privateName,realMarkersUnchanged=true},new JsonSerializerOptions{WriteIndented=true}));
    }
}
'@ | Set-Content -LiteralPath (Join-Path $Frame 'Program.cs')
& $Dotnet build $project -c Release --nologo *> (Join-Path $Frame 'build.log')
if($LASTEXITCODE -ne 0){throw 'Private registry fixture build failed; inspect build.log'}
& $Dotnet (Join-Path $Frame 'bin\Release\net8.0-windows\RegistryCheck.dll') $Frame *> (Join-Path $Frame 'checks.log')
if($LASTEXITCODE -ne 0){throw 'Private registry cleanup E2E failed; evidence retained'}
[IO.File]::ReadAllText((Join-Path $Frame 'proof.json'))
