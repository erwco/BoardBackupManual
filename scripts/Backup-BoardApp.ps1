<#
.SYNOPSIS
    Self-contained backup script for UEFA Board Application.
    Syncs backup files from Azure Storage to a local network filer using AzCopy.

.DESCRIPTION
    Designed for direct user execution (not as a scheduled task).
    - Auto-downloads AzCopy if not present
    - Prompts for the SAS token interactively with validation
    - All configuration is embedded - no external config file needed
    - Logs output to a transcript file when launched with -EnableLogs (Run-Backup-Debug.bat)

.NOTES
    Requires PowerShell 5.1+.
    Companion module: azCopyInterface.psm1 (must be in the same directory)
    Launch via: Run-Backup.bat (double-click)
#>

param(
    [switch]$EnableLogs
)

$ErrorActionPreference = 'Stop'

# Ensure TLS 1.2 for Azure/Microsoft endpoints (PS5 defaults to TLS 1.0/1.1)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Script root detection ────────────────────────────────────────────────────
$ScriptRoot = $PSScriptRoot
$ScriptName = $MyInvocation.MyCommand
if ($psEditor) {
    $context = $psEditor.GetEditorContext()
    $ScriptRoot = [System.IO.Path]::GetDirectoryName($context.CurrentFile.Path)
    $ScriptName = [System.IO.Path]::GetFileName($context.CurrentFile.Path)
}
elseif ($psISE) {
    $ScriptRoot = [System.IO.Path]::GetDirectoryName($psISE.CurrentFile.FullPath)
    $ScriptName = $psISE.CurrentFile.DisplayName
}

# ── Transcript logging (enabled with -EnableLogs or Run-Backup-Debug.bat) ────
$transcriptPath = $null
if ($EnableLogs) {
    $logDir = [System.IO.Path]::Combine($ScriptRoot, "logs")
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $transcriptPath = [System.IO.Path]::Combine($logDir, "Backup-BoardApp_$([datetime]::Now.ToString('yyyy-MM-dd_HH-mm-ss')).log")
    Start-Transcript -Path $transcriptPath -Append | Out-Null
}

$backupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Regex pattern to redact SAS tokens from error messages and logs
$sasRedactPattern = '\?sv=[^\s"'']*'

