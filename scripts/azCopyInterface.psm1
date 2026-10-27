# Module-scoped variable - set by the main script after resolving/downloading azcopy.exe
$script:AzCopyExePath = $null

# Required for [System.Web.HttpUtility] on PS5 (auto-loaded in PS7)
Add-Type -AssemblyName System.Web

# Defense in depth: module functions run in the module's own scope, so the caller's
# $ErrorActionPreference does not propagate. Set Stop here so all cmdlet errors in
# module functions are terminating by default.
$ErrorActionPreference = 'Stop'

function Set-AzCopyPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $script:AzCopyExePath = $Path
}

function Read-ResponseOutput ([Microsoft.PowerShell.Commands.WebResponseObject]$Response) {
    $reader = [System.IO.StreamReader]::new(
        $Response.RawContentStream,
        [System.Text.Encoding]::UTF8,
        $true,   # detectEncodingFromByteOrderMarks
        1024,    # bufferSize (default)
        $true    # leaveOpen - don't dispose the response stream
    )
    try {
        $string = $reader.ReadToEnd()
        return $string
    }
    finally {
        $reader.Dispose()
    }
}

function Add-URIParam ([System.UriBuilder]$uri, [string]$Key, [string]$Value) {
    $queryParams = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
    $queryParams.Add($key, $Value)
    $uri.Query = $queryParams.ToString()
}

function Print {
    param (
        [parameter(Mandatory)]
        [string]$Message,
        [parameter(Mandatory)]
        [ValidateSet('Info','Error','Warning')]
        [string]$messageType
    )
     
    [string]$category = ""
    [string]$ForegroundColor = ""

    switch ($messageType) {
        "Info" {
            $category = $messageType + "   "
            $ForegroundColor = "White"
            }
        "Error" {
            $category = $messageType + "  "
            $ForegroundColor = "Red"
            }
        "Warning" {
            $category = $messageType
            $ForegroundColor = "Yellow"
            }
    }

    $capitalizedCategory = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ToTitleCase($category.ToLower())

    $finalMessage = [String]::Join('   ', $([Datetime]::Now, $capitalizedCategory, $Message) )

    Write-Host $finalMessage -ForegroundColor $ForegroundColor -BackgroundColor Black
}

function Get-LastMonthDay {
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 31)]
        [Int16]
        $DayOfMonth
    )

    $ReferenceDate = [DateTime]::Today

    $monthDate = if ($ReferenceDate.Day -ge $DayOfMonth) {
        $ReferenceDate
    }
    else {
        $ReferenceDate.AddMonths(-1)
    }

    $daysInMonth = [DateTime]::DaysInMonth($monthDate.Year, $monthDate.Month)
    if ($DayOfMonth -gt $daysInMonth) {
        $DayOfMonth = $daysInMonth
    }

    [DateTime]::new($monthDate.Year, $monthDate.Month, $DayOfMonth)
}

function Write-InlineProgress {
    param(
        [Parameter(Mandatory)]
        [double]$Percent,

        [string]$Label
    )

    $barWidth = 30
    $filled = [Math]::Floor($barWidth * ($Percent / 100))
    $empty  = $barWidth - $filled

    $bar = ([char]0x2588).ToString() * $filled + ([char]0x2591).ToString() * $empty
    $pct = '{0,6:N1}%' -f $Percent

    $text = "`r  [$bar] $pct"
    if ($Label) {
        $text += " - $Label"
    }

    # Pad with spaces to overwrite any leftover characters from a longer previous line
    $consoleWidth = try { [Console]::WindowWidth } catch { 120 }
    $padLen = [Math]::Max(0, $consoleWidth - $text.Length - 1)
    $text += ' ' * $padLen

    Write-Host $text -NoNewline

    if ($Percent -ge 100) {
        Write-Host ""
    }
}

function Write-InlineStatus {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [int]$SpinnerIndex = 0
    )

    $frames = @('|', '/', '-', '\')
    $spinner = $frames[$SpinnerIndex % $frames.Count]

    $text = "`r  $spinner $Message"

    # Pad with spaces to overwrite any leftover characters from a longer previous line
    $consoleWidth = try { [Console]::WindowWidth } catch { 120 }
    $padLen = [Math]::Max(0, $consoleWidth - $text.Length - 1)
    $text += ' ' * $padLen

    Write-Host $text -NoNewline
}

