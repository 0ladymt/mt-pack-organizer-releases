Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
Add-Type -AssemblyName System.Windows.Forms

Add-Type -ReferencedAssemblies PresentationCore,WindowsBase -TypeDefinition @'
using System;
using System.Windows.Media;
using System.Windows.Media.Imaging;
public static class MtTextureLighting {
    public static BitmapSource Brighten(BitmapSource source, int light) {
        if (source == null || light <= 0) return source;
        light = Math.Max(0, Math.Min(100, light));
        double gamma = 1.0 - 0.63 * light / 100.0;
        byte[] lut = new byte[256];
        for (int i = 0; i < 256; i++)
            lut[i] = (byte)Math.Min(255, Math.Round(255.0 * Math.Pow(i / 255.0, gamma)));
        BitmapSource rgba = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        int stride = checked(rgba.PixelWidth * 4);
        byte[] pixels = new byte[checked(stride * rgba.PixelHeight)];
        rgba.CopyPixels(pixels, stride, 0);
        for (int i = 0; i < pixels.Length; i += 4) {
            pixels[i] = lut[pixels[i]];
            pixels[i + 1] = lut[pixels[i + 1]];
            pixels[i + 2] = lut[pixels[i + 2]];
        }
        BitmapSource result = BitmapSource.Create(rgba.PixelWidth, rgba.PixelHeight,
            rgba.DpiX, rgba.DpiY, PixelFormats.Bgra32, null, pixels, stride);
        result.Freeze();
        return result;
    }
}
'@

# A busca de arquivos ocorre fora da thread WPF. A janela continua animando
# mesmo durante a varredura de packs muito grandes ou discos lentos.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
public sealed class MtPackScan {
    public volatile int FoundModels;
    public volatile int FoundTextures;
    public volatile bool IsDone;
    public Exception Error;
    public string[] Models;
    public string[] Textures;
    public static MtPackScan Start(string root) {
        var state = new MtPackScan();
        Task.Run(() => {
            try {
                var models = new List<string>();
                var textures = new List<string>();
                foreach (string path in Directory.EnumerateFiles(root, "*.ydd", SearchOption.AllDirectories)) {
                    if (path.IndexOf(Path.DirectorySeparatorChar + "_PARA_EXCLUIR" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) >= 0) continue;
                    models.Add(path);
                    state.FoundModels = models.Count;
                }
                foreach (string path in Directory.EnumerateFiles(root, "*.ytd", SearchOption.AllDirectories)) {
                    if (path.IndexOf(Path.DirectorySeparatorChar + "_PARA_EXCLUIR" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) >= 0) continue;
                    textures.Add(path);
                    state.FoundTextures = textures.Count;
                }
                state.Models = models.ToArray();
                state.Textures = textures.ToArray();
            } catch (Exception error) { state.Error = error; }
            finally { state.IsDone = true; }
        });
        return state;
    }
}
'@

$ErrorActionPreference = 'Stop'
# Evita duas janelas de trabalho quando o usuário clica no atalho novamente.
$script:InstanceMutex=$null
$createdNew=$false
try {
    $script:InstanceMutex=[Threading.Mutex]::new($true,'Local\MTStudio.PackOrganizer.SingleInstance',[ref]$createdNew)
    if(-not $createdNew){
        # Se o atalho for clicado outra vez, traz a janela existente para frente.
        try {
            Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class MtFocusWindow { [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n); [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); }' -ErrorAction SilentlyContinue
            $existing=Get-Process -Name powershell,pwsh -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like '*Pack Organizer*' -and $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
            if($existing){[void][MtFocusWindow]::ShowWindow($existing.MainWindowHandle,9);[void][MtFocusWindow]::SetForegroundWindow($existing.MainWindowHandle)}
        } catch {}
        exit 0
    }
} catch { }
$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
# Branding oficial: os assets são empacotados pelo build e nunca são recriados/reescritos em runtime.
# Isso evita PNG corrompido, logo ausente e divergência entre app, barra de tarefas e instalador.
$StateDir = Join-Path $AppRoot 'state'
$LogDir = Join-Path $AppRoot 'logs'
New-Item -ItemType Directory -Force -Path $StateDir,$LogDir | Out-Null