# ── Top-level error handling - window must never close silently ───────────────
try {

# ── Startup banner ────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor DarkCyan
Write-Host ''
Write-Host '    ██╗   ██╗███████╗███████╗ █████╗' -ForegroundColor Yellow
Write-Host '    ██║   ██║██╔════╝██╔════╝██╔══██╗' -ForegroundColor Yellow
Write-Host '    ██║   ██║█████╗  █████╗  ███████║' -ForegroundColor White
Write-Host '    ██║   ██║██╔══╝  ██╔══╝  ██╔══██║' -ForegroundColor Yellow
Write-Host '    ╚██████╔╝███████╗██║     ██║  ██║' -ForegroundColor Yellow
Write-Host '     ╚═════╝ ╚══════╝╚═╝     ╚═╝  ╚═╝' -ForegroundColor DarkYellow
Write-Host ''
Write-Host '    ██████╗  ██████╗  █████╗ ██████╗ ██████╗' -ForegroundColor Cyan
Write-Host '    ██╔══██╗██╔═══██╗██╔══██╗██╔══██╗██╔══██╗' -ForegroundColor Cyan
Write-Host '    ██████╔╝██║   ██║███████║██████╔╝██║  ██║' -ForegroundColor White
Write-Host '    ██╔══██╗██║   ██║██╔══██║██╔══██╗██║  ██║' -ForegroundColor Cyan
Write-Host '    ██████╔╝╚██████╔╝██║  ██║██║  ██║██████╔╝' -ForegroundColor Cyan
Write-Host '    ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝' -ForegroundColor DarkCyan
Write-Host ''
Write-Host '    ██████╗  █████╗  ██████╗██╗  ██╗██╗   ██╗██████╗' -ForegroundColor Green
Write-Host '    ██╔══██╗██╔══██╗██╔════╝██║ ██╔╝██║   ██║██╔══██╗' -ForegroundColor Green
Write-Host '    ██████╔╝███████║██║     █████╔╝ ██║   ██║██████╔╝' -ForegroundColor White
Write-Host '    ██╔══██╗██╔══██║██║     ██╔═██╗ ██║   ██║██╔═══╝' -ForegroundColor Green
Write-Host '    ██████╔╝██║  ██║╚██████╗██║  ██╗╚██████╔╝██║' -ForegroundColor Green
Write-Host '    ╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝' -ForegroundColor DarkGreen
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor DarkCyan
Write-Host ''

# ── Load configuration from backup-config.json ──────────────────────────────
$configPath = [System.IO.Path]::Combine($ScriptRoot, 'backup-config.json')
if (-not (Test-Path $configPath)) {
    throw "Configuration file not found: $configPath`nCopy 'backup-config.example.json' to 'backup-config.json' and fill in your environment values."
}
try {
    $config = Get-Content -Path $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
}
catch {
    throw "Failed to read configuration file. Make sure 'backup-config.json' contains valid JSON. Details: $($_.Exception.Message)"
}

$requiredKeys = @('StorageUrl', 'Destination', 'BackupDays', 'DirectoryRegex', 'BackupPaths')
foreach ($key in $requiredKeys) {
    if (-not $config.PSObject.Properties[$key] -or $null -eq $config.$key) {
        throw "Configuration file is missing required key '$key'. See 'backup-config.example.json' for the expected format."
    }
}

if (@($config.BackupPaths).Count -eq 0) {
    throw "Configuration error: 'BackupPaths' must contain at least one entry."
}

$StorageUrl     = $config.StorageUrl
$BackupDays     = @($config.BackupDays)
$Destination    = $config.Destination
$DirectoryRegex = $config.DirectoryRegex

# Optional: per-folder AzCopy sync timeout (default 5 hours)
$SyncTimeoutSeconds = if ($config.PSObject.Properties['SyncTimeoutSeconds'] -and $config.SyncTimeoutSeconds) {
    [int]$config.SyncTimeoutSeconds
} else {
    18000
}

# Convert JSON objects to hashtables (ConvertFrom-Json returns PSCustomObjects on PS 5.1)
$BackupPaths = @(
    foreach ($bp in $config.BackupPaths) {
        if (-not $bp.types -or @($bp.types).Count -eq 0) {
            throw "Configuration error: BackupPaths entry '$($bp.name)' has no 'types' defined."
        }
        @{ name = $bp.name; path = $bp.path; types = @($bp.types) }
    }
)

# ── Validate companion module ────────────────────────────────────────────────
$modulePath = [System.IO.Path]::Combine($ScriptRoot, "azCopyInterface.psm1")
if (-not (Test-Path $modulePath)) {
    throw "The file 'azCopyInterface.psm1' is missing. It must be in the same folder as this script ($ScriptRoot)."
}

# ── Validate network filer is reachable ──────────────────────────────────────
if (-not (Test-Path $Destination)) {
    throw "Cannot reach the backup destination ($Destination). Please check your VPN connection and network access, then try again."
}

# ── Dependency: AzCopy ───────────────────────────────────────────────────────
$azCopyPath = [System.IO.Path]::Combine($ScriptRoot, "azcopy.exe")

if (-not (Test-Path $azCopyPath)) {
    Write-Host "[Setup] azcopy.exe not found - downloading (this is a one-time setup)..." -ForegroundColor Yellow

    $zipPath = [System.IO.Path]::Combine($ScriptRoot, "azcopy.zip")
    $extractPath = [System.IO.Path]::Combine($ScriptRoot, "azcopy_temp")

    try {
        # Download from official Microsoft URL
        Invoke-WebRequest -Uri "https://aka.ms/downloadazcopy-v10-windows" -OutFile $zipPath -UseBasicParsing -TimeoutSec 120

        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        # AzCopy extracts into a versioned subfolder - find azcopy.exe inside
        $exeFound = Get-ChildItem -Path $extractPath -Filter "azcopy.exe" -Recurse | Select-Object -First 1
        if (-not $exeFound) {
            throw "azcopy.exe not found in the downloaded archive."
        }

        Move-Item -Path $exeFound.FullName -Destination $azCopyPath -Force

        # Verify the downloaded binary is signed by Microsoft
        $sig = Get-AuthenticodeSignature -FilePath $azCopyPath
        if ($sig.Status -ne 'Valid') {
            Remove-Item $azCopyPath -Force -ErrorAction SilentlyContinue
            throw "azcopy.exe signature verification failed (status: $($sig.Status)). The download may be corrupted or tampered with."
        }
        if ($sig.SignerCertificate.Subject -notmatch 'O=Microsoft') {
            Remove-Item $azCopyPath -Force -ErrorAction SilentlyContinue
            throw "azcopy.exe is not signed by Microsoft (signer: $($sig.SignerCertificate.Subject)). Refusing to execute."
        }

        Write-Host "[Setup] azcopy.exe downloaded and verified successfully." -ForegroundColor Green
    }
    catch {
        throw "Failed to download AzCopy. Please check your internet connection and try again. Details: $($_.Exception.Message -replace $sasRedactPattern, '?[REDACTED]')"
    }
    finally {
        # Clean up temp files
        if (Test-Path $zipPath)     { Remove-Item $zipPath -Force }
        if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
    }
}

# ── Import companion module ──────────────────────────────────────────────────
Import-Module -Name $modulePath -Force
Set-AzCopyPath -Path $azCopyPath

# ── AzCopy environment variables ─────────────────────────────────────────────
$azCopyLogDir  = [System.IO.Path]::Combine($ScriptRoot, "logs", "AzCopyLogs", "logs")
$azCopyPlanDir = [System.IO.Path]::Combine($ScriptRoot, "logs", "AzCopyLogs", "plans")

foreach ($dir in @($azCopyLogDir, $azCopyPlanDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$env:AZCOPY_LOG_LOCATION         = $azCopyLogDir
$env:AZCOPY_JOB_PLAN_LOCATION    = $azCopyPlanDir
$env:AZCOPY_DOWNLOAD_TO_TEMP_PATH = "false"
$azCopyLogLevel = if ($EnableLogs) { 'INFO' } else { 'NONE' }

# ── SAS token prompt with validation ─────────────────────────────────────────
# Pause transcript to prevent the SAS token from being logged
if ($EnableLogs) { try { Stop-Transcript | Out-Null } catch { } }

Print -Message "Please provide the SAS token for Azure Storage access" -messageType "Info"

$SasTokenSecure = $null
$maxAttempts = 3

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $sasSecure = Read-Host "Enter the SAS token (attempt $attempt of $maxAttempts)" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sasSecure)
    try {
        $candidate = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    # Strip leading '?' if present (users sometimes copy it from the portal)
    $candidate = $candidate.TrimStart('?')

    # Reject empty input
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        Print -Message "The SAS token cannot be empty. Please paste the token provided to you." -messageType "Warning"
        continue
    }

    # Validate format: must start with sv=
    if ($candidate -notmatch '^sv=') {
        Print -Message "The SAS token does not look valid (expected it to start with 'sv='). Please check and try again." -messageType "Warning"
        continue
    }

    # Validate token works: lightweight test request against first backup path
    Print -Message "Validating SAS token against Azure Storage..." -messageType "Info"
    try {
        $testUri = [System.UriBuilder]::new($StorageUrl)
        $testUri.Path = $BackupPaths[0].path
        $testUri.Query = $candidate + "&comp=list&restype=directory"
        Invoke-WebRequest -Uri $testUri.Uri.AbsoluteUri -UseBasicParsing -TimeoutSec 30 | Out-Null
    }
    catch {
        $statusCode = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($statusCode -eq 403 -or $statusCode -eq 401) {
            Print -Message "The SAS token was rejected by Azure (access denied). It may be expired or incorrect." -messageType "Warning"
        }
        elseif ($_.Exception.Message -match 'Unable to connect|timed out|name.+not.+resolved') {
            if ($EnableLogs) { Start-Transcript -Path $transcriptPath -Append | Out-Null }
            throw "Cannot reach Azure Storage. Please check your internet connection and try again."
        }
        else {
            Print -Message "SAS token validation failed: $($_.Exception.Message -replace $sasRedactPattern, '?[REDACTED]')" -messageType "Warning"
        }
        continue
    }

    # Token passed all checks - store as SecureString to minimise plaintext lifetime
    $SasTokenSecure = [System.Security.SecureString]::new()
    foreach ($ch in $candidate.ToCharArray()) {
        $SasTokenSecure.AppendChar($ch)
    }
    $SasTokenSecure.MakeReadOnly()
    Print -Message "SAS token validated successfully." -messageType "Info"
    break
}

$candidate = $null
$testUri = $null

if (-not $SasTokenSecure) {
    if ($EnableLogs) { Start-Transcript -Path $transcriptPath -Append | Out-Null }
    throw "Failed to obtain a valid SAS token after $maxAttempts attempts. Please verify the token and run the script again."
}

# Resume transcript logging now that the SAS token is stored
if ($EnableLogs) { Start-Transcript -Path $transcriptPath -Append | Out-Null }

# ── Main backup workflow ─────────────────────────────────────────────────────

    # Calculate target dates
    $targetDates = @()
    Print -Message "Calculating target dates for the backup" -messageType "Info"
    foreach ($day in $BackupDays) {
        $targetDates += Get-LastMonthDay -DayOfMonth $day
    }
    Print -Message "Target dates: $($targetDates -join ', ')" -messageType "Info"

    # Discover directories in Azure Storage
    $targetDirectories = @(foreach ($bkPath in $BackupPaths) {
        Print -Message "Searching target directories in path $($bkPath.path) with types $($bkPath.types -join ', ')" -messageType "Info"
        $uri = [System.UriBuilder]::new($StorageUrl)
        $uri.Path = $bkPath.path
        $sasBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SasTokenSecure)
        try {
            $uri.Query = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($sasBstr)
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($sasBstr)
        }

        try {
            $directories = Get-StorageDirectories -uri $uri -expression $DirectoryRegex
        }
        catch {
            $statusCode = $null
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($statusCode -eq 403 -or $statusCode -eq 401) {
                throw "Access denied when listing Azure Storage path '$($bkPath.path)'. The SAS token may have expired."
            }
            elseif ($_.Exception.Message -match 'Unable to connect|timed out|name.+not.+resolved') {
                throw "Cannot reach Azure Storage. Please check your internet connection and try again."
            }
            else {
                throw "Failed to list Azure Storage path '$($bkPath.path)': $($_.Exception.Message -replace $sasRedactPattern, '?[REDACTED]')"
            }
        }

        foreach ($type in $bkPath.types) {
            foreach ($date in $targetDates) {
                $directories | Where-Object { $_.Parent -eq $bkPath.name -and $_.DateTime -lt $date -and $_.Type -in $type } |
                    Sort-Object DateTime -Descending |
                    Select-Object -First 1
            }
        }
    })

    Print -Message "Found $($targetDirectories.Count) target directories to back up" -messageType "Info"

    if (-not $targetDirectories -or $targetDirectories.Count -eq 0) {
        Print -Message "No directories matched the backup criteria. Nothing to sync." -messageType "Warning"
        return
    }

    # Sync each directory
    $result = [System.Collections.Generic.List[PsCustomObject]]::New()

    Print -Message "Starting sync of $($targetDirectories.Count) directories to $Destination" -messageType "Info"
    foreach ($directory in $targetDirectories) {
        Print -Message "Processing directory $($directory.DirectoryName)" -messageType "Info"
        $destinationPath = [System.IO.Path]::Combine($Destination, $directory.Parent, $directory.DirectoryName)
        $resolvedPath = [System.IO.Path]::GetFullPath($destinationPath)
        $destinationWithSep = $Destination.TrimEnd('\') + '\'
        if (-not $resolvedPath.StartsWith($destinationWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Path traversal detected - resolved path '$resolvedPath' escapes destination '$Destination'."
        }
        $dirInfo = [System.IO.DirectoryInfo]::new($resolvedPath)
        $dirInfo.Create()

        $sourceUri = [System.UriBuilder]::new($directory.Path)

        try {
            $outPut = Invoke-AzCopySyncWithStats -Source $sourceUri -Destination $dirInfo.FullName -SasToken $SasTokenSecure -Label $directory.DirectoryName -TimeoutSeconds $SyncTimeoutSeconds -LogLevel $azCopyLogLevel
            Print -Message "Completed $($directory.DirectoryName) to Destination" -messageType "Info"
            $outPut | Add-Member -MemberType NoteProperty -Name "DirectoryName" -Value $directory.DirectoryName
        }
        catch {
            Print -Message "Error syncing $($directory.DirectoryName): $($_.Exception.Message -replace $sasRedactPattern, '?[REDACTED]')" -messageType "Error"
            $outPut = [PsCustomObject]@{
                Source             = $sourceUri.Uri.AbsoluteUri
                Destination        = $dirInfo.FullName
                DirectoryName      = $directory.DirectoryName
                ExecutionTimestamp = [Datetime]::Now
                JobResult          = "Failed"
                ErrorMessage       = $_.Exception.Message -replace $sasRedactPattern, '?[REDACTED]'
                ErrorDetails       = $_.Exception.StackTrace -replace $sasRedactPattern, '?[REDACTED]'
            }
        }

        $result.Add($outPut)
    }

    # ── Results summary ──────────────────────────────────────────────────────
    $successCount = ($result | Where-Object { $_.JobResult -ne "Failed" }).Count
    $failCount    = ($result | Where-Object { $_.JobResult -eq "Failed" }).Count

    # Calculate column widths from data
    $nameWidth = ($result | ForEach-Object { $_.DirectoryName.Length } | Measure-Object -Maximum).Maximum
    if ($nameWidth -lt 4) { $nameWidth = 4 }
    $resultWidth = ($result | ForEach-Object { $_.JobResult.Length } | Measure-Object -Maximum).Maximum
    if ($resultWidth -lt 6) { $resultWidth = 6 }
    $srcWidth  = 6
    $destWidth = 6
    $copyWidth = 6

    $headerLine = '  {0}   {1}   {2}   {3}   {4}' -f 'Name'.PadRight($nameWidth), 'Result'.PadRight($resultWidth), 'Source'.PadLeft($srcWidth), 'Dest'.PadLeft($destWidth), 'Copied'.PadLeft($copyWidth)
    $divider = '  ' + ('-' * ($headerLine.Length - 2))

    Write-Host ''
    Write-Host '  ==================== BACKUP SUMMARY ====================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host $headerLine -ForegroundColor DarkGray
    Write-Host $divider -ForegroundColor DarkGray

    foreach ($r in $result) {
        $isFailed = $r.JobResult -eq 'Failed'
        $resultColor = if ($isFailed) { 'Red' } else { 'Green' }

        $src  = if ($r.PSObject.Properties['FilesInSource'])      { "$($r.FilesInSource)".PadLeft($srcWidth) }  else { ''.PadLeft($srcWidth) }
        $dst  = if ($r.PSObject.Properties['FilesInDestination']) { "$($r.FilesInDestination)".PadLeft($destWidth) } else { ''.PadLeft($destWidth) }
        $copy = if ($r.PSObject.Properties['FilesCopied'])        { "$($r.FilesCopied)".PadLeft($copyWidth) }  else { ''.PadLeft($copyWidth) }

        $line = '  {0}   {1}   {2}   {3}   {4}' -f $r.DirectoryName.PadRight($nameWidth), $r.JobResult.PadRight($resultWidth), $src, $dst, $copy
        Write-Host $line -ForegroundColor $resultColor

        if ($r.PSObject.Properties['ErrorMessage'] -and $r.ErrorMessage) {
            Write-Host "  -> $($r.ErrorMessage)" -ForegroundColor Red
        }
    }

    Write-Host $divider -ForegroundColor DarkGray

    $summaryColor = if ($failCount -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "  $successCount succeeded, $failCount failed out of $($result.Count) total." -ForegroundColor $summaryColor
    Write-Host ''

} # end top-level try
catch {
    # Use Write-Host directly here - Print may not be available if the module failed to load
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  AN ERROR OCCURRED" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  $($_.Exception.Message -replace $sasRedactPattern, '?[REDACTED]')" -ForegroundColor Red
    Write-Host ""

    # If Print is available, also log via the structured logger
    if (Get-Command -Name Print -ErrorAction SilentlyContinue) {
        Print -Message "Fatal error: $($_.Exception.Message -replace $sasRedactPattern, '?[REDACTED]')" -messageType "Error"
        Print -Message "Stack trace: $($_.ScriptStackTrace -replace $sasRedactPattern, '?[REDACTED]')" -messageType "Error"
    }
    else {
        Write-Host "  Stack trace: $($_.ScriptStackTrace -replace $sasRedactPattern, '?[REDACTED]')" -ForegroundColor Red
    }
}
finally {
    if ($SasTokenSecure) {
        $SasTokenSecure.Dispose()
        $SasTokenSecure = $null
    }

    $backupStopwatch.Stop()
    $elapsed = $backupStopwatch.Elapsed
    Write-Host ""
    Write-Host "Total elapsed time: $($elapsed.Hours)h $($elapsed.Minutes)m $($elapsed.Seconds)s" -ForegroundColor Cyan
    if ($EnableLogs) {
        Write-Host "Log file saved to: $transcriptPath" -ForegroundColor Cyan
    }
    Write-Host ""

    if ($EnableLogs) { try { Stop-Transcript | Out-Null } catch { } }

    # Clean up AzCopy plan files - they are not needed after the run
    if ($azCopyPlanDir -and (Test-Path $azCopyPlanDir)) {
        try {
            Get-ChildItem -Path $azCopyPlanDir -File | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }

    Read-Host "Press ENTER to close"
}
