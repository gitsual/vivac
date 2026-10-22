// Windows' own record of the notifications it was given (lib/Toasts.psm1).
//
// Every toast any program posts lands in the user's notification database,
// %LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db, whether or
// not Windows shows its banner. It is SQLite, and Windows carries SQLite
// itself (winsqlite3.dll), so this only opens it read-only and asks what
// arrived after the last id it saw. Nothing is ever written to it.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class VivacToastRecord {
    public long Id;
    public string Aumid;
    public string Type;
    public string Payload;
    public long Arrival;
}

public static class VivacToasts {
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_open_v2")] private static extern int Open(byte[] file, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close_v2")] private static extern int Close(IntPtr db);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_busy_timeout")] private static extern int BusyTimeout(IntPtr db, int ms);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_prepare_v2")] private static extern int Prepare(IntPtr db, byte[] sql, int n, out IntPtr st, IntPtr tail);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_step")] private static extern int Step(IntPtr st);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_finalize")] private static extern int Finalize(IntPtr st);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_bytes")] private static extern int Bytes(IntPtr st, int i);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_blob")] private static extern IntPtr Blob(IntPtr st, int i);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_int64")] private static extern long Int64(IntPtr st, int i);

    private const int ReadOnly = 0x1;
    private const int Row = 100;

    public static string DefaultPath() {
        return Environment.ExpandEnvironmentVariables(@"%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db");
    }

    private static byte[] Utf8(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }

    private static string Text(IntPtr st, int i) {
        IntPtr p = Blob(st, i);
        if (p == IntPtr.Zero) return "";
        int n = Bytes(st, i);
        byte[] a = new byte[n];
        Marshal.Copy(p, a, 0, n);
        return Encoding.UTF8.GetString(a);
    }

    private static List<VivacToastRecord> Run(string path, string sql, bool full) {
        List<VivacToastRecord> rows = new List<VivacToastRecord>();
        IntPtr db;
        if (Open(Utf8(path), out db, ReadOnly, IntPtr.Zero) != 0) { Close(db); return rows; }
        try {
            BusyTimeout(db, 500);
            IntPtr st;
            if (Prepare(db, Utf8(sql), -1, out st, IntPtr.Zero) != 0) return rows;
            try {
                while (Step(st) == Row) {
                    VivacToastRecord r = new VivacToastRecord();
                    r.Id = Int64(st, 0);
                    if (full) {
                        r.Aumid = Text(st, 1);
                        r.Type = Text(st, 2);
                        r.Payload = Text(st, 3);
                        r.Arrival = Int64(st, 4);
                    }
                    rows.Add(r);
                }
            } finally { Finalize(st); }
        } finally { Close(db); }
        return rows;
    }

    // The highest id now in the database: where watching starts, so what was
    // already there is not shown again.
    public static long LastId(string path) {
        List<VivacToastRecord> r = Run(path, "select coalesce(max(Id), 0) from Notification", false);
        return r.Count > 0 ? r[0].Id : 0;
    }

    public static List<VivacToastRecord> Since(string path, long id) {
        return Run(path,
            "select n.Id, h.PrimaryId, n.Type, n.Payload, n.ArrivalTime from Notification n " +
            "join NotificationHandler h on h.RecordId = n.HandlerId " +
            "where n.Id > " + id.ToString() + " and n.Type like 'toast%' order by n.Id", true);
    }
}
