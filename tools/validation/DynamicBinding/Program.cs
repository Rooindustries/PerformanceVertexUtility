using System.Reflection;
using System.Reflection.Emit;
using System.Reflection.Metadata;
using System.Reflection.Metadata.Ecma335;
using System.Reflection.PortableExecutable;

var operandTypes = typeof(OpCodes).GetFields().Select(field => (OpCode)field.GetValue(null)!).GroupBy(code => (ushort)code.Value).ToDictionary(group => group.Key, group => group.First().OperandType);
if (args is ["--self-test"])
{
    var self = Analyze([typeof(RooIndustries.Optimizer.GuardFixtures.Misuse).Assembly.Location], out _);
    string[] expected = ["Misuse.Property", "Misuse.Index", "Misuse.ProductConnect", "Misuse.Operator", "Misuse.SimpleName"];
    var missing = expected.Where(name => !self.Any(finding => finding.Contains(name + ":", StringComparison.Ordinal))).ToArray();
    var unexpected = self.Where(finding => !expected.Any(name => finding.Contains(name + ":", StringComparison.Ordinal))).ToArray();
    foreach (var finding in self) Console.WriteLine("FOUND " + finding);
    if (missing.Length > 0 || unexpected.Length > 0) { Console.Error.WriteLine("FAIL guard self-test missed: " + string.Join(", ", missing) + " unexpected: " + string.Join(" | ", unexpected)); return 1; }
    Console.WriteLine("PASS the guard rejects dynamic property, index, operator and same-name product calls in its fixture");
    return 0;
}
if (args.Length == 0) { Console.Error.WriteLine("Provide the product assemblies to check, before obfuscation."); return 2; }
var findings = Analyze(args, out var sites);
foreach (var finding in findings) Console.Error.WriteLine("FAIL " + finding);
if (findings.Count > 0) { Console.Error.WriteLine("Pass product objects as statically typed values (for example object) and use dynamic only for COM objects inside the COM interop classes."); return 1; }
Console.WriteLine("PASS " + sites + " dynamic operations in " + args.Length + " assemblies stay inside COM interop code and share no name with a renamed product member.");
return 0;

