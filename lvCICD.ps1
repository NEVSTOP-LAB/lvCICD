# Determine script location for PowerShell

# This script must always run to completion and leave $LASTEXITCODE (set by
# LabVIEWCLI) untouched, so that the caller can propagate it. Pin the error
# action preference regardless of the caller's setting. Note: do NOT call
# `exit` at the end of this script -- when this script is invoked directly
# from a GitHub composite action (or an Azure DevOps inline task), `exit`
# would terminate the caller's PowerShell session before it can read
# output.txt / write outputs. The early `exit 1` below is intentional: it
# only fires when the environment is broken (LabVIEWCLI missing).
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
#   StartupTimeout:      max seconds to wait for the LabVIEW VI Server port to accept connections
#   MaxRetries:          how many times to retry LabVIEWCLI when it fails with the transient error code 66
#   RetryDelay:          seconds to wait between error-66 retries
#   RestartOnError66:    restart LabVIEW (kill all LabVIEW/LabVIEWCLI processes, start a fresh
#                        instance) when error 66 repeats -- a long-lived shared LabVIEW instance
#                        whose proxy channel is broken does not recover by simple retries
#   RestartAfterFailures: consecutive error-66 failures before triggering the LabVIEW restart
$StartupTimeout = $args[14]; if($StartupTimeout){} else {$StartupTimeout = 120}
$MaxRetries = $args[15]; if($MaxRetries){} else {$MaxRetries = 3}
$RetryDelay = $args[16]; if($RetryDelay){} else {$RetryDelay = 10}
$RestartOnError66 = $args[17]; if($RestartOnError66){} else {$RestartOnError66 = 'true'}
$RestartAfterFailures = $args[18]; if($RestartAfterFailures){} else {$RestartAfterFailures = 2}

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
Write-Host "RestartOnError66 = $RestartOnError66"
Write-Host "RestartAfterFailures = $RestartAfterFailures"

# Check LabVIEWCLI is available before doing anything else, so that we fail
# fast with a clear message instead of looping through retries.
if ( -not (Get-Command LabVIEWCLI -ErrorAction SilentlyContinue) ) {
    Write-Error "LabVIEWCLI is not found in PATH. Please install the NI LabVIEW Command Line Interface or add its folder to PATH."
    exit 1
}

# Helper: test whether the LabVIEW VI Server TCP port is accepting connections.
function Test-LvPortOpen([int]$Port, [int]$TimeoutMs = 1000) {
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $result = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $opened = $result.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ( $opened ) { $client.EndConnect($result) }
        return $opened
    } catch {
        # Note: when the port is closed, the TCP connect is refused and
        # EndConnect throws -- this is the COMMON case while LabVIEW is still
        # starting up, so the client must be released here as well.
        return $false
    } finally {
        # Always release the socket + wait handle, even on the throw path.
        if ( $client ) { $client.Close() }
    }
}

# Ensure LabVIEW is running and its VI Server port is accepting connections.
# Reuses a running instance when possible; otherwise starts LabVIEW and polls
# the VI Server port until it is ready (or StartupTimeout expires).
function Ensure-LvServerUp([int]$Port, [string]$LabVIEWExePath, [int]$StartupTimeout) {
    $ready = Test-LvPortOpen $Port
    if ( $ready ) {
        Write-Host "LabVIEW VI Server is already listening on port $Port. Reusing the running LabVIEW instance."
        return
    }
    Write-Host "Start-Process -FilePath ""$LabVIEWExePath"""
    Start-Process -FilePath "$LabVIEWExePath"
    # Wait until LabVIEW is actually up (VI Server port open) instead of a
    # fixed sleep: on loaded self-hosted runners LabVIEW can take well over
    # 10 seconds to start, and LabVIEWCLI fails with error 66 if it cannot
    # reach VI Server in time.
    Write-Host "Waiting for LabVIEW VI Server (port $Port) to become ready (timeout ${StartupTimeout}s) ..."
    $deadline = (Get-Date).AddSeconds($StartupTimeout)
    while ( -not $ready -and (Get-Date) -lt $deadline ) {
        Start-Sleep -Seconds 2
        $ready = Test-LvPortOpen $Port
    }
    if ( $ready ) {
        Write-Host "LabVIEW VI Server is ready on port $Port."
    } else {
        Write-Warning "LabVIEW VI Server did not become ready within ${StartupTimeout}s. Proceeding anyway; LabVIEWCLI may still fail to connect (transient error 66 / -350000 will be retried)."
    }
}

