function Backup-ToSFTP {
    param (
        [string]$ConfigPath = "C:\Path\To\backup-config.json" # Путь к JSON-файлу конфигурации
    )

    # Проверка наличия конфигурационного файла
    if (-not (Test-Path -Path $ConfigPath)) {
        Write-Host "Configuration file not found at path: $ConfigPath" -ForegroundColor Red
        return
    }

    # Загрузка конфигурации из JSON-файла
    $Config = Get-Content -Path $ConfigPath | ConvertFrom-Json

    # Извлечение названия проекта
    $ProjectName = $Config.ProjectName

    # Настройка логирования
    $LogPath = $Config.LogPath
    $Timestamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $LogFile = "$LogPath-$Timestamp.log"

    # Создание папки для логов, если она не существует
    if (-not (Test-Path -Path (Split-Path -Path $LogFile -Parent))) {
        New-Item -ItemType Directory -Path (Split-Path -Path $LogFile -Parent) | Out-Null
    }

    # Логирование функции
    function Log-Message {
        param (
            [string]$Message,
            [string]$LogLevel = "INFO"
        )
        $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $LogEntry = "$Timestamp [$LogLevel] $ProjectName : $Message"
        Add-Content -Path $LogFile -Value $LogEntry
    }

    # Запись начального сообщения в лог
    Log-Message "Starting backup process using configuration file at $ConfigPath..."

    # Начало отслеживания времени
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Получение параметров из конфигурации
    $BackupSource = $Config.BackupSource
    $ResticPath = $Config.ResticPath
    $Repository = $Config.Repository
    $ResticPassword = $Config.ResticPassword
    $UseFsSnapshot = $Config.UseFsSnapshot
    $RetentionPolicy = $Config.RetentionPolicy
    $EmailSettings = $Config.EmailSettings

    # Проверка существования исполняемого файла Restic
    if (-not (Test-Path -Path $ResticPath)) {
        Log-Message "Restic executable not found at path: $ResticPath" "ERROR"
        return
    }

    # Установка переменной окружения для пароля Restic
    $Env:RESTIC_PASSWORD = $ResticPassword

    # Построение команды резервного копирования с опциональным --use-fs-snapshot
    $BackupCommand = "$ResticPath -r $Repository backup $BackupSource"
    if ($UseFsSnapshot) {
        $BackupCommand += " --use-fs-snapshot"
    }

    # Проверка, существует ли репозиторий, и инициализация, если нет
    try {
        & $ResticPath -r $Repository snapshots 2>$null
    } catch {
        Log-Message "Repository does not exist. Initializing a new one." "INFO"
        & $ResticPath -r $Repository init
    }

    # Выполнение резервного копирования
    Log-Message "Starting backup of $BackupSource to SFTP repository at $Repository..."
    Log-Message "Executing command: $BackupCommand"
    
    $BackupOutput = Invoke-Expression $BackupCommand 2>&1 # Capture both output and error
    Log-Message "Restic Output: $BackupOutput"

    # Получение размера резервной копии
    $SizeOutput = & $ResticPath -r $Repository stats | Select-String "Total Size:"
    $TotalSize = $SizeOutput -replace 'Total Size:\s+', ''  # Извлечение значения

    # Подготовка переменной сообщения
    $MessageBody = "Backup process details for project '$ProjectName':`n"
    $MessageBody += "Configuration file used: $ConfigPath`n"

    # Проверка результата и вывод логов
    if ($LASTEXITCODE -eq 0) {
        Log-Message "Backup completed successfully." "INFO"
        $MessageBody += "Backup completed successfully at $(Get-Date).`n"
        $MessageBody += "Total size of the backup: $TotalSize.`n"  # Добавление информации о размере
    } else {
        Log-Message "Backup failed. Please check the logs for more details." "ERROR"
        $MessageBody += "Backup failed at $(Get-Date). Please check the logs for more details.`n"
    }

    # Построение команды forget для политики хранения
    if ($RetentionPolicy) {
        $ForgetCommand = "$ResticPath -r $Repository forget --prune"
        if ($RetentionPolicy.KeepLast) { $ForgetCommand += " --keep-last $($RetentionPolicy.KeepLast)" }
        if ($RetentionPolicy.KeepDaily) { $ForgetCommand += " --keep-daily $($RetentionPolicy.KeepDaily)" }
        if ($RetentionPolicy.KeepWeekly) { $ForgetCommand += " --keep-weekly $($RetentionPolicy.KeepWeekly)" }
        if ($RetentionPolicy.KeepMonthly) { $ForgetCommand += " --keep-monthly $($RetentionPolicy.KeepMonthly)" }
        if ($RetentionPolicy.KeepYearly) { $ForgetCommand += " --keep-yearly $($RetentionPolicy.KeepYearly)" }

        Log-Message "Applying retention policy and pruning old backups..."
        Log-Message "Executing command: $ForgetCommand"
        
        $ForgetOutput = Invoke-Expression $ForgetCommand 2>&1 # Capture both output and error
        Log-Message "Forget Command Output: $ForgetOutput"

        # Проверка результата команды forget
        if ($LASTEXITCODE -eq 0) {
            Log-Message "Retention policy applied successfully." "INFO"
            $MessageBody += "Retention policy applied successfully at $(Get-Date).`n"
        } else {
            Log-Message "Failed to apply retention policy. Please check the logs for more details." "ERROR"
            $MessageBody += "Failed to apply retention policy at $(Get-Date). Please check the logs for more details.`n"
        }
    }

    # Очистка переменной окружения для безопасности
    Remove-Item Env:RESTIC_PASSWORD

    # Окончание отслеживания времени
    $Stopwatch.Stop()
    $Duration = $Stopwatch.Elapsed
    $DurationString = "{0:D2}:{1:D2}:{2:D2}" -f $Duration.Hours, $Duration.Minutes, $Duration.Seconds

    # Добавление информации о продолжительности в сообщение
    $MessageBody += "Total duration of backup process: $DurationString.`n"

    # Отправка уведомления по электронной почте с результатами
    try {
        $SmtpServer = $EmailSettings.SmtpServer
        $SmtpPort = $EmailSettings.SmtpPort
        $SmtpUser = $EmailSettings.SmtpUser
        $SmtpPassword = $EmailSettings.SmtpPassword
        $From = $EmailSettings.From
        $To = $EmailSettings.To
        $Subject = "Backup Notification for $ProjectName"

        # Создание сообщения электронной почты
        $EmailMessage = @{
            SmtpServer = $SmtpServer
            Port = $SmtpPort
            From = $From
            To = $To
            Subject = $Subject
            Body = $MessageBody
            Credential = New-Object System.Management.Automation.PSCredential($SmtpUser, (ConvertTo-SecureString $SmtpPassword -AsPlainText -Force))
            UseSsl = $true
        }

        # Отправка электронной почты
        Send-MailMessage @EmailMessage
        Log-Message "Notification email sent successfully." "INFO"
    } catch {
        Log-Message "Failed to send email notification. Error: $_" "ERROR"
    }
}

