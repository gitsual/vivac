<#
.SYNOPSIS
  Turn on (or off) automatic Windows sign-in, for apply-system.ps1 -AutoLogin.

.DESCRIPTION
  Does what Sysinternals Autologon does -- the password goes into the LSA
  secret DefaultPassword, encrypted by Windows, never into the registry in
  plain text -- with one difference that matters for Microsoft accounts:
  Windows accepts their sign-in under more than one spelling (the e-mail
  under the MicrosoftAccount domain, the bare e-mail, the local account
  name), and Autologon tries only the one typed. This tries each against
  Windows and keeps the one that works.

  The password is typed into Windows' own credential prompt, checked, stored
  and cleared from memory. It is never printed or logged; the log
  (%LOCALAPPDATA%\vivac\autologon.log) records only which spelling worked.

  Run elevated: the LSA secret and the Winlogon settings are machine-wide.

.PARAMETER Disable
  Turn automatic sign-in off and erase the stored password.
#>
[CmdletBinding()]
param([switch]$Disable)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Vivac.psm1') -Force
[void](Import-VivacStrings (Read-VivacSettings)['language'])

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VivacLsa {
    [StructLayout(LayoutKind.Sequential)] private struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] private struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] private static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attrs, uint access, out IntPtr policy);
    [DllImport("advapi32.dll")] private static extern uint LsaStorePrivateData(IntPtr policy, ref LSA_UNICODE_STRING key, IntPtr data);
    [DllImport("advapi32.dll")] private static extern uint LsaClose(IntPtr policy);
    [DllImport("advapi32.dll")] private static extern int LsaNtStatusToWinError(uint status);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LogonUser(string user, string domain, IntPtr password, int type, int provider, out IntPtr token);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);

    private static LSA_UNICODE_STRING Str(IntPtr buffer, int chars) {
        LSA_UNICODE_STRING s = new LSA_UNICODE_STRING();
        s.Buffer = buffer; s.Length = (ushort)(chars * 2); s.MaximumLength = (ushort)(chars * 2 + 2);
        return s;
    }
    // Interactive logon with a password held in unmanaged memory; the token
    // is closed at once, it is only the answer that is wanted.
    // Returns 0, or the Win32 error that says why Windows refused.
    public static int Check(string user, string domain, IntPtr password) {
        IntPtr token;
        if (!LogonUser(user, domain, password, 2, 0, out token)) return Marshal.GetLastWin32Error();
        CloseHandle(token);
        return 0;
    }
    // Stores the password as the LSA secret DefaultPassword, or erases it
    // when password is IntPtr.Zero.
    public static int StoreDefaultPassword(IntPtr password, int chars) {
        LSA_OBJECT_ATTRIBUTES attrs = new LSA_OBJECT_ATTRIBUTES();
        IntPtr policy;
        uint st = LsaOpenPolicy(IntPtr.Zero, ref attrs, 0x00000020 | 0x00000004, out policy);
        if (st != 0) return LsaNtStatusToWinError(st);
        IntPtr keyBuf = Marshal.StringToHGlobalUni("DefaultPassword");
        IntPtr dataPtr = IntPtr.Zero;
        try {
            LSA_UNICODE_STRING key = Str(keyBuf, "DefaultPassword".Length);
            if (password != IntPtr.Zero) {
                LSA_UNICODE_STRING data = Str(password, chars);
                dataPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(LSA_UNICODE_STRING)));
                Marshal.StructureToPtr(data, dataPtr, false);
            }
            st = LsaStorePrivateData(policy, ref key, dataPtr);
            return st == 0 ? 0 : LsaNtStatusToWinError(st);
        } finally {
            if (dataPtr != IntPtr.Zero) Marshal.FreeHGlobal(dataPtr);
            Marshal.FreeHGlobal(keyBuf);
            LsaClose(policy);
        }
    }
}
'@

$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$log = Join-Path (Get-VivacPaths).State 'autologon.log'
function Log([string]$m) { Add-Content -LiteralPath $log -Value ("{0}  {1}" -f (Get-Date -Format s), $m) }

if ($Disable) {
    Set-ItemProperty -LiteralPath $winlogon -Name AutoAdminLogon -Value '0' -Type String
    Remove-ItemProperty -LiteralPath $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
    $err = [VivacLsa]::StoreDefaultPassword([IntPtr]::Zero, 0)
    Log "disabled (lsa erase result $err)"
    Write-Host (T 'autologon.disabled')
    return
}

# The e-mail of the Microsoft account signed in here, to put in the prompt.
$email = ''
$crl = 'HKCU:\Software\Microsoft\IdentityCRL\UserExtendedProperties'
if (Test-Path -LiteralPath $crl) { $email = @(Get-ChildItem -LiteralPath $crl | ForEach-Object { $_.PSChildName } | Where-Object { $_ -match '@' })[0] }
if (-not $email) { $email = $env:USERNAME }

$cred = Get-Credential -UserName $email -Message (T 'autologon.prompt')
if (-not $cred) { Write-Host (T 'autologon.cancelled'); exit 1 }
$typed = $cred.UserName
$secure = $cred.Password
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($secure)
try {
    # Each spelling Windows may accept for this account, most specific first.
    $tries = @(
        @{ User = $typed; Domain = 'MicrosoftAccount' },
        @{ User = $typed; Domain = $null },
        @{ User = $env:USERNAME; Domain = $env:COMPUTERNAME },
        @{ User = $env:USERNAME; Domain = '.' }
    )
    $hit = $null
    $why = @()
    foreach ($t in $tries) {
        $e = [VivacLsa]::Check($t.User, $t.Domain, $ptr)
        if ($e -eq 0) { $hit = $t; break }
        $why += "$($t.Domain)\$($t.User)=$e"
    }
    if (-not $hit) {
        # 1326 wrong password, 1327 account restriction, 1385 logon type not granted, 1311 no logon server.
        Log "no spelling accepted the password (user typed: $typed; $($why -join ', '))"
        Write-Host (T 'autologon.rejected') -ForegroundColor Red
        exit 2
    }
    $err = [VivacLsa]::StoreDefaultPassword($ptr, $secure.Length)
    if ($err -ne 0) { Log "LSA store failed: $err"; Write-Host (T 'autologon.store_failed' @($err)) -ForegroundColor Red; exit 3 }
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr)
    $secure.Dispose()
}
$domain = $hit.Domain
if (-not $domain) { $domain = '' }
if ($domain -eq '.') { $domain = $env:COMPUTERNAME }
Set-ItemProperty -LiteralPath $winlogon -Name DefaultUserName -Value $hit.User -Type String
Set-ItemProperty -LiteralPath $winlogon -Name DefaultDomainName -Value $domain -Type String
Remove-ItemProperty -LiteralPath $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
Remove-ItemProperty -LiteralPath $winlogon -Name AutoLogonCount -ErrorAction SilentlyContinue
Set-ItemProperty -LiteralPath $winlogon -Name AutoAdminLogon -Value '1' -Type String
Log "enabled as '$($hit.User)' domain '$domain'"
Write-Host (T 'autologon.enabled' @($hit.User, $domain)) -ForegroundColor Green
