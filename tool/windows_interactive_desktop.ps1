# Read desktop state and raise only the diagnostic application's own window.
if (-not ('KMReaderProbeDesktop' -as [type])) {
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class KMReaderProbeDesktop {
  [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder value, uint length, out uint needed);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
  public static string InputDesktopName() {
    IntPtr desktop=OpenInputDesktop(0,false,1);
    if(desktop==IntPtr.Zero)return null;
    try {
      StringBuilder value=new StringBuilder(256);uint needed;
      return GetUserObjectInformation(desktop,2,value,512,out needed)?value.ToString():null;
    } finally { CloseDesktop(desktop); }
  }
  public static bool Pin(IntPtr window, bool enabled) {
    if(enabled)ShowWindow(window,9);
    return SetWindowPos(window,new IntPtr(enabled?-1:-2),0,0,0,0,0x13);
  }
}
'@
}

function Assert-KmReaderInteractiveDesktop {
    if ([KMReaderProbeDesktop]::InputDesktopName() -ne 'Default') {
        throw 'Unlock the Windows desktop before running the reader benchmark. A locked desktop cannot provide valid presentation measurements.'
    }
}