List<string> Analyze(IEnumerable<string> paths, out int sites)
{
    string[] comInterop = ["RooIndustries.Optimizer.TimerStartupControl", "RooIndustries.Optimizer.WindowsControlStore"];
    const string ArgumentInfo = "Microsoft.CSharp.RuntimeBinder.CSharpArgumentInfo";
    const string BinderType = "Microsoft.CSharp.RuntimeBinder.Binder::";
    string[] named = ["InvokeMember", "GetMember", "SetMember", "IsEvent"];
    string[] unnamed = ["GetIndex", "SetIndex", "Invoke"];
    var assemblies = paths.Select(Path.GetFullPath).Distinct(StringComparer.OrdinalIgnoreCase).Select(path => (Path: path, Pe: new PEReader(File.OpenRead(path)))).ToArray();
    var ownMethods = new HashSet<string>(StringComparer.Ordinal); var renamedBy = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
    foreach (var (_, pe) in assemblies)
    {
        var metadata = pe.GetMetadataReader();
        var assemblyName = metadata.GetString(metadata.GetAssemblyDefinition().Name);
        if (!renamedBy.TryGetValue(assemblyName, out var renamed)) renamedBy[assemblyName] = renamed = new(StringComparer.Ordinal);
        foreach (var typeHandle in metadata.TypeDefinitions)
        {
            var visible = Visible(metadata, typeHandle); var type = metadata.GetTypeDefinition(typeHandle);
            foreach (var handle in type.GetMethods())
            {
                var method = metadata.GetMethodDefinition(handle); var name = metadata.GetString(method.Name);
                ownMethods.Add(name);
                var access = method.Attributes & MethodAttributes.MemberAccessMask;
                if (name is not (".ctor" or ".cctor") && !(visible && access is MethodAttributes.Public or MethodAttributes.Family or MethodAttributes.FamORAssem)) renamed.TryAdd(name, TypeName(metadata, typeHandle) + "." + name);
            }
            foreach (var handle in type.GetFields())
            {
                var field = metadata.GetFieldDefinition(handle);
                if (!(visible && (field.Attributes & FieldAttributes.FieldAccessMask) == FieldAttributes.Public)) renamed.TryAdd(metadata.GetString(field.Name), TypeName(metadata, typeHandle) + "." + metadata.GetString(field.Name));
            }
        }
    }
    var found = new List<string>(); sites = 0;
    foreach (var (path, pe) in assemblies)
    {
        var metadata = pe.GetMetadataReader();
        var reachable = new[] { metadata.GetString(metadata.GetAssemblyDefinition().Name) }.Concat(metadata.AssemblyReferences.Select(handle => metadata.GetString(metadata.GetAssemblyReference(handle).Name)))
            .Where(renamedBy.ContainsKey).SelectMany(name => renamedBy[name]).GroupBy(item => item.Key).ToDictionary(group => group.Key, group => group.First().Value, StringComparer.Ordinal);
        foreach (var typeHandle in metadata.TypeDefinitions)
        {
            var type = metadata.GetTypeDefinition(typeHandle);
            var owner = TypeName(metadata, typeHandle); var interop = comInterop.Any(name => owner == name || owner.StartsWith(name + "+", StringComparison.Ordinal));
            foreach (var methodHandle in type.GetMethods())
            {
                var method = metadata.GetMethodDefinition(methodHandle);
                if (method.RelativeVirtualAddress == 0) continue;
                var code = Decode(pe.GetMethodBody(method.RelativeVirtualAddress).GetILReader(), metadata);
                var where = Path.GetFileName(path) + " " + owner + "." + metadata.GetString(method.Name);
                for (var index = 0; index < code.Count; index++)
                {
                    var callee = code[index].Callee;
                    if (callee is null || !callee.StartsWith(BinderType, StringComparison.Ordinal)) continue;
                    var kind = callee[BinderType.Length..];
                    if (kind is "BinaryOperation" or "UnaryOperation") { found.Add(where + ": applies an operator to a dynamic value, so the runtime binder can look up a product operator by name. Cast the operands first."); continue; }
                    if (!named.Contains(kind) && !unnamed.Contains(kind)) continue;
                    sites++;
                    var array = code.FindLastIndex(index, item => item.Op == OpCodes.Newarr.Value && item.Type == ArgumentInfo);
                    var receiver = array < 0 ? -1 : code.FindIndex(array, index - array, item => item.Callee == ArgumentInfo + "::Create");
                    var name = !named.Contains(kind) || array < 0 ? -1 : code.FindLastIndex(array, item => item.Op == OpCodes.Ldstr.Value);
                    var flags = name < 1 ? null : code[name - 1].Constant;
                    if (receiver < 2 || code[receiver - 2].Constant is not { } receiverFlags || named.Contains(kind) && (name < 1 || flags is null))
                    {
                        found.Add(where + ": a dynamic " + kind + " site has an unrecognized shape; check it by hand and extend this guard.");
                        continue;
                    }
                    var member = name < 0 ? "[" + kind + "]" : code[name].Text!;
                    var dynamicReceiver = (receiverFlags & (1 | 32)) == 0 && ((flags ?? 0) & 2) == 0;
                    if (!dynamicReceiver)
                    {
                        if (kind == "InvokeMember" && (((flags ?? 0) & 2) != 0 || ownMethods.Contains(member)))
                            found.Add(where + ": calls '" + member + "' with a dynamic argument, so the runtime binder looks up a product method by a name that obfuscation can rename.");
                        continue;
                    }
                    if (!interop)
                        found.Add(where + ": uses '" + member + "' on a dynamic value outside the COM interop classes; the value could be a product object whose members obfuscation renames.");
                    else if (reachable.TryGetValue(member, out var clash))
                        found.Add(where + ": uses '" + member + "' on a dynamic value, and the product member " + clash + " has that name and is renamed by obfuscation. Rename the product member.");
                }
            }
        }
    }
    foreach (var (_, pe) in assemblies) pe.Dispose();
    return found;
}

