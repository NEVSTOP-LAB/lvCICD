# Determine script location for PowerShell

# This script must always run to completion and exit with the LabVIEWCLI exit
# code, so pin the error action preference regardless of the caller's setting.
$ErrorActionPreference = 'Continue'


$lvCICD_Tool_dir = Split-Path $script:MyInvocation.MyCommand.Path
Write-Host "lvCICD tool script directory is $lvCICD_Tool_dir"

$LabVIEW_Version = $args[0]
$Architecture = $args[1]
$OperationVIPath = $args[2]
if($LabVIEW_Version){} else {$LabVIEW_Version = '2019'}
if($Architecture){} else {$Architecture = 'x86'}
if($OperationVIPath){} else {$OperationVIPath = "$lvCICD_Tool_dir"}


$LabVIEWExePath = & "$lvCICD_Tool_dir\scripts\LabVIEW_exe_path.ps1" $LabVIEW_Version $Architecture;
$PortNum = & "$lvCICD_Tool_dir\scripts\ViServerPort.ps1" $LabVIEW_Version;
$Operation = $args[3]; #if($Operation){} else {$Operation = 'lvEcho'}
$Parameter1 = $args[4]; #if ( $Parameter1 ) { $Parameter1 = "'$Parameter1'" }
$Parameter2 = $args[5]; #if ( $Parameter2 ) { $Parameter2 = "'$Parameter2'" }
$Parameter3 = $args[6]; #if ( $Parameter3 ) { $Parameter3 = "'$Parameter3'" }
$Parameter4 = $args[7]; #if ( $Parameter4 ) { $Parameter4 = "'$Parameter4'" }
$Parameter5 = $args[8]; #if ( $Parameter5 ) { $Parameter5 = "'$Parameter5'" }
$Parameter6 = $args[9]; #if ( $Parameter6 ) { $Parameter6 = "'$Parameter6'" }
$Parameter7 = $args[10]; #if ( $Parameter7 ) { $Parameter7 = "'$Parameter7'" }
$Parameter8 = $args[11]; #if ( $Parameter8 ) { $Parameter8 = "'$Parameter8'" }
$Parameter9 = $args[12]; #if ( $Parameter9 ) { $Parameter9 = "'$Parameter9'" }
$Parameter10 = $args[13]; #if ( $Parameter10 ) { $Parameter10 = "'$Parameter10'" }

# Optional robustness settings (see action.yml inputs):
#   StartupTimeout: max seconds to wait for the LabVIEW VI Server port to accept connections
#   MaxRetries:     how many times to retry LabVIEWCLI when it fails with the transient error code 66
#   RetryDelay:     seconds to wait between error-66 retries
$StartupTimeout = $args[14]; if($StartupTimeout){} else {$StartupTimeout = 120}
$MaxRetries = $args[15]; if($MaxRetries){} else {$MaxRetries = 3}
$RetryDelay = $args[16]; if($RetryDelay){} else {$RetryDelay = 10}

Write-Host "LabVIEW_Version = $LabVIEW_Version"
Write-Host "Architecture = $Architecture"
Write-Host "OperationVIPath = $OperationVIPath"
Write-Host "Operation = $Operation"
Write-Host "Parameter1 = $Parameter1"
Write-Host "Parameter2 = $Parameter2"
Write-Host "Parameter3 = $Parameter3"
Write-Host "Parameter4 = $Parameter4"
Write-Host "Parameter5 = $Parameter5"
Write-Host "Parameter6 = $Parameter6"
Write-Host "Parameter7 = $Parameter7"
Write-Host "Parameter8 = $Parameter8"
Write-Host "Parameter9 = $Parameter9"
Write-Host "Parameter10 = $Parameter10"
Write-Host "LabVIEWExePath = $LabVIEWExePath"
Write-Host "PortNum = $PortNum"
Write-Host "StartupTimeout = $StartupTimeout"
Write-Host "MaxRetries = $MaxRetries"
Write-Host "RetryDelay = $RetryDelay"

# Check LabVIEWCLI is available before doing anything else, so that we fail
# fast with a clear message instead of looping through retries.
if ( -not (Get-Command LabVIEWCLI -ErrorAction SilentlyContinue) ) {
    Write-Error "LabVIEWCLI is not found in PATH. Please install the NI LabVIEW Command Line Interface or add its folder to PATH."
    exit 1
}

# Helper: test whether the LabVIEW VI Server TCP port is accepting connections.
function Test-LvPortOpen([int]$Port, [int]$TimeoutMs = 1000) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $result = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $opened = $result.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ( $opened ) { $client.EndConnect($result) }
        $client.Close()
        return $opened
    } catch {
        return $false
    }
}

