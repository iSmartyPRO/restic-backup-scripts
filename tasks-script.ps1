function New-DailyScheduledTask {
    param (
        [string]$TaskName = "DailyPowerShellScript",          # Task name
        [string]$ScriptPath,                                   # Path to the PowerShell script
        [string]$Time = "23:00",                               # Time to run in HH:mm format
        [string]$Description = "Run PowerShell script daily",  # Task description
        [string]$UserId = "SYSTEM",                           # User account to run the task (default is SYSTEM)
        [string]$WorkingDirectory = "C:\Path\To\WorkingDir"  # Working directory for the script
    )

    # Check if the script path is specified
    if (-not (Test-Path -Path $ScriptPath)) {
        Write-Error "The specified script path does not exist: $ScriptPath"
        return
    }

    # Check if the working directory is specified
    if (-not (Test-Path -Path $WorkingDirectory)) {
        Write-Error "The specified working directory does not exist: $WorkingDirectory"
        return
    }

    # Create an action to run PowerShell with the specified script
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File `"$ScriptPath`" -NoProfile -WindowStyle Hidden"

    # Create a daily trigger with the specified start time
    $TriggerTime = [datetime]::ParseExact($Time, "HH:mm", $null)
    $Trigger = New-ScheduledTaskTrigger -Daily -At $TriggerTime

    # Set the account and privilege level for running the task
    $Principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType ServiceAccount -RunLevel Highest

    # Register the scheduled task with the specified working directory
    Register-ScheduledTask -Action $Action -Trigger $Trigger -Principal $Principal -TaskName $TaskName -Description $Description -WorkingDirectory $WorkingDirectory

    Write-Output "Task '$TaskName' has been successfully created for daily execution at $Time with working directory '$WorkingDirectory'."
}

# Example of calling the function
# New-DailyScheduledTask -TaskName "Restic Backup - Project Name" -ScriptPath "C:\apps\backupScripts\scheduledScripts\task-ng2.ps1" -Time "23:00" -Description "Run Restic Backup every night at 23:00" -WorkingDirectory "C:\apps\backupScripts"