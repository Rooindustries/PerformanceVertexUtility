using System.Text.Json.Nodes;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.Operations;
using Microsoft.CodeAnalysis.Text;

var input = JsonNode.Parse(File.ReadAllText(args[0]))!;
var facts = new JsonArray();
var units = input["units"]!.AsArray().Select(unit => new Unit(unit!, (string)input["root"]!, facts)).ToList();
foreach (var unit in units)
    unit.Read(units);
Console.Out.Write(facts.ToJsonString());

sealed class Unit
{
    const string Hole = "\0";
    const string PathPiece = "\u0001";
    const string Self = "\u0002";
    static readonly SymbolDisplayFormat TypeFormat = new(
        typeQualificationStyle: SymbolDisplayTypeQualificationStyle.NameAndContainingTypesAndNamespaces,
        genericsOptions: SymbolDisplayGenericsOptions.None);

    readonly JsonNode unit;
    readonly string root;
    readonly JsonArray facts;
    CSharpCommandLineArguments parsed;
    readonly List<(CSharpCommandLineArguments Parsed, bool Framework)> variants;
    bool framework;
    readonly string dir;
    public readonly string? Output;
    CSharpCompilation? built;
    bool building;
    CSharpCompilation compilation = null!;
    readonly HashSet<IAssemblySymbol> repo = new(SymbolEqualityComparer.Default);
    readonly Dictionary<ISymbol, List<IOperation>> calls = new(SymbolEqualityComparer.Default);
    readonly Dictionary<(ISymbol, string), List<IOperation>> writes = new();
    readonly HashSet<ISymbol> grouped = new(SymbolEqualityComparer.Default);
    readonly HashSet<ISymbol> visiting = new(SymbolEqualityComparer.Default);

    public Unit(JsonNode unit, string root, JsonArray facts)
    {
        this.unit = unit;
        this.root = root;
        this.facts = facts;
        dir = (string)unit["dir"]!;
        var arguments = unit["args"]!.AsArray().Select(a => (string)a!).ToList();
        parsed = CSharpCommandLineParser.Default.Parse(arguments, dir, null);
        variants = [(parsed, false)];
        if (unit["framework"] is { } other)
            variants.Add((CSharpCommandLineParser.Default.Parse(other.AsArray().Select(a => (string)a!), dir, null), true));
        if (arguments.Any(a => a.StartsWith("/out:")) && parsed.OutputFileName is not null)
            Output = Path.GetFullPath(Path.Combine(parsed.OutputDirectory, parsed.OutputFileName));
    }