# Start LabVIEW Process to ensure TCP Port of VI Server is active.
# If the VI Server port is already accepting connections (e.g. a previous
# step left LabVIEW running on the runner), reuse the running instance
# instead of starting a second one. Two LabVIEW instances fighting for the
# same VI Server port is one of the root causes of the transient LabVIEWCLI
# "Error code : 66" (communication call error in ProxyCaller) seen on
# self-hosted runners.
$portReady = Test-LvPortOpen $PortNum
if ( $portReady ) {
    Write-Host "LabVIEW VI Server is already listening on port $PortNum. Reusing the running LabVIEW instance."
} else {
    Write-Host "Start-Process -FilePath ""$LabVIEWExePath"""
    Start-Process -FilePath "$LabVIEWExePath"

    # Wait until LabVIEW is actually up (VI Server port open) instead of a
    # fixed sleep: on loaded self-hosted runners LabVIEW can take well over
    # 10 seconds to start, and LabVIEWCLI fails with error 66 if it cannot
    # reach VI Server in time.
    Write-Host "Waiting for LabVIEW VI Server (port $PortNum) to become ready (timeout ${StartupTimeout}s) ..."
    $deadline = (Get-Date).AddSeconds([int]$StartupTimeout)
    while ( -not $portReady -and (Get-Date) -lt $deadline ) {
        Start-Sleep -Seconds 2
        $portReady = Test-LvPortOpen $PortNum
    }
    if ( $portReady ) {
        Write-Host "LabVIEW VI Server is ready on port $PortNum."
    } else {
        Write-Warning "LabVIEW VI Server did not become ready within ${StartupTimeout}s. Proceeding anyway; LabVIEWCLI may still fail to connect (error 66 will be retried)."
    }
}

$lvCICDVIPath = "$lvCICD_Tool_dir\LabVIEW-Adapter\lvCICD.vi"
$outputVFile = "$lvCICD_Tool_dir\output.txt"

$LabVIEWCLIArgs = @(
    '-OperationName', 'RunVI',
    '-VIPath', "$lvCICDVIPath",
    '-LogFilePath', "$lvCICD_Tool_dir\lVCLI.log",
    '-LogToConsole', 'True',
    '-LabVIEWPath', "$LabVIEWExePath",
    '-PortNumber', "$PortNum",
    "$OperationVIPath",
    $Operation,
    $Parameter1,
    $Parameter2,
    $Parameter3,
    $Parameter4,
    $Parameter5,
    $Parameter6,
    $Parameter7,
    $Parameter8,
    $Parameter9,
    $Parameter10
)

# Run LabVIEWCLI, retrying ONLY on the transient "Error code : 66"
# (communication call error in ProxyCaller). Real operation failures
# (e.g. broken VIs detected, build errors, failing test cases) exit
# non-zero as well, but must NOT be retried, so the retry triggers only
# when the LabVIEWCLI output contains "Error code : 66".
$retryableErrorCodes = @('66')
$attempt = 1
$exitCode = 0
$lastOutput = @()

while ( $true ) {
    Write-Host ""
    Write-Host "==== LabVIEWCLI attempt $attempt of $MaxRetries ===="
    Write-Host "LabVIEWCLI -OperationName RunVI -VIPath ""$lvCICDVIPath"" -LogFilePath ""$lvCICD_Tool_dir\lVCLI.log"" -LogToConsole True -LabVIEWPath ""$LabVIEWExePath"" -PortNumber $PortNum ""$OperationVIPath"" $Operation $Parameter1 $Parameter2 $Parameter3 $Parameter4 $Parameter5 $Parameter6 $Parameter7 $Parameter8 $Parameter9 $Parameter10"

    # Remove the result file of a previous run/attempt, so a stale output
    # is never mistaken for the result of this attempt.
    if ( Test-Path -Path $outputVFile ) { Remove-Item -Path $outputVFile -Force }

    $lastOutput = & LabVIEWCLI @LabVIEWCLIArgs 2>&1
    $exitCode = $LASTEXITCODE
    $lastOutput | ForEach-Object { Write-Host $_ }

    if ( $exitCode -eq 0 ) { break }

    $outputText = $lastOutput -join "`n"
    $isTransient = $false
    foreach ( $code in $retryableErrorCodes ) {
        if ( $outputText -match "Error code\s*:\s*$code\b" ) { $isTransient = $true; break }
    }

    if ( -not $isTransient ) {
        Write-Host ""
        Write-Error "LabVIEWCLI failed with exit code $exitCode. This is not the transient error code 66, so no retry will be performed."
        break
    }

    if ( $attempt -ge [int]$MaxRetries ) {
        Write-Host ""
        Write-Error "LabVIEWCLI failed with the transient error code 66 after $attempt attempt(s). Giving up."
        break
    }

    Write-Host ""
    Write-Warning "LabVIEWCLI hit the transient error code 66 (communication call error in ProxyCaller). Retrying in ${RetryDelay}s ..."
    Start-Sleep -Seconds ([int]$RetryDelay)
    $attempt = $attempt + 1
}

Write-Host "lvCICD output is saved to ""$outputVFile"""
$Result = Get-Content -Path "$outputVFile" -ErrorAction SilentlyContinue;
Write-Host "Result=$Result";

exit $exitCode