static bool Visible(MetadataReader metadata, TypeDefinitionHandle handle)
{
    var type = metadata.GetTypeDefinition(handle);
    var access = type.Attributes & TypeAttributes.VisibilityMask;
    if (access == TypeAttributes.Public) return true;
    return access is TypeAttributes.NestedPublic or TypeAttributes.NestedFamily or TypeAttributes.NestedFamORAssem && Visible(metadata, type.GetDeclaringType());
}

List<Instruction> Decode(BlobReader reader, MetadataReader metadata)
{
    var list = new List<Instruction>();
    while (reader.RemainingBytes > 0)
    {
        ushort op = reader.ReadByte();
        if (op == 0xFE) op = (ushort)(0xFE00 | reader.ReadByte());
        long operand = 0;
        switch (operandTypes[op])
        {
            case OperandType.InlineNone: break;
            case OperandType.ShortInlineI: case OperandType.ShortInlineBrTarget: operand = reader.ReadSByte(); break;
            case OperandType.ShortInlineVar: operand = reader.ReadByte(); break;
            case OperandType.InlineVar: operand = reader.ReadUInt16(); break;
            case OperandType.ShortInlineR: reader.ReadSingle(); break;
            case OperandType.InlineI8: case OperandType.InlineR: operand = reader.ReadInt64(); break;
            case OperandType.InlineSwitch: var targets = reader.ReadInt32(); reader.Offset += checked(targets * 4); break;
            default: operand = reader.ReadInt32(); break;
        }
        long? constant = op switch { >= 0x15 and <= 0x1E => (long)op - 0x16, 0x1F or 0x20 => operand, _ => null };
        string? text = null, callee = null, type = null;
        switch (operandTypes[op])
        {
            case OperandType.InlineString: text = metadata.GetUserString(MetadataTokens.UserStringHandle((int)operand & 0xFFFFFF)); break;
            case OperandType.InlineMethod: callee = MethodName(metadata, MetadataTokens.EntityHandle((int)operand)); break;
            case OperandType.InlineType: type = HandleTypeName(metadata, MetadataTokens.EntityHandle((int)operand)); break;
        }
        list.Add(new(unchecked((short)op), constant, text, callee, type));
    }
    return list;
}

static string MethodName(MetadataReader metadata, EntityHandle handle) => handle.Kind switch
{
    HandleKind.MemberReference => HandleTypeName(metadata, metadata.GetMemberReference((MemberReferenceHandle)handle).Parent) + "::" + metadata.GetString(metadata.GetMemberReference((MemberReferenceHandle)handle).Name),
    HandleKind.MethodDefinition => TypeName(metadata, metadata.GetMethodDefinition((MethodDefinitionHandle)handle).GetDeclaringType()) + "::" + metadata.GetString(metadata.GetMethodDefinition((MethodDefinitionHandle)handle).Name),
    HandleKind.MethodSpecification => MethodName(metadata, metadata.GetMethodSpecification((MethodSpecificationHandle)handle).Method),
    _ => "",
};

static string HandleTypeName(MetadataReader metadata, EntityHandle handle) => handle.Kind switch
{
    HandleKind.TypeReference => metadata.GetString(metadata.GetTypeReference((TypeReferenceHandle)handle).Namespace) + "." + metadata.GetString(metadata.GetTypeReference((TypeReferenceHandle)handle).Name),
    HandleKind.TypeDefinition => TypeName(metadata, (TypeDefinitionHandle)handle),
    _ => "",
};

static string TypeName(MetadataReader metadata, TypeDefinitionHandle handle)
{
    var type = metadata.GetTypeDefinition(handle);
    var declaring = type.GetDeclaringType();
    return (declaring.IsNil ? metadata.GetString(type.Namespace) + "." : TypeName(metadata, declaring) + "+") + metadata.GetString(type.Name);
}

sealed record Instruction(short Op, long? Constant, string? Text, string? Callee, string? Type);
