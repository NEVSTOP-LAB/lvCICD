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
#   MaxRetries:          how many times to retry LabVIEWCLI when it fails with a transient
#                        communication error (error 66 / -350000)
#   RetryDelay:          seconds to wait between transient-failure retries
#   RestartOnError66:    stop the process holding the VI Server port and start a fresh
#                        LabVIEW instance when error 66 repeats
#   RestartAfterFailures: consecutive transient failures before triggering the restart
#   RestartOnConnectFailure: same restart for the connect error -350000, where the port is
#                        held by a process that is not the VI Server this request targets
$StartupTimeout = $args[14]; if($StartupTimeout){} else {$StartupTimeout = 120}
$MaxRetries = $args[15]; if($MaxRetries){} else {$MaxRetries = 3}
$RetryDelay = $args[16]; if($RetryDelay){} else {$RetryDelay = 10}
$RestartOnError66 = $args[17]; if($RestartOnError66){} else {$RestartOnError66 = 'false'}
$RestartAfterFailures = $args[18]; if($RestartAfterFailures){} else {$RestartAfterFailures = 2}
$RestartOnConnectFailure = $args[19]; if($RestartOnConnectFailure){} else {$RestartOnConnectFailure = 'true'}

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
Write-Host "RestartOnConnectFailure = $RestartOnConnectFailure"

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

# Helper: the process that listens on the VI Server TCP port.
function Get-VIPortOwner([int]$Port) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ( -not $conn ) { return $null }
    return Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
}

# Helper: whether the given process is a verified copy of the LabVIEW build
# this request targets. Only an executable path that can be read and matches
# the requested build is accepted: an unreadable path cannot be verified, and
# reusing such an instance risks driving another LabVIEW build.
function Test-LvOwnerIsTarget($Owner, [string]$LabVIEWExePath) {
    if ( -not $Owner ) { return $false }
    if ( -not $Owner.Path ) { return $false }
    return ( $Owner.Path -ieq $LabVIEWExePath )
}

# Helper: the port accepts connections and is hosted by the LabVIEW build this
# request targets. A listening port does not by itself identify its owner:
# another process holding the port keeps LabVIEW from binding it, and a port
# held by a different LabVIEW build is not the instance this request may drive.
function Test-LvServerReady([int]$Port, [string]$LabVIEWExePath, [switch]$Quiet) {
    if ( -not (Test-LvPortOpen $Port) ) { return $false }
    $owner = Get-VIPortOwner $Port
    if ( -not $owner ) {
        if ( -not $Quiet ) { Write-Warning "Port $Port accepts connections but its owning process cannot be resolved. The port is treated as not ready." }
        return $false
    }
    if ( Test-LvOwnerIsTarget $owner $LabVIEWExePath ) { return $true }
    if ( -not $owner.Path -and ($owner.ProcessName -ieq 'LabVIEW') ) {
        if ( -not $Quiet ) { Write-Warning "Port $Port is held by LabVIEW (PID $($owner.Id)) whose executable path is not readable, so it cannot be verified as $LabVIEWExePath. The port is treated as not ready." }
        return $false
    }
    if ( -not $Quiet ) { Write-Warning "Port $Port is held by $($owner.ProcessName) (PID $($owner.Id), $($owner.Path)) instead of $LabVIEWExePath." }
    return $false
}

# Ensure LabVIEW is running and its VI Server port is accepting connections.
# Reuses a running instance when possible; otherwise starts LabVIEW and polls
# the VI Server port until it is ready (or StartupTimeout expires).
function Ensure-LvServerUp([int]$Port, [string]$LabVIEWExePath, [int]$StartupTimeout) {
    $ready = Test-LvServerReady $Port $LabVIEWExePath
    if ( $ready ) {
        Write-Host "LabVIEW VI Server is already listening on port $Port. Reusing the running LabVIEW instance."
        return
    }
    # A port that is already held cannot be bound by a new LabVIEW instance, so
    # starting one and waiting for the port would only spend the full
    # StartupTimeout. An owner that is not a verified copy of the targeted
    # LabVIEW build (another build, an unrelated service, an unreadable path)
    # is reported and left alone: starting an instance would not release the
    # port, and driving that instance is not this request's to do.
    $owner = Get-VIPortOwner $Port
    if ( $owner -and -not (Test-LvOwnerIsTarget $owner $LabVIEWExePath) ) {
        Write-Warning "Port $Port is held by $($owner.ProcessName) (PID $($owner.Id), $($owner.Path)), which is not the targeted LabVIEW ($LabVIEWExePath). No LabVIEW instance is started while the port is held."
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
        $ready = Test-LvServerReady $Port $LabVIEWExePath -Quiet
    }
    if ( $ready ) {
        Write-Host "LabVIEW VI Server is ready on port $Port."
    } else {
        Write-Warning "LabVIEW VI Server did not become ready within ${StartupTimeout}s. Proceeding anyway; LabVIEWCLI may still fail to connect (transient error 66 / -350000 will be retried)."
    }
}

