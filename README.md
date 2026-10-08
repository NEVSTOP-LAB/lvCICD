# Customer Action for LabVIEW CI/CD (lvCICD)

<!-- [![Sync With AZDO](https://github.com/LV-APT/lvCICD/actions/workflows/Sync%20With%20AZDO.yml/badge.svg)](https://github.com/LV-APT/lvCICD/actions/workflows/Sync%20With%20AZDO.yml) -->
[![LabVIEW Project Tests](https://github.com/NEVSTOP-LAB/lvCICD/actions/workflows/LabVIEW%20Project%20Tests.yml/badge.svg)](https://github.com/NEVSTOP-LAB/lvCICD/actions/workflows/LabVIEW%20Project%20Tests.yml)

## Introduction

This repo is used to complete the missing part of LabVIEW operations in Continuous integration and continuous deployment(CI/CD).

You can use **`lvCICD`** to:

1. *Build your LabVIEW project/LabVIEW FPGA bitfile*
2. *Start Vi Analyzer*
3. *Run LabVIEW test cases*
4. *Install/uninstall VIPM libraries(vip)*
5. *Apply VIPM VIPC file(vipc)*
6. *Setup Large LabVIEW build facility*
7. *Add your own operation, [Click link to see how to contribute to it](docs/How-to-contribute.md)*

Check [**lvCICD Operation-List**](docs/Operation-List.md) for operations of `lvCICD`.

### Dependence

- [LabVIEW 2014 or Later](https://www.ni.com/zh-cn/support/downloads/software-products/download.labview.html)
- [LabVIEW Command line Interface](https://www.ni.com/zh-cn/support/downloads/software-products/download.ni-labview-command-line-interface.html#)
- VIPM Libraries: [VIPM vipc file Download Link](https://github.com/LV-APT/lvCICD/files/8727600/lvCICD.zip)
  - [OpenG by OpenG](https://www.vipm.io/package/openg.org_lib_openg_toolkit/) (LabVIEW >= 2009)
  - [Git API by Hampel Software Engineering](https://www.vipm.io/package/hse_lib_git_api/) (LabVIEW  >= 2016) *Not available in LabVIEW 2014,2015*
  - [VIPM API by JKI](https://www.vipm.io/package/jki_lib_vipm_api/) (LabVIEW  >= 2013)
  - [JKI VI Tester by JKI](https://www.vipm.io/package/jki_labs_tool_vi_tester/) (LabVIEW  >= 2013)

### Known Issues

- Only `10` Parameters could be defined
- The name of parameter is not intuitive due to limitation of github customer action. Check the Operation List for what it stands for.
- Path definition. You can use `[GLOBAL_MACRO]` in relative path parameter.
  Available `GLOBAL_MACRO`:
  - `vi.lib`: vi.lib folder of LabVIEW
  - `user.lib`: user.lib folder of LabVIEW
  - `temp`: temporary folder of System
  - `desktop`: current user's desktop folder
  - You can also use `System Environment Variable` defined in **Environment Variables**

  Examples:
  - If current user's desktop folder is ***C:\Users\Bob\Desktop***
    - ***"[Desktop]\abc.txt"*** -->  ***C:\Users\Bob\Desktop\abc.txt***
  - If LabVIEW 2019(32bit) is used
    - ***[vi.lib]\Utility\error.llb*** --> ***"C:\Program Files (x86)\National Instruments\LabVIEW 2019\vi.lib\Utility\error.llb"***
  - If set ***"SyncPath=C:\Sync"*** in **Environment Variables**
    - ***[SyncPath]\abc.txt*** --> ***"C:\Sync\abc.txt"***

### Troubleshooting: LabVIEWCLI connection failures

`LabVIEWCLI` produces two transient failures that are not operation failures:

- `Error code : 66` —
`RunExecuteOperationVI.vi ... ProxyCaller 中的通信调用错误`
(communication call error in ProxyCaller) — printed immediately after
`Connection established with LabVIEW at port number ...`. The port answers,
but the proxy call into that LabVIEW instance fails.
- `Error code : -350000` — the CLI could not establish a connection at all,
which is what a VI Server port held by a process that is not the targeted
LabVIEW build looks like.

How `lvCICD` handles them:

1. The VI Server port is reused only when its owner is a verified copy of the
LabVIEW build the request targets — the executable path must be readable and
match. When the port is held by anything else, including a LabVIEW build whose
executable path cannot be read, no LabVIEW instance is started and the port is
not polled: a port that is already held cannot be bound by a new instance.
2. Both signatures are retried up to `MaxRetries` times, `RetryDelay` seconds
apart, and the state of the targeted instance is printed on every such failure
(port owner, LabVIEW/LabVIEWCLI processes). Every other failure (broken VIs
detected, build errors, failing test cases) fails the step immediately without
retries.
3. Restart escalation after `RestartAfterFailures` consecutive transient
failures: the process holding the VI Server port is stopped, the port is waited
for, a fresh LabVIEW instance is started and the call is retried. It is on by
default for `-350000` (`RestartOnConnectFailure`) and off by default for
`Error code : 66` (`RestartOnError66`), which repeats because of instance
sharing rather than a restartable state. Only a process verified as the
targeted LabVIEW build is stopped; another LabVIEW build, an unrelated service
holding the port, and a process whose executable path cannot be read are
reported and left running. When another LabVIEWCLI process is running, the
restart is also skipped.

> [!NOTE]
> One VI Server instance per LabVIEW build is shared by every job on the
> machine, so an `Error code : 66` that reproduces on every attempt is
explained by that sharing: the shared instance is stopped or restarted by
another job while this job is calling into it. Keep one LabVIEW CI job running
at a time on a self-hosted runner.

> [!WARNING]
> Restarting a VI Server instance interrupts every job that shares it,
> including jobs of other repositories on the same runner.
>
> The "another LabVIEWCLI process is running" check that guards the restart is
> best effort, not synchronization: a job between two CLI invocations holds no
> LabVIEWCLI process, and another job can start one right after the check. The
> restart escalation therefore assumes runner-level isolation — one LabVIEW CI
> job at a time on the machine — and cannot provide it.

## Pre-works

  1. Setup a self-host runner for your repo.
     1. Add your self-hosted Windows Machine to pool [`Azure DevOps`](https://docs.microsoft.com/en-us/azure/devops/pipelines/agents/v2-windows?view=azure-devops) | [`Github`](https://docs.github.com/en/enterprise-server@3.2/actions/hosting-your-own-runners/adding-self-hosted-runners)
     2. Tips:
        1. **[!IMPORTANT!]** Please read [Security hardening for GitHub Actions](https://docs.github.com/en/enterprise-server@3.5/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners) before using a self-host runner in public repos.
        Best practice:
           1. Do NOT use `pull_request` trigger for public repos.
           2. Only use actions created by GitHub or verified creators in marketplace.
           3. Use github secret to store your critical information instead of using plant-text in workflow yml file.
        2. Running Powershell Scripts needs to be enabled on the system. [Reference](https://www.partitionwizard.com/clone-disk/running-scripts-is-disabled-on-this-system.html)
        3. If you set the runner/agent application as a service, please set the account to current user. This makes it easier to set up the environment. You can use `whoami` command to check the current user.
  2. Install LabVIEW and its components needed with [NI Package Manger](https://www.ni.com/zh-cn/support/downloads/software-products/download.package-manager.html)
  3. Install [LabVIEW Command line Interface](https://www.ni.com/zh-cn/support/downloads/software-products/download.ni-labview-command-line-interface.html#)
  4. Install dependent VIPM Libraries ([lvCICD.vipc](https://github.com/LV-APT/lvCICD/files/8727600/lvCICD.zip)).
  5. Install the softwares needed for your own case.

## Usage

### Github Actions

Add this customer-action to `steps` session in github actions yml file.

> Copy this snippet to github workflow yml file and change the content quoted by `[]` following your self-hosted agent/runner configuration and operation to execute.
>
> Use `${{ steps.[step-id].result.Result }}` in next steps to use result of lvCICD.
>
> Check [**lvCICD Operation-List**](docs/Operation-List.md) for detailed information.

    - name: [your_action_step_name]
      uses: LV-APT/lvCICD@[lvcicd_version]
      id: [step-id]
      with:
        Operation: [optional, operation_in_list, 'lvEcho' as default]
        Parameter1: [optional, parameter]
        Parameter2: [optional, parameter]
        Parameter3: [optional, parameter]
        Parameter4: [optional, parameter]
        Parameter5: [optional, parameter]
        Parameter6: [optional, parameter]
        Parameter7: [optional, parameter]
        Parameter8: [optional, parameter]
        Parameter9: [optional, parameter]
        Parameter10: [optional, parameter]
        LabVIEW_Version: [optional, LabVIEW_version,2019 or Later,2019 as default]
        Architecture: [optional, x86 or x64, x86 as default]
        OperationVIFolder: [optional, use lvCICD action path as default, set to ${{ github.workspace }} for searching operations in your repo]
        StartupTimeout: [optional, max seconds to wait for the LabVIEW VI Server port to accept connections before invoking LabVIEWCLI, 120 as default]
        MaxRetries: [optional, how many times to retry LabVIEWCLI when it fails with a transient communication error (error 66 / -350000), 3 as default]
        RetryDelay: [optional, seconds to wait between transient-failure retries, 10 as default]
        RestartOnError66: [optional, stop the process holding the VI Server port and start a fresh LabVIEW instance when error 66 keeps repeating; only a process verified as the targeted LabVIEW is stopped, false as default]
        RestartAfterFailures: [optional, consecutive transient failures before the restart, 2 as default]
        RestartOnConnectFailure: [optional, same restart for the connect error -350000; only a process verified as the targeted LabVIEW is stopped, true as default]

**Example 1**: use `lvEcho` to check runner/agent ready for lvCICD tools.

    - name: TestEnvironment
      id: lvEcho
      uses: LV-APT/lvCICD@v0.3
      with:
        Operation: lvEcho
        Parameter1: "line1"
        Parameter2: "line2"
        Parameter3: "line3"

**Example 2**: use `StartVITester` to run unit test cases in "CICD-LabVIEW-Adapter.lvproj".

    - name: Run lvCICD Test cases with VITester
      id: StartVITester
      uses: LV-APT/lvCICD@v0.3
      with:
        Operation: StartVITester
        Parameter1: ${{ github.workspace }}\LabVIEW-Adapter\CICD-LabVIEW-Adapter.lvproj

### Azure DevOps

#### Step 1: Add Variables needed for lvCICD in Azure DevOps Pipeline yml file

> Change the `lvCICD-Tool-Version`/`LabVIEW-Version`/`LabVIEW-Architecture` following your self-hosted agent/runner configuration.

    variables:
    - name: lvCICD-Tool-URL
      value: https://github.com/LV-APT/lvCICD
    - name: lvCICD-Tool-LocalPath
      value: $(Agent.TempDirectory)\lvCICD
    - name: lvCICD-Tool-Version
      value: v0.3
    - name: lvCICD
      value: '"$(lvCICD-Tool-LocalPath)\lvCICD.ps1" $(LabVIEW-Version) $(LabVIEW-Architecture) "$(OperationVIFolder)"'
    - name: LabVIEW-Version
      value: '2017'
    - name: LabVIEW-Architecture
      value: x86
    - name: OperationVIFolder
      value: ""

#### Step 2: Add task for Downloading lvCICD tools to `steps` session of Azure DevOps Pipeline yml file

> lvCICD tool repo needs to be downloaded before taking any operation by `lvCICD`.
>
> Copy this snippet to your Azure DevOps Pipeline yml file as it is. You don't need to change it.

    - task: PowerShell@2
      displayName: Clone lvCICD Tools
      inputs:
        targetType: 'inline'
        script: |
          # Show Parameters
          Write-Host "lvCICD-Tool-LocalPath = $(lvCICD-Tool-LocalPath)"
          Write-Host "lvCICD-Tool-URL = $(lvCICD-Tool-URL)"
          Write-Host "lvCICD-Tool-Version = $(lvCICD-Tool-Version)"
          # Remove temp files
          Write-Host "if ( Test-Path -Path ""$(lvCICD-Tool-LocalPath)"") { Remove-Item -Recurse -Force ""$(lvCICD-Tool-LocalPath)"" }"
          if ( Test-Path -Path "$(lvCICD-Tool-LocalPath)") { Remove-Item -Recurse -Force "$(lvCICD-Tool-LocalPath)" }
          # Clone Tools
          Write-Host "git clone --progress --depth 1 --branch $(lvCICD-Tool-Version) ""$(lvCICD-Tool-URL)"" ""$(lvCICD-Tool-LocalPath)"""
          git clone --progress --depth 1 --branch $(lvCICD-Tool-Version) "$(lvCICD-Tool-URL)" "$(lvCICD-Tool-LocalPath)"

#### Step 3: Add task of lvCICD to DevOps Pipeline yml file

> Copy this snippet to DevOps Pipeline yml file and change the content quoted by `[]` following your self-hosted agent/runner configuration and operation to execute.
>
> Check [**lvCICD Operation-List**](docs/Operation-List.md) for detailed information.

    - task: PowerShell@2
      displayName: [your_action_step_name]
      inputs:
        targetType: 'inline'
        script: |
          # Write your PowerShell commands here.
          & $(lvCICD) [Operation] [Parameter1] [Parameter2] [Parameter3] ...

> If you need to use the output of lvCICD operation, use this snippet instead.
>
> `lvCICD` operation saves the output to ***"$(lvCICD-Tool-LocalPath)\output.txt"***. The additional code in the task exports the result to a variable named `lvEchoOutput`, which could be used in following steps.
>
> Change variable name in your case. Refer to [Set variables in scripts](https://docs.microsoft.com/en-us/azure/devops/pipelines/process/set-variables-scripts?view=azure-devops&tabs=powershell) for more information.

    - task: PowerShell@2
      displayName: [your_action_step_name]
      inputs:
        targetType: 'inline'
        script: |
          # Write your PowerShell commands here.
          & $(lvCICD) [Operation] [Parameter1] [Parameter2] [Parameter3] ...
          $Result=Get-Content -Path "$(lvCICD-Tool-LocalPath)\output.txt";
          Write-Host "##vso[task.setvariable variable=lvEchoOutput;]$Result"

**Example 1**: use `lvEcho` to check runner/agent ready for lvCICD tools.

    - task: PowerShell@2
      displayName: lvEcho
      inputs:
        targetType: 'inline'
        script: |
          & $(lvCICD) lvEcho a b c

**Example 2**: use `lvBuild` to build "lvCICD-Example.lvproj" which contains a build spec in it.

    - task: PowerShell@2
      displayName: lvBuild
      inputs:
        targetType: 'inline'
        script: |
          Write-Host "$(Pipeline.Workspace)"
          Write-Host "$(Build.Repository.LocalPath)"
          & $(lvCICD) lvBuild '$(Build.Repository.LocalPath)\lvCICD-Example.lvproj'