function Write-AppLog([string]$text) {
    try {
        Add-Content -LiteralPath (Join-Path $LogDir 'mt_pack_organizer.log') `
            -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$text) -Encoding UTF8
    } catch {}
}
function Show-Error([string]$message) {
    Write-AppLog $message
    try { [System.Windows.MessageBox]::Show($message,'MT Pack Organizer','OK','Error') | Out-Null } catch {}
}
function Invoke-Safe([scriptblock]$Action) {
    try { & $Action } catch { Show-Error $_.Exception.Message }
}

# ---------------------------------------------------------------------------
# Leitor interno RSC7 / YDD / YTD
# - Sem CodeWalker
# - Sem GRZY
# - Sem render por PNG
# - A malha vira MeshGeometry3D e permanece na memória
# ---------------------------------------------------------------------------

$cs = @'
using System;
#pragma warning disable 0219
using System.IO;
using System.IO.Compression;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Media.Media3D;

public static class MtRageParser
{
    const ulong SYSTEM_BASE = 0x50000000UL;
    const ulong GRAPHICS_BASE = 0x60000000UL;

    public class MeshPartResult
    {
        public MeshGeometry3D Mesh;
        public int RenderBucket;
        public string DiffuseTexture;
        public int Vertices;
        public int Triangles;
        public int ShaderId;
        public int UvType;
        public int UvOffset;
    }

    public class MeshResult
    {
        public MeshPartResult[] Parts;
        public Rect3D Bounds;
        public int Vertices;
        public int Triangles;
    }

    public class TextureResult
    {
        public BitmapSource Bitmap;
        public string Name;
        public int Width;
        public int Height;
        public uint Format;
        public uint Usage;
    }

    public class TextureInfoResult
    {
        public string Name;
        public int Width;
        public int Height;
        public uint Format;
        public uint Usage;
    }

    class ShaderInfo
    {
        public int RenderBucket;
        public string DiffuseTexture;
    }

    class Rsc
    {
        public byte[] SystemData;
        public byte[] Graphics;

        public byte[] Resolve(ulong va, int len)
        {
            if (va == 0 || len < 0) return null;
            byte[] src;
            long off;
            if ((va & GRAPHICS_BASE) == GRAPHICS_BASE)
            {
                src = Graphics;
                off = (long)(va - GRAPHICS_BASE);
            }
            else if ((va & SYSTEM_BASE) == SYSTEM_BASE)
            {
                src = SystemData;
                off = (long)(va - SYSTEM_BASE);
            }
            else return null;

            if (off < 0 || off > src.Length || len > src.Length - off) return null;
            byte[] b = new byte[len];
            Buffer.BlockCopy(src, (int)off, b, 0, len);
            return b;
        }

        public string StringAt(ulong va)
        {
            if ((va & SYSTEM_BASE) != SYSTEM_BASE) return "";
            long off = (long)(va - SYSTEM_BASE);
            if (off < 0 || off >= SystemData.Length) return "";
            int max = Math.Min(256, SystemData.Length - (int)off);
            int end = 0;
            while (end < max && SystemData[(int)off + end] != 0) end++;
            if (end == max) return "";
            return global::System.Text.Encoding.UTF8.GetString(SystemData, (int)off, end);
        }
    }

    static ushort U16(byte[] b, int o) { return BitConverter.ToUInt16(b, o); }
    static uint U32(byte[] b, int o) { return BitConverter.ToUInt32(b, o); }
    static ulong U64(byte[] b, int o) { return BitConverter.ToUInt64(b, o); }
    static float F32(byte[] b, int o) { return BitConverter.ToSingle(b, o); }

    static int ResourceSize(uint flags)
    {
        uint s0 = ((flags >> 27) & 1) << 0;
        uint s1 = ((flags >> 26) & 1) << 1;
        uint s2 = ((flags >> 25) & 1) << 2;
        uint s3 = ((flags >> 24) & 1) << 3;
        uint s4 = ((flags >> 17) & 0x7F) << 4;
        uint s5 = ((flags >> 11) & 0x3F) << 5;
        uint s6 = ((flags >> 7) & 0x0F) << 6;
        uint s7 = ((flags >> 5) & 0x03) << 7;
        uint s8 = ((flags >> 4) & 0x01) << 8;
        int ss = (int)(flags & 0xF);
        long baseSize = 0x200L << ss;
        long units = s0+s1+s2+s3+s4+s5+s6+s7+s8;
        long n = baseSize * units;
        if (n < 0 || n > Int32.MaxValue) throw new Exception("Recurso RSC7 grande demais.");
        return (int)n;
    }

    static Rsc ReadRsc(string path)
    {
        byte[] data = File.ReadAllBytes(path);
        if (data.Length < 16 || data[0] != (byte)'R' || data[1] != (byte)'S' ||
            data[2] != (byte)'C' || data[3] != (byte)'7')
            throw new Exception(Path.GetFileName(path) + " não é um recurso RSC7 válido.");

        uint sf = U32(data, 8);
        uint gf = U32(data, 12);
        int sysSize = ResourceSize(sf);
        int gfxSize = ResourceSize(gf);

        byte[] body = new byte[data.Length - 16];
        Buffer.BlockCopy(data, 16, body, 0, body.Length);
        byte[] dec = null;

        try
        {
            using (MemoryStream input = new MemoryStream(body))
            using (DeflateStream ds = new DeflateStream(input, CompressionMode.Decompress))
            using (MemoryStream output = new MemoryStream())
            {
                ds.CopyTo(output);
                if (output.Length > 0) dec = output.ToArray();
            }
        }
        catch { dec = null; }

        if (dec == null || dec.Length < sysSize)
            dec = body; // alguns recursos são armazenados sem deflate

        if (dec.Length < sysSize)
            throw new Exception("RSC7 incompleto em " + Path.GetFileName(path) + ".");

        Rsc r = new Rsc();
        r.SystemData = new byte[sysSize];
        Buffer.BlockCopy(dec, 0, r.SystemData, 0, sysSize);

        int haveGfx = Math.Min(gfxSize, Math.Max(0, dec.Length - sysSize));
        r.Graphics = new byte[haveGfx];
        if (haveGfx > 0) Buffer.BlockCopy(dec, sysSize, r.Graphics, 0, haveGfx);
        return r;
    }

    static int ComponentSize(int t)
    {
        switch (t)
        {
            case 1: return 4;  // Half2
            case 2: return 4;  // Float
            case 3: return 8;  // Half4
            case 5: return 8;  // Float2
            case 6: return 12; // Float3
            case 7: return 16; // Float4
            case 8: return 4;  // UByte4
            case 9: return 4;  // Colour
            case 10:return 4;  // RGBA8Snorm
            default:return 0;
        }
    }

    static float HalfToFloat(ushort h)
    {
        uint sign = (uint)(h & 0x8000) << 16;
        uint exp = (uint)(h >> 10) & 0x1F;
        uint mant = (uint)h & 0x03FF;
        uint bits;
        if (exp == 0)
        {
            if (mant == 0) bits = sign;
            else
            {
                int e = -14;
                while ((mant & 0x0400) == 0) { mant <<= 1; e--; }
                mant &= 0x03FF;
                bits = sign | (uint)((e + 127) << 23) | (mant << 13);
            }
        }
        else if (exp == 0x1F) bits = sign | 0x7F800000U | (mant << 13);
        else bits = sign | ((exp + 112U) << 23) | (mant << 13);
        return BitConverter.ToSingle(BitConverter.GetBytes(bits), 0);
    }

    static double Snorm8(byte raw)
    {
        sbyte v = unchecked((sbyte)raw);
        return Math.Max(-1.0, v / 127.0);
    }

    static Vector3D ReadVec3(byte[] data, int o, int type)
    {
        try
        {
            switch(type)
            {
                case 1: return new Vector3D(HalfToFloat(U16(data,o)), HalfToFloat(U16(data,o+2)), 0.0); // Half2
                case 2: return new Vector3D(F32(data,o), 0.0, 0.0); // Float
                case 3: return new Vector3D(HalfToFloat(U16(data,o)), HalfToFloat(U16(data,o+2)), HalfToFloat(U16(data,o+4))); // Half4
                case 5: return new Vector3D(F32(data,o), F32(data,o+4), 0.0); // Float2
                case 6: return new Vector3D(F32(data,o), F32(data,o+4), F32(data,o+8)); // Float3
                case 7: return new Vector3D(F32(data,o), F32(data,o+4), F32(data,o+8)); // Float4 xyz
                case 8: // UByte4
                case 9: // Colour
                    return new Vector3D(data[o] / 255.0, data[o+1] / 255.0, data[o+2] / 255.0);
                case 10: // RGBA8Snorm
                    return new Vector3D(Snorm8(data[o]), Snorm8(data[o+1]), Snorm8(data[o+2]));
            }
        } catch {}
        return new Vector3D(0,0,1);
    }

    static Point ReadUV(byte[] data, int o, int type)
    {
        try
        {
            double u=0.0, v=0.0;
            switch(type)
            {
                case 1: // Half2
                    u=HalfToFloat(U16(data,o)); v=HalfToFloat(U16(data,o+2)); break;
                case 2: // Float
                    u=F32(data,o); v=0.0; break;
                case 3: // Half4 -> XY
                    u=HalfToFloat(U16(data,o)); v=HalfToFloat(U16(data,o+2)); break;
                case 5: // Float2
                    u=F32(data,o); v=F32(data,o+4); break;
                case 6: // Float3 -> XY
                case 7: // Float4 -> XY
                    u=F32(data,o); v=F32(data,o+4); break;
                case 8: // UByte4 -> normalized XY
                case 9: // Colour -> normalized XY
                    u=data[o] / 255.0; v=data[o+1] / 255.0; break;
                case 10: // RGBA8Snorm -> XY
                    u=Snorm8(data[o]); v=Snorm8(data[o+1]); break;
                default:
                    return new Point(0,0);
            }
            if (Double.IsNaN(u) || Double.IsInfinity(u) || Double.IsNaN(v) || Double.IsInfinity(v)) return new Point(0,0);

            // IMPORTANTE:
            // Preserve as coordenadas GTA originais, inclusive fora de 0..1.
            // O repeat precisa acontecer no sampler/brush DEPOIS da interpolação,
            // não por vértice. Pré-aplicar fract aqui quebra triângulos que
            // atravessam a borda do tile.
            return new Point(u, v);
        } catch { return new Point(0,0); }
    }

    static bool TryReadVertexBuffer(Rsc r, byte[] geom, out byte[] data, out int count,
                                    out int stride, out int posType, out int posOff,
                                    out int normType, out int normOff,
                                    out int uvType, out int uvOff)
    {
        data=null; count=0; stride=0;
        posType=6;posOff=0;normType=0;normOff=0;uvType=0;uvOff=0;

        ulong vbptr=U64(geom,0x18);
        byte[] vb=r.Resolve(vbptr,0x80);
        ulong infoPtr=0;

        if (vb != null)
        {
            int legacyStride=U16(vb,0x08);
            int legacyCount=(int)U32(vb,0x18);
            ulong p1=U64(vb,0x10);
            ulong p2=U64(vb,0x20);
            byte[] d1 = (legacyCount>0 && legacyStride>0) ? r.Resolve(p1, legacyCount*legacyStride) : null;
            byte[] d2 = (legacyCount>0 && legacyStride>0) ? r.Resolve(p2, legacyCount*legacyStride) : null;

            if (d1 != null || d2 != null)
            {
                data=d1!=null?d1:d2; count=legacyCount; stride=legacyStride; infoPtr=U64(vb,0x30);
            }
            else
            {
                int gc=(int)U32(vb,0x08);
                int gs=U16(vb,0x0C);
                ulong gp=U64(vb,0x18);
                byte[] gd=(gc>0 && gs>0)?r.Resolve(gp,gc*gs):null;
                if (gd!=null) { data=gd;count=gc;stride=gs;infoPtr=0; }
            }
        }

        if (data==null)
        {
            int ic=U16(geom,0x60);
            int ins=U16(geom,0x70);
            ulong ip=U64(geom,0x78);
            byte[] id=(ic>0&&ins>0)?r.Resolve(ip,ic*ins):null;
            if(id==null) return false;
            data=id;count=ic;stride=ins;infoPtr=0;
        }

        if (infoPtr != 0)
        {
            byte[] decl=r.Resolve(infoPtr,16);
            if(decl!=null)
            {
                uint flags=U32(decl,0);
                ulong types=U64(decl,8);
                int off=0;
                for(int sem=0;sem<16;sem++)
                {
                    if(((flags>>sem)&1)==0) continue;
                    int t=(int)((types>>(sem*4))&0xF);
                    if(sem==0){posType=t;posOff=off;}
                    if(sem==3){normType=t;normOff=off;}
                    if(sem==6){uvType=t;uvOff=off;}
                    off+=ComponentSize(t);
                }
            }
        }
        return true;
    }

    const uint DIFFUSE_SAMPLER = 0xF1FE2B71U;
    const uint TEXTURE_SAMPLER = 0x2B5170FDU;

    static ShaderInfo[] ParseShaders(Rsc r, ulong shaderGroupPtr)
    {
        if (shaderGroupPtr == 0) return new ShaderInfo[0];
        byte[] group = r.Resolve(shaderGroupPtr, 0x40);
        if (group == null) return new ShaderInfo[0];
        ulong shadersPtr = U64(group, 0x10);
        int count = U16(group, 0x18);
        byte[] shaderPtrs = count > 0 ? r.Resolve(shadersPtr, count * 8) : null;
        if (shaderPtrs == null) return new ShaderInfo[0];
        ShaderInfo[] result = new ShaderInfo[count];
        for (int si = 0; si < count; si++)
        {
            ShaderInfo info = new ShaderInfo();
            info.RenderBucket = 0;
            info.DiffuseTexture = null;
            ulong sp = U64(shaderPtrs, si * 8);
            byte[] sh = r.Resolve(sp, 0x30);
            if (sh == null) { result[si] = info; continue; }
            info.RenderBucket = sh[0x11];
            ulong paramsPtr = U64(sh, 0x00);
            int paramCount = sh[0x10];
            if (paramsPtr != 0 && paramCount > 0)
            {
                byte[] pr = r.Resolve(paramsPtr, paramCount * 16);
                if (pr != null)
                {
                    int valueBytes = 0;
                    for (int pi = 0; pi < paramCount; pi++) valueBytes += pr[pi * 16] * 16;
                    ulong hashesPtr = paramsPtr + (ulong)(paramCount * 16 + valueBytes);
                    byte[] hashes = r.Resolve(hashesPtr, paramCount * 4);
                    string oldSampler = null;
                    for (int pi = 0; pi < paramCount; pi++)
                    {
                        int po = pi * 16;
                        byte dataType = pr[po];
                        if (dataType != 0 || hashes == null) continue;
                        uint nameHash = U32(hashes, pi * 4);
                        if (nameHash != DIFFUSE_SAMPLER && nameHash != TEXTURE_SAMPLER) continue;
                        ulong texPtr = U64(pr, po + 8);
                        byte[] tex = r.Resolve(texPtr, 0x50);
                        if (tex == null) continue;
                        string texName = r.StringAt(U64(tex, 0x28));
                        if (String.IsNullOrWhiteSpace(texName)) continue;
                        if (nameHash == DIFFUSE_SAMPLER) info.DiffuseTexture = texName;
                        else oldSampler = texName;
                    }
                    if (String.IsNullOrWhiteSpace(info.DiffuseTexture)) info.DiffuseTexture = oldSampler;
                }
            }
            result[si] = info;
        }
        return result;
    }

    static MeshPartResult BuildGeometryPart(Rsc r, ulong gva, int shaderId, ShaderInfo[] shaders)
    {
        byte[] g=r.Resolve(gva,0x98);
        if(g==null) return null;
        byte[] vdata; int vc,stride,pt,po,nt,no,ut,uo;
        if(!TryReadVertexBuffer(r,g,out vdata,out vc,out stride,out pt,out po,out nt,out no,out ut,out uo)) return null;
        MeshGeometry3D mesh = new MeshGeometry3D();
        for(int i=0;i<vc;i++)
        {
            int o=i*stride;
            Vector3D positionVec=ReadVec3(vdata,o+po,pt);
            mesh.Positions.Add(new Point3D(positionVec.X,positionVec.Y,positionVec.Z));
            Vector3D n = nt==0 ? new Vector3D(0,0,1) : ReadVec3(vdata,o+no,nt);
            if(n.LengthSquared>0.000001) n.Normalize();
            mesh.Normals.Add(n);
            mesh.TextureCoordinates.Add(ut==0 ? new Point(0,0) : ReadUV(vdata,o+uo,ut));
        }
        ulong ibptr=U64(g,0x38);
        byte[] ib=r.Resolve(ibptr,0x60);
        if(ib==null) return null;
        int ic=(int)U32(ib,0x08);
        ulong indexPtr16=U64(ib,0x10);
        byte[] idx=(ic>0)?r.Resolve(indexPtr16,ic*2):null;
        if(idx!=null)
        {
            for(int i=0;i<ic;i++) { int ix=U16(idx,i*2); if(ix>=0 && ix<vc) mesh.TriangleIndices.Add(ix); }
        }
        else
        {
            int isz=U16(ib,0x0C);
            ulong indexPtr32=U64(ib,0x18);
            if(isz==4)
            {
                idx=(ic>0)?r.Resolve(indexPtr32,ic*4):null;
                if(idx!=null) for(int i=0;i<ic;i++) { long ix=U32(idx,i*4); if(ix>=0 && ix<vc) mesh.TriangleIndices.Add((int)ix); }
            }
        }
        if (mesh.Positions.Count == 0 || mesh.TriangleIndices.Count == 0) return null;
        mesh.Freeze();
        ShaderInfo shader = (shaderId >= 0 && shaderId < shaders.Length) ? shaders[shaderId] : null;
        MeshPartResult part = new MeshPartResult();
        part.Mesh = mesh;
        part.Vertices = mesh.Positions.Count;
        part.Triangles = mesh.TriangleIndices.Count / 3;
        part.ShaderId = shaderId;
        part.RenderBucket = shader != null ? shader.RenderBucket : 0;
        part.DiffuseTexture = shader != null ? shader.DiffuseTexture : null;
        part.UvType = ut;
        part.UvOffset = uo;
        return part;
    }

    static void AddDrawable(Rsc r, ulong dva, List<MeshPartResult> parts)
    {
        byte[] d=r.Resolve(dva,0xD0);
        if(d==null) return;
        ShaderInfo[] shaders = ParseShaders(r, U64(d,0x10));
        ulong high=U64(d,0x50); if(high==0) high=U64(d,0xA0); if(high==0) return;
        byte[] lh=r.Resolve(high,16); if(lh==null) return;
        ulong arrp=U64(lh,0); int count=U16(lh,8); int cap=U16(lh,10); if(count==0) count=cap;
        byte[] marr=(count>0)?r.Resolve(arrp,count*8):null; if(marr==null) return;
        for(int m=0;m<count;m++)
        {
            ulong mva=U64(marr,m*8); if(mva==0) continue;
            byte[] model=r.Resolve(mva,0x30); if(model==null) continue;
            ulong garrp=U64(model,0x08); int gc=U16(model,0x10);
            ulong shaderMapPtr=U64(model,0x20);
            byte[] shaderMap = gc > 0 ? r.Resolve(shaderMapPtr, gc * 2) : null;
            byte[] garr=(gc>0)?r.Resolve(garrp,gc*8):null; if(garr==null) continue;
            for(int gi=0;gi<gc;gi++)
            {
                ulong gva=U64(garr,gi*8);
                int shaderId = shaderMap != null ? U16(shaderMap,gi*2) : 0;
                if(gva!=0) { MeshPartResult part = BuildGeometryPart(r,gva,shaderId,shaders); if(part != null) parts.Add(part); }
            }
        }
    }

    public static MeshResult LoadMesh(string path)
    {
        Rsc r=ReadRsc(path);
        List<MeshPartResult> parts = new List<MeshPartResult>();
        bool dictionary=false;
        if(r.SystemData.Length>=0x40)
        {
            int dc=U16(r.SystemData,0x38); ulong dp=U64(r.SystemData,0x30);
            byte[] arr=(dc>0)?r.Resolve(dp,dc*8):null;
            if(arr!=null)
            {
                dictionary=true;
                for(int i=0;i<dc;i++) { ulong dva=U64(arr,i*8); if(dva!=0) AddDrawable(r,dva,parts); }
            }
        }
        if(!dictionary) AddDrawable(r,SYSTEM_BASE,parts);
        if(parts.Count==0) throw new Exception("A malha 3D não pôde ser lida de " + Path.GetFileName(path) + ".");
        Rect3D bounds = Rect3D.Empty; int vertices=0, triangles=0;
        foreach(MeshPartResult part in parts)
        {
            if(bounds.IsEmpty) bounds = part.Mesh.Bounds; else bounds.Union(part.Mesh.Bounds);
            vertices += part.Vertices; triangles += part.Triangles;
        }
        MeshResult result=new MeshResult();
        result.Parts=parts.ToArray(); result.Bounds=bounds; result.Vertices=vertices; result.Triangles=triangles;
        return result;
    }

    class TexInfo
    {
        public string Name;
        public int Width,Height,Stride,Levels;
        public uint Format,Usage;
        public ulong DataPtr;
    }

    static void Color565(ushort c, out byte r, out byte g, out byte b)
    {
        int rr=(c>>11)&31, gg=(c>>5)&63, bb=c&31;
        r=(byte)((rr<<3)|(rr>>2));
        g=(byte)((gg<<2)|(gg>>4));
        b=(byte)((bb<<3)|(bb>>2));
    }

    static void SetPixel(byte[] outp,int w,int x,int y,byte r,byte g,byte b,byte a)
    {
        if(x<0||y<0||x>=w) return;
        int h=outp.Length/(w*4);
        if(y>=h) return;
        int p=(y*w+x)*4;
        outp[p]=b;outp[p+1]=g;outp[p+2]=r;outp[p+3]=a;
    }

    static void DecodeColorBlock(byte[] src,int so,byte[] outp,int w,int h,int bx,int by,bool forceFour,byte[] alpha)
    {
        ushort c0=U16(src,so),c1=U16(src,so+2);
        byte r0,g0,b0,r1,g1,b1;
        Color565(c0,out r0,out g0,out b0); Color565(c1,out r1,out g1,out b1);
        byte[,] c=new byte[4,4];
        c[0,0]=r0;c[0,1]=g0;c[0,2]=b0;c[0,3]=255;
        c[1,0]=r1;c[1,1]=g1;c[1,2]=b1;c[1,3]=255;
        if(c0>c1 || forceFour)
        {
            for(int k=0;k<3;k++){ c[2,k]=(byte)((2*c[0,k]+c[1,k])/3); c[3,k]=(byte)((c[0,k]+2*c[1,k])/3); }
            c[2,3]=c[3,3]=255;
        }
        else
        {
            for(int k=0;k<3;k++) c[2,k]=(byte)((c[0,k]+c[1,k])/2);
            c[2,3]=255; c[3,0]=c[3,1]=c[3,2]=0;c[3,3]=0;
        }
        uint bits=U32(src,so+4);
        for(int py=0;py<4;py++) for(int px=0;px<4;px++)
        {
            int i=py*4+px; int ci=(int)((bits>>(2*i))&3);
            byte a=alpha==null?c[ci,3]:alpha[i];
            SetPixel(outp,w,bx*4+px,by*4+py,c[ci,0],c[ci,1],c[ci,2],a);
        }
    }

    static byte[] DecodeDXT1(byte[] src,int w,int h)
    {
        byte[] o=new byte[w*h*4]; int so=0;
        int bw=(w+3)/4,bh=(h+3)/4;
        for(int y=0;y<bh;y++)for(int x=0;x<bw;x++){if(so+8>src.Length)break;DecodeColorBlock(src,so,o,w,h,x,y,false,null);so+=8;}
        return o;
    }

    static byte[] DecodeDXT3(byte[] src,int w,int h)
    {
        byte[] o=new byte[w*h*4]; int so=0; int bw=(w+3)/4,bh=(h+3)/4;
        for(int y=0;y<bh;y++)for(int x=0;x<bw;x++)
        {
            if(so+16>src.Length)break;
            byte[] a=new byte[16];
            for(int i=0;i<16;i++){ int nib=(src[so+i/2] >> ((i%2)*4)) & 0xF; a[i]=(byte)(nib*17); }
            DecodeColorBlock(src,so+8,o,w,h,x,y,true,a);so+=16;
        }
        return o;
    }

    static byte[] DecodeDXT5(byte[] src,int w,int h)
    {
        byte[] o=new byte[w*h*4]; int so=0; int bw=(w+3)/4,bh=(h+3)/4;
        for(int y=0;y<bh;y++)for(int x=0;x<bw;x++)
        {
            if(so+16>src.Length)break;
            byte a0=src[so],a1=src[so+1]; byte[] at=new byte[8]; at[0]=a0;at[1]=a1;
            if(a0>a1)
            {
                for(int i=1;i<=6;i++) at[i+1]=(byte)(((7-i)*a0+i*a1)/7);
            }
            else
            {
                for(int i=1;i<=4;i++) at[i+1]=(byte)(((5-i)*a0+i*a1)/5);
                at[6]=0;at[7]=255;
            }
            ulong bits=0; for(int i=0;i<6;i++) bits|=((ulong)src[so+2+i])<<(8*i);
            byte[] a=new byte[16]; for(int i=0;i<16;i++) a[i]=at[(int)((bits>>(3*i))&7)];
            DecodeColorBlock(src,so+8,o,w,h,x,y,true,a);so+=16;
        }
        return o;
    }

    static byte[] DecodeTexture(Rsc r, TexInfo t)
    {
        int top=Math.Max(0,t.Stride*t.Height);
        byte[] src=r.Resolve(t.DataPtr,top);
        if(src==null) throw new Exception("Dados da textura '" + t.Name + "' não encontrados.");
        int w=t.Width,h=t.Height;

        if(t.Format==0x31545844) return DecodeDXT1(src,w,h);
        if(t.Format==0x33545844) return DecodeDXT3(src,w,h);
        if(t.Format==0x35545844) return DecodeDXT5(src,w,h);

        byte[] o=new byte[w*h*4];
        if(t.Format==21 || t.Format==22) // A8R8G8B8 / X8R8G8B8 = BGRA/BGRX
        {
            int n=Math.Min(w*h,src.Length/4);
            for(int i=0;i<n;i++){o[i*4]=src[i*4];o[i*4+1]=src[i*4+1];o[i*4+2]=src[i*4+2];o[i*4+3]=(t.Format==22)?(byte)255:src[i*4+3];}
            return o;
        }
        if(t.Format==32) // A8B8G8R8 = RGBA
        {
            int n=Math.Min(w*h,src.Length/4);
            for(int i=0;i<n;i++){o[i*4]=src[i*4+2];o[i*4+1]=src[i*4+1];o[i*4+2]=src[i*4];o[i*4+3]=src[i*4+3];}
            return o;
        }
        if(t.Format==25) // A1R5G5B5
        {
            int n=Math.Min(w*h,src.Length/2);
            for(int i=0;i<n;i++)
            {
                ushort v=U16(src,i*2); int a=(v>>15)&1,r5=(v>>10)&31,g5=(v>>5)&31,b5=v&31;
                byte rr=(byte)((r5<<3)|(r5>>2)),gg=(byte)((g5<<3)|(g5>>2)),bb=(byte)((b5<<3)|(b5>>2));
                o[i*4]=bb;o[i*4+1]=gg;o[i*4+2]=rr;o[i*4+3]=(byte)(a==1?255:0);
            }
            return o;
        }
        if(t.Format==50 || t.Format==28) // L8 / A8
        {
            int n=Math.Min(w*h,src.Length);
            for(int i=0;i<n;i++)
            {
                byte v=src[i];
                if(t.Format==50){o[i*4]=v;o[i*4+1]=v;o[i*4+2]=v;o[i*4+3]=255;}
                else{o[i*4]=255;o[i*4+1]=255;o[i*4+2]=255;o[i*4+3]=v;}
            }
            return o;
        }
        throw new Exception("Formato de textura ainda não suportado: 0x" + t.Format.ToString("X") + " (" + t.Name + ").");
    }

    public static TextureInfoResult[] LoadTextureInfos(string path)
    {
        Rsc r=ReadRsc(path);
        if(r.SystemData.Length<0x40) throw new Exception("YTD inválida: " + Path.GetFileName(path));
        ulong arrp=U64(r.SystemData,0x30); int count=U16(r.SystemData,0x38);
        byte[] arr=(count>0)?r.Resolve(arrp,count*8):null;
        if(arr==null || count==0) return new TextureInfoResult[0];
        List<TextureInfoResult> result = new List<TextureInfoResult>();
        for(int i=0;i<count;i++)
        {
            ulong va=U64(arr,i*8); if(va==0)continue;
            byte[] tr=r.Resolve(va,0x90); if(tr==null)continue;
            TextureInfoResult res=new TextureInfoResult();
            res.Name=r.StringAt(U64(tr,0x28)); res.Width=U16(tr,0x50);res.Height=U16(tr,0x52);
            res.Format=U32(tr,0x58);res.Usage=U32(tr,0x40)&0x1F;
            result.Add(res);
        }
        return result.ToArray();
    }

    public static TextureResult[] LoadTextures(string path)
    {
        Rsc r=ReadRsc(path);
        if(r.SystemData.Length<0x40) throw new Exception("YTD inválida: " + Path.GetFileName(path));
        ulong arrp=U64(r.SystemData,0x30); int count=U16(r.SystemData,0x38);
        byte[] arr=(count>0)?r.Resolve(arrp,count*8):null;
        if(arr==null || count==0) throw new Exception("YTD sem texturas: " + Path.GetFileName(path));
        List<TextureResult> result = new List<TextureResult>();
        for(int i=0;i<count;i++)
        {
            ulong va=U64(arr,i*8); if(va==0)continue;
            byte[] tr=r.Resolve(va,0x90); if(tr==null)continue;
            TexInfo ti=new TexInfo();
            ti.Name=r.StringAt(U64(tr,0x28)); ti.Width=U16(tr,0x50);ti.Height=U16(tr,0x52);ti.Stride=U16(tr,0x56);
            ti.Format=U32(tr,0x58);ti.Levels=tr[0x5D];ti.DataPtr=U64(tr,0x70);ti.Usage=U32(tr,0x40)&0x1F;
            byte[] pixels=DecodeTexture(r,ti);
            BitmapSource bmp=BitmapSource.Create(ti.Width,ti.Height,96,96,PixelFormats.Bgra32,null,pixels,ti.Width*4); bmp.Freeze();
            TextureResult res=new TextureResult();
            res.Bitmap=bmp;res.Name=ti.Name;res.Width=ti.Width;res.Height=ti.Height;res.Format=ti.Format;res.Usage=ti.Usage;
            result.Add(res);
        }
        if(result.Count==0) throw new Exception("YTD sem textura legível.");
        return result.ToArray();
    }

    // Alguns YDDs guardam os recursos de textura dentro dos próprios shaders.
    // Reutilizamos o leitor de textura RSC7, sem depender de uma YTD externa.
    public static TextureResult[] LoadEmbeddedTextures(string path)
    {
        Rsc r = ReadRsc(path);
        List<ulong> drawables = new List<ulong>();
        if (r.SystemData.Length >= 0x40)
        {
            int count = U16(r.SystemData, 0x38);
            byte[] arr = count > 0 && count < 4096 ? r.Resolve(U64(r.SystemData, 0x30), count * 8) : null;
            if (arr != null) for (int i = 0; i < count; i++) drawables.Add(U64(arr, i * 8));
        }
        if (drawables.Count == 0) drawables.Add(SYSTEM_BASE);

        HashSet<ulong> seen = new HashSet<ulong>();
        List<TextureResult> results = new List<TextureResult>();
        foreach (ulong drawablePtr in drawables)
        {
            byte[] drawable = r.Resolve(drawablePtr, 0xD0);
            if (drawable == null) continue;
            byte[] group = r.Resolve(U64(drawable, 0x10), 0x40);
            if (group == null) continue;
            int shaderCount = U16(group, 0x18);
            byte[] shaderPtrs = shaderCount > 0 && shaderCount < 2048 ? r.Resolve(U64(group, 0x10), shaderCount * 8) : null;
            if (shaderPtrs == null) continue;
            for (int si = 0; si < shaderCount; si++)
            {
                byte[] shader = r.Resolve(U64(shaderPtrs, si * 8), 0x30);
                if (shader == null) continue;
                ulong paramPtr = U64(shader, 0);
                int paramCount = shader[0x10];
                byte[] parameters = paramPtr != 0 && paramCount > 0 ? r.Resolve(paramPtr, paramCount * 16) : null;
                if (parameters == null) continue;
                for (int pi = 0; pi < paramCount; pi++)
                {
                    if (parameters[pi * 16] != 0) continue;
                    ulong texturePtr = U64(parameters, pi * 16 + 8);
                    if (texturePtr == 0 || !seen.Add(texturePtr)) continue;
                    byte[] tr = r.Resolve(texturePtr, 0x90);
                    if (tr == null) continue;
                    TexInfo ti = new TexInfo();
                    ti.Name = r.StringAt(U64(tr, 0x28));
                    ti.Width = U16(tr, 0x50); ti.Height = U16(tr, 0x52);
                    ti.Stride = U16(tr, 0x56); ti.Format = U32(tr, 0x58);
                    ti.Levels = tr[0x5D]; ti.DataPtr = U64(tr, 0x70);
                    ti.Usage = U32(tr, 0x40) & 0x1F;
                    if (ti.Width < 1 || ti.Height < 1 || ti.Width > 8192 || ti.Height > 8192 || ti.DataPtr == 0) continue;
                    try
                    {
                        byte[] pixels = DecodeTexture(r, ti);
                        BitmapSource bmp = BitmapSource.Create(ti.Width, ti.Height, 96, 96, PixelFormats.Bgra32, null, pixels, ti.Width * 4);
                        bmp.Freeze();
                        TextureResult result = new TextureResult();
                        result.Name = ti.Name; result.Width = ti.Width; result.Height = ti.Height;
                        result.Format = ti.Format; result.Usage = ti.Usage; result.Bitmap = bmp;
                        results.Add(result);
                    }
                    catch { /* formato de textura não suportado: tentar as demais */ }
                }
            }
        }
        return results.ToArray();
    }

    public static BitmapSource BitmapForRenderBucket(BitmapSource input, int renderBucket)
    {
        int w=input.PixelWidth, h=input.PixelHeight, stride=w*4;
        byte[] pixels=new byte[stride*h]; input.CopyPixels(pixels,stride,0);
        for(int i=3;i<pixels.Length;i+=4)
        {
            if(renderBucket==0) pixels[i]=255;
            else if(renderBucket==3) pixels[i]=(byte)(pixels[i] < 128 ? 0 : 255);
        }
        BitmapSource bmp=BitmapSource.Create(w,h,96,96,PixelFormats.Bgra32,null,pixels,stride); bmp.Freeze(); return bmp;
    }
}
'@

try {
    # IMPORTANTE:
    # Em alguns Windows/PowerShell 5.1, Add-Type não resolve "WindowsBase.dll"
    # apenas pelo nome. Pegamos os caminhos REAIS das assemblies já carregadas.
    $refs = New-Object System.Collections.Generic.List[string]

    foreach ($asm in @(
        [System.Object].Assembly,
        [System.Uri].Assembly,
        [System.Linq.Enumerable].Assembly,
        [System.Windows.Point].Assembly,
        [System.Windows.Media.Media3D.MeshGeometry3D].Assembly,
        [System.Windows.Application].Assembly,
        [System.IO.Compression.DeflateStream].Assembly
    )) {
        if ($asm -and $asm.Location -and (Test-Path $asm.Location) -and -not $refs.Contains($asm.Location)) {
            $refs.Add($asm.Location)
        }
    }

    Write-AppLog ("Assemblies do motor 3D: " + ($refs -join ' | '))
    Add-Type -TypeDefinition $cs -Language CSharp -ReferencedAssemblies $refs.ToArray() -IgnoreWarnings
} catch {
    Write-AppLog $_.Exception.ToString()
    Show-Error ("Não consegui inicializar o motor 3D interno.`n`n" + $_.Exception.Message + "`n`nVeja também a pasta logs.")
    exit
}

# --------------------------- Estado e arquivos --------------------------------

function Get-AppDataDir {
    $dir=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MTStudio\PackOrganizer'
    if(-not (Test-Path -LiteralPath $dir)){[void](New-Item -ItemType Directory -Path $dir -Force)}
    return $dir
}

function Get-StatePathForPack([string]$path) {
    if([string]::IsNullOrWhiteSpace($path)){return $null}
    $normalized=[IO.Path]::GetFullPath($path).TrimEnd('\').ToLowerInvariant()
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $digest=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))
        $id=([BitConverter]::ToString($digest)).Replace('-','').Substring(0,20).ToLowerInvariant()
    } finally {$sha.Dispose()}
    return (Join-Path (Get-AppDataDir) ("project_$id.json"))
}

function Get-StatePath {
    return (Get-StatePathForPack ([string]$script:PackPath))
}

function Get-ProjectStateCandidates([string]$path) {
    $primary=Get-StatePathForPack $path
    $legacy=Join-Path $path '_MT_PACK_ORGANIZER_STATE.json'
    $candidates=@($primary,($primary+'.bak'),$legacy)
    return @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } -Descending)
}

function Get-RecentProjectsPath {
    return (Join-Path (Get-AppDataDir) 'recent_projects.json')
}

function Get-RecentProjectPaths {
    try {
        $file=Get-RecentProjectsPath
        if(Test-Path -LiteralPath $file){return @((Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) | Where-Object { $_ -and (Test-Path -LiteralPath ([string]$_) -PathType Container) })}
    } catch { Write-AppLog ('Projetos recentes: '+$_.Exception.Message) }
    return @()
}

function Remember-Project([string]$path) {
    if([string]::IsNullOrWhiteSpace($path)){return}
    try {
        $paths=@($path)+@(Get-RecentProjectPaths | Where-Object { [string]$_ -ne $path } | Select-Object -First 19)
        ConvertTo-Json -InputObject @($paths) | Set-Content -LiteralPath (Get-RecentProjectsPath) -Encoding UTF8
    } catch { Write-AppLog ('Salvar projeto recente: '+$_.Exception.Message) }
}

function Remove-RecentProject([string]$path) {
    $projectInfo=Get-SavedProjectInfo $path
    if(-not (Confirm-RemoveProject $projectInfo.Name $path)){return}
    $statePath=Get-StatePathForPack $path
    $archiveDir=Join-Path (Get-AppDataDir) 'projetos_arquivados'
    if(-not (Test-Path -LiteralPath $archiveDir)){[void](New-Item -ItemType Directory -Path $archiveDir -Force)}
    foreach($file in @($statePath,($statePath+'.bak'))){
        if(Test-Path -LiteralPath $file){
            $name=([IO.Path]::GetFileName($file))+'_'+(Get-Date -Format 'yyyyMMddHHmmssfff')
            Move-Item -LiteralPath $file -Destination (Join-Path $archiveDir $name)
        }
    }
    $paths=@(Get-RecentProjectPaths | Where-Object { [string]$_ -ne $path })
    ConvertTo-Json -InputObject @($paths) | Set-Content -LiteralPath (Get-RecentProjectsPath) -Encoding UTF8
    Refresh-RecentProjects
}

function New-ProjectModal([string]$heading,[string]$description,[int]$width=500,[int]$height=310) {
    # Mesmo padrão de janelas em renomear, excluir e localizar pastas.
    $dialog=New-Object Windows.Window
    $dialog.Width=$width;$dialog.Height=$height;$dialog.MinWidth=$width
    $dialog.WindowStyle='None';$dialog.ResizeMode='NoResize'
    $dialog.AllowsTransparency=$true;$dialog.Background=[Windows.Media.Brushes]::Transparent
    $dialog.ShowInTaskbar=$false;$dialog.WindowStartupLocation='CenterOwner';$dialog.Owner=$win
    # Uma janela WPF separada não herda os estilos de controles da janela principal.
    # Compartilhe os estilos de rolagem e use botões tematizados abaixo.
    try {
        $scrollStyle=$win.TryFindResource([Windows.Controls.Primitives.ScrollBar])
        if($scrollStyle){$dialog.Resources.Add([Windows.Controls.Primitives.ScrollBar],$scrollStyle)}
    } catch {Write-AppLog ('Estilo de rolagem do modal: '+$_.Exception.Message)}
    $frame=New-Object Windows.Controls.Border
    $frame.Background=New-SolidBrush '#111116';$frame.BorderBrush=New-SolidBrush '#5B3270'
    $frame.BorderThickness='1';$frame.CornerRadius='16';$frame.Padding='24'
    $dialog.Content=$frame
    $body=New-Object Windows.Controls.Grid
    $body.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height=[Windows.GridLength]::Auto}))
    $body.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height=[Windows.GridLength]::Auto}))
    $body.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}))
    $body.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height=[Windows.GridLength]::Auto}))
    $frame.Child=$body
    $header=New-Object Windows.Controls.Grid
    $header.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
    $header.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{Width=[Windows.GridLength]::Auto}))
    $title=New-Object Windows.Controls.TextBlock
    $title.Text=$heading;$title.Foreground=New-SolidBrush '#FFFFFF';$title.FontSize=21;$title.FontWeight='Bold';$title.VerticalAlignment='Center'
    $close=New-ModalButton '✕'
    $close.Content='✕';$close.Width=32;$close.Height=32;$close.FontSize=13
    $close.Margin='0'
    $close.Background=New-SolidBrush '#231D28';$close.Foreground=New-SolidBrush '#C2B9C8'
    $close.BorderBrush=New-SolidBrush '#3A3040';$close.Cursor='Hand'
    [Windows.Controls.Grid]::SetColumn($close,1)
    [void]$header.Children.Add($title);[void]$header.Children.Add($close)
    [Windows.Controls.Grid]::SetRow($header,0);[void]$body.Children.Add($header)
    $subtitle=New-Object Windows.Controls.TextBlock
    $subtitle.Text=$description;$subtitle.FontSize=12;$subtitle.TextWrapping='Wrap'
    $subtitle.Foreground=New-SolidBrush '#A9A0B2';$subtitle.Margin='0,9,0,18'
    [Windows.Controls.Grid]::SetRow($subtitle,1);[void]$body.Children.Add($subtitle)
    $content=New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetRow($content,2);[void]$body.Children.Add($content)
    $footer=New-Object Windows.Controls.StackPanel
    $footer.Orientation='Horizontal';$footer.HorizontalAlignment='Right';$footer.Margin='0,18,0,0'
    [Windows.Controls.Grid]::SetRow($footer,3);[void]$body.Children.Add($footer)
    $close.Add_Click({$dialog.DialogResult=$false}.GetNewClosure())
    $header.Add_MouseLeftButtonDown({param($s,$e);try{$dialog.DragMove()}catch{}}.GetNewClosure())
    return [pscustomobject]@{Window=$dialog;Content=$content;Footer=$footer;Close=$close}
}

function Clear-ProjectModalEffects {
    # Nunca aplique BlurEffect no Grid raiz: ele também contém o loader.
    foreach($element in @($topHeader,$emptyState,$mainContent)){
        if($null -ne $element){$element.Effect=$null}
    }
    if($null -ne $win.Content){$win.Content.Effect=$null}
}

function Show-ProjectModal([Windows.Window]$dialog) {
    try {
        Clear-ProjectModalEffects
        $blur=New-Object Windows.Media.Effects.BlurEffect
        $blur.Radius=10;$blur.KernelType='Gaussian'
        foreach($element in @($topHeader,$emptyState,$mainContent)){
            if($null -ne $element){$element.Effect=$blur}
        }
        return $dialog.ShowDialog()
    } finally {
        Clear-ProjectModalEffects
    }
}

function New-ModalButton([string]$label,[bool]$primary=$false,[bool]$danger=$false) {
    $button=New-Object Windows.Controls.Button
    $button.Content=$label;$button.Width=137;$button.Height=40;$button.Margin='9,0,0,0'
    $button.FontSize=11;$button.FontWeight='SemiBold';$button.Cursor='Hand'
    $button.Foreground=New-SolidBrush '#FFFFFF'
    if($danger){$normal='#8A2941';$hover='#A43854';$border='#C0546D'}
    elseif($primary){$normal='#A432DC';$hover='#B54BE8';$border='#C069EE'}
    else{$normal='#28242E';$hover='#37303F';$border='#45404D'}
    $button.Background=New-SolidBrush $normal;$button.BorderBrush=New-SolidBrush $border
    # ControlTemplate explícito impede o hover azul do tema do Windows.
    $button.Template=[Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
  <Border x:Name="surface" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="$normal" BorderBrush="$border" BorderThickness="1" CornerRadius="8">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="surface" Property="Background" Value="$hover"/></Trigger>
    <Trigger Property="IsPressed" Value="True"><Setter TargetName="surface" Property="Opacity" Value="0.82"/></Trigger>
    <Trigger Property="IsEnabled" Value="False"><Setter TargetName="surface" Property="Opacity" Value="0.45"/></Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
"@)
    return $button
}

function Show-AppHelp {
    $modal=New-ProjectModal 'Ajuda e informações' 'MT STUDIO PACK ORGANIZER • orientações e canais oficiais' 570 535
    $dialog=$modal.Window
    foreach($section in @(
        @{Title='COMO COMEÇAR';Body='Clique em NOVO PROJETO para escolher uma pasta com arquivos YDD e YTD. O aplicativo salva suas decisões e a última peça visualizada automaticamente.'},
        @{Title='REVISÃO RÁPIDA';Body='1 = manter • 2 = excluir • ←/→ = navegar. TODAS AS CATEGORIAS volta à primeira peça; ÚLTIMA PENDENTE localiza a primeira peça ainda sem decisão na ordem original do pack.'},
        @{Title='VISUALIZAÇÃO 3D';Body='Arraste para manipular a peça. Passe o mouse nas bordas ou cantos da caixa delimitadora para ativar seus controles. Ctrl + rolagem ajusta a escala.'},
        @{Title='ARQUIVOS E SEGURANÇA';Body='Marcar EXCLUIR não apaga arquivos. A opção APLICAR EXCLUSÕES move os selecionados para _PARA_EXCLUIR. Confira o resultado antes de distribuir o pack.'},
        @{Title='ATUALIZAÇÕES';Body='A versão instalada aparece ao lado do nome PACK ORGANIZER. Quando houver uma atualização oficial, o aplicativo avisa e oferece a instalação.'}
    )){
        $card=New-Object Windows.Controls.StackPanel
        $card.Margin='0,0,0,12'
        $title=New-Object Windows.Controls.TextBlock
        $title.Text=$section.Title;$title.FontSize=11;$title.FontWeight='Bold';$title.Foreground=New-SolidBrush '#D9A4F1'
        $description=New-Object Windows.Controls.TextBlock
        $description.Text=$section.Body;$description.FontSize=11;$description.Foreground=New-SolidBrush '#C5BACD'
        $description.TextWrapping='Wrap';$description.Margin='0,5,0,0';$description.LineHeight=17
        [void]$card.Children.Add($title);[void]$card.Children.Add($description)
        [void]$modal.Content.Children.Add($card)
    }
    $modal.Footer.HorizontalAlignment='Stretch'
    $modal.Footer.Width=520
    $support=New-ModalButton 'SUPORTE'
    $support.Margin='0'
    $support.Background=New-SolidBrush '#30203D'
    $support.BorderBrush=New-SolidBrush '#75518E'
    $support.ToolTip='Abrir o servidor oficial MT STUDIO no Discord'
    $supportUrl=[string]$script:SupportDiscordUrl
    $support.IsEnabled=(-not [string]::IsNullOrWhiteSpace($supportUrl))
    $support.Add_Click({
        if($supportUrl -match '^https://(discord\.gg/|discord\.com/invite/)'){
            Start-Process -FilePath $supportUrl
        }
    }.GetNewClosure())
    $spacer=New-Object Windows.Controls.Border;$spacer.Width=236
    $close=New-ModalButton 'ENTENDI' $true
    [void]$modal.Footer.Children.Add($support)
    [void]$modal.Footer.Children.Add($spacer)
    [void]$modal.Footer.Children.Add($close)
    $close.Add_Click({$dialog.DialogResult=$true}.GetNewClosure())
    if($env:MT_PACK_ORGANIZER_UITEST -eq '1'){
        [void]$dialog.Dispatcher.BeginInvoke([Action]{
            if(-not $support.IsEnabled){throw 'O botão SUPORTE deveria estar ativo com o convite oficial.'}
            if($supportUrl -ne 'https://discord.gg/MAPubH3vRw'){throw 'Convite Discord incorreto no suporte.'}
            $close.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }.GetNewClosure(),[Windows.Threading.DispatcherPriority]::Loaded)
    }
    [void](Show-ProjectModal $dialog)
}

function Save-ModalPreview([Windows.Window]$dialog,[string]$kind) {
    if($env:MT_PACK_ORGANIZER_UITEST -ne '1' -or -not $env:MT_PACK_ORGANIZER_SCREENSHOT){return}
    if(-not ($emptyState.Effect -is [Windows.Media.Effects.BlurEffect])){
        throw 'O fundo da janela principal não foi desfocado ao abrir o menu.'
    }
    try {
        $dialog.UpdateLayout()
        $w=[int]$dialog.ActualWidth;$h=[int]$dialog.ActualHeight
        if($w -lt 30 -or $h -lt 30){return}
        $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap $w,$h,96,96,([Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($dialog)
        $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $dest=$env:MT_PACK_ORGANIZER_SCREENSHOT.Replace('.png',('-'+$kind+'.png'))
        $out=[IO.File]::Create($dest)
        try{$encoder.Save($out)}finally{$out.Dispose()}
    } catch { Write-AppLog ('Captura modal: '+$_.Exception.Message) }
}

function Confirm-RemoveProject([string]$name,[string]$path) {
    $modal=New-ProjectModal 'Excluir projeto?' 'Esta ação remove o projeto da sua página inicial.' 535 330
    $dialog=$modal.Window
    $project=New-Object Windows.Controls.Border
    $project.Background=New-SolidBrush '#1B1721';$project.BorderBrush=New-SolidBrush '#46304D'
    $project.BorderThickness='1';$project.CornerRadius='9';$project.Padding='13'
    $stack=New-Object Windows.Controls.StackPanel
    $nameText=New-Object Windows.Controls.TextBlock
    $nameText.Text=$name;$nameText.Foreground=New-SolidBrush '#FFFFFF';$nameText.FontSize=15;$nameText.FontWeight='SemiBold'
    $pathText=New-Object Windows.Controls.TextBlock
    $pathText.Text=$path;$pathText.Foreground=New-SolidBrush '#81798A';$pathText.FontSize=10
    $pathText.TextTrimming='CharacterEllipsis';$pathText.Margin='0,5,0,0'
    [void]$stack.Children.Add($nameText);[void]$stack.Children.Add($pathText);$project.Child=$stack
    [void]$modal.Content.Children.Add($project)
    $notice=New-Object Windows.Controls.TextBlock
    $notice.Text='✓ Seus arquivos de roupas não serão apagados. O histórico será arquivado para recuperação.'
    $notice.TextWrapping='Wrap';$notice.Foreground=New-SolidBrush '#C7B6D0';$notice.FontSize=11;$notice.Margin='0,16,0,0'
    [void]$modal.Content.Children.Add($notice)
    $cancel=New-ModalButton 'CANCELAR';$remove=New-ModalButton 'EXCLUIR PROJETO' $false $true
    [void]$modal.Footer.Children.Add($cancel);[void]$modal.Footer.Children.Add($remove)
    $cancel.Add_Click({$dialog.DialogResult=$false}.GetNewClosure())
    $remove.Add_Click({$dialog.DialogResult=$true}.GetNewClosure())
    if($env:MT_PACK_ORGANIZER_UITEST -eq '1'){
        [void]$dialog.Dispatcher.BeginInvoke([Action]{
            Save-ModalPreview $dialog 'excluir'
            $cancel.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }.GetNewClosure(),[Windows.Threading.DispatcherPriority]::Loaded)
    }
    return ((Show-ProjectModal $dialog) -eq $true)
}

function Get-SavedProjectInfo([string]$path) {
    $info=[pscustomobject]@{Name=(Get-DefaultProjectName $path);Keep=0;Delete=0;Total=0;Index=0;Percent=0}
    foreach($stateFile in @(Get-ProjectStateCandidates $path)){
        try {
            $state=Get-Content -LiteralPath $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if($null -eq $state.decisions){continue}
            $decisions=@($state.decisions.PSObject.Properties)
            $info.Keep=@($decisions | Where-Object { $_.Value -eq 'MANTER' }).Count
            $info.Delete=@($decisions | Where-Object { $_.Value -eq 'EXCLUIR' }).Count
            $info.Total=[int]$state.total_pieces
            $info.Index=[int]$state.index
            $info.Percent=if($info.Total -gt 0){[Math]::Min(100,[Math]::Round(100*($info.Keep+$info.Delete)/$info.Total))}else{0}
            if(-not [string]::IsNullOrWhiteSpace([string]$state.project_name)){$info.Name=[string]$state.project_name}
            break
        } catch {Write-AppLog ('Resumo de '+$stateFile+': '+$_.Exception.Message)}
    }
    return $info
}

function Prompt-ProjectName([string]$current) {
    $modal=New-ProjectModal 'Nome do projeto' 'Escolha um nome para identificar seu pack na página inicial.' 490 275
    $dialog=$modal.Window
    $heading=New-Object Windows.Controls.TextBlock
    $heading.Text='IDENTIFICAÇÃO DO PROJETO';$heading.Foreground=New-SolidBrush '#D88BFF';$heading.FontWeight='Bold';$heading.FontSize=10
    [void]$modal.Content.Children.Add($heading)
    $projectNameInput=New-Object Windows.Controls.TextBox
    $projectNameInput.Text=$current;$projectNameInput.FontSize=14;$projectNameInput.Height=44;$projectNameInput.Margin='0,8,0,0';$projectNameInput.MaxLength=60
    $projectNameInput.Background=New-SolidBrush '#1B1720';$projectNameInput.Foreground=New-SolidBrush '#FFFFFF'
    $projectNameInput.BorderBrush=New-SolidBrush '#A432DC';$projectNameInput.Padding='12,9'
    [void]$modal.Content.Children.Add($projectNameInput)
    $cancel=New-ModalButton 'CANCELAR';$confirm=New-ModalButton 'SALVAR NOME' $true
    # Handlers WPF executam após a saída do escopo de Prompt-ProjectName.
    # GetNewClosure preserva a janela e o campo, inclusive ao clicar em SALVAR.
    $cancel.Add_Click({$dialog.DialogResult=$false}.GetNewClosure())
    $confirm.Add_Click({if(-not [string]::IsNullOrWhiteSpace($projectNameInput.Text)){$dialog.DialogResult=$true}}.GetNewClosure())
    $projectNameInput.Add_KeyDown({param($s,$e);if($e.Key -eq 'Return' -and -not [string]::IsNullOrWhiteSpace($projectNameInput.Text)){$dialog.DialogResult=$true}}.GetNewClosure())
    [void]$modal.Footer.Children.Add($cancel);[void]$modal.Footer.Children.Add($confirm)
    $projectNameInput.SelectAll();$projectNameInput.Focus() | Out-Null
    if($env:MT_PACK_ORGANIZER_UITEST -eq '1'){
        [void]$dialog.Dispatcher.BeginInvoke([Action]{
            Save-ModalPreview $dialog 'renomear'
            $projectNameInput.Text='Projeto nomeado no teste'
            $confirm.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }.GetNewClosure(),[Windows.Threading.DispatcherPriority]::Loaded)
    }
    if((Show-ProjectModal $dialog) -eq $true){return $projectNameInput.Text.Trim()}
    return $null
}

function Rename-RecentProject([string]$path) {
    $old=Get-SavedProjectInfo $path
    $name=Prompt-ProjectName $old.Name
    if([string]::IsNullOrWhiteSpace($name)){return}
    if([string]$script:PackPath -ieq $path){
        $script:ProjectName=$name;Save-State;$lblPackName.Text=$name
    } else {
        $previousPath=$script:PackPath;$previousName=$script:ProjectName
        try {
            $script:PackPath=$path;$script:ProjectName=$name
            # Renomear um projeto fechado sem alterar suas decisões existentes.
            $statePath=Get-StatePath
            $candidate=@(Get-ProjectStateCandidates $path | Select-Object -First 1)
            if($candidate.Count -gt 0){
                $data=Get-Content -LiteralPath $candidate[0] -Raw | ConvertFrom-Json
                $data | Add-Member -NotePropertyName project_name -NotePropertyValue $name -Force
                $json=ConvertTo-Json -InputObject $data -Depth 10
                if(Test-Path -LiteralPath $statePath){Copy-Item -LiteralPath $statePath -Destination ($statePath+'.bak') -Force}
                [IO.File]::WriteAllText($statePath,$json,[Text.Encoding]::UTF8)
            }
        } finally {
            $script:PackPath=$previousPath;$script:ProjectName=$previousName
        }
    }
    Refresh-RecentProjects
}

function Refresh-RecentProjects {
    if($null -eq $lstRecentProjects){return}
    $lstRecentProjects.Items.Clear()
    $homeKeep=0;$homeDelete=0;$homeTotal=0;$homeReviewed=0
    foreach($path in @(Get-RecentProjectPaths)) {
        $summary=Get-SavedProjectInfo $path
        $homeKeep += [int]$summary.Keep
        $homeDelete += [int]$summary.Delete
        $homeTotal += [int]$summary.Total
        $homeReviewed += ([int]$summary.Keep+[int]$summary.Delete)
        $item=New-Object Windows.Controls.ListBoxItem
        $item.Tag=[string]$path
        $panel=New-Object Windows.Controls.Grid
        $panel.Margin='15,12'
        $panel.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
        $rightCol=New-Object Windows.Controls.ColumnDefinition;$rightCol.Width='Auto';$panel.ColumnDefinitions.Add($rightCol)
        $left=New-Object Windows.Controls.StackPanel
        $heading=New-Object Windows.Controls.StackPanel;$heading.Orientation='Horizontal'
        $name=New-Object Windows.Controls.TextBlock
        $name.Text=[string]$summary.Name
        $name.FontWeight='Bold';$name.FontSize=17;$name.VerticalAlignment='Center'
        [void]$heading.Children.Add($name)
        $status=New-Object Windows.Controls.Border
        $status.Background=New-SolidBrush $(if([int]$summary.Percent -ge 100){'#193327'}else{'#2C1E37'})
        $status.BorderBrush=New-SolidBrush $(if([int]$summary.Percent -ge 100){'#43745B'}else{'#68427E'})
        $status.BorderThickness='1';$status.CornerRadius='7';$status.Padding='8,4';$status.Margin='12,0,0,0'
        $statusLabel=New-Object Windows.Controls.TextBlock
        $statusLabel.Text=if([int]$summary.Percent -ge 100){'CONCLUÍDO'}else{'EM ANDAMENTO'}
        $statusLabel.FontSize=9;$statusLabel.FontWeight='Bold'
        $statusLabel.Foreground=New-SolidBrush $(if([int]$summary.Percent -ge 100){'#9EE3B8'}else{'#D8B5F0'})
        $status.Child=$statusLabel;[void]$heading.Children.Add($status)
        [void]$left.Children.Add($heading)
        $details=New-Object Windows.Controls.TextBlock
        $details.Margin='0,12,0,12';$details.FontSize=11;$details.Foreground=New-SolidBrush '#B5A9BD'
        $details.Text="MANTER  $($summary.Keep)    •    EXCLUIR  $($summary.Delete)    •    $($summary.Percent)% CONCLUÍDO    •    PEÇA $([int]$summary.Index+1)/$($summary.Total)"
        [void]$left.Children.Add($details)
        $bar=New-Object Windows.Controls.ProgressBar
        $bar.Height=5;$bar.Maximum=100;$bar.Value=[double]$summary.Percent
        $bar.Foreground=New-SolidBrush '#A432DC';$bar.Background=New-SolidBrush '#302637'
        $bar.MinWidth=320;$bar.HorizontalAlignment='Stretch'
        [void]$left.Children.Add($bar)
        $pathText=New-Object Windows.Controls.TextBlock
        $pathText.Text=[string]$path;$pathText.FontSize=10;$pathText.Foreground=New-SolidBrush '#92889B'
        $pathText.Margin='0,10,0,0';$pathText.TextTrimming='CharacterEllipsis';[void]$left.Children.Add($pathText)
        [Windows.Controls.Grid]::SetColumn($left,0);[void]$panel.Children.Add($left)
        $actions=New-Object Windows.Controls.StackPanel;$actions.Orientation='Vertical';$actions.Margin='24,0,0,0'
        $open=New-Object Windows.Controls.Button;$open.Content='CONTINUAR  ›';$open.Width=136;$open.Height=39;$open.Padding='2'
        $open.Background=New-SolidBrush '#8837B8';$open.BorderBrush=New-SolidBrush '#A65DCC';$open.FontWeight='Bold'
        $rename=New-Object Windows.Controls.Button;$rename.Content='RENOMEAR';$rename.Width=136;$rename.Height=34;$rename.Padding='2';$rename.Margin='0,8,0,0'
        $remove=New-Object Windows.Controls.Button;$remove.Content='EXCLUIR PROJETO';$remove.Width=136;$remove.Height=34;$remove.Padding='2';$remove.Margin='0,8,0,0'
        $remove.Foreground=New-SolidBrush '#FF9CA4'
        $localPath=[string]$path
        $open.Add_Click({Invoke-Safe {Open-PackPath $localPath}}.GetNewClosure())
        $rename.Add_Click({Invoke-Safe {Rename-RecentProject $localPath}}.GetNewClosure())
        $remove.Add_Click({Invoke-Safe {Remove-RecentProject $localPath}}.GetNewClosure())
        [void]$actions.Children.Add($open);[void]$actions.Children.Add($rename);[void]$actions.Children.Add($remove)
        [Windows.Controls.Grid]::SetColumn($actions,1);[void]$panel.Children.Add($actions)
        $item.Content=$panel
        [void]$lstRecentProjects.Items.Add($item)
    }
    $lblNoProjects.Visibility=if($lstRecentProjects.Items.Count -eq 0){'Visible'}else{'Collapsed'}
    if($lblHomeProjects){$lblHomeProjects.Text=[string]$lstRecentProjects.Items.Count}
    if($lblHomeKeep){$lblHomeKeep.Text=[string]$homeKeep}
    if($lblHomeDelete){$lblHomeDelete.Text=[string]$homeDelete}
    if($lblHomeReviewed){$lblHomeReviewed.Text="${homeReviewed} / ${homeTotal}"}
}

function Go-Home {
    if($script:PackPath){Save-State}
    $mainContent.Visibility='Collapsed'
    $emptyState.Visibility='Visible'
    $btnHome.Visibility='Collapsed'
    $packHeaderInfo.Visibility='Collapsed'
    $lblPackName.Text=''
    $lblPackPath.Text=''
    Refresh-RecentProjects
}

function Save-State {
    if (-not $script:PackPath -or $script:AllowStateSave -eq $false) { return }
    if($txtAddonName){$script:AddonNameSaved=[string]$txtAddonName.Text}
    $obj = [ordered]@{
        version = 9
        project_name = $script:ProjectName
        pack = $script:PackPath
        index = $script:Index
        total_pieces = @($script:Pieces).Count
        view = [ordered]@{
            yaw=$script:Yaw; pitch=$script:Pitch; roll=$script:Roll
            scale=$script:ModelScale; offset_x=$script:ModelOffsetX; offset_y=$script:ModelOffsetY; offset_z=$script:ModelOffsetZ
            camera_distance=$script:CameraDistance
            light_level=$script:LightLevel
        }
        prop_alignment = $script:PropAlignment
        decisions = $script:Decisions
        texture_deletions = @($script:TextureDeletions.Keys)
        category_overrides = $script:CategoryOverrides
        hide_hair = $script:HideHairSelections
        addon_name = $script:AddonNameSaved
        build_settings = [ordered]@{
            max_pieces_per_pack = 150
            mask_hide_hair_manual = $true
            hat_hair_scale_auto = $true
        }
    }
    # Estado leve: NÃO recalcula plano/build a cada clique. Isso era uma das maiores causas de travamento.
    try {
        $target=Get-StatePath
        $temp=$target+'.tmp'
        $json=ConvertTo-Json -InputObject $obj -Depth 10
        [void]($json | ConvertFrom-Json -ErrorAction Stop)
        [IO.File]::WriteAllText($temp,$json,[Text.Encoding]::UTF8)
        if(Test-Path -LiteralPath $target){Copy-Item -LiteralPath $target -Destination ($target+'.bak') -Force}
        Move-Item -LiteralPath $temp -Destination $target -Force
    } catch { Write-AppLog ('Não foi possível salvar o progresso: '+$_.Exception.Message) }
}

function Load-State {
    $script:Decisions = @{}
    $script:TextureDeletions = @{}
    $script:CategoryOverrides = @{}
    $script:HideHairSelections = @{}
    $script:ProjectName=Get-DefaultProjectName $script:PackPath
    $candidates=@(Get-ProjectStateCandidates $script:PackPath)
    $script:AllowStateSave=($candidates.Count -eq 0)
    foreach($p in $candidates){
        try {
            $o = Get-Content -Raw -LiteralPath $p -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if(-not $o -or $null -eq $o.index -or $null -eq $o.decisions){throw 'Estado incompleto.'}
            $script:Decisions=@{}
            if ($o.decisions) {
                foreach ($prop in $o.decisions.PSObject.Properties) {
                    $v = [string]$prop.Value
                    if ($v -eq 'MANTER' -or $v -eq 'EXCLUIR') {
                        $script:Decisions[$prop.Name] = $v
                    }
                }
            }
            if ($o.texture_deletions) {
                foreach ($tp in @($o.texture_deletions)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$tp)) { $script:TextureDeletions[[string]$tp] = $true }
                }
            }
            if ($o.category_overrides) { foreach($prop in $o.category_overrides.PSObject.Properties){ $script:CategoryOverrides[$prop.Name]=[string]$prop.Value } }
            if ($o.hide_hair) { foreach($prop in $o.hide_hair.PSObject.Properties){ $script:HideHairSelections[$prop.Name]=[bool]$prop.Value } }
            if ($null -ne $o.index) { $script:Index = [int]$o.index }
            if ($o.view) {
                $script:SavedView=$o.view
            }
            if($o.prop_alignment){foreach($p in $o.prop_alignment.PSObject.Properties){$script:PropAlignment[$p.Name]=$p.Value}}
            if ($o.addon_name) { $script:AddonNameSaved = [string]$o.addon_name }
            if(-not [string]::IsNullOrWhiteSpace([string]$o.project_name)){$script:ProjectName=[string]$o.project_name}
            $script:AllowStateSave=$true
            Write-AppLog ('Estado restaurado de '+$p+' com '+$script:Decisions.Count+' decisões.')
            return
        } catch { Write-AppLog "Estado anterior em $p não pôde ser lido: $($_.Exception.Message)" }
    }
    if(-not $script:AllowStateSave){
        Show-Error 'Os dados do projeto não puderam ser restaurados. Os arquivos antigos foram preservados e o salvamento automático foi suspenso para evitar substituir suas marcações. Consulte a pasta logs.'
    }
}

function Get-DefaultProjectName([string]$path){
    $leaf=Split-Path $path -Leaf
    if($leaf -ieq 'stream'){$leaf=Split-Path (Split-Path $path -Parent) -Leaf}
    if([string]::IsNullOrWhiteSpace($leaf)){return 'Meu projeto'}
    return $leaf
}

function Get-VariantIndexKey([string]$dir,[string]$prefix,[string]$slot,[int]$num,[string]$kind) {
    $d = ([string]$dir).ToLowerInvariant()
    $p = ([string]$prefix).ToLowerInvariant()
    $s = ([string]$slot).ToLowerInvariant()
    $k = ([string]$kind).ToLowerInvariant()
    return ($d + '|' + $p + '|' + $s + '|' + $num + '|' + $k)
}

function Ensure-RuntimeCollections {
    if($null -eq $script:Decisions -or -not ($script:Decisions -is [hashtable])){$script:Decisions=@{}}
    if($null -eq $script:TextureDeletions -or -not ($script:TextureDeletions -is [hashtable])){$script:TextureDeletions=@{}}
    if($null -eq $script:CategoryOverrides -or -not ($script:CategoryOverrides -is [hashtable])){$script:CategoryOverrides=@{}}
    if($null -eq $script:HideHairSelections -or -not ($script:HideHairSelections -is [hashtable])){$script:HideHairSelections=@{}}
    if($null -eq $script:VariantIndex -or -not ($script:VariantIndex -is [hashtable])){$script:VariantIndex=@{}}
    if($null -eq $script:TextureCache -or -not ($script:TextureCache -is [hashtable])){$script:TextureCache=@{}}
    if($null -eq $script:TextureCacheCost -or -not ($script:TextureCacheCost -is [hashtable])){$script:TextureCacheCost=@{}}
    if($null -eq $script:TextureCacheBytes){$script:TextureCacheBytes=[long]0}
    if($null -eq $script:TextureInfoCache -or -not ($script:TextureInfoCache -is [hashtable])){$script:TextureInfoCache=@{}}
    if($null -eq $script:MeshCache -or -not ($script:MeshCache -is [hashtable])){$script:MeshCache=@{}}
    if($null -eq $script:MaterialBitmapCache -or -not ($script:MaterialBitmapCache -is [hashtable])){$script:MaterialBitmapCache=@{}}
    if($null -eq $script:TextureCacheOrder){$script:TextureCacheOrder=@()}
    if($null -eq $script:MeshCacheOrder){$script:MeshCacheOrder=@()}
    if($null -eq $script:ThumbGeneration){$script:ThumbGeneration=0}
}

function Build-FileIndex($scan=$null) {
    Ensure-RuntimeCollections
    $script:VariantIndex = @{}
    $script:Pieces = @()
    if ([string]::IsNullOrWhiteSpace([string]$script:PackPath)) { return }

    $ydds = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $yddPaths = New-Object 'System.Collections.Generic.List[string]'
    $ytdPaths = New-Object 'System.Collections.Generic.List[string]'
    $scannedPieces=0
    $modelPaths=if($null -ne $scan){$scan.Models}else{[IO.Directory]::EnumerateFiles([string]$script:PackPath,'*.ydd',[IO.SearchOption]::AllDirectories)}
    foreach($path in $modelPaths) {
        if([string]$path -match '\\_PARA_EXCLUIR\\'){ continue }
        $yddPaths.Add([string]$path)
        $scannedPieces++
        if($scannedPieces % 150 -eq 0){Update-LoadingActivity "Encontradas $scannedPieces peças 3D..."}
    }
    $texturePaths=if($null -ne $scan){$scan.Textures}else{[IO.Directory]::EnumerateFiles([string]$script:PackPath,'*.ytd',[IO.SearchOption]::AllDirectories)}
    foreach($path in $texturePaths) {
        if([string]$path -match '\\_PARA_EXCLUIR\\'){ continue }
        $ytdPaths.Add([string]$path)
        if($ytdPaths.Count % 150 -eq 0){Update-LoadingActivity "Localizando arquivos: $scannedPieces peças • $($ytdPaths.Count) texturas..."}
    }
    $totalFiles=[Math]::Max(1,$yddPaths.Count+$ytdPaths.Count)
    $indexedFiles=0
    foreach($path in $yddPaths){
        $ydds.Add((New-Object IO.FileInfo $path))
        $indexedFiles++
        if($indexedFiles % 100 -eq 0){Update-LoadingActivity "Indexando $indexedFiles de $totalFiles arquivos..." $indexedFiles $totalFiles}
    }
    $script:Pieces = @($ydds | Sort-Object FullName)
    if ($script:Pieces.Count -eq 0) { throw 'Nenhum arquivo YDD foi encontrado nessa pasta.' }

    $componentSlots = 'head|berd|hair|uppr|lowr|hand|feet|teef|accs|task|decl|jbib'
    $propSlots = 'p_head|p_eyes|p_ears|p_mouth|p_lhand|p_rhand|p_lwrist|p_rwrist|p_hip|p_lfoot|p_rfoot|p_ph_l_hand|p_ph_r_hand'
    Update-LoadingActivity "$($script:Pieces.Count) peças localizadas. Procurando texturas..."
    $scannedTextures=0
    foreach($path in $ytdPaths) {
        $scannedTextures++
        $indexedFiles++
        if($scannedTextures % 100 -eq 0){Update-LoadingActivity "Indexando $indexedFiles de $totalFiles arquivos..." $indexedFiles $totalFiles}
        $f = New-Object IO.FileInfo ([string]$path)
        $name = [string]$f.Name
        if($name -match "^(?<prefix>.*\^)?(?<slot>$componentSlots)_diff_(?<num>\d+)_(?<letter>[a-z])_(?<kind>uni|whi)\.ytd$") {
            $prefix=if($Matches.prefix){[string]$Matches.prefix}else{''}
            $kind=[string]$Matches.kind
            $key=Get-VariantIndexKey ([string]$f.DirectoryName) $prefix ([string]$Matches.slot) ([int]$Matches.num) $kind
            if(-not $script:VariantIndex.ContainsKey($key)){$script:VariantIndex[$key]=New-Object 'System.Collections.Generic.List[object]'}
            $script:VariantIndex[$key].Add([pscustomobject]@{Letter=([string]$Matches.letter).ToUpperInvariant();Kind=$kind.ToUpperInvariant();IsRelative=($kind -eq 'whi');File=$f})
        } elseif($name -match "^(?<prefix>.*\^)?(?<slot>$propSlots)_diff_(?<num>\d+)_(?<letter>[a-z])(?:_(?<kind>uni|whi))?\.ytd$") {
            $prefix=if($Matches.prefix){[string]$Matches.prefix}else{''}
            $key=Get-VariantIndexKey ([string]$f.DirectoryName) $prefix ([string]$Matches.slot) ([int]$Matches.num) 'prop'
            if(-not $script:VariantIndex.ContainsKey($key)){$script:VariantIndex[$key]=New-Object 'System.Collections.Generic.List[object]'}
            $script:VariantIndex[$key].Add([pscustomobject]@{Letter=([string]$Matches.letter).ToUpperInvariant();Kind='PROP';IsRelative=$false;File=$f})
        }
    }
    Update-LoadingActivity "Índice pronto: $($script:Pieces.Count) peças e $scannedTextures texturas." $totalFiles $totalFiles
    if ($script:Index -lt 0 -or $script:Index -ge $script:Pieces.Count) { $script:Index = 0 }
}

function Find-Variants([IO.FileInfo]$Ydd) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($Ydd.Name)
    $componentSlots = 'head|berd|hair|uppr|lowr|hand|feet|teef|accs|task|decl|jbib'
    $propSlots = 'p_head|p_eyes|p_ears|p_mouth|p_lhand|p_rhand|p_lwrist|p_rwrist|p_hip|p_lfoot|p_rfoot|p_ph_l_hand|p_ph_r_hand'
    if ($stem -match "^(?<prefix>.*\^)?(?<slot>$componentSlots)_(?<num>\d+)_(?<variant>[ur])$") {
        $prefix=if($Matches.prefix){[string]$Matches.prefix}else{''}
        $kind=if(([string]$Matches.variant).ToLowerInvariant() -eq 'r'){'whi'}else{'uni'}
        $key=Get-VariantIndexKey $Ydd.DirectoryName $prefix ([string]$Matches.slot) ([int]$Matches.num) $kind
        if($script:VariantIndex -and $script:VariantIndex.ContainsKey($key)){return @($script:VariantIndex[$key] | Sort-Object Letter)}
        return @()
    }
    if ($stem -match "^(?<prefix>.*\^)?(?<slot>$propSlots)_(?<num>\d+)$") {
        $prefix=if($Matches.prefix){[string]$Matches.prefix}else{''}
        $key=Get-VariantIndexKey $Ydd.DirectoryName $prefix ([string]$Matches.slot) ([int]$Matches.num) 'prop'
        if($script:VariantIndex -and $script:VariantIndex.ContainsKey($key)){return @($script:VariantIndex[$key] | Sort-Object Letter)}
    }
    return @()
}

function Get-PieceDisplayNumber([IO.FileInfo]$Ydd) {
    $stem=[IO.Path]::GetFileNameWithoutExtension($Ydd.Name)
    if($stem -match '_(?<num>\d+)(?:_[ur])?$') {
        $n=0; if([int]::TryParse([string]$Matches.num,[ref]$n)){return ('{0:D4}' -f $n)}
    }
    return ('{0:D4}' -f $script:Index)
}

function Get-PixelFormatName([uint32]$format) {
    switch ($format) {
        21 { return 'A8R8G8B8' }
        22 { return 'X8R8G8B8' }
        25 { return 'A1R5G5B5' }
        28 { return 'A8' }
        32 { return 'A8B8G8R8' }
        50 { return 'L8' }
        0x31545844 { return 'DXT1' }
        0x33545844 { return 'DXT3' }
        0x35545844 { return 'DXT5' }
        default { return ('0x{0:X8}' -f $format) }
    }
}

function Get-DetectedPieceDescriptor([IO.FileInfo]$Ydd) {
    $stem=[IO.Path]::GetFileNameWithoutExtension($Ydd.Name)
    $componentMap=@{ head=0; berd=1; hair=2; uppr=3; lowr=4; hand=5; feet=6; teef=7; accs=8; task=9; decl=10; jbib=11 }
    $propMap=@{ p_head=0; p_eyes=1; p_ears=2; p_mouth=3; p_lhand=4; p_rhand=5; p_lwrist=6; p_rwrist=7; p_hip=8; p_lfoot=9; p_rfoot=10; p_ph_l_hand=11; p_ph_r_hand=12 }
    $sex = if($Ydd.Name -match '(?i)mp_m_freemode_01'){'male'}elseif($Ydd.Name -match '(?i)mp_f_freemode_01'){'female'}else{'female'}

    foreach($slot in $componentMap.Keys) {
        if($stem -match ('(?i)(?:^|\^)'+[regex]::Escape($slot)+'_(?<num>\d+)_(?<variant>[ur])$')) {
            $variant=([string]$Matches.variant).ToLowerInvariant()
            $hideMode = if($slot -eq 'berd'){'MASK_HIDE_HAIR'}else{'NONE'}
            return [pscustomobject]@{
                Slot=$slot; TypeNumeric=[int]$componentMap[$slot]; IsProp=$false; Number=[int]$Matches.num
                Variant=$variant; TextureKind=$(if($variant -eq 'r'){'whi'}else{'uni'}); HasSkin=($variant -eq 'r')
                Sex=$sex; AutoHideHair=($hideMode -ne 'NONE'); HairMode=$hideMode
            }
        }
    }
    foreach($slot in $propMap.Keys) {
        if($stem -match ('(?i)(?:^|\^)'+[regex]::Escape($slot)+'_(?<num>\d+)$')) {
            $hideMode = if($slot -eq 'p_head'){'HAT_HAIR_SCALE'}else{'NONE'}
            return [pscustomobject]@{
                Slot=$slot; TypeNumeric=[int]$propMap[$slot]; IsProp=$true; Number=[int]$Matches.num
                Variant='p'; TextureKind='prop'; HasSkin=$false; Sex=$sex
                AutoHideHair=($hideMode -ne 'NONE'); HairMode=$hideMode
            }
        }
    }
    return [pscustomobject]@{Slot='unknown';TypeNumeric=-1;IsProp=$false;Number=-1;Variant='';TextureKind='';HasSkin=$false;Sex=$sex;AutoHideHair=$false;HairMode='NONE'}
}

function Get-PieceDescriptor([IO.FileInfo]$Ydd) {
    # A categoria real vem do nome do drawable. O seletor da interface agora
    # é um FILTRO de navegação, não um renomeador da peça.
    return Get-DetectedPieceDescriptor $Ydd
}

function Write-AddonBuildPlan {
    # Planejamento interno para o futuro gerador YMT/add-on.
    # Cada tipo/slot é dividido em blocos de no máximo 150 peças mantidas.
    if (-not $script:PackPath -or -not $script:Pieces) { return }
    try {
        $maxPerPack = 150
        $kept = @()
        foreach ($ydd in @($script:Pieces)) {
            if ($script:Decisions.ContainsKey($ydd.FullName) -and $script:Decisions[$ydd.FullName] -eq 'EXCLUIR') { continue }
            $d = Get-PieceDescriptor $ydd
            $vars = @(Find-Variants $ydd | Where-Object { -not $script:TextureDeletions.ContainsKey($_.File.FullName) })
            $kept += [pscustomobject]@{
                file = $ydd.FullName
                slot = $d.Slot
                source_number = $d.Number
                auto_hide_hair = $d.AutoHideHair
                hair_mode = $d.HairMode
                textures = @($vars | ForEach-Object { $_.File.FullName })
            }
        }
        $packs = @()
        foreach ($group in @($kept | Group-Object slot)) {
            $ordered = @($group.Group | Sort-Object source_number,file)
            for ($i=0; $i -lt $ordered.Count; $i += $maxPerPack) {
                $take = [Math]::Min($maxPerPack,$ordered.Count-$i)
                $packs += [pscustomobject]@{
                    slot = $group.Name
                    pack_index = [int]([Math]::Floor($i / $maxPerPack) + 1)
                    count = $take
                    pieces = @($ordered[$i..($i+$take-1)])
                }
            }
        }
        $plan = [ordered]@{
            version = 1
            max_pieces_per_slot_per_pack = $maxPerPack
            auto_hide_hair_masks = $true
            auto_hide_hair_hats = $true
            note_masks = 'berd: pedalternativevariations.meta automático'
            note_hats = 'p_head: esconder cabelo somente quando marcado'
            packs = $packs
        }
        $plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $script:PackPath '_MT_ADDON_BUILD_PLAN.json') -Encoding UTF8
    } catch { Write-AppLog ("Build plan: " + $_.Exception.ToString()) }
}

function Rescan-Pieces {
    Build-FileIndex
}


# --------------------------- UI / viewport ------------------------------------

function New-SolidBrush([string]$hex) {
    $color = [Windows.Media.ColorConverter]::ConvertFromString($hex)
    $brush = New-Object Windows.Media.SolidColorBrush $color
    $brush.Freeze()
    return $brush
}

function New-SolidMaterial([string]$hex) {
    $brush = New-SolidBrush $hex
    return (New-Object Windows.Media.Media3D.DiffuseMaterial $brush)
}

function New-TextureMaterial($bitmap) {
    # A luz clareia os pixels da textura, preservando contraste e transparência.
    # A iluminação 3D comum multiplica o preto por branco e não consegue revelar
    # uma estampa escura; ajustar gama é necessário para esse caso.
    $bitmap=[MtTextureLighting]::Brighten($bitmap,[int]$script:LightLevel)
    $brush = New-Object Windows.Media.ImageBrush
    $brush.ImageSource = $bitmap

    # MeshGeometry3D pode usar TextureCoordinates fora de 0..1.
    # Com ViewportUnits=Absolute, cada unidade UV representa um tile inteiro.
    # TileMode=Tile faz o repeat DEPOIS da interpolação, equivalente ao sampler
    # wrap do GTA/DirectX e correto para UVs como V=1.55..1.99.
    $brush.ViewportUnits = [Windows.Media.BrushMappingMode]::Absolute
    $brush.Viewport = [Windows.Rect]::new(0,0,1,1)
    $brush.ViewboxUnits = [Windows.Media.BrushMappingMode]::RelativeToBoundingBox
    $brush.Viewbox = [Windows.Rect]::new(0,0,1,1)
    $brush.TileMode = [Windows.Media.TileMode]::Tile
    $brush.Stretch = [Windows.Media.Stretch]::Fill
    $brush.AlignmentX = [Windows.Media.AlignmentX]::Left
    $brush.AlignmentY = [Windows.Media.AlignmentY]::Top
    $brush.Freeze()
    $diff = New-Object Windows.Media.Media3D.DiffuseMaterial $brush
    $group = New-Object Windows.Media.Media3D.MaterialGroup
    $group.Children.Add($diff)
    $group.Freeze()
    return $group
}

function Set-NeutralMaterial {
    $mat = New-SolidMaterial '#8D8D92'
    foreach ($entry in @($script:GeometryEntries)) {
        $entry.Model.Material = $mat
        $entry.Model.BackMaterial = $mat
    }
}

function Update-ModelTransform {
    if (-not $script:ModelRoot) { return }
    $g = New-Object Windows.Media.Media3D.Transform3DGroup
    $g.Children.Add((New-Object Windows.Media.Media3D.TranslateTransform3D (-$script:CenterX),(-$script:CenterY),(-$script:CenterZ)))
    $g.Children.Add((New-Object Windows.Media.Media3D.ScaleTransform3D $script:ModelScale,$script:ModelScale,$script:ModelScale))

    # Props da cabeça usam coordenadas locais diferentes das roupas do PED.
    # A orientação é aplicada só à prévia, nunca aos arquivos originais.
    if($script:CurrentPropSlot -in @('p_head','p_eyes','p_ears')){
        $key=[string]$script:CurrentPropSlot
        # Brincos são exportados de lado: a orientação de frente exige mais um quarto de volta.
        $defaults=if($key -eq 'p_ears'){@{Pitch=90;Yaw=90}}else{@{Pitch=90;Yaw=180}}
        # Sempre inicia na orientação padrão, sem reaplicar giros manuais antigos.
        $alignment=[pscustomobject]$defaults
        $basePitch=New-Object Windows.Media.Media3D.AxisAngleRotation3D ([Windows.Media.Media3D.Vector3D]::new(1,0,0)),([double]$alignment.Pitch)
        $baseYaw=New-Object Windows.Media.Media3D.AxisAngleRotation3D ([Windows.Media.Media3D.Vector3D]::new(0,0,1)),([double]$alignment.Yaw)
        $g.Children.Add((New-Object Windows.Media.Media3D.RotateTransform3D $basePitch))
        $g.Children.Add((New-Object Windows.Media.Media3D.RotateTransform3D $baseYaw))
    }

    $pitch = New-Object Windows.Media.Media3D.AxisAngleRotation3D ([Windows.Media.Media3D.Vector3D]::new(1,0,0)),$script:Pitch
    $yaw = New-Object Windows.Media.Media3D.AxisAngleRotation3D ([Windows.Media.Media3D.Vector3D]::new(0,0,1)),$script:Yaw
    $g.Children.Add((New-Object Windows.Media.Media3D.RotateTransform3D $pitch))
    $g.Children.Add((New-Object Windows.Media.Media3D.RotateTransform3D $yaw))
    $roll = New-Object Windows.Media.Media3D.AxisAngleRotation3D ((New-Object Windows.Media.Media3D.Vector3D 0,1,0)),$script:Roll
    $g.Children.Add((New-Object Windows.Media.Media3D.RotateTransform3D $roll))
    $g.Children.Add((New-Object Windows.Media.Media3D.TranslateTransform3D $script:ModelOffsetX,$script:ModelOffsetY,$script:ModelOffsetZ))
    $script:ModelRoot.Transform = $g
    Update-TransformBoxVisual
}

function Get-ProjectedModelBounds {
    if($null -eq $script:ModelBounds -or $null -eq $script:ModelRoot -or $null -eq $script:Camera){return $null}
    $vw=[double]$viewHost.ActualWidth
    $vh=[double]$viewHost.ActualHeight
    if($vw -lt 20 -or $vh -lt 20){return $null}
    $b=$script:ModelBounds
    $matrix=$script:ModelRoot.Transform.Value
    $tanH=[Math]::Tan((([double]$script:Camera.FieldOfView * [Math]::PI / 180.0) / 2.0))
    if($tanH -le 0){return $null}
    $aspect=$vw/$vh
    $tanV=$tanH/[Math]::Max(0.01,$aspect)
    $minX=[double]::PositiveInfinity; $minY=[double]::PositiveInfinity
    $maxX=[double]::NegativeInfinity; $maxY=[double]::NegativeInfinity
    $valid=0
    $xs=@([double]$b.X,[double]($b.X+$b.SizeX))
    $ys=@([double]$b.Y,[double]($b.Y+$b.SizeY))
    $zs=@([double]$b.Z,[double]($b.Z+$b.SizeZ))
    foreach($x in $xs){foreach($y in $ys){foreach($z in $zs){
        $p=[Windows.Media.Media3D.Point3D]::new($x,$y,$z)
        $p=$matrix.Transform($p)
        $depth=[double]$p.Y+[double]$script:CameraDistance
        if($depth -le 0.001){continue}
        $sx=($vw/2.0)+(($p.X/($depth*$tanH))*($vw/2.0))
        $sy=($vh/2.0)-(($p.Z/($depth*$tanV))*($vh/2.0))
        if([double]::IsNaN($sx) -or [double]::IsNaN($sy)){continue}
        if($sx -lt $minX){$minX=$sx}; if($sx -gt $maxX){$maxX=$sx}
        if($sy -lt $minY){$minY=$sy}; if($sy -gt $maxY){$maxY=$sy}
        $valid++
    }}}
    if($valid -eq 0){return $null}
    # O centro geométrico, ao contrário da média dos extremos projetados,
    # não salta de posição ao girar uma malha assimétrica.
    $cp=$matrix.Transform([Windows.Media.Media3D.Point3D]::new(($b.X+$b.SizeX/2.0),($b.Y+$b.SizeY/2.0),($b.Z+$b.SizeZ/2.0)))
    $cd=[Math]::Max(0.01,[double]$cp.Y+[double]$script:CameraDistance)
    $cx=($vw/2.0)+(($cp.X/($cd*$tanH))*($vw/2.0))
    $cy=($vh/2.0)-(($cp.Z/($cd*$tanV))*($vh/2.0))
    [pscustomobject]@{Left=$minX;Top=$minY;Right=$maxX;Bottom=$maxY;CenterX=$cx;CenterY=$cy}
}

function Update-Lighting {
    $value=[double]$script:LightLevel
    if($lblLightValue){$lblLightValue.Text="$([int]$value)%"}
    $channel=[byte][Math]::Round([Math]::Max(190,[Math]::Min(255,190+$value*0.65)))
    if($script:AmbientLight){$script:AmbientLight.Color=[Windows.Media.Color]::FromRgb($channel,$channel,$channel)}
    if($viewHost){$viewHost.Background=New-SolidBrush '#121218'}
    if($script:CurrentTextures -and $script:CurrentTextures.Count -gt 0 -and $script:GeometryEntries.Count -gt 0){
        Apply-TextureArray $script:CurrentTextures
    }
}

function Change-Light([int]$delta){
    $script:LightLevel=[Math]::Max(0,[Math]::Min(100,[int]$script:LightLevel+$delta))
    Update-Lighting
    Save-State
}

function Update-TransformBoxVisual {
    if($null -eq $transformBox -or -not $script:TransformBoxEnabled){return}
    $pb=Get-ProjectedModelBounds
    if($null -eq $pb){return}
    $vw=[double]$viewHost.ActualWidth; $vh=[double]$viewHost.ActualHeight
    $pad=10.0
    $left=[Math]::Max(5.0,[double]$pb.Left-$pad)
    $top=[Math]::Max(5.0,[double]$pb.Top-$pad)
    $right=[Math]::Min($vw-5.0,[double]$pb.Right+$pad)
    $bottom=[Math]::Min($vh-5.0,[double]$pb.Bottom+$pad)
    $w=[Math]::Max(36.0,$right-$left); $h=[Math]::Max(36.0,$bottom-$top)
    # A moldura segue o centro da malha mas não muda de dimensão ao girar.
    # Escala e zoom são as únicas operações que alteram seu tamanho.
    if($script:SelectionBoxWidth -gt 0 -and $script:SelectionBoxScale -gt 0 -and $script:SelectionBoxDistance -gt 0){
        $referenceDepth=[Math]::Max(0.01,[double]$script:SelectionBoxDistance+[double]$script:SelectionBoxOffsetY)
        $currentDepth=[Math]::Max(0.01,[double]$script:CameraDistance+[double]$script:ModelOffsetY)
        $factor=($script:ModelScale/$script:SelectionBoxScale)*($referenceDepth/$currentDepth)
        $w=[Math]::Max(36.0,$script:SelectionBoxWidth*$factor)
        $h=[Math]::Max(36.0,$script:SelectionBoxHeight*$factor)
    }
    $centerX=[double]$pb.CenterX; $centerY=[double]$pb.CenterY
    $transformBox.Width=$w
    $transformBox.Height=$h
    $transformBox.RenderTransform=[Windows.Media.TranslateTransform]::new($centerX-($vw/2.0),$centerY-($vh/2.0))
}

function Set-TransformBox([bool]$show) {
    $script:TransformBoxEnabled=$show
    if($show){
        if(-not $script:SelectionBoxWidth){
            $script:SelectionBoxWidth=0.0
            $script:SelectionBoxHeight=0.0
            Update-TransformBoxVisual
            $script:SelectionBoxWidth=[double]$transformBox.Width
            $script:SelectionBoxHeight=[double]$transformBox.Height
            $script:SelectionBoxScale=[double]$script:ModelScale
            $script:SelectionBoxDistance=[double]$script:CameraDistance
            $script:SelectionBoxOffsetY=[double]$script:ModelOffsetY
        }
        $transformBox.Visibility='Visible'
    }
    else{
        $transformBox.Visibility='Collapsed';$script:SelectionBoxWidth=0.0;$script:SelectionBoxHeight=0.0
        Set-TransformHover ''
    }
    Update-TransformBoxVisual
}

function Save-TransformGizmoPreview([string]$kind) {
    if($env:MT_PACK_ORGANIZER_UITEST -ne '1' -or -not $env:MT_PACK_ORGANIZER_SCREENSHOT){return}
    try {
        [void]$win.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
        $viewHost.UpdateLayout()
        $w=[int]$viewHost.ActualWidth;$h=[int]$viewHost.ActualHeight
        if($w -lt 150 -or $h -lt 150){return}
        $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap $w,$h,96,96,([Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($viewHost)
        $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $dest=$env:MT_PACK_ORGANIZER_SCREENSHOT.Replace('.png',('-gizmo-'+$kind+'.png'))
        $out=[IO.File]::Create($dest)
        try{$encoder.Save($out)}finally{$out.Dispose()}
    } catch {Write-AppLog ('Captura de gizmo '+$kind+': '+$_.Exception.Message)}
}

function Invoke-TransformGizmoSelfTest {
    $oldRoot=$script:ModelRoot;$oldCamera=$script:Camera;$oldBounds=$script:ModelBounds
    $oldDistance=$script:CameraDistance;$oldScale=$script:ModelScale
    $oldYaw=$script:Yaw;$oldPitch=$script:Pitch;$oldRoll=$script:Roll
    $oldX=$script:ModelOffsetX;$oldY=$script:ModelOffsetY;$oldZ=$script:ModelOffsetZ
    try {
        $script:ModelRoot=New-Object Windows.Media.Media3D.ModelVisual3D
        $script:ModelBounds=[Windows.Media.Media3D.Rect3D]::new(-1,-0.5,-1.4,2,1,2.8)
        $script:Camera=New-Object Windows.Media.Media3D.PerspectiveCamera
        $script:Camera.FieldOfView=45
        $script:CameraDistance=6;$script:ModelScale=1
        $script:Yaw=0;$script:Pitch=0;$script:Roll=0
        $script:ModelOffsetX=0;$script:ModelOffsetY=0;$script:ModelOffsetZ=0
        Update-ModelTransform
        # O teste deve calibrar a caixa para a câmera sintética, sem herdar
        # dimensões da peça que o fixture acabou de abrir.
        Set-TransformBox $false
        $viewHost.UpdateLayout()
        [void]$win.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
        $projectionReady=([double]$viewHost.ActualWidth -ge 150 -and [double]$viewHost.ActualHeight -ge 150 -and $null -ne (Get-ProjectedModelBounds))
        Set-TransformBox $true
        $width=[double]$transformBox.Width;$height=[double]$transformBox.Height
        if($width -lt 30 -or $height -lt 30){throw 'Caixa de seleção 3D não foi projetada.'}
        $script:Yaw=73;$script:Pitch=28;$script:Roll=41
        Update-ModelTransform
        if([Math]::Abs([double]$transformBox.Width-$width) -gt 0.01 -or [Math]::Abs([double]$transformBox.Height-$height) -gt 0.01){
            throw 'Caixa de seleção mudou de tamanho somente ao girar a peça.'
        }
        $script:ModelOffsetY=-1;Update-ModelTransform
        # Runners headless podem não montar viewport projetável antes do tick Loaded.
        # Nesse caso a projeção não deve ser inferida dos 330px de fallback do XAML.
        if($projectionReady -and [double]$transformBox.Width -le $width){throw 'Movimento em profundidade não ajustou a projeção.'}
        $zones=@(
            (Get-TransformHoverMode 8 8 330 440),
            (Get-TransformHoverMode 7 220 330 440),
            (Get-TransformHoverMode 165 7 330 440),
            (Get-TransformHoverMode 165 220 330 440)
        )
        if(($zones -join ',') -ne 'ROTATE_ROLL,ROTATE_YAW,ROTATE_PITCH,'){
            throw ('Os quadrantes não mapearam os controles do Photoshop: '+($zones -join ','))
        }
        Set-TransformHover 'ROTATE_ROLL'
        Save-TransformGizmoPreview 'cantos'
        if($hoverNW.Visibility -ne 'Visible' -or $hoverLeft.Visibility -ne 'Collapsed'){
            throw 'O hover do canto mostrou o destaque errado.'
        }
        Set-TransformHover 'ROTATE_YAW'
        Save-TransformGizmoPreview 'lateral'
        if($hoverLeft.Visibility -ne 'Visible' -or $hoverRight.Visibility -ne 'Visible' -or $hoverNW.Visibility -ne 'Collapsed'){
            throw 'As faixas verticais não substituíram os quadrados.'
        }
        Set-TransformHover 'ROTATE_PITCH'
        Save-TransformGizmoPreview 'superior'
        if($hoverTop.Visibility -ne 'Visible' -or $hoverBottom.Visibility -ne 'Visible' -or $hoverLeft.Visibility -ne 'Collapsed'){
            throw 'As faixas horizontais não substituíram as verticais.'
        }
        Set-TransformHover 'MOVE_X'
        if($centerAxisX.StrokeThickness -lt 4.5 -or $centerAxisY.StrokeThickness -ge 4.5){
            throw 'Manipulador central: seta X não foi destacada individualmente.'
        }
        Set-TransformHover 'MOVE_Y'
        if($centerAxisY.StrokeThickness -lt 4.5 -or $centerAxisZ.StrokeThickness -ge 4.5){
            throw 'Manipulador central: seta Y não foi destacada individualmente.'
        }
        Set-TransformHover 'MOVE_Z'
        if($centerAxisZ.StrokeThickness -lt 4.5){throw 'Manipulador central: seta Z não recebeu o hover.'}
        Save-TransformGizmoPreview 'centro'
        if($hoverTop.Visibility -ne 'Collapsed' -or $hoverLeft.Visibility -ne 'Collapsed'){
            throw 'O hover central não isolou os destaques das bordas.'
        }
        Set-TransformHover ''
        Save-TransformGizmoPreview 'inativo'
        if($hoverNW.Visibility -ne 'Collapsed' -or $hoverLeft.Visibility -ne 'Collapsed'){
            throw 'O gizmo continuou visível sem hover.'
        }
        Write-Host 'MT_PACK_ORGANIZER_GIZMO_SELFTEST_OK'
    } finally {
        Set-TransformBox $false;Set-TransformHover ''
        $script:ModelRoot=$oldRoot;$script:Camera=$oldCamera;$script:ModelBounds=$oldBounds
        $script:CameraDistance=$oldDistance;$script:ModelScale=$oldScale
        $script:Yaw=$oldYaw;$script:Pitch=$oldPitch;$script:Roll=$oldRoll
        $script:ModelOffsetX=$oldX;$script:ModelOffsetY=$oldY;$script:ModelOffsetZ=$oldZ
    }
}

function Update-Camera {
    if (-not $script:Camera) { return }
    $d = $script:CameraDistance
    $script:Camera.Position = [Windows.Media.Media3D.Point3D]::new(0,-$d,0)
    $script:Camera.LookDirection = [Windows.Media.Media3D.Vector3D]::new(0,$d,0)
    $script:Camera.UpDirection = [Windows.Media.Media3D.Vector3D]::new(0,0,1)
}

function Reset-View {
    $script:Yaw = 0.0
    $script:Pitch = 0.0
    $script:Roll = 0.0
    $script:ModelScale=1.0
    $script:ModelOffsetX=0.0
    $script:ModelOffsetY=0.0
    $script:ModelOffsetZ=0.0
    $script:TransformScreenX=0.0
    $script:TransformScreenY=0.0
    if ($script:BaseCameraDistance -gt 0) { $script:CameraDistance = $script:BaseCameraDistance }
    Update-ModelTransform
    Update-Camera
    Save-State
}

function Get-MeshCached([IO.FileInfo]$ydd) {
    Ensure-RuntimeCollections
    $key=[string]$ydd.FullName
    if($script:MeshCache.ContainsKey($key)){
        $script:MeshCacheOrder=@($script:MeshCacheOrder | Where-Object { [string]$_ -ne $key }) + $key
        return $script:MeshCache[$key]
    }
    $parsed=[MtRageParser]::LoadMesh($key)
    if($null -eq $parsed){throw "O parser 3D não retornou dados para $($ydd.Name)."}
    $script:MeshCache[$key]=$parsed
    $script:MeshCacheOrder=@($script:MeshCacheOrder) + $key
    # Malhas são pesadas: manter só uma pequena janela de navegação em memória.
    while(@($script:MeshCacheOrder).Count -gt 12){
        $old=[string]$script:MeshCacheOrder[0]
        $script:MeshCacheOrder=@($script:MeshCacheOrder | Select-Object -Skip 1)
        if(-not [string]::IsNullOrWhiteSpace($old)){$script:MeshCache.Remove($old)}
    }
    return $parsed
}

function Build-Viewport([IO.FileInfo]$ydd) {
    $parsed = Get-MeshCached $ydd
    $script:CurrentPropSlot=(Get-DetectedPieceDescriptor $ydd).Slot
    $firstViewport = ($null -eq $script:Camera)

    $viewport.Children.Clear()
    $scene = New-Object Windows.Media.Media3D.Model3DGroup

    $ambient = New-Object Windows.Media.Media3D.AmbientLight ([Windows.Media.ColorConverter]::ConvertFromString('#B0B0B0'))
    $script:AmbientLight=$ambient
    $key = New-Object Windows.Media.Media3D.DirectionalLight ([Windows.Media.ColorConverter]::ConvertFromString('#FFFFFF')),([Windows.Media.Media3D.Vector3D]::new(-1,1,-1))
    $fill = New-Object Windows.Media.Media3D.DirectionalLight ([Windows.Media.ColorConverter]::ConvertFromString('#777777')),([Windows.Media.Media3D.Vector3D]::new(1,-1,0.5))
    $scene.Children.Add($ambient); $scene.Children.Add($key); $scene.Children.Add($fill)

    $script:GeometryEntries = @()
    foreach ($part in @($parsed.Parts)) {
        $gm = New-Object Windows.Media.Media3D.GeometryModel3D
        $gm.Geometry = $part.Mesh
        $neutral = New-SolidMaterial '#8D8D92'
        $gm.Material = $neutral
        $gm.BackMaterial = $neutral
        $scene.Children.Add($gm)
        $script:GeometryEntries += [pscustomobject]@{
            Model = $gm
            RenderBucket = [int]$part.RenderBucket
            DiffuseTexture = [string]$part.DiffuseTexture
            ShaderId = [int]$part.ShaderId
            UvType = [int]$part.UvType
            UvOffset = [int]$part.UvOffset
        }
    }

    $script:ModelRoot = New-Object Windows.Media.Media3D.ModelVisual3D
    $script:ModelRoot.Content = $scene
    $viewport.Children.Add($script:ModelRoot)

    $b = $parsed.Bounds
    $script:ModelBounds = $b
    $script:CenterX = $b.X + $b.SizeX/2
    $script:CenterY = $b.Y + $b.SizeY/2
    $script:CenterZ = $b.Z + $b.SizeZ/2

    $maxDim = [Math]::Max($b.SizeX,[Math]::Max($b.SizeY,$b.SizeZ))
    if ($maxDim -lt 0.05) { $maxDim = 0.5 }
    $script:ModelExtent=$maxDim
    $script:BaseCameraDistance = $maxDim * 3.05
    # Trocar de peça não redefine enquadramento, escala nem orientação escolhidos.
    if ($firstViewport) {
        $script:CameraDistance = $script:BaseCameraDistance
        if($script:SavedView) {
            $v=$script:SavedView
            $script:Yaw=[double]$v.yaw;$script:Pitch=[double]$v.pitch;$script:Roll=[double]$v.roll
            if([double]$v.scale -gt 0){$script:ModelScale=[double]$v.scale}
            $script:ModelOffsetX=[double]$v.offset_x;$script:ModelOffsetY=[double]$v.offset_y;$script:ModelOffsetZ=[double]$v.offset_z
            if([double]$v.camera_distance -gt 0){$script:CameraDistance=[double]$v.camera_distance}
            if($null -ne $v.light_level){$script:LightLevel=[int]$v.light_level}
            $script:SavedView=$null
        }
    }
    if($transformBox){$transformBox.Visibility='Collapsed';$script:TransformBoxEnabled=$false;$script:SelectionBoxWidth=0.0;$script:SelectionBoxHeight=0.0}

    if ($firstViewport) { $script:Camera = New-Object Windows.Media.Media3D.PerspectiveCamera }
    $script:Camera.FieldOfView = 36
    $viewport.Camera = $script:Camera
    Update-ModelTransform
    Update-Camera
    $script:CurrentTextures=@()
    Update-Lighting
    Set-NeutralMaterial

    $lblMesh.Text = "$($parsed.Vertices) vértices  •  $($parsed.Triangles) triângulos"

}

function Get-TextureInfosCached([IO.FileInfo]$file) {
    Ensure-RuntimeCollections
    $key = [string]$file.FullName + '|' + [string]$file.Length + '|' + [string]$file.LastWriteTimeUtc.Ticks
    if ($script:TextureInfoCache.ContainsKey($key)) { return $script:TextureInfoCache[$key] }
    $arr = @([MtRageParser]::LoadTextureInfos($file.FullName))
    $script:TextureInfoCache[$key] = $arr
    if($script:TextureInfoCache.Count -gt 256){
        $oldest=@($script:TextureInfoCache.Keys | Select-Object -First 64)
        foreach($old in $oldest){if($old -ne $key){$script:TextureInfoCache.Remove($old)}}
    }
    return $arr
}

function Load-ThumbnailForItem($item) {
    if($null -eq $item -or $null -eq $item.Tag){return}
    try {
        $file=New-Object IO.FileInfo ([string]$item.Tag)
        $textures=@(Get-TexturesCached $file)
        if($textures.Count -eq 0){return}
        $grid=$item.Content
        if($null -eq $grid -or $grid.Children.Count -lt 1){return}
        $thumbBorder=$grid.Children[0]
        $img=New-Object Windows.Controls.Image
        $img.Source=$textures[0].Bitmap
        $img.Stretch=[Windows.Media.Stretch]::Uniform
        $img.Margin=2
        $thumbBorder.Child=$img
    } catch { Write-AppLog ('Thumbnail lazy: '+$_.Exception.Message) }
}

function Show-TexturePreview($item,$target) {
    if($null -eq $item -or $null -eq $item.Tag -or $null -eq $target){return}
    try {
        $file=New-Object IO.FileInfo ([string]$item.Tag)
        $textures=@(Get-TexturesCached $file)
        if($textures.Count -eq 0){return}
        $t=$textures[0]
        $imgTexturePreview.Source=$t.Bitmap
        $lblTexturePreviewName.Text=$file.Name
        $fmt=Get-PixelFormatName ([uint32]$t.Format)
        $lblTexturePreviewMeta.Text="$fmt  •  $($t.Width)×$($t.Height)"
        $texturePreviewPopup.PlacementTarget=$target
        $texturePreviewPopup.Placement=[Windows.Controls.Primitives.PlacementMode]::Right
        $texturePreviewPopup.HorizontalOffset=10
        $texturePreviewPopup.VerticalOffset=-20
        # Não recria o popup enquanto o cursor continua na mesma miniatura.
        if (-not $texturePreviewPopup.IsOpen) { $texturePreviewPopup.IsOpen=$true }
        Load-ThumbnailForItem $item
    } catch { Write-AppLog ('Preview hover: '+$_.Exception.Message) }
}

function Hide-TexturePreview {
    if($texturePreviewPopup){$texturePreviewPopup.IsOpen=$false}
}

function Get-TexturesCached([IO.FileInfo]$file) {
    Ensure-RuntimeCollections
    $key = [string]$file.FullName + '|' + [string]$file.Length + '|' + [string]$file.LastWriteTimeUtc.Ticks
    if ($script:TextureCache.ContainsKey($key)) {
        $script:TextureCacheOrder=@($script:TextureCacheOrder | Where-Object { [string]$_ -ne $key }) + $key
        return $script:TextureCache[$key]
    }
    $arr = @([MtRageParser]::LoadTextures([string]$file.FullName))
    $script:TextureCache[$key] = $arr
    $cost=[long]0
    foreach($t in $arr){$cost += ([long]$t.Width)*([long]$t.Height)*4L}
    $script:TextureCacheCost[$key]=$cost
    $script:TextureCacheBytes=[long]$script:TextureCacheBytes+$cost
    $script:TextureCacheOrder=@($script:TextureCacheOrder) + $key
    # 192 MB de texturas decodificadas por padrão, sem descartar a textura atual.
    # Evita que centenas de variações de packs grandes esgotem a RAM.
    $limit=[long](192*1024*1024)
    while(@($script:TextureCacheOrder).Count -gt 1 -and
        (@($script:TextureCacheOrder).Count -gt 12 -or [long]$script:TextureCacheBytes -gt $limit)) {
        $oldKey=[string]$script:TextureCacheOrder[0]
        $script:TextureCacheOrder=@($script:TextureCacheOrder | Select-Object -Skip 1)
        if(-not [string]::IsNullOrWhiteSpace($oldKey)){
            $script:TextureCache.Remove($oldKey)
            if($script:TextureCacheCost.ContainsKey($oldKey)){
                $script:TextureCacheBytes=[Math]::Max([long]0,[long]$script:TextureCacheBytes-[long]$script:TextureCacheCost[$oldKey])
                $script:TextureCacheCost.Remove($oldKey)
            }
        }
    }
    return $arr
}

function Find-TextureForGeometry($textures, [string]$name) {
    if ($textures.Count -eq 0) { return $null }

    # Em packs add-on, o arquivo externo pode ter sido renumerado mas o nome
    # interno da textura continuar apontando para a peça original. O GRZY usa
    # a variação externa como diffuse. Se a YTD selecionada tem só uma textura,
    # ela é o override correto para todo geometry que possui diffuse sampler.
    if ($textures.Count -eq 1) { return $textures[0] }

    if (-not [string]::IsNullOrWhiteSpace($name)) {
        foreach ($tex in $textures) {
            if ([string]::Equals([string]$tex.Name,$name,[StringComparison]::OrdinalIgnoreCase)) { return $tex }
        }
    }
    $diffuse = @($textures | Where-Object { $_.Usage -eq 20 })
    if ($diffuse.Count -eq 1) { return $diffuse[0] }
    $named = @($textures | Where-Object { ([string]$_.Name) -match '(?i)diff|albedo|basecolor' })
    if ($named.Count -gt 0) { return $named[0] }
    return $textures[0]
}

function Apply-TextureArray($textures) {
    $script:CurrentTextures=@($textures)
    $script:MaterialBitmapCache = @{}
    foreach ($entry in @($script:GeometryEntries)) {
        $tex = Find-TextureForGeometry $textures $entry.DiffuseTexture
        if ($null -eq $tex) {
            $neutral = New-SolidMaterial '#8D8D92'
            $entry.Model.Material = $neutral; $entry.Model.BackMaterial = $neutral; continue
        }
        $cacheKey = ([string]$tex.Name) + '|' + [string]$entry.RenderBucket
        if (-not $script:MaterialBitmapCache.ContainsKey($cacheKey)) {
            $bmp = [MtRageParser]::BitmapForRenderBucket($tex.Bitmap,[int]$entry.RenderBucket)
            $script:MaterialBitmapCache[$cacheKey] = New-TextureMaterial $bmp
        }
        $mat = $script:MaterialBitmapCache[$cacheKey]
        $entry.Model.Material = $mat; $entry.Model.BackMaterial = $mat
    }
    $main = if ($textures.Count -gt 0) { $textures[0] } else { $null }
    if ($main) {
        $fmt = Get-PixelFormatName ([uint32]$main.Format)
        $lblTextureInfo.Text = "$($main.Width)×$($main.Height)  •  $fmt  •  $($main.Name)"
    }
}

function Apply-TextureItem($item) {
    if ($null -eq $item -or $null -eq $item.Tag -or [string]::IsNullOrWhiteSpace([string]$item.Tag)) { return }
    $file = New-Object IO.FileInfo ([string]$item.Tag)
    try {
        $textures = @(Get-TexturesCached $file)
        Apply-TextureArray $textures
    } catch {
        Write-AppLog $_.Exception.ToString(); $lblTextureInfo.Text = 'Não foi possível abrir esta YTD'; Set-NeutralMaterial
    }
}

function Start-ThumbnailQueue {
    param([object[]]$Items)
    if($script:ThumbTimer){ try{$script:ThumbTimer.Stop()}catch{} }
    $script:ThumbQueue=@($Items | Where-Object { $_ -and $_.Tag })
    $script:ThumbQueueIndex=0
    if($script:ThumbQueue.Count -eq 0){ return }

    # DispatcherTimer sem closure local: sempre trabalha na fila atual.
    $timer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background)
    $timer.Interval=[TimeSpan]::FromMilliseconds(240)
    $timer.Add_Tick({
        if($script:ThumbQueueIndex -ge @($script:ThumbQueue).Count){
            try{$script:ThumbTimer.Stop()}catch{}
            return
        }
        $it=$script:ThumbQueue[$script:ThumbQueueIndex]
        $script:ThumbQueueIndex++
        try{ Load-ThumbnailForItem $it }catch{ Write-AppLog ('Thumbnail queue: '+$_.Exception.Message) }
    })
    $script:ThumbTimer=$timer
    $timer.Start()
}

function Populate-Textures([IO.FileInfo]$ydd) {
    $script:PopulatingTextures = $true
    try {
        $lstTextures.Items.Clear()
        $vars = @(Find-Variants $ydd)
        if ($vars.Count -eq 0) {
            # PEDs e alguns acessórios possuem texturas embutidas no próprio YDD.
            # Aplicamos essas texturas sem oferecê-las para exclusão individual.
            try {
                $embedded=@([MtRageParser]::LoadEmbeddedTextures($ydd.FullName))
                if($embedded.Count -gt 0){
                    Apply-TextureArray $embedded
                    $empty=New-Object Windows.Controls.ListBoxItem
                    $empty.Content="Texturas incorporadas ao PED ($($embedded.Count))"
                    $empty.IsEnabled=$false
                    [void]$lstTextures.Items.Add($empty)
                    $lblTextureCount.Text="$($embedded.Count) TEXTURAS EMBUTIDAS"
                    return
                }
            } catch { Write-AppLog ('Texturas embutidas '+$ydd.Name+': '+$_.Exception.Message) }
            $empty = New-Object Windows.Controls.ListBoxItem
            $empty.Content = 'Sem texturas associadas'
            $empty.IsEnabled = $false
            $lstTextures.Items.Add($empty) | Out-Null
            $lblTextureCount.Text = '0 TEXTURAS'
            Set-NeutralMaterial
            $lblTextureInfo.Text = ''
            return
        }

        foreach ($v in $vars) {
            $item = New-Object Windows.Controls.ListBoxItem
            $item.Tag = $v.File.FullName

            $grid = New-Object Windows.Controls.Grid
            $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = '48'
            $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '38'
            $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = '*'
            $grid.ColumnDefinitions.Add($c0); $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)

            # Miniatura em carregamento preguiçoso: o pack abre primeiro; as imagens entram depois.
            $thumbBorder = New-Object Windows.Controls.Border
            $thumbBorder.Width = 42; $thumbBorder.Height = 42; $thumbBorder.CornerRadius = 6
            $thumbBorder.Background = New-SolidBrush '#0E0D10'
            $thumbBorder.BorderBrush = New-SolidBrush '#3A3540'; $thumbBorder.BorderThickness = 1
            $thumbBorder.Margin = '0,0,6,0'
            $ph = New-Object Windows.Controls.TextBlock
            $ph.Text='•'; $ph.Foreground=New-SolidBrush '#6E347E'; $ph.FontSize=20
            $ph.HorizontalAlignment='Center'; $ph.VerticalAlignment='Center'
            $thumbBorder.Child=$ph
            [Windows.Controls.Grid]::SetColumn($thumbBorder,0)

            $badge = New-Object Windows.Controls.Border
            $badge.Width = 30; $badge.Height = 30; $badge.CornerRadius = 7
            $badge.Background = New-SolidBrush '#2A2038'; $badge.Margin = '0,6,8,0'
            $letter = New-Object Windows.Controls.TextBlock
            $letter.Text = $v.Letter; $letter.FontWeight = 'Bold'; $letter.FontSize = 13
            $letter.Foreground = [Windows.Media.Brushes]::White
            $letter.HorizontalAlignment = 'Center'; $letter.VerticalAlignment = 'Center'
            $badge.Child = $letter
            [Windows.Controls.Grid]::SetColumn($badge,1)

            $info = New-Object Windows.Controls.StackPanel
            $info.VerticalAlignment = 'Center'
            $name = New-Object Windows.Controls.TextBlock
            $name.Text = $v.File.Name; $name.TextTrimming = 'CharacterEllipsis'
            $name.Foreground = New-SolidBrush '#D6D1DB'; $name.FontSize = 10.5
            $meta = New-Object Windows.Controls.TextBlock
            $meta.Foreground = New-SolidBrush '#817A89'; $meta.FontSize = 9; $meta.Margin = '0,3,0,0'
            try {
                $previewInfos = @(Get-TextureInfosCached $v.File)
                if ($previewInfos.Count -gt 0) {
                    $p = $previewInfos[0]
                    $fmt = Get-PixelFormatName ([uint32]$p.Format)
                    $rel = if ($v.IsRelative) { '  •  WHI / RELATIVA' } else { '  •  UNI' }
                    $meta.Text = "$fmt  •  $($p.Width)×$($p.Height)$rel"
                } else { $meta.Text = $(if($v.IsRelative){'WHI / RELATIVA'}else{'UNI'}) }
            } catch { $meta.Text = $(if($v.IsRelative){'WHI / RELATIVA'}else{'UNI'}) }
            $info.Children.Add($name) | Out-Null; $info.Children.Add($meta) | Out-Null
            [Windows.Controls.Grid]::SetColumn($info,2)

            if ($script:TextureDeletions.ContainsKey($v.File.FullName)) {
                $item.Background = New-SolidBrush '#2B181D'; $item.BorderBrush = New-SolidBrush '#9B4D55'
                $name.TextDecorations = [Windows.TextDecorations]::Strikethrough; $name.Foreground = New-SolidBrush '#FF9CA4'
            }

            $grid.Children.Add($thumbBorder) | Out-Null; $grid.Children.Add($badge) | Out-Null; $grid.Children.Add($info) | Out-Null
            $localItem=$item; $localThumb=$thumbBorder
            $thumbBorder.Cursor=[Windows.Input.Cursors]::Hand
            $thumbBorder.Add_MouseEnter({ Show-TexturePreview $localItem $localThumb }.GetNewClosure())
            $thumbBorder.Add_MouseLeave({ Hide-TexturePreview })
            $item.Content = $grid
            $lstTextures.Items.Add($item) | Out-Null
        }

        $lblTextureCount.Text = "$($vars.Count) " + $(if($vars.Count -eq 1){'TEXTURA'}else{'TEXTURAS'})
        $lstTextures.SelectedIndex = 0
    } finally {
        $script:PopulatingTextures = $false
    }
    if ($lstTextures.SelectedItem) {
        Apply-TextureItem $lstTextures.SelectedItem
        # A primeira miniatura reutiliza a textura já decodificada para o 3D.
        try { Load-ThumbnailForItem $lstTextures.SelectedItem } catch {}
    }
    Start-ThumbnailQueue @($lstTextures.Items | Select-Object -Skip 1)
    Update-TextureDeleteButton

}

function Update-TextureDeleteButton {
    if ($null -eq $btnDeleteTexture) { return }
    $item = $lstTextures.SelectedItem
    if ($null -eq $item -or $null -eq $item.Tag -or [string]::IsNullOrWhiteSpace([string]$item.Tag)) {
        $btnDeleteTexture.IsEnabled = $false
        $btnDeleteTexture.Content = 'EXCLUIR TEXTURA SELECIONADA'
        return
    }
    $path = [string]$item.Tag
    $btnDeleteTexture.IsEnabled = $true
    if ($script:TextureDeletions.ContainsKey($path)) {
        $btnDeleteTexture.Content = 'CANCELAR EXCLUSÃO DA TEXTURA'
    } else {
        $btnDeleteTexture.Content = 'EXCLUIR TEXTURA SELECIONADA'
    }
}

function Toggle-TextureDelete {
    $item = $lstTextures.SelectedItem
    if ($null -eq $item -or $null -eq $item.Tag) { return }
    $path = [string]$item.Tag
    if ([string]::IsNullOrWhiteSpace($path)) { return }

    if ($script:TextureDeletions.ContainsKey($path)) {
        $script:TextureDeletions.Remove($path)
    } else {
        $script:TextureDeletions[$path] = $true
    }
    Save-State

    # Recria a lista para mostrar imediatamente a textura marcada/desmarcada.
    $ydd = $script:Pieces[$script:Index]
    $selectedPath = $path
    try { Populate-Textures $ydd }
    catch {
        Write-AppLog ('Falha ao carregar texturas '+$ydd.FullName+': '+$_.Exception.ToString())
        $lstTextures.Items.Clear();$lblTextureCount.Text='0 TEXTURAS'
        $lblTextureInfo.Text='Não foi possível ler as texturas desta peça.'
    }
    foreach ($it in @($lstTextures.Items)) {
        if ($it.Tag -and ([string]$it.Tag -eq $selectedPath)) { $lstTextures.SelectedItem = $it; break }
    }
    Update-TextureDeleteButton
}

function Update-Stats {
    $keep = 0; $del = 0
    foreach ($v in $script:Decisions.Values) {
        if ($v -eq 'MANTER') { $keep++ }
        elseif ($v -eq 'EXCLUIR') { $del++ }
    }
    $done = $keep + $del
    $lblKeepCount.Text = [string]$keep
    $lblDeleteCount.Text = [string]$del
    $lblDone.Text = "$done / $($script:Pieces.Count)"
    if ($script:Pieces.Count -gt 0) { $progress.Value = (100.0 * $done / $script:Pieces.Count) } else { $progress.Value = 0 }
}

function Update-Decision {
    if ($script:Pieces.Count -eq 0) { $lblDecision.Text='PENDENTE'; return }
    $p = $script:Pieces[$script:Index].FullName
    $status = if ($script:Decisions.ContainsKey($p)) { $script:Decisions[$p] } else { 'PENDENTE' }
    $lblDecision.Text = $status
    if ($status -eq 'MANTER') { $decisionDot.Fill = New-SolidBrush '#A78BFA' }
    elseif ($status -eq 'EXCLUIR') { $decisionDot.Fill = New-SolidBrush '#E16B73' }
    else { $decisionDot.Fill = New-SolidBrush '#6B6570' }
}

function Get-FilteredPieceIndices {
    if($script:Pieces.Count -eq 0){ return @() }
    $filter=[string]$script:SelectedCategoryFilter
    if([string]::IsNullOrWhiteSpace($filter) -or $filter -eq 'all'){
        return @(0..($script:Pieces.Count-1))
    }
    $out=@()
    for($i=0;$i -lt $script:Pieces.Count;$i++){
        $d=Get-DetectedPieceDescriptor $script:Pieces[$i]
        if($d.Slot -eq $filter){ $out += $i }
    }
    return @($out)
}

function Load-CurrentPiece {
    if ($script:Pieces.Count -eq 0) { return }
    $ydd = $script:Pieces[$script:Index]

    $pieceNumber = Get-PieceDisplayNumber $ydd
    $lblPieceIndex.Text = "$pieceNumber / {0:D4}" -f ([Math]::Max(0,$script:Pieces.Count-1))
    $lblPieceName.Text = $ydd.Name
    $relative = $ydd.FullName.Substring($script:PackPath.Length).TrimStart('\')
    $lblPiecePath.Text = $relative
    $desc = Get-DetectedPieceDescriptor $ydd
    $script:UpdatingPieceOptions=$true
    try {
        if($desc.Slot -eq 'berd' -or $desc.Slot -eq 'p_head'){
            $chkHideHair.Visibility='Visible'
            $chkHideHair.IsChecked=($script:HideHairSelections.ContainsKey($ydd.FullName) -and [bool]$script:HideHairSelections[$ydd.FullName])
        } else {
            $chkHideHair.Visibility='Collapsed'
            $chkHideHair.IsChecked=$false
        }
        $lblDetectedCategory.Text = "DETECTADA: " + (($script:CategoryItems | Where-Object {$_.Key -eq $desc.Slot} | Select-Object -First 1).Display)
        if([string]::IsNullOrWhiteSpace($lblDetectedCategory.Text) -or $lblDetectedCategory.Text -eq 'DETECTADA: '){$lblDetectedCategory.Text='DETECTADA: '+$desc.Slot.ToUpperInvariant()}
    } finally { $script:UpdatingPieceOptions=$false }

    $indices=@(Get-FilteredPieceIndices)
    $pos=-1
    for($j=0;$j -lt $indices.Count;$j++){if([int]$indices[$j] -eq [int]$script:Index){$pos=$j;break}}
    if($pos -lt 0){$pos=0}
    $btnPrev.IsEnabled = ($indices.Count -gt 0 -and $pos -gt 0)
    $btnFirst.IsEnabled = $btnPrev.IsEnabled
    $btnNext.IsEnabled = ($indices.Count -gt 0 -and $pos -lt $indices.Count-1)
    $btnLast.IsEnabled = $btnNext.IsEnabled

    try { Build-Viewport $ydd }
    catch {
        # Um drawable inválido não deve impedir a revisão das outras peças.
        Write-AppLog ('Falha ao carregar malha '+$ydd.FullName+': '+$_.Exception.ToString())
        $viewport.Children.Clear();$script:ModelRoot=$null;$script:ModelBounds=$null
        $lblMesh.Text='Não foi possível visualizar esta peça (arquivo inválido ou incompatível).'
    }
    try { Populate-Textures $ydd }
    catch {
        Write-AppLog ('Falha ao carregar texturas '+$ydd.FullName+': '+$_.Exception.ToString())
        $lstTextures.Items.Clear();$lblTextureCount.Text='0 TEXTURAS'
        $lblTextureInfo.Text='Não foi possível ler as texturas desta peça.'
    }
    Update-Decision
    Update-Stats
    Save-State
}

function Go-FirstPiece {
    $indices=@(Get-FilteredPieceIndices)
    if($indices.Count -eq 0){return}
    $script:Index=[int]$indices[0]
    Load-CurrentPiece
}

function Go-LastPiece {
    $indices=@(Get-FilteredPieceIndices)
    if($indices.Count -eq 0){return}
    $script:Index=[int]$indices[$indices.Count-1]
    Load-CurrentPiece
}

function Navigate-Piece([int]$delta) {
    $indices=@(Get-FilteredPieceIndices)
    if($indices.Count -eq 0){return}
    $pos=-1
    for($j=0;$j -lt $indices.Count;$j++){ if([int]$indices[$j] -eq [int]$script:Index){$pos=$j;break} }
    if($pos -lt 0){$pos=0}
    $newPos=[Math]::Max(0,[Math]::Min($indices.Count-1,$pos+$delta))
    $new=[int]$indices[$newPos]
    if($new -eq $script:Index){return}
    $script:Index=$new
    Load-CurrentPiece
}

function Go-NextPendingPiece {
    if($lblPendingJump){$lblPendingJump.Text=''}
    # Localiza a primeira peça sem decisão na ordem integral do pack.
    # A categoria selecionada anteriormente não altera a busca.
    if($script:Pieces.Count -eq 0){return}
    for($target=0;$target -lt $script:Pieces.Count;$target++){
        $path=$script:Pieces[$target].FullName
        if(-not $script:Decisions.ContainsKey($path) -or [string]$script:Decisions[$path] -eq 'PENDENTE'){
            if($cmbCategory.SelectedValue -ne 'all'){$cmbCategory.SelectedValue='all'}
            $script:Index=$target
            Load-CurrentPiece
            return
        }
    }
    if($lblPendingJump){$lblPendingJump.Text='Todas as peças do pack foram revisadas.'}
}

function Mark-Current([string]$value) {
    if ($script:Pieces.Count -eq 0) { return }
    $p = $script:Pieces[$script:Index].FullName
    $previous = if($script:Decisions.ContainsKey($p)){$script:Decisions[$p]}else{$null}
    $script:LastAction = [pscustomobject]@{ Path=$p; Previous=$previous; Index=$script:Index }
    $script:Decisions[$p] = $value
    Save-State
    Update-Stats

    $indices=@(Get-FilteredPieceIndices)
    $pos=-1
    for($j=0;$j -lt $indices.Count;$j++){if([int]$indices[$j] -eq [int]$script:Index){$pos=$j;break}}
    if($pos -ge 0 -and $pos -lt $indices.Count-1){
        $script:Index=[int]$indices[$pos+1]
        Load-CurrentPiece
    } else { Update-Decision }
}

function Undo-Last {
    if (-not $script:LastAction) { return }
    $a = $script:LastAction
    if ($null -eq $a.Previous -or $a.Previous -eq '') { $script:Decisions.Remove($a.Path) }
    else { $script:Decisions[$a.Path] = $a.Previous }
    $script:Index = [int]$a.Index
    $script:LastAction = $null
    Save-State
    Load-CurrentPiece
}

function Set-Loading([bool]$show,[string]$message='Preparando pack...') {
    if($null -eq $loadingOverlay){return}
    if($show){
        Clear-ProjectModalEffects
        $lblLoading.Text=$message
        if($lblLoadingActivity){$lblLoadingActivity.Text='Preparando os arquivos do projeto...'}
        if($loadingProgress){$loadingProgress.Value=0}
        if($lblLoadingPercent){$lblLoadingPercent.Text='LOCALIZANDO ARQUIVOS'}
        $loadingOverlay.Visibility='Visible'
        $btnNewProject.IsEnabled=$false
        [void]$win.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
    } else {
        $loadingOverlay.Visibility='Collapsed'
        $btnNewProject.IsEnabled=$true
    }
}

function Update-LoadingActivity([string]$message,[int]$completed=-1,[int]$total=0) {
    if($null -eq $loadingOverlay -or $loadingOverlay.Visibility -ne 'Visible'){return}
    if($lblLoadingActivity){$lblLoadingActivity.Text=$message}
    if($completed -ge 0 -and $total -gt 0){
        $percent=[Math]::Min(100,[Math]::Max(0,[int][Math]::Floor(100.0*$completed/$total)))
        if($loadingProgress){$loadingProgress.Value=$percent}
        if($lblLoadingPercent){$lblLoadingPercent.Text="$percent%  •  $completed / $total arquivos"}
    }
    [void]$win.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
}

function Convert-AppVersion([string]$value) {
    try {
        $clean=(([string]$value).Trim() -replace '^[vV]','')
        $parts=@($clean -split '\.')
        while($parts.Count -lt 4){$parts += '0'}
        return [Version](($parts[0..3] -join '.'))
    } catch { return [Version]'0.0.0.0' }
}

function Get-LatestRelease {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $uri="https://api.github.com/repos/$($script:UpdateRepo)/releases/latest"
    $headers=@{'User-Agent'='MT-Pack-Organizer';'Accept'='application/vnd.github+json'}
    return Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 15
}

function Install-ReleaseUpdate($release) {
    if($null -eq $release){return}
    $asset=@($release.assets | Where-Object { ([string]$_.name) -match '(?i)^MT_Pack_Organizer_Setup_.*\.exe$' } | Select-Object -First 1)
    if($asset.Count -eq 0){
        Show-Error 'A release mais recente não possui o instalador MT_Pack_Organizer_Setup_*.exe nos Assets.'
        return
    }
    $tag=[string]$release.tag_name
    $safeTag=($tag -replace '[^0-9A-Za-z._-]','_')
    $dest=Join-Path ([IO.Path]::GetTempPath()) ("MT_Pack_Organizer_Update_$safeTag.exe")
    Set-Loading $true "BAIXANDO ATUALIZAÇÃO $tag..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc=New-Object Net.WebClient
        $wc.Headers['User-Agent']='MT-Pack-Organizer'
        $wc.DownloadFile([string]$asset.browser_download_url,$dest)
        if(-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 100000){throw 'O instalador baixado parece incompleto.'}
        Start-Process -FilePath $dest -ArgumentList @('--waitpid',[string]$PID)
        $win.Close()
    } catch {
        Write-AppLog ('Update download: '+$_.Exception.ToString())
        Show-Error ("Não consegui baixar a atualização.`n`n"+$_.Exception.Message)
    } finally { Set-Loading $false }
}

function Set-UpdateArrowFromRelease($release) {
    if($null -eq $btnUpdate){return}
    try {
        if($null -eq $release){$script:PendingUpdateRelease=$null;$btnUpdate.Visibility='Collapsed';return}
        $latest=Convert-AppVersion ([string]$release.tag_name)
        $current=Convert-AppVersion $script:AppVersion
        if($latest -gt $current){
            $script:PendingUpdateRelease=$release
            $btnUpdate.ToolTip="Atualização $($release.tag_name) disponível"
            $btnUpdate.Visibility='Visible'
        } else {
            $script:PendingUpdateRelease=$null
            $btnUpdate.Visibility='Collapsed'
        }
    } catch {
        $script:PendingUpdateRelease=$null
        $btnUpdate.Visibility='Collapsed'
        Write-AppLog ('Update result: '+$_.Exception.Message)
    }
}

function Start-SilentUpdateCheck {
    try {
        if($script:UpdateJob){return}
        $repo=[string]$script:UpdateRepo
        $script:UpdateJob=Start-Job -ArgumentList $repo -ScriptBlock {
            param($repo)
            [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
            $uri="https://api.github.com/repos/$repo/releases/latest"
            $headers=@{'User-Agent'='MT-Pack-Organizer';'Accept'='application/vnd.github+json'}
            Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 10
        }
        $script:UpdateTimer=New-Object Windows.Threading.DispatcherTimer
        $script:UpdateTimer.Interval=[TimeSpan]::FromMilliseconds(500)
        $script:UpdateTimer.Add_Tick({
            try {
                if($null -eq $script:UpdateJob){$script:UpdateTimer.Stop();return}
                $state=[string]$script:UpdateJob.State
                if($state -eq 'Completed'){
                    $release=Receive-Job $script:UpdateJob -ErrorAction SilentlyContinue | Select-Object -First 1
                    Remove-Job $script:UpdateJob -Force -ErrorAction SilentlyContinue
                    $script:UpdateJob=$null
                    $script:UpdateTimer.Stop()
                    Set-UpdateArrowFromRelease $release
                } elseif($state -eq 'Failed' -or $state -eq 'Stopped'){
                    Remove-Job $script:UpdateJob -Force -ErrorAction SilentlyContinue
                    $script:UpdateJob=$null
                    $script:UpdateTimer.Stop()
                    $btnUpdate.Visibility='Collapsed'
                }
            } catch {
                try{$script:UpdateTimer.Stop()}catch{}
                $btnUpdate.Visibility='Collapsed'
                Write-AppLog ('Silent update check: '+$_.Exception.Message)
            }
        })
        $script:UpdateTimer.Start()
    } catch {
        $btnUpdate.Visibility='Collapsed'
        Write-AppLog ('Silent update startup: '+$_.Exception.Message)
    }
}

function Confirm-And-InstallUpdate {
    $release=$script:PendingUpdateRelease
    if($null -eq $release){$btnUpdate.Visibility='Collapsed';return}
    $tag=[string]$release.tag_name
    $modal=New-ProjectModal 'Atualização disponível' "Uma nova versão do MT Pack Organizer está pronta para instalar." 495 300
    $dialog=$modal.Window
    $version=New-Object Windows.Controls.TextBlock
    $version.Text="NOVA VERSÃO  $tag";$version.FontSize=15;$version.FontWeight='Bold'
    $version.Foreground=New-SolidBrush '#DCA1FC';$version.Margin='0,0,0,12'
    [void]$modal.Content.Children.Add($version)
    $info=New-Object Windows.Controls.TextBlock
    $info.Text='Ao confirmar, o aplicativo será fechado e reaberto após a atualização.'
    $info.TextWrapping='Wrap';$info.FontSize=12;$info.Foreground=New-SolidBrush '#BBB2C2'
    [void]$modal.Content.Children.Add($info)
    $cancel=New-ModalButton 'AGORA NÃO'
    $install=New-ModalButton 'ATUALIZAR AGORA' $true
    $install.Width=158
    $cancel.Add_Click({$dialog.DialogResult=$false}.GetNewClosure())
    $install.Add_Click({$dialog.DialogResult=$true}.GetNewClosure())
    [void]$modal.Footer.Children.Add($cancel)
    [void]$modal.Footer.Children.Add($install)
    $dialog.Add_ContentRendered({Save-ModalPreview $dialog 'update'}.GetNewClosure())
    if($env:MT_PACK_ORGANIZER_UITEST -eq '1'){
        [void]$dialog.Dispatcher.BeginInvoke([Action]{
            $cancel.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }.GetNewClosure(),[Windows.Threading.DispatcherPriority]::Loaded)
    }
    if((Show-ProjectModal $dialog) -eq $true){Install-ReleaseUpdate $release}
}

function Select-PackFolder {
    $modal=New-ProjectModal 'Abrir um pack' 'Localize a pasta stream do pack ou cole o caminho da pasta abaixo.' 650 640
    $dialog=$modal.Window
    $state=[pscustomobject]@{Path='';Chosen=''}
    $toolbar=New-Object Windows.Controls.StackPanel
    $toolbar.Orientation='Horizontal';$toolbar.Margin='0,0,0,12'
    $back=New-ModalButton '↑  VOLTAR'
    $back.Width=115;$back.Margin='0,0,8,0'
    $pc=New-ModalButton 'ESTE COMPUTADOR';$pc.Width=170;$pc.Margin='0'
    [void]$toolbar.Children.Add($back);[void]$toolbar.Children.Add($pc)
    [void]$modal.Content.Children.Add($toolbar)
    $pathBox=New-Object Windows.Controls.TextBox
    $pathBox.Height=39;$pathBox.FontSize=12;$pathBox.Padding='11,8'
    $pathBox.Background=New-SolidBrush '#1C1922';$pathBox.Foreground=New-SolidBrush '#FFFFFF'
    $pathBox.BorderBrush=New-SolidBrush '#50415D';$pathBox.Margin='0,0,0,12'
    $pathBox.ToolTip='Digite ou cole o caminho completo de uma pasta e pressione Enter'
    [void]$modal.Content.Children.Add($pathBox)
    $folderList=New-Object Windows.Controls.ListBox
    $folderList.Height=300;$folderList.DisplayMemberPath='Name';$folderList.FontSize=13
    $folderList.Background=New-SolidBrush '#17151C';$folderList.Foreground=New-SolidBrush '#F1EAF7'
    $folderList.BorderBrush=New-SolidBrush '#322939';$folderList.Padding='9'
    [void]$modal.Content.Children.Add($folderList)
    $tip=New-Object Windows.Controls.TextBlock
    $tip.Text='Clique duas vezes para entrar em uma pasta. Clique em ABRIR ESTA PASTA para selecioná-la.'
    $tip.Foreground=New-SolidBrush '#82798B';$tip.FontSize=10;$tip.Margin='0,11,0,0'
    [void]$modal.Content.Children.Add($tip)
    $cancel=New-ModalButton 'CANCELAR'
    $select=New-ModalButton 'ABRIR ESTA PASTA' $true
    $select.Width=174
    [void]$modal.Footer.Children.Add($cancel);[void]$modal.Footer.Children.Add($select)
    $refresh={
        param([string]$newPath)
        $folderList.Items.Clear()
        if([string]::IsNullOrWhiteSpace($newPath)){
            $state.Path='';$pathBox.Text='Este Computador'
            foreach($drive in [IO.DriveInfo]::GetDrives()){
                if($drive.IsReady){[void]$folderList.Items.Add([pscustomobject]@{Name=('💾  '+$drive.Name);FullName=$drive.RootDirectory.FullName})}
            }
            return
        }
        if(-not (Test-Path -LiteralPath $newPath -PathType Container)){return}
        $state.Path=[IO.Path]::GetFullPath($newPath);$pathBox.Text=$state.Path
        try {
            $folders=@(Get-ChildItem -LiteralPath $state.Path -Directory -ErrorAction Stop | Sort-Object Name)
            foreach($folder in $folders){[void]$folderList.Items.Add([pscustomobject]@{Name=('📁  '+$folder.Name);FullName=$folder.FullName})}
        } catch { Write-AppLog ('Navegar pasta: '+$_.Exception.Message) }
    }.GetNewClosure()
    $back.Add_Click({
        if($state.Path){$parent=[IO.Directory]::GetParent($state.Path);if($parent){& $refresh $parent.FullName}else{& $refresh ''}}
    }.GetNewClosure())
    $pc.Add_Click({& $refresh ''}.GetNewClosure())
    $folderList.Add_MouseDoubleClick({
        if($folderList.SelectedItem){& $refresh ([string]$folderList.SelectedItem.FullName)}
    }.GetNewClosure())
    $pathBox.Add_KeyDown({param($s,$e)
        if($e.Key -eq 'Return'){
            $candidate=$pathBox.Text.Trim(' ','"')
            if(Test-Path -LiteralPath $candidate -PathType Container){& $refresh $candidate}
            $e.Handled=$true
        }
    }.GetNewClosure())
    $cancel.Add_Click({$dialog.DialogResult=$false}.GetNewClosure())
    $select.Add_Click({
        $candidate=$pathBox.Text.Trim(' ','"')
        if(Test-Path -LiteralPath $candidate -PathType Container){$state.Chosen=[IO.Path]::GetFullPath($candidate);$dialog.DialogResult=$true}
        elseif($state.Path -and (Test-Path -LiteralPath $state.Path -PathType Container)){$state.Chosen=$state.Path;$dialog.DialogResult=$true}
    }.GetNewClosure())
    $initial=Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
    if($script:PackPath -and (Test-Path -LiteralPath $script:PackPath -PathType Container)){$initial=$script:PackPath}
    if(Test-Path -LiteralPath $initial -PathType Container){& $refresh $initial}else{& $refresh ''}
    if($env:MT_PACK_ORGANIZER_UITEST -eq '1' -and $env:MT_PACK_ORGANIZER_PICKER_TEST_PATH){
        [void]$dialog.Dispatcher.BeginInvoke([Action]{
            Save-ModalPreview $dialog 'abrir'
            $pathBox.Text=$env:MT_PACK_ORGANIZER_PICKER_TEST_PATH
            $select.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }.GetNewClosure(),[Windows.Threading.DispatcherPriority]::Loaded)
    }
    if((Show-ProjectModal $dialog) -eq $true){return [string]$state.Chosen}
    return $null
}

function Open-Pack {
    $selectedPath=Select-PackFolder
    if([string]::IsNullOrWhiteSpace($selectedPath)){return}
    Open-PackPath $selectedPath
}

function Finish-OpeningPack($scan,[bool]$indexReady=$false) {
    $stage='INDEXANDO ARQUIVOS'
    try {
        $lblLoading.Text='INDEXANDO PEÇAS E TEXTURAS...'
        if(-not $indexReady){Build-FileIndex $scan}
        $stage='ATUALIZANDO INTERFACE'
        $lblPackName.Text=[string]$script:ProjectName
        $lblPackPath.Text=[string]$script:PackPath
        $packHeaderInfo.Visibility='Visible'
        if($script:AddonNameSaved){$txtAddonName.Text=Convert-ToAddonName ([string]$script:AddonNameSaved)}else{$txtAddonName.Text=Get-DefaultAddonName}
        $emptyState.Visibility='Collapsed'
        $mainContent.Visibility='Visible'
        $btnHome.Visibility='Visible'
        $stage='ABRINDO PRIMEIRA PEÇA'
        $lblLoading.Text='PREPARANDO VISUALIZAÇÃO 3D...'
        Load-CurrentPiece
        Remember-Project $script:PackPath
        Refresh-RecentProjects
        if($loadingProgress){$loadingProgress.Value=100}
        if($lblLoadingPercent){$lblLoadingPercent.Text='PROJETO PRONTO'}
    } catch {
        Write-AppLog ("Finish-OpeningPack [$stage]: " + $_.Exception.ToString())
        $mainContent.Visibility='Collapsed';$emptyState.Visibility='Visible'
        Show-Error ("Não consegui abrir este pack.`n`nEtapa: $stage`n`n"+$_.Exception.Message)
    } finally {
        Set-Loading $false
    }
}

# Indexação cooperativa: um lote curto por tick, permitindo renderização,
# interação e animações entre os lotes até mesmo com milhares de texturas.
function Start-AsyncVariantIndex($scan) {
    if($null -eq $scan -or $null -eq $scan.Models -or $null -eq $scan.Textures){throw 'Resultado de varredura incompleto.'}
    $script:VariantIndex=@{}
    $script:Pieces=@($scan.Models | Sort-Object | ForEach-Object {New-Object IO.FileInfo ([string]$_)})
    if($script:Pieces.Count -eq 0){throw 'Nenhum arquivo YDD foi encontrado nessa pasta.'}
    $script:AsyncIndexPaths=$scan.Textures
    $script:AsyncIndexPosition=0
    $script:AsyncIndexTotal=$scan.Models.Length+$scan.Textures.Length
    $script:AsyncIndexTimer=New-Object Windows.Threading.DispatcherTimer
    $script:AsyncIndexTimer.Interval=[TimeSpan]::FromMilliseconds(16)
    $script:AsyncIndexTimer.Add_Tick({
        try {
            $componentSlots='head|berd|hair|uppr|lowr|hand|feet|teef|accs|task|decl|jbib'
            $propSlots='p_head|p_eyes|p_ears|p_mouth|p_lhand|p_rhand|p_lwrist|p_rwrist|p_hip|p_lfoot|p_rfoot|p_ph_l_hand|p_ph_r_hand'
            $end=[Math]::Min($script:AsyncIndexPaths.Length,$script:AsyncIndexPosition+45)
            for($i=$script:AsyncIndexPosition;$i -lt $end;$i++){
                $f=New-Object IO.FileInfo ([string]$script:AsyncIndexPaths[$i])
                $name=[string]$f.Name
                if($name -match "^(?<prefix>.*\^)?(?<slot>$componentSlots)_diff_(?<num>\d+)_(?<letter>[a-z])_(?<kind>uni|whi)\.ytd$"){
                    $prefix=if($Matches.prefix){[string]$Matches.prefix}else{''}
                    $kind=[string]$Matches.kind
                    $key=Get-VariantIndexKey ([string]$f.DirectoryName) $prefix ([string]$Matches.slot) ([int]$Matches.num) $kind
                    if(-not $script:VariantIndex.ContainsKey($key)){$script:VariantIndex[$key]=New-Object 'System.Collections.Generic.List[object]'}
                    $script:VariantIndex[$key].Add([pscustomobject]@{Letter=([string]$Matches.letter).ToUpperInvariant();Kind=$kind.ToUpperInvariant();IsRelative=($kind -eq 'whi');File=$f})
                } elseif($name -match "^(?<prefix>.*\^)?(?<slot>$propSlots)_diff_(?<num>\d+)_(?<letter>[a-z])(?:_(?<kind>uni|whi))?\.ytd$"){
                    $prefix=if($Matches.prefix){[string]$Matches.prefix}else{''}
                    $key=Get-VariantIndexKey ([string]$f.DirectoryName) $prefix ([string]$Matches.slot) ([int]$Matches.num) 'prop'
                    if(-not $script:VariantIndex.ContainsKey($key)){$script:VariantIndex[$key]=New-Object 'System.Collections.Generic.List[object]'}
                    $script:VariantIndex[$key].Add([pscustomobject]@{Letter=([string]$Matches.letter).ToUpperInvariant();Kind='PROP';IsRelative=$false;File=$f})
                }
            }
            $script:AsyncIndexPosition=$end
            $done=$script:Pieces.Count+$end
            Update-LoadingActivity "Indexando $done de $($script:AsyncIndexTotal) arquivos..." $done ([Math]::Max(1,$script:AsyncIndexTotal))
            if($end -ge $script:AsyncIndexPaths.Length){
                $script:AsyncIndexTimer.Stop();$script:AsyncIndexTimer=$null
                $script:AsyncIndexPaths=$null
                if($script:Index -lt 0 -or $script:Index -ge $script:Pieces.Count){$script:Index=0}
                Finish-OpeningPack $null $true
            }
        } catch {
            $script:AsyncIndexTimer.Stop();$script:AsyncIndexTimer=$null
            Write-AppLog ('Indexação em lotes: '+$_.Exception.ToString())
            Set-Loading $false
            Show-Error ('Não foi possível indexar o pack: '+$_.Exception.Message)
        }
    })
    $script:AsyncIndexTimer.Start()
}

function Start-AsyncPackIndex([string]$path) {
    $script:PackScan=[MtPackScan]::Start($path)
    $script:PackScanTimer=New-Object Windows.Threading.DispatcherTimer
    $script:PackScanTimer.Interval=[TimeSpan]::FromMilliseconds(90)
    $script:PackScanTimer.Add_Tick({
        $scan=$script:PackScan
        if($null -eq $scan){return}
        if(-not $scan.IsDone){
            if($lblLoadingActivity){$lblLoadingActivity.Text="Localizando $($scan.FoundModels) peças e $($scan.FoundTextures) texturas..."}
            return
        }
        $script:PackScanTimer.Stop()
        $script:PackScanTimer=$null
        $script:PackScan=$null
        if($scan.Error){
            Write-AppLog ('Busca em segundo plano: '+$scan.Error.ToString())
            Set-Loading $false
            Show-Error ('Não consegui localizar os arquivos do projeto: '+$scan.Error.Message)
            return
        }
        Start-AsyncVariantIndex $scan
    })
    $script:PackScanTimer.Start()
}

function Open-PackPath([string]$selectedPath) {
    if(-not (Test-Path -LiteralPath $selectedPath -PathType Container)){
        Show-Error 'A pasta deste projeto não existe mais.';Refresh-RecentProjects;return
    }

    if($script:PackScanTimer -and $script:PackScanTimer.IsEnabled){return}
    $stage='INICIALIZAÇÃO'
    $deferred=$false
    Set-Loading $true 'INDEXANDO O PACK...'
    try {
        Ensure-RuntimeCollections
        if($script:ThumbTimer){ try{$script:ThumbTimer.Stop()}catch{}; $script:ThumbTimer=$null }
        $script:PackPath = $selectedPath
        $script:Index = 0
        $script:SavedView=$null
        $script:PropAlignment=@{}
        # Um pack diferente inicia com enquadramento próprio; peças do mesmo
        # pack compartilham a vista até o usuário modificá-la manualmente.
        $script:Camera = $null
        $script:Yaw = 0.0; $script:Pitch = 0.0; $script:Roll = 0.0
        $script:ModelScale = 1.0
        $script:ModelOffsetX = 0.0; $script:ModelOffsetY = 0.0; $script:ModelOffsetZ = 0.0
        $script:TextureCache=@{}
        $script:TextureCacheCost=@{}
        $script:TextureCacheBytes=[long]0
        $script:TextureInfoCache=@{}
        $script:TextureCacheOrder=@()
        $script:MeshCache=@{}
        $script:MeshCacheOrder=@()
        $script:ThumbGeneration=[int]$script:ThumbGeneration + 1
        $script:VariantIndex=@{}

        $stage='CARREGANDO ESTADO'
        Load-State
        Ensure-RuntimeCollections
        if($env:MT_PACK_ORGANIZER_UITEST -ne '1' -and (@(Get-ProjectStateCandidates $script:PackPath)).Count -eq 0){
            $enteredName=Prompt-ProjectName $script:ProjectName
            if(-not [string]::IsNullOrWhiteSpace($enteredName)){$script:ProjectName=$enteredName}
        }

        $stage='INDEXANDO ARQUIVOS'
        $lblLoading.Text='LOCALIZANDO PEÇAS E TEXTURAS...'
        [void]$win.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
        if($env:MT_PACK_ORGANIZER_UITEST -ne '1'){
            Start-AsyncPackIndex $selectedPath
            $deferred=$true
            return
        }
        Build-FileIndex

        $stage='ATUALIZANDO INTERFACE'
        $lblPackName.Text = [string]$script:ProjectName
        $lblPackPath.Text = [string]$script:PackPath
        $packHeaderInfo.Visibility='Visible'
        if($script:AddonNameSaved){$txtAddonName.Text=Convert-ToAddonName ([string]$script:AddonNameSaved)}else{$txtAddonName.Text=Get-DefaultAddonName}
        $emptyState.Visibility = 'Collapsed'
        $mainContent.Visibility = 'Visible'
        $btnHome.Visibility='Visible'

        $stage='ABRINDO PRIMEIRA PEÇA'
        $lblLoading.Text='ABRINDO A PRIMEIRA PEÇA...'
        [void]$win.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
        Load-CurrentPiece
        Remember-Project $script:PackPath
        Refresh-RecentProjects
    } catch {
        $line=$_.InvocationInfo.ScriptLineNumber
        $pos=$_.InvocationInfo.PositionMessage
        Write-AppLog ("Open-Pack [$stage] linha $line :: "+$_.Exception.ToString()+"`n"+$pos)
        $mainContent.Visibility='Collapsed'; $emptyState.Visibility='Visible'
        Show-Error ("Não consegui abrir este pack.`n`nEtapa: $stage`nLinha: $line`n`n"+$_.Exception.Message+"`n`nO erro completo foi salvo em logs.")
    } finally {
        if(-not $deferred){Set-Loading $false}
    }
}


