using System.Reflection.Emit;
using System.Reflection.Metadata;
using System.Reflection.Metadata.Ecma335;
using System.Reflection.PortableExecutable;

if (args.Length == 0) { Console.Error.WriteLine("Provide the product assemblies to check, before obfuscation."); return 2; }
var operandTypes = typeof(OpCodes).GetFields().Select(field => (OpCode)field.GetValue(null)!).GroupBy(code => (ushort)code.Value).ToDictionary(group => group.Key, group => group.First().OperandType);
var assemblies = args.Select(Path.GetFullPath).Distinct(StringComparer.OrdinalIgnoreCase).Select(path => (Path: path, Pe: new PEReader(File.OpenRead(path)))).ToArray();
var ownMethods = new HashSet<string>(StringComparer.Ordinal);
foreach (var (_, pe) in assemblies)
{
    var metadata = pe.GetMetadataReader();
    foreach (var handle in metadata.MethodDefinitions) ownMethods.Add(metadata.GetString(metadata.GetMethodDefinition(handle).Name));
}
const string Binder = "Microsoft.CSharp.RuntimeBinder.Binder::InvokeMember";
string[] operators = ["Microsoft.CSharp.RuntimeBinder.Binder::BinaryOperation", "Microsoft.CSharp.RuntimeBinder.Binder::UnaryOperation"];
var comMembers = new HashSet<string>(["Connect", "GetFolder", "GetTask", "GetTasks", "DeleteTask", "NewTask", "Create", "RegisterTaskDefinition", "GetSecurityDescriptor", "GetInstances", "Run", "Item"], StringComparer.Ordinal);
const string ArgumentInfo = "Microsoft.CSharp.RuntimeBinder.CSharpArgumentInfo";
var findings = new List<string>(); var sites = 0;
foreach (var (path, pe) in assemblies)
{
    var metadata = pe.GetMetadataReader();
    foreach (var typeHandle in metadata.TypeDefinitions)
    {
        var type = metadata.GetTypeDefinition(typeHandle);
        foreach (var methodHandle in type.GetMethods())
        {
            var method = metadata.GetMethodDefinition(methodHandle);
            if (method.RelativeVirtualAddress == 0) continue;
            var code = Decode(pe.GetMethodBody(method.RelativeVirtualAddress).GetILReader(), metadata);
            for (var index = 0; index < code.Count; index++)
            {
                var where = Path.GetFileName(path) + " " + TypeName(metadata, typeHandle) + "." + metadata.GetString(method.Name);
                if (operators.Contains(code[index].Callee)) { findings.Add(where + ": applies an operator to a dynamic value, so the runtime binder can look up a product operator by name. Cast the operands first."); continue; }
                if (code[index].Callee != Binder) continue;
                sites++;
                var array = code.FindLastIndex(index, item => item.Op == OpCodes.Newarr.Value && item.Type == ArgumentInfo);
                var name = array < 0 ? -1 : code.FindLastIndex(array, item => item.Op == OpCodes.Ldstr.Value);
                var receiver = array < 0 ? -1 : code.FindIndex(array, index - array, item => item.Callee == ArgumentInfo + "::Create");
                if (name < 1 || receiver < 2 || code[name - 1].Constant is not { } binderFlags || code[receiver - 2].Constant is not { } receiverFlags)
                {
                    findings.Add(where + ": a dynamic call site has an unrecognized shape; check it by hand and extend this guard.");
                    continue;
                }
                var member = code[name].Text!;
                if ((binderFlags & 2) != 0 || (receiverFlags & (1 | 32)) != 0 && ownMethods.Contains(member))
                    findings.Add(where + ": calls '" + member + "' with a dynamic argument, so the runtime binder looks up a product method by a name that obfuscation can rename.");
                else if ((receiverFlags & (1 | 32)) == 0 && ownMethods.Contains(member) && !comMembers.Contains(member))
                    findings.Add(where + ": calls '" + member + "' on a dynamic value; if that value is a product object, obfuscation renames the method. Add the name to the COM member list only if the receiver is always a COM object.");
            }
        }
    }
}
foreach (var finding in findings) Console.Error.WriteLine("FAIL " + finding);
if (findings.Count > 0) { Console.Error.WriteLine("Pass product objects as statically typed values (for example object) and convert to dynamic only for COM calls."); return 1; }
Console.WriteLine("PASS " + sites + " dynamic member calls in " + assemblies.Length + " assemblies bind only on COM or framework receivers, with no dynamic operators.");
return 0;

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