# Kill every LabVIEW / LabVIEWCLI process on the machine and start a fresh
# LabVIEW instance. Used when error 66 repeats: a long-lived shared LabVIEW
# instance (left running by earlier steps / previous runs) can end up with a
# broken proxy channel that simple retries never recover. A fresh instance
# gives LabVIEWCLI a clean communication channel.
# NOTE: this kills ALL LabVIEW.exe processes on the machine. Set the
# RestartOnError66 action input to "false" if the machine runs several
# concurrent jobs that must not be disturbed.
function Restart-LabVIEW([int]$Port, [string]$LabVIEWExePath, [int]$StartupTimeout) {
    Write-Host ""
    Write-Host "==== Repeated error 66: restarting LabVIEW to clear the broken proxy channel ===="
    Write-Host "Stopping all LabVIEW processes ..."
    Get-Process -Name LabVIEW -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "Stopping lingering LabVIEWCLI processes ..."
    Get-Process -Name LabVIEWCLI -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # Wait until the VI Server port is actually released by the old instance.
    Write-Host "Waiting for VI Server port $Port to be released ..."
    $deadline = (Get-Date).AddSeconds(60)
    while ( (Test-LvPortOpen $Port) -and (Get-Date) -lt $deadline ) {
        Start-Sleep -Seconds 2
    }

    # Start a fresh LabVIEW instance and wait for its VI Server.
    Write-Host "Start-Process -FilePath ""$LabVIEWExePath"""
    Start-Process -FilePath "$LabVIEWExePath"
    Write-Host "Waiting for the fresh LabVIEW VI Server (port $Port) to become ready (timeout ${StartupTimeout}s) ..."
    $ready = $false
    $deadline = (Get-Date).AddSeconds($StartupTimeout)
    while ( -not $ready -and (Get-Date) -lt $deadline ) {
        Start-Sleep -Seconds 2
        $ready = Test-LvPortOpen $Port
    }
    if ( $ready ) {
        Write-Host "Fresh LabVIEW VI Server is ready on port $Port."
    } else {
        Write-Warning "Fresh LabVIEW VI Server did not become ready within ${StartupTimeout}s. Proceeding anyway."
    }
    Write-Host "==== LabVIEW restart done ===="
}

# Start LabVIEW Process to ensure TCP Port of VI Server is active.
# If the VI Server port is already accepting connections (e.g. a previous
# step left LabVIEW running on the runner), reuse the running instance
# instead of starting a second one. Two LabVIEW instances fighting for the
# same VI Server port is one of the root causes of the transient LabVIEWCLI
# "Error code : 66" (communication call error in ProxyCaller) seen on
# self-hosted runners.
Ensure-LvServerUp $PortNum $LabVIEWExePath ([int]$StartupTimeout)

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

# Run LabVIEWCLI, retrying ONLY on transient communication failures.
# Retryable signatures (from LabVIEWCLI console output):
#   "Error code : 66"       - communication call error in ProxyCaller: the
#                             proxy call to the running LabVIEW failed, even
#                             though the TCP connection works. Usually a
#                             timing race, but it can also mean the long-lived
#                             shared LabVIEW instance is broken (see restart
#                             escalation below).
#   "Error code : -350000"  - the CLI failed to establish a connection with
#                             LabVIEW (VI Server not ready yet).
# Real operation failures (e.g. broken VIs detected, build errors, failing
# test cases) exit non-zero as well, but must NOT be retried, so the retry
# triggers only on the signatures above.
$retryableErrorCodes = @('66', '-350000')
$transientErrorDescriptions = @{
    '66'      = 'communication call error in ProxyCaller'
    '-350000' = 'failed to establish a connection with LabVIEW (VI Server not ready yet)'
}
$attempt = 1
$exitCode = 0
$lastOutput = @()
$consecutive66 = 0
$restartCount = 0