# Stop the process that holds the given VI Server port and start a fresh
# LabVIEW instance for that port. Used when a transient failure repeats.
# Only a process verified as the targeted LabVIEW build is stopped: another
# LabVIEW build, an unrelated service holding the port and a process whose
# executable path cannot be read are reported and left running. Returns $true
# when the instance was restarted.
#
# The LabVIEWCLI process check below is a best-effort guard, not
# synchronization: a job between two CLI invocations holds no LabVIEWCLI
# process, and another job can start one right after the check. A VI Server
# instance is shared by every job on the machine, so a restart can still
# interrupt another job. Run one LabVIEW CI job at a time on a self-hosted
# runner when the restart escalation is enabled.
function Restart-LabVIEW([int]$Port, [string]$LabVIEWExePath, [int]$StartupTimeout) {
    Write-Host ""
    Write-Host "==== Restarting the VI Server instance on port $Port ===="
    $otherCli = @(Get-Process -Name LabVIEWCLI -ErrorAction SilentlyContinue)
    if ( $otherCli.Count -gt 0 ) {
        Write-Warning "Skipped the restart: $($otherCli.Count) LabVIEWCLI process(es) are running and may be calling into the same VI Server instance."
        return $false
    }
    $owner = Get-VIPortOwner $Port
    if ( $owner ) {
        if ( -not (Test-LvOwnerIsTarget $owner $LabVIEWExePath) ) {
            Write-Warning "Skipped the restart: port $Port is held by $($owner.ProcessName) (PID $($owner.Id), $($owner.Path)), which cannot be verified as the targeted LabVIEW ($LabVIEWExePath). That process is left running."
            return $false
        }
        Write-Host "Stopping $($owner.ProcessName) (PID $($owner.Id)) holding port $Port ..."
        Stop-Process -Id $owner.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $owner.Id -Timeout 60 -ErrorAction SilentlyContinue
    } else {
        Write-Host "No process is listening on port $Port."
    }

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
        $ready = Test-LvServerReady $Port $LabVIEWExePath -Quiet
    }
    if ( $ready ) {
        Write-Host "Fresh LabVIEW VI Server is ready on port $Port."
    } else {
        Write-Warning "Fresh LabVIEW VI Server did not become ready within ${StartupTimeout}s. Proceeding anyway."
    }
    Write-Host "==== LabVIEW restart done ===="
    return $true
}

# Report the state of the VI Server instance the request targets, plus every
# LabVIEW / LabVIEWCLI process on the machine. One VI Server instance per
# LabVIEW build is shared by every job on the machine, so these values tell
# apart "the instance is gone" from "another job drives the same instance".
function Write-LvInstanceDiagnostics([int]$Port, [string]$LabVIEWExePath) {
    Write-Host "---- VI Server diagnostics ----"
    Write-Host "Port $Port accepts connections: $(Test-LvPortOpen $Port)"
    $owner = Get-VIPortOwner $Port
    if ( $owner ) {
        Write-Host "Port $Port owner: $($owner.ProcessName) (PID $($owner.Id), $($owner.Path))"
    } else {
        Write-Host "Port $Port has no listening process."
    }
    Write-Host "Expected LabVIEW: $LabVIEWExePath"
    $lvs = @(Get-Process -Name LabVIEW -ErrorAction SilentlyContinue)
    if ( $lvs.Count -eq 0 ) {
        Write-Host "LabVIEW processes: none"
    } else {
        $lvs | ForEach-Object { Write-Host "LabVIEW process: PID $($_.Id) $($_.Path)" }
    }
    $clis = @(Get-Process -Name LabVIEWCLI -ErrorAction SilentlyContinue)
    if ( $clis.Count -eq 0 ) {
        Write-Host "LabVIEWCLI processes: none"
    } else {
        $clis | ForEach-Object { Write-Host "LabVIEWCLI process: PID $($_.Id)" }
    }
}

# List the files named "<Operation>.vi" below the operation folder. LabVIEW
# locates the operation VI by name under that folder, so every match is a
# candidate and extra copies are reported instead of being picked silently.
function Show-OperationVICandidates([string]$SearchRoot, [string]$Operation) {
    if ( -not (Test-Path -LiteralPath $SearchRoot) ) {
        Write-Warning "Operation folder ""$SearchRoot"" does not exist; the operation VI ""$Operation.vi"" cannot be located."
        return
    }
    $candidates = @(Get-ChildItem -LiteralPath $SearchRoot -Filter "$Operation.vi" -Recurse -File -ErrorAction SilentlyContinue)
    if ( $candidates.Count -eq 0 ) {
        Write-Warning "No ""$Operation.vi"" exists below ""$SearchRoot""; the operation VI cannot be located."
    } elseif ( $candidates.Count -eq 1 ) {
        Write-Host "Operation VI: $($candidates[0].FullName)"
    } else {
        Write-Warning "$($candidates.Count) files named ""$Operation.vi"" exist below ""$SearchRoot""; which one is used is decided by LabVIEW:"
        $candidates | ForEach-Object { Write-Host "    $($_.FullName)" }
    }
}

# Start LabVIEW Process to ensure TCP Port of VI Server is active.
# If the VI Server port is already hosted by the targeted LabVIEW build (e.g.
# a previous step left LabVIEW running on the runner), the running instance is
# reused instead of starting a second one.
Ensure-LvServerUp $PortNum $LabVIEWExePath ([int]$StartupTimeout)
Show-OperationVICandidates $OperationVIPath $Operation

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
#                             though the TCP connection works.
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
$consecutiveFailures = 0
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
    # Both transient signatures are instance-level failures, so the state of the
    # targeted instance is reported before the retry decision. A restart is
    # enabled per signature: error 66 means the instance answered but the proxy
    # call failed, -350000 means the port is held by something that is not the
    # VI Server this request targets.
    Write-LvInstanceDiagnostics $PortNum $LabVIEWExePath
    $restartEnabled = ( $RestartOnConnectFailure -eq 'true' )
    if ( $hitCode -eq '66' ) { $restartEnabled = ( $RestartOnError66 -eq 'true' ) }
    $consecutiveFailures = $consecutiveFailures + 1
    if ( $restartEnabled -and $consecutiveFailures -ge [int]$RestartAfterFailures ) {
        if ( Restart-LabVIEW $PortNum $LabVIEWExePath ([int]$StartupTimeout) ) {
            $restartCount = $restartCount + 1
        }
        $consecutiveFailures = 0
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
