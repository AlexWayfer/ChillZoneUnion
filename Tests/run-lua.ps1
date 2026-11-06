param([string]$File = 'ChillZoneUnion/Tests/simulation.lua')
Set-Location -LiteralPath (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$source = @'
using System;
using System.Runtime.InteropServices;
public static class LuaHarness {
    const string Lib = @"C:\Program Files\obs-studio\bin\64bit\lua51.dll";
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr luaL_newstate();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern void luaL_openlibs(IntPtr l);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int luaL_loadfile(IntPtr l, string file);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int lua_pcall(IntPtr l, int nargs, int nresults, int errfunc);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr lua_tolstring(IntPtr l, int idx, out UIntPtr len);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern void lua_close(IntPtr l);
    public static string Run(string path) {
        IntPtr l = luaL_newstate();
        try {
            luaL_openlibs(l);
            int code = luaL_loadfile(l, path);
            if (code == 0) code = lua_pcall(l, 0, -1, 0);
            if (code == 0) return "Lua simulation passed.";
            UIntPtr length; IntPtr text = lua_tolstring(l, -1, out length);
            var bytes = new byte[(int)length.ToUInt64()];
            Marshal.Copy(text, bytes, 0, bytes.Length);
            throw new Exception(System.Text.Encoding.UTF8.GetString(bytes));
        } finally { lua_close(l); }
    }
}
'@
Add-Type -TypeDefinition $source
[LuaHarness]::Run((Join-Path (Get-Location) $File))

