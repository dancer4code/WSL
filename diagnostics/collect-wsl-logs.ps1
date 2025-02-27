#Requires -RunAsAdministrator

[CmdletBinding()]
Param (
    $LogProfile = $null,
    [switch]$Dump = $false
   )

Set-StrictMode -Version Latest

$folder = "WslLogs-" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss")
mkdir -p $folder

if ($LogProfile -eq $null)
{
    $LogProfile = "$folder/wsl.wprp"
    try {
        Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/microsoft/WSL/master/diagnostics/wsl.wprp" -OutFile $LogProfile
    }
    catch {
        throw
    }
}

reg.exe export HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lxss $folder/HKCU.txt
reg.exe export HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Lxss $folder/HKLM.txt
reg.exe export HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\P9NP $folder/P9NP.txt
reg.exe export HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\WinSock2 $folder/Winsock2.txt

$wslconfig = "$env:USERPROFILE/.wslconfig"
if (Test-Path $wslconfig)
{
    Copy-Item $wslconfig $folder
}

get-appxpackage MicrosoftCorporationII.WindowsSubsystemforLinux > $folder/appxpackage.txt
get-acl "C:\ProgramData\Microsoft\Windows\WindowsApps" -ErrorAction Ignore | Format-List > $folder/acl.txt
Get-WindowsOptionalFeature -Online > $folder/optional-components.txt

$wprOutputLog = "$folder/wpr.txt"

wpr.exe -start $LogProfile -filemode 2>&1 >> $wprOutputLog
if ($LastExitCode -Ne 0)
{
    Write-Host -ForegroundColor Yellow "Log collection failed to start (exit code: $LastExitCode), trying to reset it."
    wpr.exe -cancel 2>&1 >> $wprOutputLog

    wpr.exe -start $LogProfile -filemode 2>&1 >> $wprOutputLog
    if ($LastExitCode -Ne 0)
    {
        Write-Host -ForegroundColor Red "Couldn't start log collection (exitCode: $LastExitCode)"
    }
}

try
{
    Write-Host -NoNewLine -ForegroundColor Green "Log collection is running. Please reproduce the problem and press any key to save the logs."

    $KeysToIgnore =
          16,  # Shift (left or right)
          17,  # Ctrl (left or right)
          18,  # Alt (left or right)
          20,  # Caps lock
          91,  # Windows key (left)
          92,  # Windows key (right)
          93,  # Menu key
          144, # Num lock
          145, # Scroll lock
          166, # Back
          167, # Forward
          168, # Refresh
          169, # Stop
          170, # Search
          171, # Favorites
          172, # Start/Home
          173, # Mute
          174, # Volume Down
          175, # Volume Up
          176, # Next Track
          177, # Previous Track
          178, # Stop Media
          179, # Play
          180, # Mail
          181, # Select Media
          182, # Application 1
          183  # Application 2

    $Key = $null
    while ($Key -Eq $null -Or $Key.VirtualKeyCode -Eq $null -Or $KeysToIgnore -Contains $Key.VirtualKeyCode)
    {
        $Key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }

    Write-Host "`nSaving logs..."
}
finally
{
    wpr.exe -stop $folder/logs.etl 2>&1 >> $wprOutputLog
}

if ($Dump)
{
    $Assembly = [PSObject].Assembly.GetType('System.Management.Automation.WindowsErrorReporting')
    $DumpMethod = $Assembly.GetNestedType('NativeMethods', 'NonPublic').GetMethod('MiniDumpWriteDump', [Reflection.BindingFlags] 'NonPublic, Static')

    $dumpFolder = Join-Path (Resolve-Path "$folder") dumps
    New-Item -ItemType "directory" -Path "$dumpFolder"

    $executables = "wsl", "wslservice", "wslhost", "msrdc"
    foreach($process in Get-Process | Where-Object { $executables -contains $_.ProcessName})
    {
        $dumpFile =  "$dumpFolder/$($process.ProcessName).$($process.Id).dmp"
        Write-Host "Writing $($dumpFile)"

        $OutputFile = New-Object IO.FileStream($dumpFile, [IO.FileMode]::Create)

        $Result = $DumpMethod.Invoke($null, @($process.Handle,
                                              $process.id,
                                              $OutputFile.SafeFileHandle,
                                              [UInt32] 2,
                                              [IntPtr]::Zero,
                                              [IntPtr]::Zero,
                                              [IntPtr]::Zero))

        $OutputFile.Close()
        if (-not $Result)
        {
            Write-Host "Failed to write dump for: $($dumpFile)"
        }
    }
}

$logArchive = "$(Resolve-Path $folder).zip"
Compress-Archive -Path $folder -DestinationPath $logArchive
Remove-Item $folder -Recurse

Write-Host -ForegroundColor Green "Logs saved in: $logArchive. Please attach that file to the GitHub issue."