function Apply-Removals {
    if (-not $script:PackPath) { return }
    $pieceCount = @($script:Decisions.Values | Where-Object { $_ -eq 'EXCLUIR' }).Count
    $textureCount = @($script:TextureDeletions.Keys).Count
    if ($pieceCount -eq 0 -and $textureCount -eq 0) {
        [System.Windows.MessageBox]::Show('Nenhuma peça ou textura está marcada para excluir.','MT Pack Organizer') | Out-Null
        return
    }

    $answer = [System.Windows.MessageBox]::Show(
        "Aplicar exclusões?`n`nPeças: $pieceCount`nTexturas individuais: $textureCount`n`nTudo será movido para _PARA_EXCLUIR. Nada será apagado definitivamente.",
        'Confirmar limpeza','YesNo','Question')
    if ($answer -ne 'Yes') { return }

    $dest = Join-Path $script:PackPath '_PARA_EXCLUIR'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $movedPieces = 0
    $movedTextures = 0

    # 1) Peças inteiras: move YDD + todas as variantes YTD.
    foreach ($ydd in @($script:Pieces)) {
        if (-not $script:Decisions.ContainsKey($ydd.FullName) -or $script:Decisions[$ydd.FullName] -ne 'EXCLUIR') { continue }
        if (-not (Test-Path $ydd.FullName)) { continue }

        $rel = $ydd.FullName.Substring($script:PackPath.Length).TrimStart('\')
        $relDir = [IO.Path]::GetDirectoryName($rel)
        $dd = if($relDir){Join-Path $dest $relDir}else{$dest}
        New-Item -ItemType Directory -Force -Path $dd | Out-Null

        $vars = @(Find-Variants $ydd)
        Move-Item -LiteralPath $ydd.FullName -Destination (Join-Path $dd $ydd.Name) -Force
        foreach ($v in $vars) {
            if (Test-Path $v.File.FullName) {
                Move-Item -LiteralPath $v.File.FullName -Destination (Join-Path $dd $v.File.Name) -Force
                $script:TextureDeletions.Remove($v.File.FullName)
            }
        }
        $movedPieces++
    }

    # 2) Texturas individuais de peças mantidas.
    foreach ($path in @($script:TextureDeletions.Keys)) {
        if (-not (Test-Path -LiteralPath $path)) { $script:TextureDeletions.Remove($path); continue }
        $file = New-Object IO.FileInfo $path
        $rel = $file.FullName.Substring($script:PackPath.Length).TrimStart('\')
        $relDir = [IO.Path]::GetDirectoryName($rel)
        $dd = if($relDir){Join-Path $dest $relDir}else{$dest}
        New-Item -ItemType Directory -Force -Path $dd | Out-Null
        Move-Item -LiteralPath $file.FullName -Destination (Join-Path $dd $file.Name) -Force
        $script:TextureDeletions.Remove($path)
        $movedTextures++
    }

    Save-State
    [System.Windows.MessageBox]::Show(
        "$movedPieces peça(s) e $movedTextures textura(s) individual(is) movida(s) para _PARA_EXCLUIR.`nNenhum arquivo foi apagado.",
        'MT Pack Organizer') | Out-Null

    $script:Index = 0
    Rescan-Pieces
    Load-CurrentPiece
}


# --------------------------- Gerador de add-on FiveM --------------------------

function Convert-ToAddonName([string]$name) {
    if([string]::IsNullOrWhiteSpace($name)){ $name='mtstudio_pack' }
    $s=$name.ToLowerInvariant() -replace '[^a-z0-9_]+','_'
    $s=$s.Trim('_')
    if([string]::IsNullOrWhiteSpace($s)){ $s='mtstudio_pack' }
    if($s.Length -gt 42){ $s=$s.Substring(0,42).TrimEnd('_') }
    return $s
}

function Get-DefaultAddonName {
    if(-not $script:PackPath){return 'mtstudio_pack'}
    $parent=Split-Path $script:PackPath -Parent
    $leaf=Split-Path $parent -Leaf
    return Convert-ToAddonName ('mtstudio_'+$leaf)
}

function Ensure-NugetDll([string]$id,[string]$version,[string]$dllName) {
    $backend=Join-Path $PSScriptRoot 'backend'
    New-Item -ItemType Directory -Force -Path $backend | Out-Null
    $target=Join-Path $backend $dllName
    if(Test-Path $target){return $target}

    $pkg=Join-Path $backend ($id+'.'+$version+'.nupkg')
    $extract=Join-Path $backend ($id+'.'+$version)

    try {
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

        # NuGet .nupkg é um ZIP. Expand-Archive do Windows PowerShell aceita apenas
        # extensão .zip, então usamos ZipFile diretamente para não depender da extensão.
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        $downloadPackage = {
            param($url,$dest)
            $tmp=$dest+'.download'
            if(Test-Path $tmp){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp
            if(-not (Test-Path $tmp)){throw 'O download do pacote não foi concluído.'}
            if((Get-Item -LiteralPath $tmp).Length -lt 1024){throw 'O pacote baixado parece estar incompleto.'}
            Move-Item -LiteralPath $tmp -Destination $dest -Force
        }

        $url="https://www.nuget.org/api/v2/package/$id/$version"
        if(-not (Test-Path $pkg)){
            & $downloadPackage $url $pkg
        }

        $tryExtract = {
            if(Test-Path $extract){Remove-Item -Recurse -Force -LiteralPath $extract}
            New-Item -ItemType Directory -Force -Path $extract | Out-Null
            [System.IO.Compression.ZipFile]::ExtractToDirectory($pkg,$extract)
        }

        try {
            & $tryExtract
        } catch {
            # Se ficou um .nupkg parcial/corrompido de uma tentativa anterior,
            # baixa novamente uma vez e tenta extrair de novo.
            Remove-Item -LiteralPath $pkg -Force -ErrorAction SilentlyContinue
            if(Test-Path $extract){Remove-Item -Recurse -Force -LiteralPath $extract -ErrorAction SilentlyContinue}
            & $downloadPackage $url $pkg
            & $tryExtract
        }

        $found=Get-ChildItem -LiteralPath $extract -Recurse -File -Filter $dllName | Select-Object -First 1
        if(-not $found){throw "$dllName não encontrado dentro do pacote $id."}
        Copy-Item -LiteralPath $found.FullName -Destination $target -Force
        return $target
    } catch {
        throw "Não consegui preparar $id $version. Verifique a internet e tente novamente. $($_.Exception.Message)"
    }
}

function Ensure-AddonBuilderBackend {
    if('MtAddonYmtBuilder' -as [type]){return}
    $buildStatusVar=Get-Variable lblBuildStatus -Scope Script -ErrorAction SilentlyContinue
    if($buildStatusVar -and $buildStatusVar.Value){$buildStatusVar.Value.Text='Preparando gerador YMT (primeira vez)...'}
    [System.Windows.Forms.Application]::DoEvents()
    $cw=Ensure-NugetDll 'CodeWalker.Core' '1.0.3' 'CodeWalker.Core.dll'
    $sdx=Ensure-NugetDll 'SharpDX' '4.2.0' 'SharpDX.dll'
    $sdxm=Ensure-NugetDll 'SharpDX.Mathematics' '4.2.0' 'SharpDX.Mathematics.dll'
    [Reflection.Assembly]::LoadFrom($sdx) | Out-Null
    [Reflection.Assembly]::LoadFrom($sdxm) | Out-Null
    [Reflection.Assembly]::LoadFrom($cw) | Out-Null

    # CodeWalker.Core depende de netstandard. Em PowerShell, variáveis de ambiente
    # com parênteses (ProgramFiles(x86)) PRECISAM ser acessadas via Environment API;
    # a forma "$env:ProgramFiles(x86)" era interpretada errado e nos fazia carregar
    # o reference assembly do NuGet, duplicando mscorlib/System.*.
    $pf86=[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    $netstdCandidates=@(
      (Join-Path $pf86 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8\Facades\netstandard.dll'),
      (Join-Path $pf86 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.7.2\Facades\netstandard.dll'),
      (Join-Path $pf86 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.7.1\Facades\netstandard.dll'),
      (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\Facades\netstandard.dll'),
      (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\Facades\netstandard.dll')
    )
    $forceNugetNetstandard=($env:MT_PACK_ORGANIZER_FORCE_NUGET_NETSTANDARD -eq '1')
    $netstd=$null
    if(-not $forceNugetNetstandard){
        $netstd=$netstdCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        if(-not $netstd) {
            try {
                $ns=[Reflection.Assembly]::Load('netstandard')
                if($ns -and $ns.Location -and (Test-Path -LiteralPath $ns.Location)){$netstd=$ns.Location}
            } catch {}
        }
    }

    # PCs comuns normalmente têm apenas o runtime do .NET Framework, sem o
    # "Developer Pack/Targeting Pack". Nesse caso a pasta Reference Assemblies
    # não existe, embora o programa possa rodar normalmente. Baixamos SOMENTE
    # a facade correta do Targeting Pack oficial do .NET Framework 4.7.1.
    # NÃO usamos NETStandard.Library aqui: aquela DLL é um reference assembly
    # completo e, com o csc do .NET Framework, duplica tipos de mscorlib/System.*.
    if(-not $netstd){
        try {
            $netstd=Ensure-NugetDll 'Microsoft.NETFramework.ReferenceAssemblies.net471' '1.0.3' 'netstandard.dll'
        } catch {
            throw ('Não consegui preparar automaticamente a facade netstandard.dll necessária ao gerador YMT. '+$_.Exception.Message)
        }
    }
    if(-not $netstd -or -not (Test-Path -LiteralPath $netstd)){
        throw 'Não foi possível preparar netstandard.dll para o gerador YMT.'
    }

    $refs=@($cw,$sdx,$sdxm,$netstd,'System.dll','System.Core.dll','System.Xml.dll','System.Xml.Linq.dll')

    $builderCs=@'
using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using CodeWalker.GameFiles;

public class MtAddonPiece
{
    public int TypeNumeric;
    public bool IsProp;
    public int Number;
    public int TextureCount;
    public bool HasSkin;
    public bool EnableHairScale;
    public float HairScaleValue;
}

public static class MtAddonYmtBuilder
{
    public static void Build(string outputPath, string projectName, MtAddonPiece[] input)
    {
        MtAddonPiece[] pieces = input ?? new MtAddonPiece[0];
        MetaBuilder mb = new MetaBuilder();
        mb.EnsureBlock(MetaName.CPedVariationInfo);
        CPedVariationInfo ped = new CPedVariationInfo();
        ped.bHasDrawblVariations = 1;
        ped.bHasTexVariations = 1;
        ped.bHasLowLODs = 0;
        ped.bIsSuperLOD = 0;

        byte[] gen = new byte[] {255,255,255,255,255,255,255,255,255,255,255,255};
        byte compCount=0;
        for(int i=0;i<12;i++)
        {
            if(pieces.Any(p => !p.IsProp && p.TypeNumeric==i)) { gen[i]=compCount; compCount++; }
        }
        ArrayOfBytes12 avail = new ArrayOfBytes12();
        avail.b00=gen[0];  avail.b01=gen[1];  avail.b02=gen[2];  avail.b03=gen[3];
        avail.b04=gen[4];  avail.b05=gen[5];  avail.b06=gen[6];  avail.b07=gen[7];
        avail.b08=gen[8];  avail.b09=gen[9];  avail.b10=gen[10]; avail.b11=gen[11];
        ped.availComp = avail;

        MtAddonPiece[] comps = pieces.Where(p => !p.IsProp).OrderBy(p=>p.TypeNumeric).ThenBy(p=>p.Number).ToArray();
        MtAddonPiece[] propsIn = pieces.Where(p => p.IsProp).OrderBy(p=>p.TypeNumeric).ThenBy(p=>p.Number).ToArray();
        Dictionary<byte,CPVComponentData> components = new Dictionary<byte,CPVComponentData>();
        for(byte type=0;type<12;type++)
        {
            if(gen[type]==255) continue;
            MtAddonPiece[] arr = comps.Where(p=>p.TypeNumeric==type).ToArray();
            CPVDrawblData[] draw = new CPVDrawblData[arr.Length];
            for(int d=0;d<arr.Length;d++)
            {
                draw[d].propMask=(byte)(arr[d].HasSkin?17:1);
                draw[d].numAlternatives=0;
                draw[d].clothData=new CPVDrawblData__CPVClothComponentData(){ownsCloth=0};
                CPVTextureData[] tex=new CPVTextureData[arr[d].TextureCount];
                for(int t=0;t<tex.Length;t++){tex[t].texId=(byte)(arr[d].HasSkin?1:0); tex[t].distribution=255;}
                draw[d].aTexData=mb.AddItemArrayPtr(MetaName.CPVTextureData,tex);
            }
            CPVComponentData cd=new CPVComponentData();
            cd.numAvailTex=(byte)Math.Min(255,arr.Sum(p=>p.TextureCount));
            cd.aDrawblData3=mb.AddItemArrayPtr(MetaName.CPVDrawblData,draw);
            components[type]=cd;
        }
        ped.aComponentData3=mb.AddItemArrayPtr(MetaName.CPVComponentData,components.Values.ToArray());

        CComponentInfo[] infos=new CComponentInfo[comps.Length];
        for(int i=0;i<infos.Length;i++)
        {
            MtAddonPiece p=comps[i];
            infos[i].pedXml_audioID=JenkHash.GenHash("none");
            infos[i].pedXml_audioID2=JenkHash.GenHash("none");
            infos[i].pedXml_expressionMods=new ArrayOfFloats5(){f0=0,f1=0,f2=0,f3=0,f4=0};
            infos[i].flags=0; infos[i].inclusions=0; infos[i].exclusions=0;
            infos[i].pedXml_vfxComps=ePedVarComp.PV_COMP_HEAD;
            infos[i].pedXml_flags=0;
            infos[i].pedXml_compIdx=(byte)p.TypeNumeric;
            infos[i].pedXml_drawblIdx=(byte)p.Number;
        }
        ped.compInfos=mb.AddItemArrayPtr(MetaName.CComponentInfo,infos);

        CPedPropInfo propInfo=new CPedPropInfo();
        propInfo.numAvailProps=(byte)Math.Min(255,propsIn.Length);
        CPedPropMetaData[] props=new CPedPropMetaData[propsIn.Length];
        for(int i=0;i<props.Length;i++)
        {
            MtAddonPiece p=propsIn[i];
            props[i].audioId=JenkHash.GenHash("none");
            // CodeWalker.Core 1.0.3 usa ArrayOfBytes5 neste campo (a versão
            // atual do grzyClothTool usa ArrayOfFloats5). Mantemos zero/default
            // aqui para compatibilidade do YMT; o ocultamento de cabelo é
            // tratado pelo meta de variações quando aplicável.
            props[i].expressionMods=new ArrayOfBytes5();
            CPedPropTexData[] tex=new CPedPropTexData[p.TextureCount];
            for(int t=0;t<tex.Length;t++)
            {
                tex[t].inclusions=0; tex[t].exclusions=0; tex[t].texId=(byte)t;
                tex[t].inclusionId=0; tex[t].exclusionId=0; tex[t].distribution=255;
            }
            props[i].texData=mb.AddItemArrayPtr(MetaName.CPedPropTexData,tex);
            props[i].renderFlags=(ePropRenderFlags)0; props[i].propFlags=0; props[i].flags=0;
            props[i].anchorId=(byte)p.TypeNumeric; props[i].propId=(byte)p.Number;
        }
        propInfo.aPropMetaData=mb.AddItemArrayPtr(MetaName.CPedPropMetaData,props);
        MtAddonPiece[] uniqueProps=propsIn.GroupBy(p=>p.TypeNumeric).Select(g=>g.First()).ToArray();
        CAnchorProps[] anchors=new CAnchorProps[uniqueProps.Length];
        for(int i=0;i<anchors.Length;i++)
        {
            MtAddonPiece[] pp=propsIn.Where(p=>p.TypeNumeric==uniqueProps[i].TypeNumeric).ToArray();
            anchors[i].props=mb.AddByteArrayPtr(pp.Select(p=>(byte)p.TextureCount).ToArray());
            anchors[i].anchor=(eAnchorPoints)uniqueProps[i].TypeNumeric;
        }
        propInfo.aAnchors=mb.AddItemArrayPtr(MetaName.CAnchorProps,anchors);
        ped.propInfo=propInfo;
        ped.dlcName=JenkHash.GenHash(projectName);

        mb.AddItem(MetaName.CPedVariationInfo,ped);
        mb.AddStructureInfo(MetaName.CPedVariationInfo);
        mb.AddStructureInfo(MetaName.CPedPropInfo);
        mb.AddStructureInfo(MetaName.CPedPropTexData);
        mb.AddStructureInfo(MetaName.CAnchorProps);
        mb.AddStructureInfo(MetaName.CComponentInfo);
        mb.AddStructureInfo(MetaName.CPVComponentData);
        mb.AddStructureInfo(MetaName.CPVDrawblData);
        mb.AddStructureInfo(MetaName.CPVDrawblData__CPVClothComponentData);
        mb.AddStructureInfo(MetaName.CPVTextureData);
        mb.AddStructureInfo(MetaName.CPedPropMetaData);
        mb.AddEnumInfo(MetaName.ePedVarComp);
        mb.AddEnumInfo(MetaName.eAnchorPoints);
        mb.AddEnumInfo(MetaName.ePropRenderFlags);
        Meta meta=mb.GetMeta(); meta.Name=projectName;
        byte[] data=ResourceBuilder.Build(meta,2);
        File.WriteAllBytes(outputPath,data);
    }
}
'@
    # Add-Type + netstandard facade e instavel no Windows PowerShell 5.1.
    # Compilamos o bridge com o csc do proprio .NET Framework e carregamos a DLL.
    $cscCandidates=@(
      (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
      (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $csc=$cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if(-not $csc){throw 'Compilador C# do .NET Framework nao encontrado (csc.exe).'}

    # Nunca compilar em um DLL fixo compartilhado. Depois que uma assembly .NET e
    # carregada, o arquivo fica bloqueado ate o processo fechar. Se outra instancia
    # estiver aberta, recompilar em ymt_bridge\MtAddonYmtBuilder.dll gera CS0016.
    # Cada processo usa seu proprio diretorio e seu proprio DLL.
    $bridgeBase=Join-Path ([IO.Path]::GetTempPath()) 'MTStudioPackOrganizer\ymt_bridge'
    $bridgeDir=Join-Path $bridgeBase ("proc_{0}_{1}" -f $PID,([guid]::NewGuid().ToString('N')))
    [IO.Directory]::CreateDirectory($bridgeDir) | Out-Null
    $srcPath=Join-Path $bridgeDir 'MtAddonYmtBuilder.cs'
    $dllPath=Join-Path $bridgeDir 'MtAddonYmtBuilder.dll'
    [IO.File]::WriteAllText($srcPath,$builderCs,(New-Object Text.UTF8Encoding($false)))

    $cscArgs=@(
      '/nologo',
      '/target:library',
      '/optimize+',
      ('/out:"{0}"' -f $dllPath),
      ('/reference:"{0}"' -f $cw),
      ('/reference:"{0}"' -f $sdx),
      ('/reference:"{0}"' -f $sdxm),
      ('/reference:"{0}"' -f $netstd),
      ('"{0}"' -f $srcPath)
    )
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$csc
    $psi.Arguments=($cscArgs -join ' ')
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $proc=[Diagnostics.Process]::Start($psi)
    $stdout=$proc.StandardOutput.ReadToEnd()
    $stderr=$proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $dllPath)){
        throw ('Falha ao compilar o gerador YMT.'+[Environment]::NewLine+$stdout+[Environment]::NewLine+$stderr)
    }
    [Reflection.Assembly]::LoadFrom($dllPath) | Out-Null
    if(-not ('MtAddonYmtBuilder' -as [type])){throw 'O gerador YMT foi compilado, mas nao pode ser carregado.'}
}

function Write-ShopMeta([string]$root,[string]$project,[string]$sex) {
    $ped=if($sex -eq 'male'){'mp_m_freemode_01'}else{'mp_f_freemode_01'}
    $char=if($sex -eq 'male'){'SCR_CHAR_MULTIPLAYER'}else{'SCR_CHAR_MULTIPLAYER_F'}
    $g=if($sex -eq 'male'){'m'}else{'f'}
    $xml=@" 
<?xml version="1.0" encoding="UTF-8"?>
<ShopPedApparel>
    <pedName>$ped</pedName>
    <dlcName>$project</dlcName>
    <fullDlcName>${ped}_${project}</fullDlcName>
    <eCharacter>$char</eCharacter>
    <creatureMetaData>mp_creaturemetadata_${g}_${project}</creatureMetaData>
    <pedOutfits>
    </pedOutfits>
    <pedComponents>
    </pedComponents>
    <pedProps>
    </pedProps>
</ShopPedApparel>
"@
    $path=Join-Path $root ("${ped}_${project}.meta")
    [IO.File]::WriteAllText($path,$xml,(New-Object Text.UTF8Encoding($false)))
    return [IO.Path]::GetFileName($path)
}

function Get-HairEntries([string]$sex) {
    # Mesmas listas-base usadas pelo grzyClothTool para pedalternativevariations.
    if($sex -eq 'male') {
        return @(
          @{D='';I=0..15},@{D='male_freemode_beach';I=0..1},@{D='Male_freemode_business';I=0..1},@{D='Male_freemode_hipster';I=0..1},
          @{D='Male_freemode_independence';I=@(0)},@{D='male_heist';I=@(0)},@{D='mp_m_lowrider_01';I=0..3},@{D='mp_m_lowrider_02';I=0..2},
          @{D='mp_m_bikerdlc_01';I=0..5},@{D='mp_m_gunrunning_hair_01';I=0..36},@{D='mp_m_vinewood';I=@(0)},@{D='mp_m_sum2';I=0..1},
          @{D='mp_m_tuner';I=@(0)},@{D='mp_m_security';I=@(0)},@{D='mp_m_2023_01';I=0..1},@{D='mp_m_2023_02';I=@(0)},@{D='mp_m_2024_02';I=@(0)}
        )
    }
    return @(
      @{D='';I=0..23},@{D='female_freemode_beach';I=0..2},@{D='Female_freemode_business';I=0..1},@{D='Female_freemode_hipster';I=0..2},
      @{D='Female_freemode_independence';I=@(0)},@{D='Female_heist';I=@(0)},@{D='mp_f_lowrider_01';I=0..3},@{D='mp_f_lowrider_02';I=0..2},
      @{D='mp_f_bikerdlc_01';I=0..5},@{D='mp_f_gunrunning_hair_01';I=0..37},@{D='mp_f_vinewood';I=@(0)},@{D='mp_f_sum2';I=0..2},
      @{D='mp_f_tuner';I=@(0)},@{D='mp_f_security';I=@(0)},@{D='mp_f_2023_01';I=0..2},@{D='mp_f_2023_02';I=@(0)}
    )
}

function Write-PedAlternativeMeta([string]$root,[string]$project,[string]$sex,$pieces) {
    $masks=@($pieces | Where-Object {$_.Slot -eq 'berd' -and $_.HideHair})
    if($masks.Count -eq 0){return $null}
    $ped=if($sex -eq 'male'){'mp_m_freemode_01'}else{'mp_f_freemode_01'}
    $sb=New-Object Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    [void]$sb.AppendLine('<CAlternateVariations><peds><Item>')
    [void]$sb.AppendLine("<name>$ped</name><switches>")
    foreach($he in @(Get-HairEntries $sex)) {
        foreach($hi in @($he.I)) {
            [void]$sb.AppendLine('<Item>')
            if(-not [string]::IsNullOrWhiteSpace([string]$he.D)){[void]$sb.AppendLine("<dlcNameHash>$($he.D)</dlcNameHash>")}
            [void]$sb.AppendLine('<component value="2" />')
            [void]$sb.AppendLine(('<index value="{0}" /><alt value="1" /><sourceAssets>' -f $hi))
            foreach($m in $masks) {
                [void]$sb.AppendLine(('<Item><dlcNameHash>{0}</dlcNameHash><component value="1" /><index value="{1}" /></Item>' -f $project,$m.NewNumber))
            }
            [void]$sb.AppendLine('</sourceAssets></Item>')
        }
    }
    # Também aplica a alternância aos cabelos adicionados no próprio resource.
    foreach($hair in @($pieces | Where-Object {$_.Slot -eq 'hair'})) {
        [void]$sb.AppendLine(('<Item><dlcNameHash>{0}</dlcNameHash><component value="2" /><index value="{1}" /><alt value="1" /><sourceAssets>' -f $project,$hair.NewNumber))
        foreach($m in $masks){[void]$sb.AppendLine(('<Item><dlcNameHash>{0}</dlcNameHash><component value="1" /><index value="{1}" /></Item>' -f $project,$m.NewNumber))}
        [void]$sb.AppendLine('</sourceAssets></Item>')
    }
    [void]$sb.AppendLine('</switches></Item></peds></CAlternateVariations>')
    $path=Join-Path $root ("pedalternativevariations_${ped}_${project}.meta")
    [IO.File]::WriteAllText($path,$sb.ToString(),(New-Object Text.UTF8Encoding($false)))
    return [IO.Path]::GetFileName($path)
}

function Write-FxManifest([string]$root,[string[]]$metaFiles,[string[]]$altFiles) {
    $files=@()
    if($metaFiles){$files+=@($metaFiles)}
    if($altFiles){$files+=@($altFiles)}
    $sb=New-Object Text.StringBuilder
    [void]$sb.AppendLine('-- Generated by MT Studio Pack Organizer')
    [void]$sb.AppendLine("fx_version 'cerulean'")
    [void]$sb.AppendLine("game 'gta5'")
    [void]$sb.AppendLine("author 'MT Studio'")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('files {')
    foreach($f in @($files)){[void]$sb.AppendLine("  '$f',")}
    [void]$sb.AppendLine('}')
    foreach($f in @($metaFiles)){[void]$sb.AppendLine("data_file 'SHOP_PED_APPAREL_META_FILE' '$f'")}
    foreach($f in @($altFiles)){[void]$sb.AppendLine("data_file 'ALTERNATE_VARIATIONS_FILE' '$f'")}
    [IO.File]::WriteAllText((Join-Path $root 'fxmanifest.lua'),$sb.ToString(),(New-Object Text.UTF8Encoding($false)))
}
function Get-KeptBuildPieces {
    $out=@()
    foreach($ydd in @($script:Pieces)) {
        if(-not $script:Decisions.ContainsKey($ydd.FullName) -or $script:Decisions[$ydd.FullName] -ne 'MANTER'){continue}
        $d=Get-PieceDescriptor $ydd
        if($d.TypeNumeric -lt 0){continue}
        $vars=@(Find-Variants $ydd | Where-Object {-not $script:TextureDeletions.ContainsKey($_.File.FullName)})
        if($vars.Count -eq 0){continue}
        $hideHair=(($d.Slot -eq 'berd' -or $d.Slot -eq 'p_head') -and $script:HideHairSelections.ContainsKey($ydd.FullName) -and [bool]$script:HideHairSelections[$ydd.FullName])
        $out += [pscustomobject]@{Ydd=$ydd;Slot=$d.Slot;TypeNumeric=$d.TypeNumeric;IsProp=$d.IsProp;SourceNumber=$d.Number;Variant=$d.Variant;TextureKind=$d.TextureKind;HasSkin=$d.HasSkin;Sex=$d.Sex;HairMode=$d.HairMode;HideHair=$hideHair;Textures=$vars}
    }
    return $out
}

function Build-FiveMAddon {
    if(-not $script:PackPath){return}
    $kept=@(Get-KeptBuildPieces)
    if($kept.Count -eq 0){[System.Windows.MessageBox]::Show('Nenhuma peça marcada como MANTER com textura válida.','MT Studio')|Out-Null;return}

    $pending=$script:Pieces.Count-@($script:Decisions.Values).Count
    if($pending -gt 0) {
        $ans=[System.Windows.MessageBox]::Show("Ainda existem $pending peça(s) pendentes. Elas NÃO entrarão no add-on. Continuar?",'MT Studio','YesNo','Question')
        if($ans -ne 'Yes'){return}
    }

    $base=Convert-ToAddonName $txtAddonName.Text
    $txtAddonName.Text=$base
    $lblBuildStatus.Text='Preparando DLCs...'
    [System.Windows.Forms.Application]::DoEvents()
    Ensure-AddonBuilderBackend

    # UMA pasta/resource. Os packs sao DLC namespaces dentro dela.
    # A regra de 150 vale POR CATEGORIA em cada DLC.
    $packRoot=Split-Path $script:PackPath -Parent
    $stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
    $outRoot=Join-Path $packRoot ("MT_ADDONS_GERADOS\${base}_$stamp")
    $stream=Join-Path $outRoot 'stream'
    New-Item -ItemType Directory -Force -Path $stream | Out-Null

    $maxPerCategory=150
    $prepared=@()

    foreach($grp in @($kept | Group-Object Sex,IsProp,TypeNumeric)) {
        $ordered=@($grp.Group | Sort-Object SourceNumber,@{E={$_.Ydd.Name}})
        for($i=0;$i -lt $ordered.Count;$i++) {
            $p=$ordered[$i]
            $dlcIndex=[int][Math]::Floor($i/$maxPerCategory)+1
            $newNumber=[int]($i % $maxPerCategory)
            $prepared += [pscustomobject]@{
                Ydd=$p.Ydd;Slot=$p.Slot;TypeNumeric=$p.TypeNumeric;IsProp=$p.IsProp;
                SourceNumber=$p.SourceNumber;Variant=$p.Variant;TextureKind=$p.TextureKind;
                HasSkin=$p.HasSkin;Sex=$p.Sex;HairMode=$p.HairMode;HideHair=$p.HideHair;
                Textures=$p.Textures;DlcIndex=$dlcIndex;NewNumber=$newNumber
            }
        }
    }

    $maxDlc=[int](($prepared | Measure-Object DlcIndex -Maximum).Maximum)
    if($maxDlc -lt 1){$maxDlc=1}
    $metaFiles=@(); $altFiles=@(); $made=@(); $createdDirs=@{}

    # Sem ZIP e sem subpastas por DLC: todos os arquivos convivem no mesmo stream.
    for($di=1;$di -le $maxDlc;$di++) {
        $project='{0}_{1:D2}' -f $base,$di
        $subset=@($prepared | Where-Object {$_.DlcIndex -eq $di})
        if($subset.Count -eq 0){continue}
        $made += $project

        foreach($sex in @('female','male')) {
            $sx=@($subset | Where-Object {$_.Sex -eq $sex})
            if($sx.Count -eq 0){continue}
            $ped=if($sex -eq 'male'){'mp_m_freemode_01'}else{'mp_f_freemode_01'}
            $gender=if($sex -eq 'male'){'[male]'}else{'[female]'}

            foreach($p in $sx) {
                $folder=Join-Path (Join-Path $stream $gender) $p.Slot
                if(-not $createdDirs.ContainsKey($folder)){
                    [IO.Directory]::CreateDirectory($folder) | Out-Null
                    $createdDirs[$folder]=$true
                }
                # Props usam obrigatoriamente mp_*_freemode_01_p_<dlc>^...
                $prefix=if($p.IsProp){"${ped}_p_${project}^"}else{"${ped}_${project}^"}
                if($p.IsProp){$outYdd="$prefix$($p.Slot)_{0:D3}.ydd" -f $p.NewNumber}
                else{$outYdd="$prefix$($p.Slot)_{0:D3}_$($p.Variant).ydd" -f $p.NewNumber}
                [IO.File]::Copy($p.Ydd.FullName,(Join-Path $folder $outYdd),$true)

                # O YMT usa índices 0..N-1. Sempre renumera as texturas restantes a,b,c...
                # para não deixar buracos após exclusões (ex.: a,c,d).
                $texIndex=0
                foreach($v in @($p.Textures | Sort-Object Letter)) {
                    $letter=[char]([int][char]'a' + $texIndex)
                    if($p.IsProp){$outYtd="$prefix$($p.Slot)_diff_{0:D3}_${letter}.ytd" -f $p.NewNumber}
                    else{$outYtd="$prefix$($p.Slot)_diff_{0:D3}_${letter}_$($p.TextureKind).ytd" -f $p.NewNumber}
                    [IO.File]::Copy($v.File.FullName,(Join-Path $folder $outYtd),$true)
                    $texIndex++
                }
            }

            $metaFiles += Write-ShopMeta $outRoot $project $sex
            $specs=New-Object 'System.Collections.Generic.List[MtAddonPiece]'
            foreach($p in $sx) {
                $sp=New-Object MtAddonPiece
                $sp.TypeNumeric=$p.TypeNumeric; $sp.IsProp=$p.IsProp; $sp.Number=$p.NewNumber
                $sp.TextureCount=@($p.Textures).Count; $sp.HasSkin=$p.HasSkin
                $sp.EnableHairScale=($p.IsProp -and $p.Slot -eq 'p_head' -and $p.HideHair)
                $sp.HairScaleValue=if($sp.EnableHairScale){1.0}else{0.0}
                $specs.Add($sp)
            }
            [MtAddonYmtBuilder]::Build((Join-Path $stream ("${ped}_${project}.ymt")),$project,$specs.ToArray())
            $alt=Write-PedAlternativeMeta $outRoot $project $sex $sx
            if($alt){$altFiles += $alt}
        }
    }

    Write-FxManifest $outRoot @($metaFiles) @($altFiles)

    # Confere os nomes que o FiveM realmente vai resolver antes de concluir.
    $validationErrors=New-Object 'System.Collections.Generic.List[string]'
    foreach($p in @($prepared)) {
        $project='{0}_{1:D2}' -f $base,$p.DlcIndex
        $ped=if($p.Sex -eq 'male'){'mp_m_freemode_01'}else{'mp_f_freemode_01'}
        $gender=if($p.Sex -eq 'male'){'[male]'}else{'[female]'}
        $folder=Join-Path (Join-Path $stream $gender) $p.Slot
        $prefix=if($p.IsProp){"${ped}_p_${project}^"}else{"${ped}_${project}^"}

        if($p.IsProp){$yddName="$prefix$($p.Slot)_{0:D3}.ydd" -f $p.NewNumber}
        else{$yddName="$prefix$($p.Slot)_{0:D3}_$($p.Variant).ydd" -f $p.NewNumber}
        if(-not (Test-Path -LiteralPath (Join-Path $folder $yddName))){$validationErrors.Add("YDD ausente: $yddName")}

        for($ti=0;$ti -lt @($p.Textures).Count;$ti++){
            $letter=[char]([int][char]'a' + $ti)
            if($p.IsProp){$ytdName="$prefix$($p.Slot)_diff_{0:D3}_${letter}.ytd" -f $p.NewNumber}
            else{$ytdName="$prefix$($p.Slot)_diff_{0:D3}_${letter}_$($p.TextureKind).ytd" -f $p.NewNumber}
            if(-not (Test-Path -LiteralPath (Join-Path $folder $ytdName))){$validationErrors.Add("YTD ausente: $ytdName")}
        }
    }
    if($validationErrors.Count -gt 0){
        $msg="Validação do add-on falhou:" + [Environment]::NewLine + (($validationErrors | Select-Object -First 25) -join [Environment]::NewLine)
        throw $msg
    }

    $categoryLines=@()
    foreach($cg in @($prepared | Group-Object Sex,Slot | Sort-Object Name)){
        $dlcs=@($cg.Group | Select-Object -ExpandProperty DlcIndex -Unique | Sort-Object)
        $categoryLines += ("- {0}: {1} peça(s), {2} DLC(s)" -f $cg.Name,$cg.Count,$dlcs.Count)
    }

    $summary=@"
MT STUDIO PACK ORGANIZER - BUILD
Projeto base: $base
Gerado: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')
Peças mantidas incluídas: $($kept.Count)
Estrutura: UM ÚNICO RESOURCE
Limite: 150 peças POR CATEGORIA em cada DLC
DLCs: $($made -join ', ')
Pastas: stream/[female|male]/categoria
Compactação ZIP: desativada para geração rápida
Regras: _r -> _whi | _u -> _uni | máscara/chapéu escondem cabelo somente quando marcados

Distribuição:
$($categoryLines -join [Environment]::NewLine)
"@
    Set-Content -LiteralPath (Join-Path $outRoot 'BUILD_SUMMARY.txt') -Value $summary -Encoding UTF8
    $lblBuildStatus.Text="Concluído: 1 resource / $($made.Count) DLC(s)"
    [System.Windows.MessageBox]::Show("Add-on gerado com sucesso.`n`n1 resource com $($made.Count) DLC(s).`n$outRoot",'MT Studio')|Out-Null
    Start-Process explorer.exe $outRoot
}

function Invoke-AddonBackendSelfTest {
    $tmp=$null
    try {
        Ensure-AddonBuilderBackend
        $tmp=Join-Path ([IO.Path]::GetTempPath()) ("mt_pack_organizer_selftest_"+[guid]::NewGuid().ToString('N')+".ymt")
        $specs=New-Object 'System.Collections.Generic.List[MtAddonPiece]'

        $component=New-Object MtAddonPiece
        $component.TypeNumeric=8
        $component.IsProp=$false
        $component.Number=0
        $component.TextureCount=2
        $component.HasSkin=$false
        $component.EnableHairScale=$false
        $component.HairScaleValue=0.0
        $specs.Add($component)

        $prop=New-Object MtAddonPiece
        $prop.TypeNumeric=0
        $prop.IsProp=$true
        $prop.Number=0
        $prop.TextureCount=2
        $prop.HasSkin=$false
        $prop.EnableHairScale=$true
        $prop.HairScaleValue=1.0
        $specs.Add($prop)

        [MtAddonYmtBuilder]::Build($tmp,'mtstudio_selftest',$specs.ToArray())
        if(-not (Test-Path -LiteralPath $tmp)){throw 'O backend não criou o YMT de teste.'}
        $len=(Get-Item -LiteralPath $tmp).Length
        if($len -lt 256){throw "YMT de teste inválido/pequeno demais: $len bytes."}
        Write-Host "MT_ADDON_BACKEND_SELFTEST_OK ($len bytes)"
    } finally {
        if($tmp -and (Test-Path -LiteralPath $tmp)){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
    }
}

if($env:MT_PACK_ORGANIZER_SELFTEST -eq '1'){
    Invoke-AddonBackendSelfTest
    exit 0
}

# ------------------------------ XAML MT Studio --------------------------------

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="MT Studio • Pack Organizer"
        Width="1480" Height="900" MinWidth="1220" MinHeight="740"
        WindowStartupLocation="CenterScreen" Background="#09090D" Foreground="#FFFFFF" WindowStyle="None" ResizeMode="CanResize">
<shell:WindowChrome.WindowChrome><shell:WindowChrome CaptionHeight="0" ResizeBorderThickness="6" CornerRadius="0" GlassFrameThickness="0"/></shell:WindowChrome.WindowChrome>
<Window.Resources>
    <SolidColorBrush x:Key="Neon" Color="#A432DC"/><SolidColorBrush x:Key="Lilac" Color="#D9A4F1"/>
    <SolidColorBrush x:Key="Graphite" Color="#1F1F24"/><SolidColorBrush x:Key="Panel" Color="#111114"/>
    <SolidColorBrush x:Key="Line" Color="#2D2931"/><SolidColorBrush x:Key="Muted" Color="#8E8992"/>
    <Style TargetType="TextBlock"><Setter Property="FontFamily" Value="Montserrat,Segoe UI"/></Style>
    <Style x:Key="BaseButton" TargetType="Button">
        <Setter Property="Background" Value="#1F1F24"/><Setter Property="Foreground" Value="#FFFFFF"/>
        <Setter Property="BorderBrush" Value="#37323D"/><Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="15,10"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontWeight" Value="SemiBold"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#795189"/><Setter TargetName="b" Property="Background" Value="#302637"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.82"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="Button" BasedOn="{StaticResource BaseButton}"/>
    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource BaseButton}"><Setter Property="Background" Value="#A432DC"/><Setter Property="BorderBrush" Value="#BC79E5"/><Setter Property="FontSize" Value="14"/></Style>
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource BaseButton}"><Setter Property="Background" Value="#211619"/><Setter Property="BorderBrush" Value="#8E3D4A"/><Setter Property="Foreground" Value="#FFB5BE"/><Setter Property="FontSize" Value="14"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#0D0D10"/><Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="BorderBrush" Value="#37323D"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="10,8"/><Style.Triggers><Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter Property="BorderBrush" Value="#A432DC"/></Trigger></Style.Triggers></Style>
    <Style TargetType="ComboBoxItem">
        <Setter Property="Foreground" Value="#ECE9F0"/><Setter Property="Background" Value="#121216"/>
        <Setter Property="Padding" Value="10,8"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
            <Border Name="cbItem" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}" Margin="2,1">
                <TextBlock Text="{Binding Display}" Foreground="{TemplateBinding Foreground}" FontSize="10"/>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="cbItem" Property="Background" Value="#291734"/><Setter Property="Foreground" Value="#F0D5FF"/></Trigger>
                <Trigger Property="IsSelected" Value="True"><Setter TargetName="cbItem" Property="Background" Value="#351746"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBox">
        <Setter Property="Background" Value="#0C0C0F"/><Setter Property="Foreground" Value="#F5F2F7"/>
        <Setter Property="BorderBrush" Value="#343039"/><Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox">
            <Grid>
                <Border Name="cbBorder" Background="#0C0C0F" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="7">
                    <Grid>
                        <TextBlock Text="{Binding SelectedItem.Display, RelativeSource={RelativeSource TemplatedParent}}" Foreground="#F5F2F7" FontSize="10" Margin="11,0,34,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                        <TextBlock Text="⌄" Foreground="#C86EFF" FontSize="16" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,11,3"/>
                    </Grid>
                </Border>
                <ToggleButton Focusable="False" Background="Transparent" Foreground="Transparent" BorderBrush="Transparent" BorderThickness="0"
                              IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                    <ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border Background="#01000000"/></ControlTemplate></ToggleButton.Template>
                </ToggleButton>
                <Popup Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                    <Border Background="#0E0E12" BorderBrush="#5C2C72" BorderThickness="1" CornerRadius="8" Padding="4" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="360">
                        <ScrollViewer Background="#0E0E12" VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
                    </Border>
                </Popup>
            </Grid>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="cbBorder" Property="Background" Value="#101015"/><Setter TargetName="cbBorder" Property="BorderBrush" Value="#6E3A82"/></Trigger>
                <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="cbBorder" Property="BorderBrush" Value="#A320FF"/></Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#D8D4DC"/><Setter Property="FontSize" Value="9.5"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="ListBox"><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/><Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/></Style>
    <Style TargetType="ListBoxItem"><Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="Background" Value="Transparent"/><Setter Property="Padding" Value="7"/><Setter Property="Margin" Value="0,0,0,8"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem"><Border Name="ib" Background="#17151B" BorderBrush="#302A36" BorderThickness="1" CornerRadius="11" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property="IsSelected" Value="True"><Setter TargetName="ib" Property="BorderBrush" Value="#8150A0"/><Setter TargetName="ib" Property="Background" Value="#21182A"/></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ib" Property="BorderBrush" Value="#624675"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
    <Style TargetType="ScrollBar">
        <Setter Property="Width" Value="9"/><Setter Property="Background" Value="Transparent"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Grid Width="9" Background="#0B0B0E"><Track Name="PART_Track" IsDirectionReversed="True" Orientation="{TemplateBinding Orientation}" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" Value="{TemplateBinding Value}" ViewportSize="{TemplateBinding ViewportSize}"><Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0"/></Track.DecreaseRepeatButton><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#6E347E" CornerRadius="4" Margin="2,1"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0"/></Track.IncreaseRepeatButton></Track></Grid></ControlTemplate></Setter.Value></Setter>
    </Style>
</Window.Resources>
<Grid Background="#09090D">
    <Grid.RowDefinitions><RowDefinition Height="5"/><RowDefinition Height="92"/><RowDefinition Height="*"/><RowDefinition Height="30"/></Grid.RowDefinitions>
    <Rectangle Grid.Row="0" Fill="#A432DC"/>

    <Border Name="topHeader" Grid.Row="1" Background="#080809" BorderBrush="#19171D" BorderThickness="0,0,0,1">
        <Grid Margin="22,8"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border Width="154" Height="76" Background="Transparent" Margin="0,0,20,0" VerticalAlignment="Center"><Image Name="imgBrandLogo" Width="150" Height="74" Stretch="Uniform" HorizontalAlignment="Center" VerticalAlignment="Center" RenderOptions.BitmapScalingMode="HighQuality" SnapsToDevicePixels="True"/></Border>
            <StackPanel Grid.Column="1" VerticalAlignment="Center"><StackPanel Orientation="Horizontal"><TextBlock Text="PACK ORGANIZER" FontSize="22" FontWeight="Bold"/><Border Background="#211229" BorderBrush="#5B286B" BorderThickness="1" CornerRadius="9" Padding="7,2" Margin="10,3,0,0" VerticalAlignment="Top"><TextBlock Name="lblVersion" Text="v0.0.0" Foreground="#D88BFF" FontSize="8" FontWeight="Bold"/></Border></StackPanel><TextBlock Text="VISUALIZE • ORGANIZE • GERE O ADD-ON" Foreground="#8E8992" FontSize="9" Margin="0,5,0,0"/><Rectangle Width="64" Height="3" Fill="#A320FF" HorizontalAlignment="Left" Margin="0,9,0,0"/></StackPanel>
            <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center"><StackPanel Name="packHeaderInfo" Visibility="Collapsed" Margin="0,0,15,0" MaxWidth="360"><TextBlock Name="lblPackName" Text="" FontWeight="SemiBold" HorizontalAlignment="Right"/><TextBlock Name="lblPackPath" Text="" Foreground="#68646D" FontSize="9" TextTrimming="CharacterEllipsis" HorizontalAlignment="Right"/></StackPanel><Button Name="btnUpdate" Content="↓  ATUALIZAR" Width="114" Height="38" Margin="0,0,10,0" Padding="9,0" FontSize="11" FontWeight="Bold" Visibility="Collapsed" Background="#291333" BorderBrush="#8642AB" Foreground="#E9C3FF" ToolTip="Nova versão disponível para instalar"/><Button Name="btnHelp" Content="AJUDA" Width="85" Height="39" Margin="0,0,10,0" Padding="7,0" FontSize="11" FontWeight="Bold" ToolTip="Como usar e atalhos do aplicativo"/><Button Name="btnHome" Width="43" Height="42" Margin="0,0,8,0" Padding="0" Visibility="Collapsed" ToolTip="Voltar para meus projetos"><Canvas Width="22" Height="22"><Polygon Points="1,10 11,1 21,10" Fill="#D88BFF"/><Rectangle Canvas.Left="4" Canvas.Top="9" Width="14" Height="12" Fill="#D88BFF"/><Rectangle Canvas.Left="9" Canvas.Top="14" Width="5" Height="7" Fill="#211D28"/></Canvas></Button></StackPanel>
            <StackPanel Grid.Column="4" Orientation="Horizontal" Margin="12,0,0,0" VerticalAlignment="Top"><Button Name="btnWinMin" Content="—" Width="34" Height="28" Padding="0" FontSize="13"/><Button Name="btnWinMax" Content="□" Width="34" Height="28" Padding="0" FontSize="12" Margin="4,0,0,0"/><Button Name="btnWinClose" Content="×" Width="34" Height="28" Padding="0" FontSize="16" Margin="4,0,0,0" Background="#251519" BorderBrush="#6E2D3B"/></StackPanel>
        </Grid>
    </Border>

    <Grid Grid.Row="2" Name="emptyState" Margin="28,22">
        <Border MaxWidth="1160" Background="#101014" BorderBrush="#312B38" BorderThickness="1" CornerRadius="17" HorizontalAlignment="Stretch" VerticalAlignment="Top" Padding="28">
            <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="ESPAÇO DE TRABALHO" Foreground="#BE8BD8" FontSize="10" FontWeight="Bold"/><TextBlock Text="Seus projetos" FontSize="29" FontWeight="Bold" Margin="0,5,0,0"/><TextBlock Text="Todos os packs em um só lugar, com suas decisões e progresso preservados." Foreground="#AAA1B0" FontSize="12" Margin="0,8,0,0"/></StackPanel>
                    <Button Name="btnNewProject" Grid.Column="1" Content="+  NOVO PROJETO" Style="{StaticResource PrimaryButton}" Height="46" Width="182" FontSize="12" FontWeight="Bold" VerticalAlignment="Center"/>
                </Grid>
                <Border Grid.Row="1" Background="#18151E" BorderBrush="#342B3A" BorderThickness="1" CornerRadius="11" Margin="0,23,0,19" Padding="20,16">
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="1"/><ColumnDefinition Width="*"/><ColumnDefinition Width="1"/><ColumnDefinition Width="*"/><ColumnDefinition Width="1"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <StackPanel><TextBlock Text="PROJETOS SALVOS" Foreground="#A49AAB" FontSize="10" FontWeight="SemiBold"/><TextBlock Name="lblHomeProjects" Text="0" FontSize="23" FontWeight="Bold" Foreground="#F1DEFA" Margin="0,5,0,0"/></StackPanel>
                        <Rectangle Grid.Column="1" Width="1" Fill="#39303E" Margin="0,3,0,3"/>
                        <StackPanel Grid.Column="2" Margin="20,0,0,0"><TextBlock Text="PEÇAS MARCADAS" Foreground="#A49AAB" FontSize="10" FontWeight="SemiBold"/><TextBlock Name="lblHomeReviewed" Text="0 / 0" FontSize="23" FontWeight="Bold" Foreground="#F1DEFA" Margin="0,5,0,0"/></StackPanel>
                        <Rectangle Grid.Column="3" Width="1" Fill="#39303E" Margin="0,3,0,3"/>
                        <StackPanel Grid.Column="4" Margin="20,0,0,0"><TextBlock Text="MANTER" Foreground="#A49AAB" FontSize="10" FontWeight="SemiBold"/><TextBlock Name="lblHomeKeep" Text="0" FontSize="23" FontWeight="Bold" Foreground="#B9A0F0" Margin="0,5,0,0"/></StackPanel>
                        <Rectangle Grid.Column="5" Width="1" Fill="#39303E" Margin="0,3,0,3"/>
                        <StackPanel Grid.Column="6" Margin="20,0,0,0"><TextBlock Text="EXCLUIR" Foreground="#A49AAB" FontSize="10" FontWeight="SemiBold"/><TextBlock Name="lblHomeDelete" Text="0" FontSize="23" FontWeight="Bold" Foreground="#F2A2AF" Margin="0,5,0,0"/></StackPanel>
                    </Grid>
                </Border>
                <Border Grid.Row="2" Background="#131218" CornerRadius="12" BorderBrush="#302A36" BorderThickness="1" Padding="18">
                    <DockPanel><Grid DockPanel.Dock="Top" Margin="0,0,0,14"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="RETOMAR PROJETOS" FontSize="12" FontWeight="Bold" Foreground="#E4C0F6"/><TextBlock Grid.Column="1" Text="Continue da última peça visualizada" Foreground="#918799" FontSize="10"/></Grid>
                    <TextBlock Name="lblNoProjects" DockPanel.Dock="Top" Text="Você ainda não tem projetos. Crie seu primeiro pack para começar." Foreground="#A59AA8" FontSize="12" Margin="0,15,0,0" Visibility="Collapsed"/>
                    <ListBox Name="lstRecentProjects" MinHeight="190" MaxHeight="490" Background="Transparent" BorderThickness="0" ScrollViewer.VerticalScrollBarVisibility="Auto" ToolTip="Use CONTINUAR para retomar um projeto"/></DockPanel>
                </Border>
                <Image Name="imgEmptyLogo" Visibility="Collapsed"/>
            </Grid>
        </Border>
    </Grid>

    <Grid Grid.Row="2" Name="mainContent" Visibility="Collapsed" Margin="18,8,18,14">
        <Grid.ColumnDefinitions><ColumnDefinition Width="342"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="300"/></Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="#151319" CornerRadius="14" BorderBrush="#342C3A" BorderThickness="1" Padding="17"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <StackPanel><TextBlock Text="PEÇA ATUAL" Foreground="#D6A1EE" FontSize="11" FontWeight="Bold"/><TextBlock Name="lblPieceIndex" Text="0000 / 0000" FontSize="24" FontWeight="Bold" Margin="0,4,0,0"/><TextBlock Name="lblPieceName" Text="-" Margin="0,8,0,0" FontSize="12" TextWrapping="Wrap" FontWeight="SemiBold"/><TextBlock Name="lblPiecePath" Text="-" Visibility="Collapsed"/><TextBlock Name="lblMesh" Foreground="#A49AA9" FontSize="10" Margin="0,6,0,0"/><TextBlock Name="lblDetectedCategory" Foreground="#C994E4" FontSize="10" FontWeight="SemiBold" Margin="0,7,0,0"/></StackPanel>
            <StackPanel Grid.Row="1" Margin="0,14,0,0"><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><Button Name="btnPrev" Content="‹  ANTERIOR" Height="39" Margin="0,0,5,0"/><Button Name="btnNext" Grid.Column="1" Content="PRÓXIMA  ›" Height="39" Margin="5,0,0,0"/></Grid><Grid Margin="0,7,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><Button Name="btnFirst" Content="INÍCIO" Height="34" FontSize="11" FontWeight="Bold" Margin="0,0,5,0"/><Button Name="btnLast" Grid.Column="1" Content="FIM" Height="34" FontSize="11" FontWeight="Bold" Margin="5,0,0,0"/></Grid><Button Name="btnNextPending" Content="↳  ÚLTIMA PENDENTE" Height="39" Margin="0,9,0,0" Background="#372143" BorderBrush="#75538C" Foreground="#E8CEF4" ToolTip="Busca desde o início do pack a primeira peça sem decisão, independentemente da categoria."/><TextBlock Name="lblPendingJump" Text="" Foreground="#BCA3D0" FontSize="10" TextWrapping="Wrap" Margin="1,5,0,0"/></StackPanel>
            <Border Grid.Row="2" Background="#0C0C10" BorderBrush="#29252F" BorderThickness="1" CornerRadius="10" Padding="10" Margin="0,11,0,0">
                <StackPanel>
                    <TextBlock Text="FILTRAR POR CATEGORIA" Foreground="#D6A1EE" FontSize="10" FontWeight="Bold"/>
                    <ComboBox Name="cmbCategory" Height="34" Margin="0,6,0,0" DisplayMemberPath="Display" SelectedValuePath="Key"/>
                    <CheckBox Name="chkHideHair" Content="ESCONDER CABELO" Margin="2,9,0,0" Visibility="Collapsed"/>
                </StackPanel>
            </Border>
            <Separator Grid.Row="3" Margin="0,12,0,10" Background="#2D2931"/>
            <Grid Grid.Row="4"><TextBlock Text="TEXTURAS" Foreground="#D6A1EE" FontSize="11" FontWeight="Bold"/><TextBlock Name="lblTextureCount" Text="0 TEXTURAS" Foreground="#A399AB" FontSize="10" HorizontalAlignment="Right"/></Grid>
            <TextBlock Grid.Row="5" Text="Miniatura • formato • resolução" Foreground="#958A9E" FontSize="10" Margin="0,6,0,9"/>
            <Grid Grid.Row="6"><Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><ListBox Name="lstTextures"/><TextBlock Name="lblTextureInfo" Grid.Row="1" Foreground="#A49AA9" FontSize="10" TextWrapping="Wrap" Margin="0,8,0,0"/><Button Name="btnDeleteTexture" Grid.Row="2" Content="EXCLUIR TEXTURA SELECIONADA" Height="40" Margin="0,10,0,12" Background="#211619" BorderBrush="#8E3D4A" Foreground="#FFB5BE"/></Grid>
        </Grid></Border>

        <Border Grid.Column="2" Background="#09090B" CornerRadius="13" BorderBrush="#252229" BorderThickness="1" ClipToBounds="True"><Grid Name="viewHost" Background="#09090B" Focusable="True"><Viewport3D Name="viewport"/>
            <Border VerticalAlignment="Top" HorizontalAlignment="Left" Margin="14" Padding="9,5" CornerRadius="7" Background="#D0141417"><StackPanel Orientation="Horizontal"><Ellipse Width="6" Height="6" Fill="#A320FF" Margin="0,0,7,0"/><TextBlock Text="3D REAL • LOCAL" FontSize="9" FontWeight="Bold"/></StackPanel></Border>
            <StackPanel VerticalAlignment="Top" HorizontalAlignment="Right" Margin="14">
                <Border Padding="10,7" CornerRadius="10" Background="#19141F" BorderBrush="#543064" BorderThickness="1"><StackPanel Orientation="Horizontal"><TextBlock Text="☀" Foreground="#D88BFF" FontSize="17" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="ILUMINAÇÃO" Foreground="#DCC3E8" FontWeight="Bold" FontSize="9" VerticalAlignment="Center" Margin="0,0,9,0"/><Button Name="btnLightDown" Content="−" Width="29" Height="28" Padding="0" FontSize="17"/><Border Background="#261B2C" CornerRadius="5" Width="48" Margin="5,0" Padding="2" VerticalAlignment="Center"><TextBlock Name="lblLightValue" Text="50%" FontSize="11" FontWeight="Bold" TextAlignment="Center" Foreground="#FFFFFF"/></Border><Button Name="btnLightUp" Content="+" Width="29" Height="28" Padding="0" FontSize="16"/></StackPanel></Border>
                <Button Name="btnResetPosition" Content="↺  RESTAURAR POSIÇÃO PADRÃO" Height="33" FontSize="10" FontWeight="SemiBold" Margin="0,8,0,0" Background="#201827" Foreground="#DBBCEB" BorderBrush="#664477" ToolTip="Restaura a rotação, o tamanho e a posição original da peça no visualizador 3D."/>
            </StackPanel>
            <Grid Name="transformBox" Width="330" Height="440" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed" Background="#01000000">
                <Border BorderBrush="#8E8A93" BorderThickness="0.85" Opacity="0.78" IsHitTestVisible="False"/>
                <!-- Os destaques são desenhados sob demanda: nenhum puxador permanente. -->
                <Rectangle Name="hoverLeft" Width="16" Fill="#70D5A0F5" HorizontalAlignment="Left" Margin="3,29,0,29" Visibility="Collapsed" IsHitTestVisible="False"/>
                <Rectangle Name="hoverRight" Width="16" Fill="#70D5A0F5" HorizontalAlignment="Right" Margin="0,29,3,29" Visibility="Collapsed" IsHitTestVisible="False"/>
                <Rectangle Name="hoverTop" Height="16" Fill="#70D5A0F5" VerticalAlignment="Top" Margin="29,3,29,0" Visibility="Collapsed" IsHitTestVisible="False"/>
                <Rectangle Name="hoverBottom" Height="16" Fill="#70D5A0F5" VerticalAlignment="Bottom" Margin="29,0,29,3" Visibility="Collapsed" IsHitTestVisible="False"/>
                <Rectangle Name="hoverNW" Width="28" Height="28" Fill="#9AD5A0F5" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="2,2,0,0" Visibility="Collapsed" IsHitTestVisible="False"/>
                <Rectangle Name="hoverNE" Width="28" Height="28" Fill="#9AD5A0F5" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,2,2,0" Visibility="Collapsed" IsHitTestVisible="False"/>
                <Rectangle Name="hoverSW" Width="28" Height="28" Fill="#9AD5A0F5" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="2,0,0,2" Visibility="Collapsed" IsHitTestVisible="False"/>
                <Rectangle Name="hoverSE" Width="28" Height="28" Fill="#9AD5A0F5" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,2,2" Visibility="Collapsed" IsHitTestVisible="False"/>
                <!-- Manipulador central independente: X vermelho, Y azul e Z verde, como no Photoshop 3D. -->
                <Canvas Name="centerAxisWidget" Width="120" Height="120" HorizontalAlignment="Center" VerticalAlignment="Center" Background="Transparent">
                    <Ellipse Name="centerRotateRing" Width="86" Height="86" Canvas.Left="17" Canvas.Top="17" Stroke="#E5C938" StrokeThickness="2" Visibility="Collapsed" Cursor="Hand" ToolTip="Girar em torno do eixo Z"/>
                    <Line Name="centerAxisY" X1="60" Y1="60" X2="34" Y2="86" Stroke="#69A4FF" StrokeThickness="3.4" Cursor="SizeAll" ToolTip="Mover no eixo Y (profundidade)"/>
                    <Polygon Name="centerTipY" Points="28,92 33,78 42,87" Fill="#69A4FF" Cursor="SizeAll" ToolTip="Mover no eixo Y (profundidade)"/>
                    <Line Name="centerAxisX" X1="60" Y1="60" X2="101" Y2="60" Stroke="#F46D80" StrokeThickness="3.4" Cursor="SizeWE" ToolTip="Mover no eixo X"/>
                    <Polygon Name="centerTipX" Points="101,54 114,60 101,66" Fill="#F46D80" Cursor="SizeWE" ToolTip="Mover no eixo X"/>
                    <Line Name="centerAxisZ" X1="60" Y1="60" X2="60" Y2="19" Stroke="#64DD8A" StrokeThickness="3.4" Cursor="SizeNS" ToolTip="Mover no eixo Z"/>
                    <Polygon Name="centerTipZ" Points="54,19 60,6 66,19" Fill="#64DD8A" Cursor="SizeNS" ToolTip="Mover no eixo Z"/>
                    <Ellipse Width="13" Height="13" Canvas.Left="53.5" Canvas.Top="53.5" Fill="#DDE4F0" Stroke="#6D7280" StrokeThickness="1.3"/>
                </Canvas>
            </Grid>
            <Border VerticalAlignment="Bottom" HorizontalAlignment="Center" Margin="0,0,0,14" Padding="11,6" CornerRadius="8" Background="#D0141417"><TextBlock Name="lblTransformHint" Text="Selecione a peça • aproxime o mouse de uma borda ou canto • Ctrl + rolagem = escala" Foreground="#A5A1AA" FontSize="9"/></Border>
        </Grid></Border>

        <Border Grid.Column="4" Background="#151319" CornerRadius="13" BorderBrush="#342C3A" BorderThickness="1" Padding="17"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel>
            <TextBlock Text="DECISÃO" Foreground="#D6A1EE" FontSize="11" FontWeight="Bold"/><StackPanel Orientation="Horizontal" Margin="0,8,0,14"><Ellipse Name="decisionDot" Width="8" Height="8" Fill="#66666D" Margin="0,0,8,0"/><TextBlock Name="lblDecision" Text="PENDENTE" FontSize="14" FontWeight="Bold"/></StackPanel>
            <Button Name="btnKeep" Content="1   MANTER" Style="{StaticResource PrimaryButton}" Height="50" Margin="0,0,0,8"/><Button Name="btnDelete" Content="2   EXCLUIR" Style="{StaticResource DangerButton}" Height="50"/><Button Name="btnUndo" Content="↶   DESFAZER ÚLTIMA" Height="38" Margin="0,8,0,0"/>
            <Separator Margin="0,14,0,12" Background="#39303E"/><TextBlock Text="PROGRESSO" Foreground="#D6A1EE" FontSize="11" FontWeight="Bold"/><TextBlock Name="lblDone" Text="0 / 0" FontSize="19" FontWeight="Bold" Margin="0,6,0,7"/><ProgressBar Name="progress" Height="5" Minimum="0" Maximum="100" Foreground="#A432DC" Background="#29232F"/><Grid Margin="0,11,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><Border Background="#241A2E" CornerRadius="9" Padding="10" Margin="0,0,4,0"><StackPanel><TextBlock Name="lblKeepCount" Text="0" FontSize="19" FontWeight="Bold" Foreground="#D6A1EE"/><TextBlock Text="MANTER" Foreground="#B0A3B9" FontSize="10"/></StackPanel></Border><Border Grid.Column="1" Background="#291C23" CornerRadius="9" Padding="10" Margin="4,0,0,0"><StackPanel><TextBlock Name="lblDeleteCount" Text="0" FontSize="19" FontWeight="Bold" Foreground="#FF9AAA"/><TextBlock Text="EXCLUIR" Foreground="#B0A3B9" FontSize="10"/></StackPanel></Border></Grid>
            <Separator Margin="0,14,0,12" Background="#39303E"/><Button Name="btnApply" Content="APLICAR EXCLUSÕES" Height="40"/><TextBlock Text="Move os arquivos para _PARA_EXCLUIR. Nada é apagado definitivamente." Foreground="#A49AA9" FontSize="10" TextWrapping="Wrap" Margin="0,8,0,0"/>
            <Border Margin="0,16,0,0" Background="#1C1722" BorderBrush="#493450" BorderThickness="1" CornerRadius="11" Padding="13"><StackPanel><TextBlock Text="GERAR ADD-ON FIVEM" FontWeight="Bold" FontSize="11"/><TextBlock Text="1 resource • até 150 peças por categoria em cada DLC • r → whi • u → uni." Foreground="#A49AA9" FontSize="10" TextWrapping="Wrap" Margin="0,8,0,12"/><TextBlock Text="NOME DO ADD-ON" Foreground="#D6A1EE" FontSize="10" FontWeight="Bold"/><TextBox Name="txtAddonName" Text="mtstudio_pack" Margin="0,6,0,10"/><Button Name="btnBuildAddon" Content="GERAR ADD-ON" Style="{StaticResource PrimaryButton}" Height="42"/><TextBlock Name="lblBuildStatus" Text="Pronto para gerar" Foreground="#A49AA9" FontSize="10" TextWrapping="Wrap" Margin="0,8,0,0"/></StackPanel></Border>
        </StackPanel></ScrollViewer></Border>
    </Grid>

    <Popup Name="texturePreviewPopup" AllowsTransparency="True" StaysOpen="True" IsHitTestVisible="False" Placement="Right" PopupAnimation="None"><Border Width="360" Background="#111114" BorderBrush="#A320FF" BorderThickness="1" CornerRadius="12" Padding="12"><StackPanel><TextBlock Name="lblTexturePreviewName" Foreground="#FFFFFF" FontWeight="SemiBold" FontSize="10" TextTrimming="CharacterEllipsis"/><TextBlock Name="lblTexturePreviewMeta" Foreground="#8E8992" FontSize="9" Margin="0,3,0,9"/><Border Width="334" Height="334" Background="#09090B" BorderBrush="#2D2931" BorderThickness="1" CornerRadius="7"><Image Name="imgTexturePreview" Stretch="Uniform" Margin="6"/></Border></StackPanel></Border></Popup>

    <Border Grid.Row="2" Name="loadingOverlay" Visibility="Collapsed" Background="#F009080D" Panel.ZIndex="99"><Border Width="510" Padding="30" Background="#17131D" BorderBrush="#654279" BorderThickness="1" CornerRadius="17" HorizontalAlignment="Center" VerticalAlignment="Center"><StackPanel>
        <TextBlock Text="MT STUDIO  /  PREPARANDO PROJETO" Foreground="#BD8BD9" FontSize="10" FontWeight="Bold"/>
        <Canvas Width="220" Height="116" Margin="0,15,0,0" HorizontalAlignment="Center" ClipToBounds="False">
            <Canvas Width="76" Height="76" Canvas.Left="32" Canvas.Top="21" RenderTransformOrigin="0.5,0.5">
                <Canvas.RenderTransform><RotateTransform Angle="-14"/></Canvas.RenderTransform>
                <Canvas.Triggers><EventTrigger RoutedEvent="Canvas.Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)" From="-20" To="17" Duration="0:0:1.7" AutoReverse="True"/><DoubleAnimation Storyboard.TargetProperty="(Canvas.Top)" From="21" To="5" Duration="0:0:1.35" AutoReverse="True"/><DoubleAnimation Storyboard.TargetProperty="(Canvas.Left)" From="32" To="62" Duration="0:0:2.3" AutoReverse="True"/></Storyboard></BeginStoryboard></EventTrigger></Canvas.Triggers>
                <Image Name="imgWingLeftA" Width="76" Height="76"><Image.Clip><RectangleGeometry Rect="0,0,38,76"/></Image.Clip><Image.RenderTransform><ScaleTransform CenterX="38" ScaleX="1"/></Image.RenderTransform><Image.Triggers><EventTrigger RoutedEvent="Image.Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" From="1" To="0.13" Duration="0:0:0.13" AutoReverse="True"/></Storyboard></BeginStoryboard></EventTrigger></Image.Triggers></Image>
                <Image Name="imgWingRightA" Width="76" Height="76"><Image.Clip><RectangleGeometry Rect="38,0,38,76"/></Image.Clip><Image.RenderTransform><ScaleTransform CenterX="38" ScaleX="1"/></Image.RenderTransform><Image.Triggers><EventTrigger RoutedEvent="Image.Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" From="1" To="0.13" Duration="0:0:0.13" AutoReverse="True"/></Storyboard></BeginStoryboard></EventTrigger></Image.Triggers></Image>
            </Canvas>
            <Canvas Width="65" Height="65" Canvas.Left="122" Canvas.Top="13" RenderTransformOrigin="0.5,0.5">
                <Canvas.RenderTransform><RotateTransform Angle="18"/></Canvas.RenderTransform>
                <Canvas.Triggers><EventTrigger RoutedEvent="Canvas.Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)" From="22" To="-19" Duration="0:0:1.45" AutoReverse="True"/><DoubleAnimation Storyboard.TargetProperty="(Canvas.Top)" From="13" To="36" Duration="0:0:1.85" AutoReverse="True"/><DoubleAnimation Storyboard.TargetProperty="(Canvas.Left)" From="122" To="96" Duration="0:0:2.1" AutoReverse="True"/></Storyboard></BeginStoryboard></EventTrigger></Canvas.Triggers>
                <Image Name="imgWingLeftB" Width="65" Height="65"><Image.Clip><RectangleGeometry Rect="0,0,32.5,65"/></Image.Clip><Image.RenderTransform><ScaleTransform CenterX="32.5" ScaleX="1"/></Image.RenderTransform><Image.Triggers><EventTrigger RoutedEvent="Image.Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" From="1" To="0.13" Duration="0:0:0.17" AutoReverse="True"/></Storyboard></BeginStoryboard></EventTrigger></Image.Triggers></Image>
                <Image Name="imgWingRightB" Width="65" Height="65"><Image.Clip><RectangleGeometry Rect="32.5,0,32.5,65"/></Image.Clip><Image.RenderTransform><ScaleTransform CenterX="32.5" ScaleX="1"/></Image.RenderTransform><Image.Triggers><EventTrigger RoutedEvent="Image.Loaded"><BeginStoryboard><Storyboard RepeatBehavior="Forever"><DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" From="1" To="0.13" Duration="0:0:0.17" AutoReverse="True"/></Storyboard></BeginStoryboard></EventTrigger></Image.Triggers></Image>
            </Canvas>
        </Canvas>
        <TextBlock Name="lblLoading" Text="INDEXANDO O PACK..." FontSize="18" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,8,0,11"/>
        <ProgressBar Name="loadingProgress" Height="6" Minimum="0" Maximum="100" Value="0" Foreground="#A432DC" Background="#34273C"/>
        <TextBlock Name="lblLoadingPercent" Text="LOCALIZANDO ARQUIVOS" Foreground="#DAB6ED" FontWeight="SemiBold" FontSize="11" TextAlignment="Center" Margin="0,11,0,0"/>
        <TextBlock Name="lblLoadingActivity" Text="Preparando os arquivos do projeto..." Foreground="#C5B0D2" FontSize="12" TextAlignment="Center" Margin="0,8,0,0"/>
        <TextBlock Text="O progresso acompanha a indexação real de cada arquivo. A busca inicial identifica o total do pack." Foreground="#8D8397" FontSize="10" TextAlignment="Center" TextWrapping="Wrap" Margin="0,14,0,0"/>
    </StackPanel></Border></Border>

    <Grid Grid.Row="3" Margin="18,0"><TextBlock Text="MT STUDIO  •  ONDE IDEIAS VIRAM IDENTIDADE" Foreground="#867B8A" FontSize="9" VerticalAlignment="Center"/><TextBlock Text="1 manter  •  2 excluir  •  ← → navegar  •  Shift girar 5°  •  Z desfazer  •  R resetar" Foreground="#867B8A" FontSize="9" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
</Grid>
</Window>
'@

try {
    [xml]$xaml = $xamlText
} catch {
    Write-AppLog ("XAML XML inválido: " + $_.Exception.ToString())
    Show-Error ("A interface do MT Pack Organizer contém um erro de XAML.`n`n" + $_.Exception.Message)
    exit
}

try {
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    Write-AppLog ("Falha ao carregar XAML WPF: " + $_.Exception.ToString())
    Show-Error ("Não consegui carregar a interface do MT Pack Organizer.`n`n" + $_.Exception.Message)
    exit
}

foreach($n in @(
    'btnUpdate','btnHelp','btnHome','btnNewProject','lblHomeProjects','lblHomeReviewed','lblHomeKeep','lblHomeDelete','packHeaderInfo','lblPackName','lblPackPath','emptyState','mainContent',
    'lblPieceIndex','lblPieceName','lblPiecePath','lblMesh','lblDetectedCategory','lblVersion','btnPrev','btnNext','btnFirst','btnLast','btnNextPending','lblPendingJump','cmbCategory','chkHideHair','lstRecentProjects','lblNoProjects',
    'lstTextures','lblTextureCount','lblTextureInfo','btnDeleteTexture','viewport','viewHost','btnLightDown','btnLightUp','btnResetPosition','lblLightValue','transformBox','lblTransformHint','hoverLeft','hoverRight','hoverTop','hoverBottom','hoverNW','hoverNE','hoverSW','hoverSE','centerAxisWidget','centerAxisX','centerAxisY','centerAxisZ','centerTipX','centerTipY','centerTipZ','centerRotateRing','texturePreviewPopup','imgTexturePreview','lblTexturePreviewName','lblTexturePreviewMeta',
    'decisionDot','lblDecision','btnKeep','btnDelete','btnUndo',
    'lblDone','progress','lblKeepCount','lblDeleteCount','btnApply','txtAddonName','btnBuildAddon','lblBuildStatus','btnWinMin','btnWinMax','btnWinClose','topHeader','imgBrandLogo','imgEmptyLogo','imgWingLeftA','imgWingRightA','imgWingLeftB','imgWingRightB','loadingOverlay','lblLoading','lblLoadingActivity','lblLoadingPercent','loadingProgress'
)) { Set-Variable -Name $n -Value $win.FindName($n) -Scope Script }

$script:AddonNameSaved = $null
$script:PackPath = $null
$script:Pieces = @()
$script:Decisions = @{}
$script:TextureDeletions = @{}
$script:Index = 0
$script:SavedView=$null
$script:LightLevel=50
$script:CurrentTextures=@()
$script:TextureCache = @{}
$script:TextureCacheCost = @{}
$script:TextureCacheBytes = [long]0
$script:TextureCacheOrder = @()
$script:TextureInfoCache = @{}
$script:VariantIndex = @{}
$script:CategoryOverrides = @{}
$script:HideHairSelections = @{}
$script:PropAlignment=@{}
$script:CurrentPropSlot=''
$script:UpdatingPieceOptions = $false
$script:MeshCache = @{}
$script:MeshCacheOrder = @()
$script:ThumbGeneration = 0
$script:ThumbTimer = $null
$script:PopulatingTextures = $false
$script:AppVersion = '0.9.41'
$script:SupportDiscordUrl = 'https://discord.gg/MAPubH3vRw'
try {
    $lblVersion.Text="v$($script:AppVersion)"
    $win.Title="MT Studio • Pack Organizer $($script:AppVersion)"
} catch {}
$script:UpdateRepo = '0ladymt/mt-pack-organizer-releases'
$script:PendingUpdateRelease = $null
$script:UpdateJob = $null
$script:UpdateTimer = $null
$script:ThumbQueue = @()
$script:ThumbQueueIndex = 0
$script:SelectedCategoryFilter='all'
$script:Roll=0.0
$script:LastAction = $null
$script:GeometryEntries = @()
$script:MaterialBitmapCache = @{}
$script:ModelRoot = $null
$script:Camera = $null
$script:Yaw = 0.0
$script:Pitch = 0.0
$script:BaseCameraDistance = 1.0
$script:CameraDistance = 1.0
$script:Dragging = $false
$script:TransformBoxEnabled=$false
$script:TransformDragMode=$null
$script:ModelScale=1.0
$script:ModelOffsetX=0.0
$script:ModelOffsetY=0.0
$script:ModelOffsetZ=0.0
$script:SelectionBoxOffsetY=0.0
$script:ModelExtent=1.0
$script:ModelBounds=$null
$script:TransformScreenX=0.0
$script:TransformScreenY=0.0

try {
    $logoPath=Join-Path $PSScriptRoot 'assets\mt_logo.png'
    $butterflyPath=Join-Path $PSScriptRoot 'assets\mt_butterfly_icon.png'
    $runtimeIconPath=Join-Path $PSScriptRoot 'assets\mt_runtime_icon.ico'
    if(Test-Path $logoPath){
        $bi=New-Object Windows.Media.Imaging.BitmapImage
        $bi.BeginInit();$bi.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bi.UriSource=[Uri]::new($logoPath,[UriKind]::Absolute);$bi.EndInit();$bi.Freeze()
        $imgBrandLogo.Source=$bi;$imgEmptyLogo.Source=$bi
    }
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    if(Test-Path $butterflyPath){
        $butterflyBitmap=New-Object Windows.Media.Imaging.BitmapImage
        $butterflyBitmap.BeginInit();$butterflyBitmap.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $butterflyBitmap.UriSource=[Uri]::new($butterflyPath,[UriKind]::Absolute);$butterflyBitmap.EndInit();$butterflyBitmap.Freeze()
        $imgWingLeftA.Source=$butterflyBitmap;$imgWingRightA.Source=$butterflyBitmap
        $imgWingLeftB.Source=$butterflyBitmap;$imgWingRightB.Source=$butterflyBitmap
        $srcIcon=[System.Drawing.Bitmap]::FromFile($butterflyPath)
        $canvas=New-Object System.Drawing.Bitmap 256,256
        $g=[System.Drawing.Graphics]::FromImage($canvas)
        $g.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.Clear([System.Drawing.Color]::Transparent)
        $path=New-Object System.Drawing.Drawing2D.GraphicsPath
        $x=10;$y=10;$w=236;$h=236;$rad=42;$diam=$rad*2
        $path.AddArc($x,$y,$diam,$diam,180,90);$path.AddArc($x+$w-$diam,$y,$diam,$diam,270,90)
        $path.AddArc($x+$w-$diam,$y+$h-$diam,$diam,$diam,0,90);$path.AddArc($x,$y+$h-$diam,$diam,$diam,90,90);$path.CloseFigure()
        $bg=New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,12,10,16))
        $pen=New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255,163,32,255)),5
        $g.FillPath($bg,$path);$g.DrawPath($pen,$path)
        $scale=[Math]::Min(180.0/$srcIcon.Width,180.0/$srcIcon.Height)
        $dw=[int]($srcIcon.Width*$scale);$dh=[int]($srcIcon.Height*$scale)
        $dx=[int]((256-$dw)/2);$dy=[int]((256-$dh)/2);$g.DrawImage($srcIcon,$dx,$dy,$dw,$dh)
        $hIcon=$canvas.GetHicon();$script:TaskbarIcon=[System.Drawing.Icon]::FromHandle($hIcon)
        $fs=[IO.File]::Open($runtimeIconPath,[IO.FileMode]::Create);$script:TaskbarIcon.Save($fs);$fs.Dispose()
        $wpfIcon=[System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($hIcon,[Windows.Int32Rect]::Empty,[Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $wpfIcon.Freeze();$win.Icon=$wpfIcon
        $g.Dispose();$bg.Dispose();$pen.Dispose();$path.Dispose();$srcIcon.Dispose();$canvas.Dispose()
    }
    if(-not ('MtNativeWindow' -as [type])){ Add-Type @"
using System; using System.Runtime.InteropServices;
public static class MtNativeWindow {
 [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr SendMessage(IntPtr hWnd,uint Msg,IntPtr wParam,IntPtr lParam);
 [DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);
}
"@ }
    [void][MtNativeWindow]::SetCurrentProcessExplicitAppUserModelID('MTStudio.PackOrganizer')
    # Windows agrupa pelo processo real (powershell.exe), não pelo launcher Go.
    # Gravar as propriedades de RELANÇAMENTO na janela permite fixá-la na barra
    # como MT Pack Organizer.exe, com o ícone certo, em vez de PowerShell.
    if(-not ('MtTaskbarIdentity' -as [type])){Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface MtWindowPropertyStore {
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetAt(uint index, out MtPropertyKey key);
    [PreserveSig] int GetValue(ref MtPropertyKey key, out MtPropVariant value);
    [PreserveSig] int SetValue(ref MtPropertyKey key, ref MtPropVariant value);
    [PreserveSig] int Commit();
}
[StructLayout(LayoutKind.Sequential)] public struct MtPropertyKey { public Guid fmtid; public uint pid; }
[StructLayout(LayoutKind.Explicit, Size=24)] public struct MtPropVariant {
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr value;
}
public static class MtTaskbarIdentity {
    [DllImport("shell32.dll")] private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, out MtWindowPropertyStore store);
    private static readonly Guid fmt = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    private static void Set(MtWindowPropertyStore store, uint pid, string text) {
        MtPropertyKey key = new MtPropertyKey { fmtid=fmt, pid=pid };
        MtPropVariant value = new MtPropVariant { vt=31, value=Marshal.StringToCoTaskMemUni(text) };
        try { int hr=store.SetValue(ref key, ref value); if(hr!=0) Marshal.ThrowExceptionForHR(hr); }
        finally { Marshal.FreeCoTaskMem(value.value); }
    }
    public static void SetWindow(IntPtr hwnd, string exe, string icon) {
        Guid iid=typeof(MtWindowPropertyStore).GUID;
        MtWindowPropertyStore store;
        int hr=SHGetPropertyStoreForWindow(hwnd,ref iid,out store);
        if(hr!=0) Marshal.ThrowExceptionForHR(hr);
        try {
            Set(store,2,"\""+exe+"\""); // RelaunchCommand precisa preceder o AppID
            Set(store,3,icon+",0"); // RelaunchIconResource
            Set(store,4,"MT Pack Organizer"); // RelaunchDisplayNameResource
            Set(store,5,"MTStudio.PackOrganizer"); // AppUserModel.ID
            store.Commit();
        } finally { Marshal.ReleaseComObject(store); }
    }
}
'@ }
    $win.Add_SourceInitialized({
        try {
            $h=(New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
            if($script:TaskbarIcon){[void][MtNativeWindow]::SendMessage($h,0x80,[IntPtr]0,$script:TaskbarIcon.Handle);[void][MtNativeWindow]::SendMessage($h,0x80,[IntPtr]1,$script:TaskbarIcon.Handle)}
            $nativeExe=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MT Studio\Pack Organizer\MT Pack Organizer.exe'
            if(Test-Path -LiteralPath $nativeExe){[MtTaskbarIdentity]::SetWindow($h,$nativeExe,$nativeExe)}
        } catch {Write-AppLog ('Identidade barra de tarefas: '+$_.Exception.Message)}
    })
} catch { Write-AppLog ('Logo/assets: '+$_.Exception.Message) }

$btnNewProject.Add_Click({ Invoke-Safe { Open-Pack } })
$btnHome.Add_Click({ Invoke-Safe { Go-Home } })
$btnLightDown.Add_Click({ Invoke-Safe { Change-Light -15 } })
$btnLightUp.Add_Click({ Invoke-Safe { Change-Light 15 } })
$btnResetPosition.Add_Click({ Invoke-Safe { if($script:PackPath -and $script:Pieces.Count -gt 0){Reset-View} } })
$lstRecentProjects.Add_MouseDoubleClick({
    if($lstRecentProjects.SelectedItem){
        $path=[string]$lstRecentProjects.SelectedItem.Tag
        Invoke-Safe { Open-PackPath $path }
    }
})
Refresh-RecentProjects
$btnUpdate.Add_Click({ Invoke-Safe { Confirm-And-InstallUpdate } })
$btnPrev.Add_Click({ Invoke-Safe { Navigate-Piece -1 } })
$script:CategoryItems=@(
    [pscustomobject]@{Key='all';Display='TODAS AS CATEGORIAS'},
    [pscustomobject]@{Key='head';Display='HEAD • CABEÇA'},[pscustomobject]@{Key='berd';Display='BERD • MÁSCARAS'},[pscustomobject]@{Key='hair';Display='HAIR • CABELOS'},
    [pscustomobject]@{Key='uppr';Display='UPPR • PARTE SUPERIOR'},[pscustomobject]@{Key='lowr';Display='LOWR • CALÇAS / PERNAS'},[pscustomobject]@{Key='hand';Display='HAND • MÃOS'},
    [pscustomobject]@{Key='feet';Display='FEET • SAPATOS'},[pscustomobject]@{Key='teef';Display='TEEF • ACESSÓRIOS'},[pscustomobject]@{Key='accs';Display='ACCS • CAMISAS'},
    [pscustomobject]@{Key='task';Display='TASK • COLETES'},[pscustomobject]@{Key='decl';Display='DECL • ADESIVOS'},[pscustomobject]@{Key='jbib';Display='JBIB • JAQUETAS'},
    [pscustomobject]@{Key='p_head';Display='P_HEAD • CHAPÉUS'},[pscustomobject]@{Key='p_eyes';Display='P_EYES • ÓCULOS'},[pscustomobject]@{Key='p_ears';Display='P_EARS • BRINCOS'},
    [pscustomobject]@{Key='p_lwrist';Display='P_LWRIST • RELÓGIOS'},[pscustomobject]@{Key='p_rwrist';Display='P_RWRIST • BRACELETES'}
)
$cmbCategory.ItemsSource=$script:CategoryItems
$cmbCategory.SelectedValue='all'
$cmbCategory.Add_SelectionChanged({
    if($script:UpdatingPieceOptions -or $script:Pieces.Count -eq 0){return}
    $sel=$cmbCategory.SelectedItem
    $val=if($sel -and $sel.PSObject.Properties['Key']){[string]$sel.Key}else{[string]$cmbCategory.SelectedValue}
    if([string]::IsNullOrWhiteSpace($val)){return}
    $script:SelectedCategoryFilter=$val
    $indices=@(Get-FilteredPieceIndices)
    if($indices.Count -gt 0){$script:Index=[int]$indices[0]}
    if($indices.Count -gt 0){Load-CurrentPiece}
})
$chkHideHair.Add_Checked({ if(-not $script:UpdatingPieceOptions -and $script:Pieces.Count -gt 0){$script:HideHairSelections[$script:Pieces[$script:Index].FullName]=$true;Save-State} })
$chkHideHair.Add_Unchecked({ if(-not $script:UpdatingPieceOptions -and $script:Pieces.Count -gt 0){$script:HideHairSelections[$script:Pieces[$script:Index].FullName]=$false;Save-State} })

$btnNext.Add_Click({ Invoke-Safe { Navigate-Piece 1 } })
$btnNextPending.Add_Click({ Invoke-Safe { Go-NextPendingPiece } })
$btnHelp.Add_Click({ Invoke-Safe { Show-AppHelp } })
$btnFirst.Add_Click({ Invoke-Safe { Go-FirstPiece } })
$btnLast.Add_Click({ Invoke-Safe { Go-LastPiece } })
$btnKeep.Add_Click({ Invoke-Safe { Mark-Current 'MANTER' } })
$btnDelete.Add_Click({ Invoke-Safe { Mark-Current 'EXCLUIR' } })
$btnUndo.Add_Click({ Invoke-Safe { Undo-Last } })
$btnApply.Add_Click({ Invoke-Safe { Apply-Removals } })
$btnDeleteTexture.Add_Click({ Invoke-Safe { Toggle-TextureDelete } })
$btnBuildAddon.Add_Click({ Invoke-Safe { Build-FiveMAddon } })
$btnWinMin.Add_Click({$win.WindowState='Minimized'})
$btnWinMax.Add_Click({ if($win.WindowState -eq 'Maximized'){$win.WindowState='Normal'}else{$win.WindowState='Maximized'} })
$btnWinClose.Add_Click({$win.Close()})
$topHeader.Add_MouseLeftButtonDown({param($s,$e); if($e.OriginalSource -is [Windows.Controls.Button]){return}; if($e.ClickCount -ge 2){if($win.WindowState -eq 'Maximized'){$win.WindowState='Normal'}else{$win.WindowState='Maximized'}}else{try{$win.DragMove()}catch{}} })
$txtAddonName.Add_LostFocus({ if($script:PackPath){$txtAddonName.Text=Convert-ToAddonName $txtAddonName.Text; Save-State} })

$lstTextures.Add_MouseLeave({ Hide-TexturePreview })

$lstTextures.Add_SelectionChanged({
    if ($script:PopulatingTextures) { return }
    Invoke-Safe { if($lstTextures.SelectedItem){ Apply-TextureItem $lstTextures.SelectedItem; Load-ThumbnailForItem $lstTextures.SelectedItem }; Update-TextureDeleteButton }
})

function Start-TransformDrag([string]$mode,$e) {
    if(-not $script:ModelRoot){return}
    $script:TransformDragMode=$mode
    $script:TransformDragBoxWidth=[double]$transformBox.Width
    $script:TransformDragBoxHeight=[double]$transformBox.Height
    $script:TransformStart=$e.GetPosition($viewHost)
    $script:TransformCenterX=([double]$viewHost.ActualWidth/2.0)+[double]$transformBox.RenderTransform.X
    $script:TransformCenterY=([double]$viewHost.ActualHeight/2.0)+[double]$transformBox.RenderTransform.Y
    $script:TransformStartRadius=[Math]::Max(8.0,[Math]::Sqrt([Math]::Pow($script:TransformStart.X-$script:TransformCenterX,2)+[Math]::Pow($script:TransformStart.Y-$script:TransformCenterY,2)))
    $script:TransformStartAngle=[Math]::Atan2($script:TransformStart.Y-$script:TransformCenterY,$script:TransformStart.X-$script:TransformCenterX)
    $script:TransformStartScale=$script:ModelScale
    $script:TransformStartX=$script:ModelOffsetX
    $script:TransformStartY=$script:ModelOffsetY
    $script:TransformStartZ=$script:ModelOffsetZ
    $script:TransformStartScreenX=$script:TransformScreenX
    $script:TransformStartScreenY=$script:TransformScreenY
    $script:TransformStartYaw=$script:Yaw
    $script:TransformStartPitch=$script:Pitch
    $script:TransformStartRoll=$script:Roll
    $viewHost.CaptureMouse() | Out-Null
    Set-TransformHover $mode
    $e.Handled=$true
}

function Get-TransformHoverMode([double]$x,[double]$y,[double]$width,[double]$height) {
    # Zonas de hit-test independentes do desenho. A caixa continua fina; apenas
    # a região sob o ponteiro revela os planos amarelos vistos no Photoshop 3D.
    if($width -lt 35 -or $height -lt 35){return ''}
    if($x -lt 0 -or $y -lt 0 -or $x -gt $width -or $y -gt $height){return ''}
    $corner=[Math]::Min(43.0,[Math]::Min($width,$height)*0.24)
    if(($x -le $corner -or $x -ge $width-$corner) -and ($y -le $corner -or $y -ge $height-$corner)){
        return 'ROTATE_ROLL'
    }
    $edge=[Math]::Min(30.0,[Math]::Min($width,$height)*0.16)
    if($x -le $edge -or $x -ge $width-$edge){return 'ROTATE_YAW'}
    if($y -le $edge -or $y -ge $height-$edge){return 'ROTATE_PITCH'}
    return ''
}

function Set-TransformHover([string]$mode) {
    if($script:TransformDragMode){$mode=[string]$script:TransformDragMode}
    if($script:TransformHoverMode -eq $mode){return}
    $script:TransformHoverMode=$mode
    foreach($h in @($hoverNW,$hoverNE,$hoverSW,$hoverSE,$hoverLeft,$hoverRight,$hoverTop,$hoverBottom)){
        $h.Visibility='Collapsed'
    }
    $active=switch($mode){
        'ROTATE_ROLL'{@($hoverNW,$hoverNE,$hoverSW,$hoverSE)}
        'ROTATE_YAW'{@($hoverLeft,$hoverRight)}
        'ROTATE_PITCH'{@($hoverTop,$hoverBottom)}
        default{@()}
    }
    foreach($h in @($active)){if($null -ne $h){$h.Visibility='Visible'}}
    foreach($axis in @($centerAxisX,$centerAxisY,$centerAxisZ)){
        $axis.StrokeThickness=3.4;$axis.Opacity=0.86
    }
    foreach($tip in @($centerTipX,$centerTipY,$centerTipZ)){$tip.Opacity=0.86}
    $activeAxis=switch($mode){
        'MOVE_X'{@($centerAxisX,$centerTipX)}
        'MOVE_Y'{@($centerAxisY,$centerTipY)}
        'MOVE_Z'{@($centerAxisZ,$centerTipZ)}
        default{@()}
    }
    foreach($axis in @($activeAxis)){
        if($null -eq $axis){continue}
        $axis.Opacity=1.0
        if($axis -is [Windows.Shapes.Line]){$axis.StrokeThickness=5}
    }
    $centerRotateRing.Visibility=if($mode -eq 'ROTATE_ROLL'){'Visible'}else{'Collapsed'}
    $transformBox.Cursor=if($mode -eq 'ROTATE_ROLL'){'Hand'}elseif($mode -eq 'ROTATE_YAW'){'SizeWE'}elseif($mode -eq 'ROTATE_PITCH'){'SizeNS'}elseif($mode -eq 'MOVE_Z'){'SizeAll'}else{'Arrow'}
    if($lblTransformHint){
        $lblTransformHint.Text=switch($mode){
            'ROTATE_YAW'{'GIRAR EM TORNO DO EIXO Y • arraste a faixa vertical • Shift = 5°'}
            'ROTATE_PITCH'{'GIRAR EM TORNO DO EIXO X • arraste a faixa horizontal • Shift = 5°'}
            'ROTATE_ROLL'{'GIRAR EM TORNO DO EIXO Z • arraste o canto • Shift = 5°'}
            'MOVE_Z'{'MOVER NO EIXO Z • arraste a seta verde'}
            'MOVE_X'{'MOVER NO EIXO X • arraste a seta vermelha'}
            'MOVE_Y'{'MOVER NO EIXO Y • arraste a seta azul (profundidade)'}
            'MOVE'{'MOVER LIVREMENTE • arraste a seleção'}
            default{'Selecione a peça • aproxime o mouse de uma borda ou canto • Ctrl + rolagem = escala'}
        }
    }
}

$transformBox.Add_MouseMove({
    param($s,$e)
    if($script:TransformDragMode){return}
    if($centerAxisWidget.IsMouseOver){return}
    $p=$e.GetPosition($transformBox)
    $mode=Get-TransformHoverMode $p.X $p.Y $transformBox.ActualWidth $transformBox.ActualHeight
    Set-TransformHover $mode
})
$transformBox.Add_MouseLeftButtonDown({
    param($s,$e)
    if($centerAxisWidget.IsMouseOver){return}
    $p=$e.GetPosition($transformBox)
    $mode=Get-TransformHoverMode $p.X $p.Y $transformBox.ActualWidth $transformBox.ActualHeight
    if(([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Alt) -ne 0){$mode='MOVE'}
    if($mode){Start-TransformDrag $mode $e}
})
$transformBox.Add_MouseLeave({if(-not $script:TransformDragMode){Set-TransformHover ''}})
foreach($a in @($centerAxisX,$centerTipX)){
    $a.Add_MouseEnter({Set-TransformHover 'MOVE_X'})
    $a.Add_MouseLeftButtonDown({param($s,$e) Start-TransformDrag 'MOVE_X' $e})
}
foreach($a in @($centerAxisY,$centerTipY)){
    $a.Add_MouseEnter({Set-TransformHover 'MOVE_Y'})
    $a.Add_MouseLeftButtonDown({param($s,$e) Start-TransformDrag 'MOVE_Y' $e})
}
foreach($a in @($centerAxisZ,$centerTipZ)){
    $a.Add_MouseEnter({Set-TransformHover 'MOVE_Z'})
    $a.Add_MouseLeftButtonDown({param($s,$e) Start-TransformDrag 'MOVE_Z' $e})
}
$centerAxisWidget.Add_MouseEnter({if(-not $script:TransformDragMode){Set-TransformHover ''}})
$centerAxisWidget.Add_MouseMove({
    param($s,$e)
    if($script:TransformDragMode){return}
    $source=$e.OriginalSource
    $mode=if($source -eq $centerAxisX -or $source -eq $centerTipX){'MOVE_X'}
        elseif($source -eq $centerAxisY -or $source -eq $centerTipY){'MOVE_Y'}
        elseif($source -eq $centerRotateRing){'ROTATE_ROLL'}
        else{''}
    Set-TransformHover $mode
})
$centerAxisWidget.Add_MouseLeftButtonDown({param($s,$e)
    if(([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Alt) -ne 0){Start-TransformDrag 'MOVE' $e}
})
$centerRotateRing.Add_MouseLeftButtonDown({param($s,$e) Start-TransformDrag 'ROTATE_ROLL' $e})
$centerAxisWidget.Add_MouseLeave({
    if(-not $script:TransformDragMode){
        $p=[Windows.Input.Mouse]::GetPosition($transformBox)
        Set-TransformHover (Get-TransformHoverMode $p.X $p.Y $transformBox.ActualWidth $transformBox.ActualHeight)
    }
})


$viewHost.Add_MouseLeftButtonDown({
    param($s,$e)
    Invoke-Safe {
        if (-not $script:ModelRoot) { return }

        # Grid não possui MouseDoubleClick. O duplo clique é detectado
        # pelo ClickCount do MouseLeftButtonDown.
        if ($e.ClickCount -ge 2) {
            $script:Dragging = $false
            if ($viewHost.IsMouseCaptured) { $viewHost.ReleaseMouseCapture() }
            Reset-View
            $e.Handled = $true
            return
        }

        # Seleção estilo editor: a caixa aparece ao clicar diretamente na malha.
        $pt3d=$e.GetPosition($viewport)
        $hit3d=[Windows.Media.VisualTreeHelper]::HitTest($viewport,$pt3d)
        if($hit3d -is [Windows.Media.Media3D.RayMeshGeometry3DHitTestResult]){
            Set-TransformBox $true
        } elseif(-not $script:TransformDragMode) {
            Set-TransformBox $false
        }

        $script:Dragging = $true
        $script:DragStart = $e.GetPosition($viewHost)
        $script:DragYaw = $script:Yaw
        $script:DragPitch = $script:Pitch
        $viewHost.CaptureMouse() | Out-Null
    }
})

$viewHost.Add_MouseMove({
    param($s,$e)
    try {
        $p=$e.GetPosition($viewHost)
        if($script:TransformDragMode){
            $dx=$p.X-$script:TransformStart.X; $dy=$p.Y-$script:TransformStart.Y
            if($script:TransformDragMode -in @('MOVE','MOVE_X','MOVE_Y','MOVE_Z')){
                $w=[Math]::Max(300,$viewHost.ActualWidth); $h=[Math]::Max(300,$viewHost.ActualHeight)
                if($script:TransformDragMode -in @('MOVE','MOVE_X')){$script:ModelOffsetX=$script:TransformStartX + ($dx/$w)*$script:ModelExtent*2.2}
                if($script:TransformDragMode -in @('MOVE','MOVE_Z')){$script:ModelOffsetZ=$script:TransformStartZ - ($dy/$h)*$script:ModelExtent*2.2}
                if($script:TransformDragMode -eq 'MOVE_Y'){$script:ModelOffsetY=[Math]::Max(-$script:CameraDistance*0.75,[Math]::Min($script:CameraDistance*3.0,$script:TransformStartY + (($dx+$dy)/$w)*$script:ModelExtent*2.5))}
                if($script:TransformDragMode -eq 'MOVE'){$script:TransformScreenX=$script:TransformStartScreenX+$dx;$script:TransformScreenY=$script:TransformStartScreenY+$dy}
            } elseif($script:TransformDragMode -eq 'SCALE') {
                $radius=[Math]::Sqrt([Math]::Pow($p.X-$script:TransformCenterX,2)+[Math]::Pow($p.Y-$script:TransformCenterY,2))
                $script:ModelScale=[Math]::Max(0.25,[Math]::Min(3.2,$script:TransformStartScale*($radius/$script:TransformStartRadius)))
            } elseif($script:TransformDragMode -eq 'ROTATE_YAW') {
                $angle=$script:TransformStartYaw+($dx/[Math]::Max(80.0,$script:TransformDragBoxWidth))*180.0
                if(([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift) -ne 0){$angle=[Math]::Round($angle/5.0)*5.0}
                $script:Yaw=$angle
            } elseif($script:TransformDragMode -eq 'ROTATE_PITCH') {
                $angle=$script:TransformStartPitch-($dy/[Math]::Max(80.0,$script:TransformDragBoxHeight))*180.0
                if(([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift) -ne 0){$angle=[Math]::Round($angle/5.0)*5.0}
                $script:Pitch=[Math]::Max(-89,[Math]::Min(89,$angle))
            } elseif($script:TransformDragMode -eq 'ROTATE_ROLL') {
                $currentAngle=[Math]::Atan2($p.Y-$script:TransformCenterY,$p.X-$script:TransformCenterX)
                $angle=$script:TransformStartRoll+($currentAngle-$script:TransformStartAngle)*180.0/[Math]::PI
                if(([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift) -ne 0){$angle=[Math]::Round($angle/5.0)*5.0}
                if(([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift) -ne 0){$angle=[Math]::Round($angle/5.0)*5.0}
                $script:Roll=$angle
            }
            Update-ModelTransform
            return
        }
        if (-not $script:Dragging -or -not $script:ModelRoot) { return }
        $script:Yaw = $script:DragYaw + ($p.X-$script:DragStart.X)*0.20
        $script:Pitch = [Math]::Max(-80,[Math]::Min(80,$script:DragPitch-($p.Y-$script:DragStart.Y)*0.14))
        Update-ModelTransform
    } catch { Write-AppLog ("MouseMove: " + $_.Exception.ToString()) }
})

$viewHost.Add_MouseLeftButtonUp({
    Invoke-Safe {
        $changed=($script:TransformDragMode -or $script:Dragging)
        if($script:TransformDragMode){$script:TransformDragMode=$null;Set-TransformHover ''}
        $script:TransformDragBoxWidth=0.0;$script:TransformDragBoxHeight=0.0
        if ($script:Dragging) {$script:Dragging = $false}
        if ($viewHost.IsMouseCaptured) { $viewHost.ReleaseMouseCapture() }
        if($changed){Save-State}
    }
})

$viewHost.Add_MouseWheel({
    param($s,$e)
    Invoke-Safe {
        if (-not $script:Camera) { return }
        $factor = if($e.Delta -gt 0){0.88}else{1.14}
        if(([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) -ne 0 -and $script:TransformBoxEnabled){
            $script:ModelScale=[Math]::Max(0.25,[Math]::Min(3.2,$script:ModelScale/$factor))
            Update-ModelTransform
            Save-State
            $e.Handled=$true
            return
        }
        $script:CameraDistance = [Math]::Max(
            $script:BaseCameraDistance*0.42,
            [Math]::Min($script:BaseCameraDistance*4.5,$script:CameraDistance*$factor)
        )
        Update-Camera
        Update-TransformBoxVisual
        Save-State
        $e.Handled = $true
    }
})

$viewHost.Add_SizeChanged({ if($script:TransformBoxEnabled){ Update-TransformBoxVisual } })

$win.Add_KeyDown({
    param($s,$e)
    Invoke-Safe {
        switch($e.Key) {
            'Left' { Navigate-Piece -1; $e.Handled=$true }
            'Right' { Navigate-Piece 1; $e.Handled=$true }
            'Home' { Go-FirstPiece; $e.Handled=$true }
            'End' { Go-LastPiece; $e.Handled=$true }
            'D1' { Mark-Current 'MANTER'; $e.Handled=$true }
            'NumPad1' { Mark-Current 'MANTER'; $e.Handled=$true }
            'D2' { Mark-Current 'EXCLUIR'; $e.Handled=$true }
            'NumPad2' { Mark-Current 'EXCLUIR'; $e.Handled=$true }
            'Z' { Undo-Last; $e.Handled=$true }
            'R' { Reset-View; $e.Handled=$true }
        }
    }
})

if($env:MT_PACK_ORGANIZER_UITEST -eq '1'){
    # Exercita também XamlReader.Load, bindings, handlers e montagem real do WPF.
    # Não abre pack nem realiza atualização de produção.
    $win.Show()
    [void]$win.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
    Show-AppHelp
    if((Prompt-ProjectName 'Nome inicial') -ne 'Projeto nomeado no teste'){
        throw 'A janela de nome do projeto não confirmou SALVAR.'
    }
    $script:PendingUpdateRelease=[pscustomobject]@{tag_name='v0.9.99'}
    Confirm-And-InstallUpdate
    $script:PendingUpdateRelease=$null
    Set-Loading $true 'ABRINDO PROJETO...'
    if($null -ne $win.Content.Effect){throw 'A tela de carregamento continuou desfocada após o modal.'}
    if($null -ne $emptyState.Effect -or $null -ne $topHeader.Effect){throw 'O carregamento ainda tem fundo desfocado.'}
    Set-Loading $false
    if($packHeaderInfo.Visibility -ne 'Collapsed'){throw 'O cabeçalho do início não deveria exibir o nome dos projetos.'}
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('MTPO_UI_TEST_'+[Guid]::NewGuid().ToString('N'))
    $legacyFixture=$fixture+'_legacy'
    try {
        [void](New-Item -ItemType Directory -Path $fixture -Force)
        [IO.File]::WriteAllBytes((Join-Path $fixture 'jbib_000_u.ydd'),[byte[]](1,2,3,4))
        [IO.File]::WriteAllBytes((Join-Path $fixture 'jbib_001_u.ydd'),[byte[]](1,2,3,4))
        $env:MT_PACK_ORGANIZER_PICKER_TEST_PATH=$fixture
        try {
            if((Select-PackFolder) -ne $fixture){throw 'O seletor de pasta estilizado não confirmou a pasta escolhida.'}
        } finally {Remove-Item Env:MT_PACK_ORGANIZER_PICKER_TEST_PATH -ErrorAction SilentlyContinue}
        if(Confirm-RemoveProject 'Projeto de teste' $fixture){throw 'O botão cancelar do diálogo de exclusão não funcionou.'}
        Open-PackPath $fixture
        Invoke-TransformGizmoSelfTest
        if($script:Pieces.Count -ne 2){throw 'O projeto de teste não indexou as duas peças.'}
        if(-not ($btnHome.Content -is [Windows.Controls.Canvas])){throw 'O botão Início não tem o ícone sólido de casa.'}
        if($xamlText -match 'btnPropYaw|btnPropPitch'){throw 'Os botões de orientação extra deveriam ter sido removidos.'}
        Go-NextPendingPiece
        if($script:Index -ne 0){throw 'O botão ÚLTIMA PENDENTE não começou pela primeira peça sem decisão.'}
        Mark-Current 'MANTER'
        if($script:Index -ne 1){throw 'O projeto de teste não navegou após YDD inválida.'}
        $cmbCategory.SelectedValue='jbib'
        $cmbCategory.SelectedValue='all'
        if($script:Index -ne 0){throw 'TODAS AS CATEGORIAS deveria retornar à primeira peça do pack.'}
        Go-NextPendingPiece
        if($script:Index -ne 1){throw 'ÚLTIMA PENDENTE não localizou a primeira peça sem decisão na ordem global.'}
        Mark-Current 'EXCLUIR'
        Go-NextPendingPiece
        if($lblPendingJump.Text -notmatch 'pack foram revisadas'){throw 'O atalho não avisou quando todas as peças do pack estavam revisadas.'}
        if(-not (Test-Path -LiteralPath (Get-StatePath))){throw 'O projeto de teste não salvou seu estado.'}
        $saved=Get-Content -LiteralPath (Get-StatePath) -Raw | ConvertFrom-Json
        if([int]$saved.index -ne 1){throw 'O projeto de teste não atualizou o índice salvo.'}
        Go-Home
        if(-not [string]::IsNullOrWhiteSpace($env:MT_PACK_ORGANIZER_SCREENSHOT)){
            try {
                $win.UpdateLayout()
                $w=[int]$win.ActualWidth;$h=[int]$win.ActualHeight
                $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap $w,$h,96,96,([Windows.Media.PixelFormats]::Pbgra32)
                $bitmap.Render($win)
                $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
                $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                $output=[IO.File]::Create($env:MT_PACK_ORGANIZER_SCREENSHOT)
                try{$encoder.Save($output)}finally{$output.Dispose()}
                Write-Host 'MT_PACK_ORGANIZER_UI_PREVIEW_OK'
            } catch {Write-Host ('Captura opcional não disponível: '+$_.Exception.Message)}
        }
        Open-PackPath $fixture
        if($script:Index -ne 1 -or $script:Decisions.Count -ne 2){throw 'O progresso foi perdido ao reabrir o projeto.'}
        if($script:Decisions[$script:Pieces[0].FullName] -ne 'MANTER' -or $script:Decisions[$script:Pieces[1].FullName] -ne 'EXCLUIR'){
            throw 'As marcações de manter/excluir foram perdidas ao reabrir o projeto.'
        }
        [void](New-Item -ItemType Directory -Path $legacyFixture -Force)
        $oldYdd=Join-Path $legacyFixture 'jbib_005_u.ydd'
        [IO.File]::WriteAllBytes($oldYdd,[byte[]](1,2,3,4))
        $legacyDecisions=@{};$legacyDecisions[$oldYdd]='EXCLUIR'
        $legacyData=[ordered]@{version=9;pack=$legacyFixture;index=0;decisions=$legacyDecisions;total_pieces=1}
        $legacyData | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $legacyFixture '_MT_PACK_ORGANIZER_STATE.json') -Encoding UTF8
        Open-PackPath $legacyFixture
        if($script:Decisions.Count -ne 1 -or $script:Decisions[$oldYdd] -ne 'EXCLUIR'){
            throw 'O estado antigo dentro da stream não foi recuperado.'
        }
        if(-not (Test-Path -LiteralPath (Get-StatePath))){throw 'Migração do estado antigo não criou estado novo.'}
    } finally {
        $win.Close()
        if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
        if(Test-Path -LiteralPath $legacyFixture){Remove-Item -LiteralPath $legacyFixture -Recurse -Force}
    }
    Write-Host 'MT_PACK_ORGANIZER_UI_SELFTEST_OK'
    exit 0
}
Start-SilentUpdateCheck
$win.ShowDialog() | Out-Null
