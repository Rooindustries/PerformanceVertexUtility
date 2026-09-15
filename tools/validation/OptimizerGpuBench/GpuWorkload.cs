using System.Diagnostics;
using System.Runtime.InteropServices;
using Vortice.D3DCompiler;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

sealed record AdapterIdentity(string Name, uint VendorId, uint DeviceId, long Luid);

sealed class GpuWorkload : IDisposable
{
    readonly ID3D11Device _device;
    readonly ID3D11DeviceContext _context;
    readonly ID3D11ComputeShader _shader;
    readonly ID3D11Buffer _buffer, _staging;
    readonly ID3D11UnorderedAccessView _view;
    readonly ID3D11Query _disjoint, _begin, _end;
    public AdapterIdentity Adapter { get; }
    public int Elements { get; }
    public int Iterations { get; }
    public long Dispatches { get; private set; }
    public long Polls { get; private set; }

    public GpuWorkload(uint vendorId, uint deviceId, int elements, int iterations)
    {
        Elements = elements; Iterations = iterations;
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        IDXGIAdapter1? adapter = null;
        for (uint index = 0; factory.EnumAdapters1(index, out var candidate).Success; index++)
        {
            if (candidate.Description1.VendorId == vendorId && candidate.Description1.DeviceId == deviceId) { adapter = candidate; break; }
            candidate.Dispose();
        }
        using var selected = adapter ?? throw new InvalidOperationException("The requested hardware GPU was not found.");
        var description = selected.Description1;
        if ((description.Flags & AdapterFlags.Software) != 0) throw new InvalidOperationException("Software adapters cannot establish GPU performance.");
        Adapter = new(description.Description, description.VendorId, description.DeviceId, description.Luid);
        D3D11.D3D11CreateDevice(selected, DriverType.Unknown, DeviceCreationFlags.None, [FeatureLevel.Level_11_0], out _device, out _context).CheckError();
        var source = "RWStructuredBuffer<uint> values : register(u0); [numthreads(64,1,1)] void main(uint3 id : SV_DispatchThreadID) { uint x=values[id.x]; [loop] for(uint i=0;i<"
            + iterations + ";i++) { x=(x<<13)|(x>>19); x=x*1664525u+1013904223u; } values[id.x]=x; }";
        var bytecode = Compiler.Compile(source, "main", "measurement.hlsl", "cs_5_0", ShaderFlags.OptimizationLevel3);
        _shader = _device.CreateComputeShader(bytecode.Span);
        _buffer = _device.CreateBuffer(Enumerable.Range(1, elements).Select(value => (uint)value).ToArray(), BindFlags.UnorderedAccess,
            ResourceUsage.Default, CpuAccessFlags.None, ResourceOptionFlags.BufferStructured);
        _view = _device.CreateUnorderedAccessView(_buffer);
        _staging = _device.CreateBuffer((uint)(elements * 4), BindFlags.None, ResourceUsage.Staging, CpuAccessFlags.Read);
        _disjoint = _device.CreateQuery(new QueryDescription(QueryType.TimestampDisjoint));
        _begin = _device.CreateQuery(new QueryDescription(QueryType.Timestamp));
        _end = _device.CreateQuery(new QueryDescription(QueryType.Timestamp));
        _context.CSSetShader(_shader); _context.CSSetUnorderedAccessView(0, _view);
    }

    public double Run(int dispatches)
    {
        _context.Begin(_disjoint); _context.End(_begin);
        for (var index = 0; index < dispatches; index++) _context.Dispatch((uint)Elements / 64, 1, 1);
        _context.End(_end); _context.End(_disjoint); _context.Flush();
        var begin = ReadQuery<ulong>(_begin);
        var end = ReadQuery<ulong>(_end);
        var timing = ReadQuery<QueryDataTimestampDisjoint>(_disjoint);
        if (timing.Disjoint || timing.Frequency == 0 || end < begin) throw new InvalidDataException("GPU timestamps are disjoint or unordered.");
        Dispatches += dispatches;
        return (end - begin) * 1000d / timing.Frequency;
    }

    T ReadQuery<T>(ID3D11Query query) where T : unmanaged
    {
        var clock = Stopwatch.StartNew();
        while (true)
        {
            Polls++;
            if (_context.GetData(query, AsyncGetDataFlags.DoNotFlush, out T value)) return value;
            if (clock.Elapsed > TimeSpan.FromSeconds(10)) throw new TimeoutException("GPU query did not complete: " + query.Description.QueryType + "; device status " + _device.DeviceRemovedReason);
            Thread.Yield();
        }
    }

    public uint[] VerifyOutput()
    {
        _context.CopyResource(_staging, _buffer);
        var mapped = _context.Map(_staging, MapMode.Read);
        try
        {
            int[] indexes = [0, Elements / 3, Elements / 2, Elements - 1];
            var observed = new List<uint>();
            foreach (var index in indexes)
            {
                uint expected = (uint)(index + 1);
                for (long iteration = 0; iteration < Iterations * Dispatches; iteration++)
                {
                    expected = (expected << 13) | (expected >> 19);
                    expected = unchecked(expected * 1664525u + 1013904223u);
                }
                var actual = unchecked((uint)Marshal.ReadInt32(mapped.DataPointer, index * 4));
                if (actual != expected) throw new InvalidDataException("GPU output differs from the independent CPU calculation.");
                observed.Add(actual);
            }
            return observed.ToArray();
        }
        finally { _context.Unmap(_staging, 0); }
    }

    public void Dispose()
    {
        _context.ClearState(); _context.Flush();
        _end.Dispose(); _begin.Dispose(); _disjoint.Dispose(); _staging.Dispose(); _view.Dispose(); _buffer.Dispose(); _shader.Dispose();
        _context.Dispose(); _device.Dispose();
    }
}