    CSharpCompilation Build(List<Unit> units)
    {
        if (built is not null)
            return built;
        if (building)
            throw new InvalidOperationException("Projects reference each other in a cycle: " + Output);
        building = true;
        var trees = parsed.SourceFiles.Select(source =>
        {
            using var stream = File.OpenRead(source.Path);
            return CSharpSyntaxTree.ParseText(SourceText.From(stream), parsed.ParseOptions, source.Path);
        }).ToList();
        var references = new List<MetadataReference>();
        if (framework)
        {
            var paths = typeof(Unit).Assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyMetadataAttribute), false).Cast<System.Reflection.AssemblyMetadataAttribute>().ToDictionary(a => a.Key, a => a.Value!);
            references.AddRange(Directory.GetFiles(paths["framework"], "*.dll").Concat(Directory.GetFiles(Path.Combine(paths["framework"], "Facades"), "*.dll"))
                .Append(Path.Combine(paths["powershell"], "System.Management.Automation.dll")).Select(path => MetadataReference.CreateFromFile(path)));
        }
        foreach (var reference in framework ? [] : parsed.MetadataReferences)
        {
            var path = Path.GetFullPath(reference.Reference, dir);
            var producer = units.FirstOrDefault(u => u.Output is not null && u != this && Path.GetFileName(u.Output) == Path.GetFileName(path) && path.StartsWith(u.dir + Path.DirectorySeparatorChar));
            references.Add(producer is not null ? producer.Build(units).ToMetadataReference(reference.Properties.Aliases) : MetadataReference.CreateFromFile(path, reference.Properties));
        }
        CSharpCompilation result = CSharpCompilation.Create(Output is null ? "reader" : Path.GetFileNameWithoutExtension(Output), trees, references, parsed.CompilationOptions);
        var loader = new Loader();
        var generators = parsed.AnalyzerReferences.SelectMany(r => new Microsoft.CodeAnalysis.Diagnostics.AnalyzerFileReference(Path.GetFullPath(r.FilePath, dir), loader).GetGenerators(LanguageNames.CSharp)).ToList();
        if (generators.Count > 0)
        {
            var configs = AnalyzerConfigSet.Create(parsed.AnalyzerConfigPaths.Select(p => AnalyzerConfig.Parse(SourceText.From(File.ReadAllText(p)), p)).ToList());
            CSharpGeneratorDriver.Create(generators, parseOptions: parsed.ParseOptions, optionsProvider: new Options(configs))
                .RunGeneratorsAndUpdateCompilation(result, out var generated, out _);
            result = (CSharpCompilation)generated;
        }
        building = false;
        return built = result;
    }

    public void Read(List<Unit> units)
    {
        var report = unit["report"]!.AsObject().ToDictionary(p => Path.GetFullPath(p.Key), p => ((string)p.Value!["file"]!, (int)p.Value!["offset"]!));
        if (report.Count == 0)
            return;
        compilation = Build(units);
        if (variants.Count > 1 && Errors(compilation, report) > 0)
        {
            var first = compilation;
            (parsed, framework, built) = (variants[1].Parsed, true, null);
            compilation = Build(units);
            if (Errors(compilation, report) >= Errors(first, report))
                (parsed, framework, built, compilation) = (variants[0].Parsed, false, first, first);
        }
        foreach (var reference in compilation.References)
            if (compilation.GetAssemblyOrModuleSymbol(reference) is IAssemblySymbol assembly
                && (reference is CompilationReference || reference is PortableExecutableReference { FilePath: { } path } && path.StartsWith(root + Path.DirectorySeparatorChar)))
                repo.Add(assembly);
        var trees = compilation.SyntaxTrees.Where(t => parsed.SourceFiles.Any(s => s.Path == t.FilePath)).ToList();
        foreach (var tree in trees)
            Index(tree);
        foreach (var tree in trees)
            if (report.TryGetValue(Path.GetFullPath(tree.FilePath), out var place))
                Scan(tree, place.Item1, place.Item2);
    }

    static int Errors(CSharpCompilation compilation, Dictionary<string, (string, int)> report) =>
        compilation.SyntaxTrees.Where(t => report.ContainsKey(Path.GetFullPath(t.FilePath)))
            .Sum(t => compilation.GetSemanticModel(t).GetDiagnostics().Count(d => d.Severity == DiagnosticSeverity.Error && !d.IsWarningAsError));

    IEnumerable<IOperation> Operations(SyntaxTree tree)
    {
        var model = compilation.GetSemanticModel(tree);
        foreach (var node in tree.GetRoot().DescendantNodesAndSelf())
            if (model.GetOperation(node) is { } operation)
                yield return operation;
    }

    void Index(SyntaxTree tree)
    {
        foreach (var operation in Operations(tree))
        {
            switch (operation)
            {
                case IInvocationOperation invocation:
                    Add(calls, invocation.TargetMethod.OriginalDefinition, operation);
                    if (invocation.TargetMethod.Name == "Add" && invocation.Instance is { } list && Key(list) is { } added)
                        Add(writes, added, invocation.Arguments.FirstOrDefault()?.Value ?? operation);
                    foreach (var argument in invocation.Arguments.Where(a => a.Parameter?.RefKind is RefKind.Out or RefKind.Ref && Key(a.Value) is not null))
                        Add(writes, Key(argument.Value)!.Value, argument);
                    break;
                case IObjectCreationOperation { Constructor: { } constructor }:
                    Add(calls, constructor.OriginalDefinition, operation);
                    break;
                case IMethodReferenceOperation reference:
                    grouped.Add(reference.Method.OriginalDefinition);
                    break;
                case ISimpleAssignmentOperation assignment when Key(assignment.Target) is { } key:
                    Add(writes, key, assignment.Value);
                    break;
                case ICompoundAssignmentOperation or IDeconstructionAssignmentOperation or IIncrementOrDecrementOperation:
                    foreach (var target in operation.ChildOperations.Take(1).SelectMany(t => t.DescendantsAndSelf()))
                        if (Key(target) is { } changed)
                            Add(writes, changed, operation);
                    break;
                case IVariableDeclaratorOperation { Initializer: { } initializer } declarator:
                    Add(writes, (declarator.Symbol, ""), initializer.Value);
                    break;
                case IForEachLoopOperation loop:
                    foreach (var local in loop.Locals)
                        foreach (var element in Elements(loop.Collection))
                            Add(writes, (local, ""), element);
                    break;
            }
        }
    }

    static void Add<TKey>(Dictionary<TKey, List<IOperation>> map, TKey key, IOperation value) where TKey : notnull
    {
        if (!map.TryGetValue(key, out var list))
            map[key] = list = [];
        list.Add(value);
    }

    static (ISymbol, string)? Key(IOperation? operation)
    {
        var path = "";
        while (true)
        {
            switch (operation)
            {
                case IConversionOperation conversion:
                    operation = conversion.Operand;
                    continue;
                case ILocalReferenceOperation local:
                    return (local.Local, path);
                case IParameterReferenceOperation parameter:
                    return (parameter.Parameter, path);
                case IFieldReferenceOperation field when field.Instance is null or IInstanceReferenceOperation:
                    return (field.Field.OriginalDefinition, path);
                case IPropertyReferenceOperation property when property.Instance is null or IInstanceReferenceOperation && property.Property.DeclaringSyntaxReferences.Length > 0:
                    return (property.Property.OriginalDefinition, path);
                case IPropertyReferenceOperation member when member.Instance is not null:
                    path = member.Property.Name + (path.Length > 0 ? "." + path : "");
                    operation = member.Instance;
                    continue;
                default:
                    return null;
            }
        }
    }

    void Scan(SyntaxTree tree, string file, int offset)
    {
        var model = compilation.GetSemanticModel(tree);
        foreach (var declaration in tree.GetRoot().DescendantNodes().OfType<Microsoft.CodeAnalysis.CSharp.Syntax.BaseTypeDeclarationSyntax>())
            if (model.GetDeclaredSymbol(declaration) is INamedTypeSymbol declared)
            {
                var nested = declared.Name;
                for (var outer = declared.ContainingType; outer is not null; outer = outer.ContainingType)
                    nested = outer.Name + "+" + nested;
                var space = declared.ContainingNamespace.IsGlobalNamespace ? "" : declared.ContainingNamespace.ToDisplayString() + ".";
                Emit(file, 1, "type", space + nested);
                Emit(file, 1, "type", declared.ToDisplayString(TypeFormat));
            }
        int Line(SyntaxNode node) => tree.GetLineSpan(node.Span).StartLinePosition.Line + 1 + offset;
        foreach (var error in model.GetDiagnostics().Where(d => d.Severity == DiagnosticSeverity.Error && !d.IsWarningAsError && d.Location.IsInSource))
            Emit(file, error.Location.GetLineSpan().StartLinePosition.Line + 1 + offset, "unreadable", "the compiler cannot read this: " + error.GetMessage());
        foreach (var operation in Operations(tree))
        {
            var line = Line(operation.Syntax);
            switch (operation)
            {
                case IInvocationOperation invocation when IsStart(invocation.TargetMethod):
                    Launch(file, line, invocation);
                    break;
                case IInvocationOperation invocation:
                    if (invocation.TargetMethod.ContainingType.ToDisplayString(TypeFormat) == "System.IO.File" && invocation.TargetMethod.Name is "Copy" or "Move")
                        foreach (var source in Resolve(invocation.Arguments[0].Value))
                            foreach (var target in Resolve(invocation.Arguments[1].Value))
                                if (Program(target) is { } made)
                                    Emit(file, line, "copy", made, null, new JsonObject { ["from"] = Program(source) });
                    if (invocation.TargetMethod.Name is "Invoke" or "GetValue" or "SetValue" && invocation.TargetMethod.ContainingNamespace.ToDisplayString() == "System.Reflection"
                        && invocation.Instance is { } member && Reflected(member, 0))
                        break;
                    Use(file, line, invocation.TargetMethod, Arguments(invocation.Arguments));
                    break;
                case IObjectCreationOperation { Constructor: { } constructor } creation:
                    Use(file, line, constructor, Arguments(creation.Arguments));
                    break;
                case IMethodReferenceOperation reference:
                    Use(file, line, reference.Method, null);
                    break;
                case IPropertyReferenceOperation property:
                    var write = operation.Parent is IAssignmentOperation assignment && assignment.Target == operation ? assignment : null;
                    var accessor = write is null ? property.Property.GetMethod : property.Property.SetMethod;
                    if (accessor is not null)
                        Use(file, line, accessor, write is ISimpleAssignmentOperation simple ? [Argument(0, "value", simple.Value)] : write is null ? [] : null);
                    break;
                case IEventReferenceOperation subscription when subscription.Event.AddMethod is { } add:
                    Use(file, line, add, null);
                    break;
                case IDynamicInvocationOperation or IDynamicMemberReferenceOperation or IDynamicObjectCreationOperation or IDynamicIndexerAccessOperation:
                    Emit(file, line, "unreadable", "a dynamic call names no member the check can classify");
                    break;
                case IFunctionPointerInvocationOperation:
                    Emit(file, line, "unreadable", "a function pointer call names no member the check can classify");
                    break;
            }
        }
    }

    bool Repo(ITypeSymbol? type) =>
        type is not null && (SymbolEqualityComparer.Default.Equals(type.ContainingAssembly, compilation.Assembly) || repo.Contains(type.ContainingAssembly));

    bool Reflected(IOperation operation, int depth)
    {
        while (operation is IConversionOperation conversion)
            operation = conversion.Operand;
        if (depth > 8)
            return false;
        switch (operation)
        {
            case IInvocationOperation { TargetMethod.Name: "GetType", Instance: { } instance } when instance.Type is not null:
                return Repo(instance.Type);
            case IInvocationOperation call when call.TargetMethod.ContainingType.ToDisplayString(TypeFormat) == "System.Type" && call.Instance is { } owner:
                return owner is ITypeOfOperation type ? Repo(type.TypeOperand) : Reflected(owner, depth + 1);
            case IInvocationOperation call when call.TargetMethod.ContainingType.ToDisplayString(TypeFormat) == "System.Linq.Enumerable" && call.Arguments.Length > 0:
                return Reflected(call.Arguments[0].Value, depth + 1);
            case ILocalReferenceOperation or IParameterReferenceOperation or IFieldReferenceOperation when Key(operation) is { } key && key.Item2.Length == 0:
                var origins = Origins(key.Item1) ?? (key.Item1 is IFieldSymbol && Initializer(key.Item1) is { } initial ? [initial] : null);
                return origins is { Count: > 0 } && origins.All(origin => origin is not IArgumentOperation && Reflected(origin, depth + 1));
            case IPropertyReferenceOperation property when property.Instance is { } holder:
                return Reflected(holder, depth + 1);
        }
        return false;
    }

    static bool IsStart(IMethodSymbol method) =>
        method.Name == "Start" && method.ContainingType.ToDisplayString(TypeFormat) == "System.Diagnostics.Process";

    void Use(string file, int line, IMethodSymbol method, JsonArray? arguments)
    {
        method = method.ReducedFrom ?? method;
        var type = method.ContainingType;
        if (method.GetDllImportData() is { } import)
        {
            Emit(file, line, "native", Native(import.ModuleName, import.EntryPointName ?? method.Name), arguments);
            return;
        }
        if (method.GetAttributes().FirstOrDefault(a => a.AttributeClass?.Name == "LibraryImportAttribute") is { } library)
        {
            var entry = library.NamedArguments.FirstOrDefault(a => a.Key == "EntryPoint").Value.Value as string;
            Emit(file, line, "native", Native(library.ConstructorArguments[0].Value as string, entry ?? method.Name), arguments);
            return;
        }
        if (type is not null && type.GetAttributes().Any(a => a.AttributeClass?.Name == "ComImportAttribute"))
        {
            Emit(file, line, "call", "com:" + type.ToDisplayString(TypeFormat) + "." + method.Name, arguments);
            return;
        }
        if (method.IsExtern)
        {
            Emit(file, line, "unreadable", "an extern method without an import names no library the check can classify");
            return;
        }
        if (type is null || SymbolEqualityComparer.Default.Equals(method.ContainingAssembly, compilation.Assembly) || repo.Contains(method.ContainingAssembly))
            return;
        Emit(file, line, "call", type.OriginalDefinition.ToDisplayString(TypeFormat) + "." + method.Name, arguments);
    }

    static string Native(string? module, string entry)
    {
        var name = Path.GetFileName(module ?? "").ToLowerInvariant();
        if (name.EndsWith(".dll"))
            name = name[..^4];
        return name + "!" + entry;
    }

    JsonArray Arguments(IEnumerable<IArgumentOperation> arguments) =>
        new(arguments.Where(a => a.Parameter is not null).OrderBy(a => a.Parameter!.Ordinal).Select(a => (JsonNode?)Argument(a.Parameter!.Ordinal, a.Parameter.Name, a.Value)).ToArray());

    static JsonObject Argument(int ordinal, string name, IOperation value)
    {
        var argument = new JsonObject { ["i"] = ordinal, ["name"] = name, ["type"] = value.Type?.ToDisplayString(TypeFormat) };
        if (value is IConversionOperation { IsImplicit: true } conversion && conversion.Operand.ConstantValue.HasValue)
            value = conversion.Operand;
        if (value.ConstantValue is { HasValue: true, Value: var constant })
        {
            var named = value.Type is INamedTypeSymbol { TypeKind: TypeKind.Enum } enumeration
                ? enumeration.GetMembers().OfType<IFieldSymbol>().FirstOrDefault(f => f.HasConstantValue && Equals(f.ConstantValue, constant))?.Name
                : null;
            argument["value"] = named is not null ? JsonValue.Create(named) : constant switch
            {
                null => null,
                string text => JsonValue.Create(text),
                bool flag => JsonValue.Create(flag),
                char letter => JsonValue.Create(letter.ToString()),
                double or float => JsonValue.Create(Convert.ToDouble(constant).ToString("R")),
                _ => JsonValue.Create(Convert.ToDecimal(constant)),
            };
        }
        return argument;
    }

    void Emit(string file, int line, string kind, string name, JsonArray? arguments = null, JsonObject? extra = null)
    {
        var fact = new JsonObject { ["file"] = file, ["line"] = line, ["kind"] = kind, ["name"] = name, ["args"] = arguments };
        foreach (var pair in extra ?? [])
            fact[pair.Key] = pair.Value?.DeepClone();
        facts.Add(fact);
    }

    sealed record Start(List<List<string>> Programs, List<List<string>?> Raws, List<List<string>> List);

    static Start Unknown => new([[Hole]], [null], []);

    void Launch(string file, int line, IInvocationOperation invocation)
    {
        var method = invocation.SemanticModel?.GetEnclosingSymbol(invocation.Syntax.SpanStart) as IMethodSymbol;
        var sites = method is not null && method.MethodKind != MethodKind.AnonymousFunction && !grouped.Contains(method.OriginalDefinition)
            && !method.IsVirtual && !method.IsOverride && !method.IsAbstract && calls.TryGetValue(method.OriginalDefinition, out var found) ? found : [];
        var emitted = 0;
        foreach (var site in sites.Count > 0 ? sites.Cast<IOperation?>() : [null])
        {
            binding = site is null ? null : (site is IInvocationOperation i ? i.Arguments : ((IObjectCreationOperation)site).Arguments)
                .Where(a => a.Parameter is not null && a.ArgumentKind != ArgumentKind.ParamArray)
                .ToDictionary(a => (IParameterSymbol)a.Parameter!.OriginalDefinition, a => a.Value, (IEqualityComparer<IParameterSymbol>)SymbolEqualityComparer.Default);
            var starts = invocation.Instance is { } process ? Info(process, "StartInfo")
                : invocation.Arguments.FirstOrDefault() is { Value.Type.Name: "ProcessStartInfo" } info ? Info(info.Value, "")
                : [Make(Argument(invocation.Arguments, "fileName"), Argument(invocation.Arguments, "arguments"), [])];
            binding = null;
            foreach (var start in starts)
                foreach (var program in start.Programs.DefaultIfEmpty([Hole]))
                    foreach (var raw in start.Raws.DefaultIfEmpty(null))
                        if (emitted++ < 32)
                            Command(file, line, program, raw, start.List);
        }
    }

    Dictionary<IParameterSymbol, IOperation>? binding;

    static IOperation? Argument(IEnumerable<IArgumentOperation> arguments, string name) =>
        arguments.FirstOrDefault(a => a.Parameter?.Name == name && a.ArgumentKind != ArgumentKind.DefaultValue)?.Value;

    Start Make(IOperation? program, IOperation? arguments, IEnumerable<IOperation> list)
    {
        var items = list.ToList();
        if (arguments is not null && arguments.Type?.SpecialType != SpecialType.System_String)
        {
            items.AddRange(Elements(arguments));
            arguments = null;
        }
        return new(program is null ? [] : Resolve(program), arguments is null ? [] : Resolve(arguments).Select(r => (List<string>?)r).ToList(), items.Select(Item).ToList());
    }

    List<string> Item(IOperation item) => Resolve(item) is { Count: 1 } single ? single[0] : [Hole];

    List<Start> Info(IOperation operation, string member)
    {
        while (operation is IConversionOperation conversion)
            operation = conversion.Operand;
        if (operation is IInvocationOperation call && Returns(call.TargetMethod) is { } returned)
            return returned.SelectMany(r => Info(r, member)).ToList();
        if (operation is IObjectCreationOperation creation)
        {
            if (member.Length == 0)
                return [FromInitializer(creation.Initializer, creation.Arguments)];
            var found = new List<Start>();
            foreach (var initializer in creation.Initializer?.Initializers ?? [])
                if (initializer is ISimpleAssignmentOperation { Target: IPropertyReferenceOperation { Property.Name: "StartInfo" } } assignment)
                    found.AddRange(Info(assignment.Value, ""));
                else if (initializer is IMemberInitializerOperation { InitializedMember: IPropertyReferenceOperation { Property.Name: "StartInfo" } } nested)
                    found.Add(FromInitializer(nested.Initializer, []));
            return found;
        }
        if (operation is IParameterReferenceOperation parameter && binding is not null && binding.TryGetValue((IParameterSymbol)parameter.Parameter.OriginalDefinition, out var bound))
        {
            var saved = binding;
            binding = null;
            try { return Info(bound, member); } finally { binding = saved; }
        }
        if (Key(operation) is not { } key || key.Item2.Length > 0 || !visiting.Add(key.Item1))
            return [Unknown];
        try
        {
            var symbol = key.Item1;
            var bases = new List<Start>();
            foreach (var origin in Origins(symbol) ?? [])
                bases.AddRange((origin is IArgumentOperation or ICompoundAssignmentOperation) ? [Unknown] : Info(origin, member));
            if (member.Length > 0)
                foreach (var whole in Writes(symbol, member))
                    bases.AddRange(Info(whole, ""));
            var programs = Writes(symbol, Join(member, "FileName")).SelectMany(p => Resolve(p)).ToList();
            var raws = Writes(symbol, Join(member, "Arguments")).SelectMany(p => Resolve(p)).Select(r => (List<string>?)r).ToList();
            var items = Writes(symbol, Join(member, "ArgumentList")).Select(Item).ToList();
            var merged = bases.Select(b => new Start([.. b.Programs, .. programs], [.. b.Raws, .. raws], [.. b.List, .. items])).ToList();
            return merged.Count > 0 ? merged : [new Start(programs, raws, items)];
        }
        finally { visiting.Remove(key.Item1); }
    }

    Start FromInitializer(IObjectOrCollectionInitializerOperation? initializer, IEnumerable<IArgumentOperation> arguments)
    {
        var assigned = initializer?.Initializers.OfType<ISimpleAssignmentOperation>().ToList() ?? [];
        IOperation? Set(string name) => assigned.LastOrDefault(a => a.Target is IPropertyReferenceOperation p && p.Property.Name == name)?.Value;
        var list = initializer?.Initializers.OfType<IMemberInitializerOperation>()
            .Where(m => m.InitializedMember is IPropertyReferenceOperation { Property.Name: "ArgumentList" })
            .SelectMany(m => m.Initializer.Initializers.OfType<IInvocationOperation>().Select(add => add.Arguments[0].Value)).ToList() ?? [];
        var start = Make(Set("FileName") ?? Argument(arguments, "fileName"), Argument(arguments, "arguments"), list);
        return Set("Arguments") is { } text ? start with { Raws = Resolve(text).Select(r => (List<string>?)r).ToList() } : start;
    }

    List<IOperation>? Returns(IMethodSymbol method)
    {
        var syntax = method.OriginalDefinition.DeclaringSyntaxReferences.FirstOrDefault(r => compilation.ContainsSyntaxTree(r.SyntaxTree))?.GetSyntax();
        if (syntax is null || !visiting.Add(method.OriginalDefinition))
            return null;
        try
        {
            var body = compilation.GetSemanticModel(syntax.SyntaxTree).GetOperation(syntax);
            return body?.Descendants().OfType<IReturnOperation>().Where(r => r.ReturnedValue is not null).Select(r => r.ReturnedValue!).ToList();
        }
        finally { visiting.Remove(method.OriginalDefinition); }
    }

    IEnumerable<IOperation> Values(IOperation instance, string member) =>
        Key(instance) is { } key ? Writes(key.Item1, Join(key.Item2, member)) : [];

    static string Join(string path, string member) => path.Length > 0 ? path + "." + member : member;

    List<IOperation> Writes(ISymbol symbol, string path) =>
        writes.TryGetValue((symbol.OriginalDefinition, path), out var found) ? found : writes.TryGetValue((symbol, path), out found) ? found : [];

    List<IOperation>? Origins(ISymbol symbol)
    {
        if (symbol is IParameterSymbol parameter)
            return Callers(parameter);
        var found = Writes(symbol, "");
        return found.Count > 0 ? found : null;
    }

    List<IOperation>? Callers(IParameterSymbol parameter)
    {
        if (parameter.ContainingSymbol is not IMethodSymbol method || method.MethodKind is MethodKind.AnonymousFunction || grouped.Contains(method.OriginalDefinition)
            || method.IsVirtual || method.IsOverride || method.IsAbstract || method.ExplicitInterfaceImplementations.Length > 0
            || !calls.TryGetValue(method.OriginalDefinition, out var sites))
            return null;
        var values = new List<IOperation>();
        foreach (var site in sites)
        {
            var arguments = site is IInvocationOperation i ? i.Arguments : ((IObjectCreationOperation)site).Arguments;
            var argument = arguments.FirstOrDefault(a => a.Parameter?.Ordinal == parameter.Ordinal);
            if (argument is null || argument.ArgumentKind == ArgumentKind.ParamArray)
                return null;
            values.Add(argument.Value);
        }
        return values;
    }

    IEnumerable<IOperation> Elements(IOperation operation)
    {
        while (operation is IConversionOperation conversion)
            operation = conversion.Operand;
        return operation switch
        {
            IArrayCreationOperation { Initializer: { } initializer } => initializer.ElementValues,
            ICollectionExpressionOperation collection => collection.Elements,
            _ => [operation],
        };
    }

    List<List<string>> Resolve(IOperation? operation, int depth = 0)
    {
        if (operation is null || depth > 12)
            return [[Hole]];
        if (operation.ConstantValue is { HasValue: true } constant)
            return [[constant.Value as string ?? Hole]];
        switch (operation)
        {
            case IConversionOperation conversion:
                return Resolve(conversion.Operand, depth + 1);
            case IInterpolatedStringOperation interpolated:
                return interpolated.Parts.Aggregate(new List<List<string>> { new() }, (sum, part) => Concat(sum, part switch
                {
                    IInterpolatedStringTextOperation text => Resolve(text.Text, depth + 1),
                    IInterpolationOperation { Alignment: null, FormatString: null } hole => Resolve(hole.Expression, depth + 1),
                    _ => [[Hole]],
                }));
            case IBinaryOperation { OperatorKind: BinaryOperatorKind.Add } add when add.Type?.SpecialType == SpecialType.System_String:
                return Concat(Resolve(add.LeftOperand, depth + 1), Resolve(add.RightOperand, depth + 1));
            case IConditionalOperation { WhenFalse: { } otherwise } conditional:
                return Union(Resolve(conditional.WhenTrue, depth + 1), Resolve(otherwise, depth + 1));
            case ICoalesceOperation coalesce:
                return coalesce.WhenNull is IThrowOperation or IConversionOperation { Operand: IThrowOperation }
                    ? Resolve(coalesce.Value, depth + 1)
                    : Union(Resolve(coalesce.Value, depth + 1), Resolve(coalesce.WhenNull, depth + 1));
            case IInvocationOperation call when call.TargetMethod.ContainingType.ToDisplayString(TypeFormat) == "System.IO.Path"
                    && call.TargetMethod.Name is "Combine" or "Join":
                var parts = call.Arguments.SelectMany(a => a.ArgumentKind == ArgumentKind.ParamArray ? Elements(a.Value) : [a.Value]).ToList();
                var joined = new List<List<string>> { new() };
                foreach (var (part, index) in parts.Select((p, i) => (p, i)))
                    joined = Concat(joined, index == 0 ? PathOf(Resolve(part, depth + 1)) : Concat([[@"\"]], PathOf(Resolve(part, depth + 1))));
                return joined;
            case IInvocationOperation call when call.TargetMethod.ContainingType.ToDisplayString(TypeFormat) == "System.IO.Path"
                    && call.TargetMethod.Name is "GetTempPath" or "GetDirectoryName" or "GetFullPath":
                return call.TargetMethod.Name == "GetFullPath" ? PathOf(Resolve(call.Arguments[0].Value, depth + 1)) : [[PathPiece]];
            case IInvocationOperation call when call.TargetMethod.ToDisplayString() == "System.Environment.GetFolderPath(System.Environment.SpecialFolder)":
                return [[PathPiece]];
            case IPropertyReferenceOperation property when property.Property.ContainingType.ToDisplayString(TypeFormat) + "." + property.Property.Name
                    is "System.Environment.SystemDirectory" or "System.AppContext.BaseDirectory":
                return [[PathPiece]];
            case IPropertyReferenceOperation { Property.Name: "ProcessPath" } property when property.Property.ContainingType.ToDisplayString(TypeFormat) == "System.Environment":
                return [[Self]];
            case IPropertyReferenceOperation { Property.Name: "Location", Instance: IInvocationOperation { TargetMethod.Name: "GetEntryAssembly" or "GetExecutingAssembly" } }:
                return [[Self]];
            case IParameterReferenceOperation parameter when binding is not null && binding.TryGetValue((IParameterSymbol)parameter.Parameter.OriginalDefinition, out var bound):
                var saved = binding;
                binding = null;
                try { return Resolve(bound, depth + 1); } finally { binding = saved; }
            case ILocalReferenceOperation or IParameterReferenceOperation or IFieldReferenceOperation or IPropertyReferenceOperation when Key(operation) is { } key && key.Item2.Length == 0:
                var symbol = key.Item1;
                if (!visiting.Add(symbol))
                    return [[Hole]];
                try
                {
                    var origins = Origins(symbol) ?? (symbol is IPropertySymbol property ? Returns(property.GetMethod!) : null);
                    if (symbol is IFieldSymbol or IPropertySymbol && origins is not null && Initializer(symbol) is { } initial)
                        origins.Add(initial);
                    else if (symbol is IFieldSymbol or IPropertySymbol && Initializer(symbol) is { } only)
                        origins = [only];
                    if (origins is null || origins.Count == 0)
                        return [[Hole]];
                    return origins.Select(o => (o is IArgumentOperation or ICompoundAssignmentOperation or IDeconstructionAssignmentOperation or IIncrementOrDecrementOperation) ? [[Hole]] : Resolve(o, depth + 1))
                        .Aggregate(new List<List<string>>(), Union);
                }
                finally { visiting.Remove(symbol); }
        }
        return [[Hole]];
    }

    IOperation? Initializer(ISymbol symbol)
    {
        foreach (var reference in symbol.DeclaringSyntaxReferences.Where(r => compilation.ContainsSyntaxTree(r.SyntaxTree)))
        {
            var model = compilation.GetSemanticModel(reference.SyntaxTree);
            var node = reference.GetSyntax();
            var clause = node.ChildNodes().OfType<Microsoft.CodeAnalysis.CSharp.Syntax.EqualsValueClauseSyntax>().FirstOrDefault();
            if (clause is not null && model.GetOperation(clause) is ISymbolInitializerOperation initializer)
                return initializer.Value;
            var arrow = node.ChildNodes().OfType<Microsoft.CodeAnalysis.CSharp.Syntax.ArrowExpressionClauseSyntax>().FirstOrDefault();
            if (arrow is not null && model.GetOperation(arrow.Expression) is { } body)
                return body;
        }
        return null;
    }

    static List<List<string>> PathOf(List<List<string>> values) =>
        values.Select(v => v.Select(piece => piece == Hole ? PathPiece : piece).ToList()).ToList();

    static List<List<string>> Union(List<List<string>> left, List<List<string>> right) =>
        left.Count + right.Count > 16 ? [[Hole]] : [.. left, .. right];

    static List<List<string>> Concat(List<List<string>> left, List<List<string>> right)
    {
        if (left.Count * right.Count > 16)
            return [[Hole]];
        return left.SelectMany(l => right.Select(r => Merge(l, r))).ToList();
    }

    static List<string> Merge(List<string> left, List<string> right)
    {
        var merged = new List<string>(left);
        foreach (var piece in right)
        {
            if (merged.Count > 0 && piece.Length > 0 && !IsMarker(piece) && merged[^1].Length > 0 && !IsMarker(merged[^1]))
                merged[^1] += piece;
            else if (piece.Length > 0)
                merged.Add(piece);
        }
        return merged;
    }

    static bool IsMarker(string piece) => piece is Hole or PathPiece or Self;

    void Command(string file, int line, List<string> program, List<string>? raw, List<List<string>> list)
    {
        var name = Program(program);
        var tokens = new JsonArray();
        foreach (var token in (raw is null ? [] : Split(raw)).Concat(list))
            tokens.Add(Token(token));
        var text = raw is not null && raw.All(p => !IsMarker(p)) && list.Count == 0 ? string.Concat(raw) : null;
        if (name is null)
            Emit(file, line, "unreadable", "the program this starts is built from values the check cannot read");
        else
            Emit(file, line, "command", name, tokens, new JsonObject { ["raw"] = text, ["via"] = "System.Diagnostics.Process.Start" });
    }

    static string? Program(List<string> pieces)
    {
        if (pieces.Count == 1 && pieces[0] == Self)
            return "<self>";
        if (pieces.Count == 0 || IsMarker(pieces[^1]))
            return null;
        var last = pieces[^1];
        var cut = last.LastIndexOfAny(['\\', '/']);
        if (cut < 0 && pieces.Count > 1)
            return null;
        var name = last[(cut + 1)..];
        return name.Length > 0 ? name : null;
    }

    static List<List<string>> Split(List<string> pieces)
    {
        var tokens = new List<List<string>>();
        List<string>? current = null;
        var quoted = false;
        foreach (var piece in pieces)
        {
            if (IsMarker(piece))
            {
                (current ??= []).Add(piece);
                continue;
            }
            foreach (var letter in piece)
            {
                if (letter == '"')
                {
                    quoted = !quoted;
                    current ??= [];
                }
                else if (char.IsWhiteSpace(letter) && !quoted)
                {
                    if (current is not null)
                        tokens.Add(current);
                    current = null;
                }
                else
                {
                    current ??= [];
                    if (current.Count > 0 && !IsMarker(current[^1]))
                        current[^1] += letter;
                    else
                        current.Add(letter.ToString());
                }
            }
        }
        if (current is not null)
            tokens.Add(current);
        return tokens;
    }

    static JsonNode? Token(List<string> pieces)
    {
        if (pieces.All(p => !IsMarker(p)))
            return JsonValue.Create(string.Concat(pieces));
        if (pieces.Count > 0 && pieces[0] == PathPiece)
            return new JsonObject { ["path"] = true, ["name"] = Program(pieces) };
        if (pieces.Count > 0 && !IsMarker(pieces[0]))
            return new JsonObject { ["prefix"] = pieces[0], ["name"] = Program(pieces) };
        return null;
    }
}

sealed class Loader : IAnalyzerAssemblyLoader
{
    public void AddDependencyLocation(string fullPath) { }

    public System.Reflection.Assembly LoadFromPath(string fullPath) =>
        System.Runtime.Loader.AssemblyLoadContext.Default.LoadFromAssemblyPath(fullPath);
}

sealed class Options(AnalyzerConfigSet configs) : Microsoft.CodeAnalysis.Diagnostics.AnalyzerConfigOptionsProvider
{
    public override Microsoft.CodeAnalysis.Diagnostics.AnalyzerConfigOptions GlobalOptions { get; } = new Values(configs.GlobalConfigOptions.AnalyzerOptions);

    public override Microsoft.CodeAnalysis.Diagnostics.AnalyzerConfigOptions GetOptions(SyntaxTree tree) =>
        new Values(configs.GetOptionsForSourcePath(tree.FilePath).AnalyzerOptions.AddRange(configs.GlobalConfigOptions.AnalyzerOptions.Where(p => !configs.GetOptionsForSourcePath(tree.FilePath).AnalyzerOptions.ContainsKey(p.Key))));

    public override Microsoft.CodeAnalysis.Diagnostics.AnalyzerConfigOptions GetOptions(AdditionalText text) => GlobalOptions;

    sealed class Values(System.Collections.Immutable.ImmutableDictionary<string, string> values) : Microsoft.CodeAnalysis.Diagnostics.AnalyzerConfigOptions
    {
        public override bool TryGetValue(string key, [System.Diagnostics.CodeAnalysis.NotNullWhen(true)] out string? value) => values.TryGetValue(key, out value);
    }
}