while ( $true ) {
    Write-Host ""
    Write-Host "==== LabVIEWCLI attempt $attempt of $MaxRetries ===="
    Write-Host "LabVIEWCLI -OperationName RunVI -VIPath ""$lvCICDVIPath"" -LogFilePath ""$lvCICD_Tool_dir\lVCLI.log"" -LogToConsole True -LabVIEWPath ""$LabVIEWExePath"" -PortNumber $PortNum ""$OperationVIPath"" $Operation $Parameter1 $Parameter2 $Parameter3 $Parameter4 $Parameter5 $Parameter6 $Parameter7 $Parameter8 $Parameter9 $Parameter10"

    # Make sure LabVIEW is still up before retry attempts (it may have
    # crashed or been closed after a previous attempt). The first attempt is
    # already covered by the Ensure-LvServerUp call at script start.
    if ( $attempt -gt 1 ) {
        Ensure-LvServerUp $PortNum $LabVIEWExePath ([int]$StartupTimeout)
    }

    # Remove the result file of a previous run/attempt, so a stale output
    # is never mistaken for the result of this attempt.
    if ( Test-Path -Path $outputVFile ) { Remove-Item -Path $outputVFile -Force }

    $lastOutput = & LabVIEWCLI @LabVIEWCLIArgs 2>&1
    $exitCode = $LASTEXITCODE
    $lastOutput | ForEach-Object { Write-Host $_ }

    if ( $exitCode -eq 0 ) { break }

    $outputText = $lastOutput -join "`n"
    $isTransient = $false
    $hitCode = ''
    foreach ( $code in $retryableErrorCodes ) {
        if ( $outputText -match "Error code\s*:\s*$code\b" ) { $isTransient = $true; $hitCode = $code; break }
    }

    if ( -not $isTransient ) {
        Write-Host ""
        Write-Error "LabVIEWCLI failed with exit code $exitCode. This is not a transient communication error (error 66 / -350000), so no retry will be performed."
        break
    }

    if ( $attempt -ge [int]$MaxRetries ) {
        Write-Host ""
        Write-Error "LabVIEWCLI failed with the transient error code $hitCode after $attempt attempt(s) (LabVIEW restarted $restartCount time(s)). Giving up."
        break
    }

    # Escalation: if error 66 keeps repeating, the shared LabVIEW instance's
    # proxy channel is likely broken and simple retries will never recover.
    # Restart LabVIEW (fresh instance) before the next attempt.
    # NOTE: $consecutive66 counts ONLY consecutive error-66 failures; any
    # other transient error (e.g. -350000) resets the counter, so the
    # RestartAfterFailures threshold means what it says.
    if ( $hitCode -eq '66' ) {
        $consecutive66 = $consecutive66 + 1
        if ( $RestartOnError66 -eq 'true' -and $consecutive66 -ge [int]$RestartAfterFailures ) {
            Restart-LabVIEW $PortNum $LabVIEWExePath ([int]$StartupTimeout)
            $restartCount = $restartCount + 1
            $consecutive66 = 0
        }
    } else {
        $consecutive66 = 0
    }

    Write-Host ""
    $transientDesc = $transientErrorDescriptions[$hitCode]
    if ( -not $transientDesc ) { $transientDesc = 'transient communication error' }
    Write-Warning "LabVIEWCLI hit the transient error code $hitCode ($transientDesc). Retrying in ${RetryDelay}s ..."
    Start-Sleep -Seconds ([int]$RetryDelay)
    $attempt = $attempt + 1
}

Write-Host "lvCICD output is saved to ""$outputVFile"""
$Result = Get-Content -Path "$outputVFile" -ErrorAction SilentlyContinue;
Write-Host "Result=$Result";

# Intentionally NO `exit` here: LabVIEWCLI's exit code is still in
# $LASTEXITCODE and the caller (GitHub composite action / Azure DevOps task)
# propagates it after reading this script's output. Exiting here would
# terminate the caller's PowerShell session before it can read output.txt.