# Backup-ToSFTP -ConfigPath "C:\Path\To\backup-config.json"

function Get-ResticSnapshots {
    param (
        [string]$ConfigPath = "C:\Path\To\backup-config.json" # Путь к JSON-файлу конфигурации
    )

    # Проверка наличия конфигурационного файла
    if (-not (Test-Path -Path $ConfigPath)) {
        Write-Host "Configuration file not found at path: $ConfigPath" -ForegroundColor Red
        return
    }

    # Загрузка конфигурации из JSON-файла
    $Config = Get-Content -Path $ConfigPath | ConvertFrom-Json

    # Настройка логирования
    $LogPath = $Config.LogPath
    $Timestamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $LogFile = "$LogPath-snapshots-$Timestamp.log"

    # Создание папки для логов, если она не существует
    if (-not (Test-Path -Path (Split-Path -Path $LogFile -Parent))) {
        New-Item -ItemType Directory -Path (Split-Path -Path $LogFile -Parent) | Out-Null
    }

    # Логирование функции
    function Log-Message {
        param (
            [string]$Message,
            [string]$LogLevel = "INFO"
        )
        $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $LogEntry = "$Timestamp [$LogLevel] $Message"
        Add-Content -Path $LogFile -Value $LogEntry
    }

    # Запись начального сообщения в лог
    Log-Message "Starting to retrieve snapshots..."

    # Получение параметров из конфигурации
    $ResticPath = $Config.ResticPath
    $Repository = $Config.Repository
    $ResticPassword = $Config.ResticPassword

    # Установка переменной окружения для пароля Restic
    $Env:RESTIC_PASSWORD = $ResticPassword

    # Выполнение команды для получения списка снимков
    try {
        Log-Message "Retrieving snapshots from repository at $Repository..."
        $SnapshotsOutput = & $ResticPath -r $Repository snapshots

        # Проверка наличия снимков
        if ($SnapshotsOutput -match "No snapshots found") {
            Log-Message "No snapshots found in the repository." "INFO"
            Write-Host "No snapshots found in the repository." -ForegroundColor Yellow
        } else {
            Log-Message "Snapshots retrieved successfully." "INFO"
            Write-Host $SnapshotsOutput
        }
    } catch {
        Log-Message "Failed to retrieve snapshots. Error: $_" "ERROR"
        Write-Host "Error retrieving snapshots. Check the log for details." -ForegroundColor Red
    }

    # Очистка переменной окружения для безопасности
    Remove-Item Env:RESTIC_PASSWORD
}