function Invoke-AzCopySyncWithStats {
    param(
        [Parameter(Mandatory)]
        [System.UriBuilder]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [SecureString]$SasToken,

        [string]$Label,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$TimeoutSeconds = 18000,

        [ValidateSet('NONE','WARNING','ERROR','INFO','DEBUG')]
        [string]$LogLevel = 'NONE'
    )

    $ErrorActionPreference = 'Stop'
    $timestamp = [datetime]::Now

    $AzCopyPath = $script:AzCopyExePath
    if (-not $AzCopyPath -or -not (Test-Path $AzCopyPath)) {
        throw "AzCopy executable not found. Call Set-AzCopyPath first."
    }

    # Convert SecureString to plaintext for URI construction - minimise lifetime
    $sasBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SasToken)
    try {
        $sasPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($sasBstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($sasBstr)
    }

    # Build the full source URI with SAS token (kept out of the command line)
    $sourceWithSas = [System.UriBuilder]::new($Source.Uri.AbsoluteUri)
    $sourceWithSas.Query = $sasPlain
    $fullSourceUri = $sourceWithSas.Uri.AbsoluteUri
    $sasPlain = $null

    # Build azcopy arguments using an env-var placeholder for the source URL.
    # The actual SAS-bearing URL is injected via a child-process-scoped
    # environment variable so it never appears in process command-line listings.
    $azArgs = [System.Collections.Generic.List[string]]::new(
        [string[]]@(
            'sync',
            '"%AZCOPY_SOURCE_URI%"',
            $Destination,
            '--recursive=true',
            '--log-level', $LogLevel
        )
    )

    Write-Verbose "Running: $AzCopyPath sync $($Source.Uri.AbsoluteUri)?[REDACTED] $Destination --recursive=true --log-level $LogLevel"

    # Quote arguments that contain spaces
    $quotedArgs = ($azArgs | ForEach-Object {
        if ($_ -match '\s') { "`"$_`"" } else { $_ }
    }) -join ' '

    # Launch azcopy via cmd.exe so that %AZCOPY_SOURCE_URI% is expanded from
    # the child process environment - the parent command line only shows the
    # placeholder, not the SAS token.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [System.Environment]::GetEnvironmentVariable('COMSPEC')
    $psi.Arguments = '/c ""' + $AzCopyPath + '" ' + $quotedArgs + '"'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    # Inject the SAS-bearing URL only into the child process environment
    $psi.EnvironmentVariables['AZCOPY_SOURCE_URI'] = $fullSourceUri

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    # Collect all output for summary parsing - ConcurrentQueue for thread safety
    # since stdout/stderr events (thread-pool) and main thread both access this.
    $azOutput = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

    # Event-based capture for stderr - enqueue lines for error reporting only.
    $errAction = {
        if (-not [string]::IsNullOrEmpty($EventArgs.Data)) {
            $Event.MessageData.Enqueue($EventArgs.Data)
        }
    }
    $errEvent = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $errAction -MessageData $azOutput

    $timeoutMs = $TimeoutSeconds * 1000

    try {
        $process.Start() | Out-Null
        $process.BeginErrorReadLine()       # stderr stays async
        # No BeginOutputReadLine() - we read stdout synchronously

        $deadline = [datetime]::UtcNow.AddMilliseconds($timeoutMs)
        $lastPct  = -1
        $spinIdx  = 0

        while ($null -ne ($line = $process.StandardOutput.ReadLine())) {
            # Timeout check
            if ([datetime]::UtcNow -gt $deadline) {
                throw "AzCopy process timed out after $TimeoutSeconds seconds and was terminated."
            }

            $azOutput.Enqueue($line)

            # Parse & display progress inline
            if ($line -match '(\d+(?:\.\d+)?)\s*%.*?Throughput \(Mb/s\):\s*([\d.]+)') {
                $pct = [double]$Matches[1]
                if ($pct -ne $lastPct) {
                    $tpLabel = $Label
                    if ([double]$Matches[2] -gt 0) {
                        $tpLabel = '{0} ({1:N1} Mb/s)' -f $Label, [double]$Matches[2]
                    }
                    Write-InlineProgress -Percent $pct -Label $tpLabel
                    $lastPct = $pct
                }
            }
            elseif ($line -match '(\d+)\s+Files Scanned at Source') {
                $srcCount = $Matches[1]
                $dstCount = 0
                if ($line -match '(\d+)\s+Files Scanned at Destination') {
                    $dstCount = $Matches[1]
                }
                Write-InlineStatus -Message "Scanning - $srcCount Source / $dstCount Destination files" -SpinnerIndex $spinIdx
                $spinIdx++
            }
        }

        # Drain stderr events and finalize ExitCode
        $process.WaitForExit()

        # Show 100% bar only if we displayed at least one progress update
        if ($lastPct -ge 0 -and $lastPct -lt 100) {
            Write-InlineProgress -Percent 100 -Label $Label
        }

        $exitCode = $process.ExitCode
    }
    finally {
        Unregister-Event -SubscriptionId $errEvent.Id -ErrorAction SilentlyContinue
        Remove-Job -Id $errEvent.Id -Force -ErrorAction SilentlyContinue

        # Kill the entire process tree (cmd.exe + azcopy.exe).
        # Always attempt this regardless of HasExited, because Kill() only
        # terminates cmd.exe - azcopy.exe survives as an orphan otherwise.
        try {
            & taskkill.exe /T /F /PID $process.Id 2>&1 | Out-Null
        }
        catch { }

        $process.Dispose()
        # Remove the SAS-bearing URI from local scope as soon as possible
        $fullSourceUri = $null
    }

    if ($exitCode -ne 0) {
        # Redact SAS tokens from error output to prevent credential leaks in logs
        $redactedOutput = ($azOutput -join [Environment]::NewLine) -replace '\?sv=[^\s"'']*', '?[REDACTED]'
        throw "AzCopy sync failed with exit code $exitCode. Output:`n$redactedOutput"
    }

    # --- Parse output ---

    $jobId     = $null
    $logFile   = $null
    $summaryLines = [System.Collections.Generic.List[string]]::new()
    $inSummary = $false

    foreach ($line in $azOutput) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if (-not $jobId -and $line -match '^Job\s+([0-9a-fA-F-]+)\s+has started') {
            $jobId = $matches[1]
        }

        if (-not $logFile -and $line -match 'Log file is located at:\s*(.+)$') {
            $logFile = $matches[1].Trim()
        }

        if ($line -match '^Job\s+([0-9a-fA-F-]+)\s+summary') {
            $inSummary = $true
            continue
        }

        if ($inSummary) {
            $summaryLines.Add($line.Trim())
        }
    }

    if (-not $summaryLines.Count) {
        Write-Warning "AzCopy sync completed but no job summary was found in the output."
        return [pscustomobject]@{
            ExecutionTimestamp = $timestamp
            Source             = $Source.Uri.AbsoluteUri
            Destination        = $Destination
            JobId              = $jobId
            LogFile            = $logFile
            JobResult          = "CompletedWithWarnings"
            RawOutput          = $azOutput -join [Environment]::NewLine
        }
    }

    # Parse "Name: Value" lines from summary
    $summaryData = @{}
    foreach ($line in $summaryLines) {
        if ($line -match '^(?<name>[^:]+):\s*(?<value>.+)$') {
            $name  = $matches['name'].Trim()
            $value = $matches['value'].Trim()
            $summaryData[$name] = $value
        }
    }

    function ConvertTo-Seconds {
        param (
            [String]$Time = "0"
        )
        [decimal]$num = $Time
        $seconds = [Math]::Floor($num * 60)
        return [Math]::Round($seconds, 0)
    }

    [int32]$elapsedSeconds            = ConvertTo-Seconds  $summaryData['Elapsed Time (Minutes)']
    [int64]$bytesTransferred     = $summaryData['Total Number of Bytes Transferred']
    [int64]$bytesEnumerated      = $summaryData['Total Number of Bytes Enumerated']

    [Int32]$filesScannedSource   = $summaryData['Files Scanned at Source']
    [Int32]$filesScannedDest     = $summaryData['Files Scanned at Destination']
    [Int32]$copyTransfersFiles   = $summaryData['Number of Copy Transfers for Files']
    [Int32]$copyTransfersFolders = $summaryData['Number of Copy Transfers for Folder Properties']
    [Int32]$totalCopyTransfers   = $summaryData['Total Number Of Copy Transfers']
    [Int32]$copyCompleted        = $summaryData['Number of Copy Transfers Completed']
    [Int32]$copyFailed           = $summaryData['Number of Copy Transfers Failed']

    [string]$finalStatus          = $summaryData['Final Job Status']

    $avgThroughputMBps = 0
    if ($elapsedSeconds -and $elapsedSeconds -gt 0 -and $bytesTransferred -and $bytesTransferred -gt 0) {
        $avgThroughputMBps = [math]::Round(($bytesTransferred / 1MB) / $elapsedSeconds, 3)
    }

    return [pscustomobject]@{
        ExecutionTimestamp = $timestamp
        Source                          = $Source.Uri.AbsoluteUri
        Destination                     = $Destination
        JobId                           = $jobId
        LogFile                         = $logFile

        JobResult                  = $finalStatus

        FilesInSource            = $filesScannedSource
        FilesInDestination       = $filesScannedDest

        FilesCopied   = $copyTransfersFiles
        FoldersCopied = $copyTransfersFolders
        TotalTransfers      = $totalCopyTransfers

        TransfersCompleted  = $copyCompleted
        TransfersFailed     = $copyFailed

        TotalBytesTransferred           = $bytesTransferred
        TotalBytesEnumerated            = $bytesEnumerated
        ElapsedTimeSeconds              = $elapsedSeconds
        AverageThroughputMBps           = $avgThroughputMBps
    }
}

function Get-StorageDirectories ([System.UriBuilder]$uri, [string]$expression) {
    $listUri = [System.UriBuilder]::new($uri.Uri.AbsoluteUri)
    Add-URIParam -URI $listUri -Key "comp" -Value "list"
    Add-URIParam -URI $listUri -Key "restype" -Value "directory"

    $response = Invoke-WebRequest -Uri $listUri.Uri.AbsoluteUri -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop

    $cleanResponse = Read-ResponseOutput -Response $response

    $xmlSettings = [System.Xml.XmlReaderSettings]::new()
    $xmlSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $stringReader = [System.IO.StringReader]::new($cleanResponse)
    $xmlReader = [System.Xml.XmlReader]::Create($stringReader, $xmlSettings)
    try {
        $xml = [System.Xml.XmlDocument]::new()
        $xml.Load($xmlReader)
    }
    catch {
        throw "Failed to parse Azure Storage directory listing. The response may not be valid XML. Details: $($_.Exception.Message)"
    }
    finally {
        $xmlReader.Dispose()
        $stringReader.Dispose()
    }

    foreach ($value in $xml.EnumerationResults.Entries.Directory.Name) {

        if ($value -match $expression) {
            $datetime  = $matches['datetime'].Trim()
            $type = $matches['type'].Trim()

            [PsCustomObject]@{
                DateTime = [datetime]::Parseexact($datetime, 'yyyy-MM-dd HH-mm-ss-fff', $null)
                Type = $type
                Parent = $uri.Path.Split('/')[-1]
                DirectoryName = $value
                Path = $uri.Uri.GetLeftPart([System.UriPartial]::Path) + "/$value"
            }
        }
    }
}

Export-ModuleMember -Function Set-AzCopyPath
Export-ModuleMember -Function Print
Export-ModuleMember -Function Get-LastMonthDay
Export-ModuleMember -Function Write-InlineProgress
Export-ModuleMember -Function Write-InlineStatus
Export-ModuleMember -Function Invoke-AzCopySyncWithStats
Export-ModuleMember -Function Get-StorageDirectories
