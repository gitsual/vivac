// The resident host's pipe, created with a security descriptor of its own.
//
// GlazeWM declares uiAccess, so Windows runs it, and everything it starts --
// the host included -- above the normal integrity level. A pipe made by such
// a process carries that level, and the bar and the scripts, which run at the
// normal one, may not write "up" into it. The descriptor here grants the
// signed-in user (plus SYSTEM and Administrators) and labels the pipe low,
// so they can. .NET cannot set a label on a pipe without a privilege nobody
// has, which is why this goes through CreateNamedPipe directly.
using System;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class VivacPipe {
    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes { public int nLength; public IntPtr lpSecurityDescriptor; public bool bInheritHandle; }
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl, int revision, out IntPtr sd, IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr LocalFree(IntPtr p);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafePipeHandle CreateNamedPipe(string name, uint openMode, uint pipeMode, uint maxInstances, uint outSize, uint inSize, uint timeout, ref SecurityAttributes sa);
    public static NamedPipeServerStream Create(string name, string sddl, int maxInstances) {
        IntPtr sd;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, 1, out sd, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();
        try {
            SecurityAttributes sa = new SecurityAttributes { nLength = Marshal.SizeOf(typeof(SecurityAttributes)), lpSecurityDescriptor = sd, bInheritHandle = false };
            // PIPE_ACCESS_INBOUND; byte mode, blocking, remote clients refused.
            SafePipeHandle h = CreateNamedPipe(@"\\.\pipe\" + name, 0x1, 0x8, (uint)maxInstances, 0, 4096, 0, ref sa);
            if (h.IsInvalid) throw new System.ComponentModel.Win32Exception();
            return new NamedPipeServerStream(PipeDirection.In, false, false, h);
        } finally { LocalFree(sd); }
    }
}
