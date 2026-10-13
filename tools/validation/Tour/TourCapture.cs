using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Accessibility;
using System.Collections.Generic;

namespace RooTour {
 public static class Desktop {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; public int Width { get { return Right-Left; } } public int Height { get { return Bottom-Top; } } }
  [StructLayout(LayoutKind.Sequential)] struct Point { public int X,Y; }
  [StructLayout(LayoutKind.Sequential)] struct Cursor { public int Size,Flags; public IntPtr Handle; public Point Position; }
  [StructLayout(LayoutKind.Sequential)] struct Icon { public bool IsIcon; public int X,Y; public IntPtr Mask,Color; }
  [StructLayout(LayoutKind.Sequential)] struct Input { public uint Type; public Mouse Mouse; }
  [StructLayout(LayoutKind.Sequential)] struct Mouse { public int X,Y; public uint Data,Flags,Time; public IntPtr Extra; }
  [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr hwnd,uint id,ref Guid iid,[MarshalAs(UnmanagedType.Interface)] out IAccessible value);
  public sealed class Check { public int Index;public string Name;public int State;public Rect Bounds; }
  public static Check[] Checks(IntPtr hwnd) { IAccessible accessible=null;var iid=new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");int hr=AccessibleObjectFromWindow(hwnd,0xfffffffc,ref iid,out accessible);if(hr!=0 || accessible==null)throw new InvalidOperationException("Wizard checklist inaccessible");try{int count=accessible.accChildCount;if(count<1 || count>20)throw new InvalidOperationException("Wizard checklist count differs");var result=new List<Check>();for(int i=1;i<=count;i++){if(Convert.ToInt32(accessible.get_accRole(i))!=44)throw new InvalidOperationException("Wizard item is not a checkbox");int x,y,w,h;accessible.accLocation(out x,out y,out w,out h,i);result.Add(new Check{Index=i,Name=accessible.get_accName(i),State=Convert.ToInt32(accessible.get_accState(i)),Bounds=new Rect{Left=x,Top=y,Right=x+w,Bottom=y+h}});}return result.ToArray();}finally{Marshal.ReleaseComObject(accessible);} }
  public static int[] Position() { Point point;GetCursorPos(out point);return new[]{point.X,point.Y}; }
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd,int attribute,out Rect rect,int length);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,int x,int y,int width,int height,uint flags);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
  [DllImport("user32.dll")] static extern bool GetCursorInfo(ref Cursor info);
  [DllImport("user32.dll")] static extern bool GetIconInfo(IntPtr icon,out Icon info);
  [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr handle);
  [DllImport("user32.dll")] static extern bool DrawIconEx(IntPtr dc,int x,int y,IntPtr icon,int width,int height,int step,IntPtr brush,int flags);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out Point point);
  [DllImport("user32.dll")] static extern uint SendInput(uint count,Input[] input,int size);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from,uint to,bool attach);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd,int command);
  public static int ForegroundPid() { uint pid;GetWindowThreadProcessId(GetForegroundWindow(),out pid);return (int)pid; }
  public static bool Focus(IntPtr hwnd) {
   uint ignored;uint current=GetCurrentThreadId(), foreground=GetWindowThreadProcessId(GetForegroundWindow(),out ignored), target=GetWindowThreadProcessId(hwnd,out ignored);
   bool first=false,second=false;
   try { if(foreground!=0 && current!=foreground)first=AttachThreadInput(current,foreground,true);if(target!=0 && current!=target && target!=foreground)second=AttachThreadInput(current,target,true);ShowWindow(hwnd,9);BringWindowToTop(hwnd);return SetForegroundWindow(hwnd); }
   finally { if(second)AttachThreadInput(current,target,false);if(first)AttachThreadInput(current,foreground,false); }
  }

  public static Rect Bounds(IntPtr hwnd) { Rect rect; if(DwmGetWindowAttribute(hwnd,9,out rect,Marshal.SizeOf(typeof(Rect)))!=0 || rect.Width<=0 || rect.Height<=0) throw new InvalidOperationException("DWM frame bounds unavailable"); return rect; }
  public static void Center(IntPtr hwnd,int width,int height,int x,int y) {
   for(int i=0;i<3;i++) { Rect outer; if(!GetWindowRect(hwnd,out outer)) throw new InvalidOperationException("Window rect unavailable"); Rect frame=Bounds(hwnd); SetWindowPos(hwnd,IntPtr.Zero,x-(frame.Left-outer.Left),y-(frame.Top-outer.Top),width+outer.Width-frame.Width,height+outer.Height-frame.Height,0x0040); Thread.Sleep(150); }
   Rect result=Bounds(hwnd); if(result.Width!=width || result.Height!=height) throw new InvalidOperationException("Window frame size differs from requested capture size");
  }
  public static void Move(int x,int y) { Point start; GetCursorPos(out start); for(int i=1;i<=24;i++){double p=i/24.0;p=p*p*(3-2*p);Point pos=new Point{X=(int)(start.X+(x-start.X)*p),Y=(int)(start.Y+(y-start.Y)*p)}; MoveAbsolute(pos.X,pos.Y);Thread.Sleep(18);} }
  static void MoveAbsolute(int x,int y) { var screen=System.Windows.Forms.SystemInformation.VirtualScreen; var item=new Input{Type=0,Mouse=new Mouse{X=(int)((x-screen.Left)*65535.0/(screen.Width-1)),Y=(int)((y-screen.Top)*65535.0/(screen.Height-1)),Flags=0xC001}}; if(SendInput(1,new[]{item},Marshal.SizeOf(typeof(Input)))!=1)throw new InvalidOperationException("SendInput movement failed"); }
  public static void Click() { var input=new[]{new Input{Type=0,Mouse=new Mouse{Flags=2}},new Input{Type=0,Mouse=new Mouse{Flags=4}}}; if(SendInput(2,input,Marshal.SizeOf(typeof(Input)))!=2)throw new InvalidOperationException("SendInput click failed"); }
  public static Bitmap Capture(IntPtr hwnd,bool cursor) {
   Rect r=Bounds(hwnd); var result=new Bitmap(r.Width,r.Height,PixelFormat.Format24bppRgb);
   using(var g=Graphics.FromImage(result)){g.CopyFromScreen(r.Left,r.Top,0,0,new Size(r.Width,r.Height),CopyPixelOperation.SourceCopy);
    Cursor c=new Cursor{Size=Marshal.SizeOf(typeof(Cursor))}; if(cursor && GetCursorInfo(ref c) && (c.Flags&1)!=0){Icon icon;if(GetIconInfo(c.Handle,out icon)){IntPtr dc=g.GetHdc();try{DrawIconEx(dc,c.Position.X-r.Left-icon.X,c.Position.Y-r.Top-icon.Y,c.Handle,0,0,0,IntPtr.Zero,3);}finally{g.ReleaseHdc(dc);if(icon.Mask!=IntPtr.Zero)DeleteObject(icon.Mask);if(icon.Color!=IntPtr.Zero)DeleteObject(icon.Color);}}}
   } return result;
  }
  public static void Shot(IntPtr hwnd,string path) { using(var bitmap=Capture(hwnd,false)) using(var stream=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None))bitmap.Save(stream,ImageFormat.Png); }
  public static bool VisibleOwner(IntPtr hwnd,int pid) { uint actual; GetWindowThreadProcessId(hwnd,out actual);uint foreground;GetWindowThreadProcessId(GetForegroundWindow(),out foreground);return IsWindow(hwnd) && actual==pid && foreground==pid; }
 }
 public sealed class Recorder : IDisposable {
  readonly string folder; readonly object gate=new object(); readonly Thread thread; bool stopped; IntPtr window; int pid; Exception error; int count; long skipped; double seconds;
  public Recorder(string folder){this.folder=folder;thread=new Thread(Record){IsBackground=true};thread.Start();}
  public void Window(IntPtr hwnd,int processId){lock(gate){window=hwnd;pid=processId;}}
  public int Count {get{return count;}} public long Skipped {get{return skipped;}} public double Seconds {get{return seconds;}}
  void Record(){var clock=Stopwatch.StartNew();var encoder=Array.Find(ImageCodecInfo.GetImageEncoders(),e=>e.MimeType=="image/jpeg");using(var args=new EncoderParameters(1)){args.Param[0]=new EncoderParameter(System.Drawing.Imaging.Encoder.Quality,85L);while(true){IntPtr hwnd;int owner;lock(gate){if(stopped)break;hwnd=window;owner=pid;}var frame=Stopwatch.StartNew();try{if(hwnd!=IntPtr.Zero && Desktop.VisibleOwner(hwnd,owner)){using(var bitmap=Desktop.Capture(hwnd,true))using(var stream=new FileStream(folder+"\\frame-"+(count+1).ToString("D7")+".jpg",FileMode.CreateNew,FileAccess.Write,FileShare.None))bitmap.Save(stream,encoder,args);Interlocked.Increment(ref count);}else Interlocked.Increment(ref skipped);}catch(Exception ex){error=ex;break;}int wait=(int)(1000.0/15-frame.Elapsed.TotalMilliseconds);if(wait>0)Thread.Sleep(wait);}}seconds=clock.Elapsed.TotalSeconds;}
  public void Dispose(){lock(gate){stopped=true;}thread.Join();if(error!=null)throw new InvalidOperationException("Window recorder failed",error);}
 }
}