function Backup-ToS3 {
    param (
        [string]$ConfigPath = "C:\Path\To\backup-config.json" # Path to the configuration JSON file
    )

    # Check if the configuration file exists
    if (-not (Test-Path -Path $ConfigPath)) {
        Write-Host "Configuration file not found at path: $ConfigPath" -ForegroundColor Red
        return
    }

    # Load configuration from the JSON file
    $Config = Get-Content -Path $ConfigPath | ConvertFrom-Json

    # Extract project name for logging purposes
    $ProjectName = $Config.ProjectName

    # Set up logging
    $LogPath = $Config.LogPath
    $Timestamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $LogFile = "$LogPath-$Timestamp.log"

    # Create log directory if it doesn't exist
    if (-not (Test-Path -Path (Split-Path -Path $LogFile -Parent))) {
        New-Item -ItemType Directory -Path (Split-Path -Path $LogFile -Parent) | Out-Null
    }

    # Function for logging messages
    function Log-Message {
        param (
            [string]$Message,
            [string]$LogLevel = "INFO"
        )
        $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $LogEntry = "$Timestamp [$LogLevel] $ProjectName : $Message"
        Add-Content -Path $LogFile -Value $LogEntry
    }

    # Start logging the backup process
    Log-Message "Starting backup process using configuration file at $ConfigPath..."

    # Start tracking time
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Retrieve configuration parameters
    $BackupSource = $Config.BackupSource
    $ResticPath = $Config.ResticPath
    $Repository = $Config.Repository
    $ResticPassword = $Config.ResticPassword
    $UseFsSnapshot = $Config.UseFsSnapshot
    $RetentionPolicy = $Config.RetentionPolicy
    $EmailSettings = $Config.EmailSettings

    # Set environment variables for AWS
    $Env:AWS_ACCESS_KEY_ID = $Config.AWSAccessKeyId
    $Env:AWS_SECRET_ACCESS_KEY = $Config.AWSSecretAccessKey

    # Set the environment variable for the Restic password
    $Env:RESTIC_PASSWORD = $ResticPassword

    # Build the backup command with optional --use-fs-snapshot
    $BackupCommand = "$ResticPath -r $Repository backup $BackupSource"
    if ($UseFsSnapshot) {
        $BackupCommand += " --use-fs-snapshot"
    }

    # Execute the backup command
    Log-Message "Starting backup of $BackupSource to S3 repository at $Repository..."
    Log-Message "Executing command: $BackupCommand"
    
    $BackupOutput = Invoke-Expression $BackupCommand 2>&1 # Capture both output and error
    Log-Message "Restic Output: $BackupOutput"

    # Check the result and log accordingly
    if ($LASTEXITCODE -eq 0) {
        Log-Message "Backup completed successfully." "INFO"
        $BackupStatus = "Success"
    } else {
        Log-Message "Backup failed. Please check the logs for more details." "ERROR"
        $BackupStatus = "Failure"
    }

    # Build and execute the forget command for retention policy
    if ($RetentionPolicy) {
        $ForgetCommand = "$ResticPath -r $Repository forget --prune"
        if ($RetentionPolicy.KeepLast) { $ForgetCommand += " --keep-last $($RetentionPolicy.KeepLast)" }
        if ($RetentionPolicy.KeepDaily) { $ForgetCommand += " --keep-daily $($RetentionPolicy.KeepDaily)" }
        if ($RetentionPolicy.KeepWeekly) { $ForgetCommand += " --keep-weekly $($RetentionPolicy.KeepWeekly)" }
        if ($RetentionPolicy.KeepMonthly) { $ForgetCommand += " --keep-monthly $($RetentionPolicy.KeepMonthly)" }
        if ($RetentionPolicy.KeepYearly) { $ForgetCommand += " --keep-yearly $($RetentionPolicy.KeepYearly)" }

        Log-Message "Applying retention policy and pruning old backups..."
        Log-Message "Executing command: $ForgetCommand"
        
        $ForgetOutput = Invoke-Expression $ForgetCommand 2>&1 # Capture both output and error
        Log-Message "Forget Command Output: $ForgetOutput"

        # Check the result of the forget command
        if ($LASTEXITCODE -eq 0) {
            Log-Message "Retention policy applied successfully." "INFO"
        } else {
            Log-Message "Failed to apply retention policy. Please check the logs for more details." "ERROR"
        }
    }

    # Clean up environment variables for security
    Remove-Item Env:AWS_ACCESS_KEY_ID
    Remove-Item Env:AWS_SECRET_ACCESS_KEY
    Remove-Item Env:RESTIC_PASSWORD

    # Stop tracking time
    $Stopwatch.Stop()
    $Duration = $Stopwatch.Elapsed
    Log-Message "Total duration of backup process: $($Duration.ToString())."

    # Send email notification if enabled in configuration
    if ($EmailSettings) {
        $Subject = "$ProjectName Backup Status: $BackupStatus"
        $Body = "Backup Process completed with status: $BackupStatus`nLog Path: $LogFile`nDuration: $($Duration.ToString())"
        
        $SmtpClient = New-Object System.Net.Mail.SmtpClient($EmailSettings.SmtpServer, $EmailSettings.SmtpPort)
        $SmtpClient.EnableSsl = $true
        $SmtpClient.Credentials = New-Object System.Net.NetworkCredential($EmailSettings.SmtpUser, $EmailSettings.SmtpPassword)

        $MailMessage = New-Object System.Net.Mail.MailMessage
        $MailMessage.From = $EmailSettings.From
        $MailMessage.To.Add($EmailSettings.To)
        $MailMessage.Subject = $Subject
        $MailMessage.Body = $Body

        try {
            $SmtpClient.Send($MailMessage)
            Log-Message "Email notification sent successfully." "INFO"
        } catch {
            Log-Message "Failed to send email notification: $_" "ERROR"
        }
    }
}


function Initialize-Repository {
    param (
        [string]$ConfigPath = "C:\Path\To\backup-config.json" # Путь к JSON-файлу конфигурации
    )

    $Config = Get-Content -Path $ConfigPath | ConvertFrom-Json

    # Установка переменной окружения для пароля Restic
    $Env:RESTIC_PASSWORD = $config.ResticPassword

    try {
        # Инициализация репозитория
        & $config.ResticPath -r $config.Repository init
        Write-Host "Repository initialized successfully at $($config.Repository)." -ForegroundColor Green
    } catch {
        Write-Host "Failed to initialize repository at $($Repository). Error: $_" -ForegroundColor Red
        return $false
    } finally {
        # Очистка переменной окружения
        Remove-Item Env:RESTIC_PASSWORD
    }
    
    return $true
}