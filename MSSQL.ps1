# Dosya Yolu: REPO_ROOT/MSSQL.ps1
# Amac: SQL Server 2022 Docker test ortamini tek komut veya menuden yonetir
# Modul - PowerShell
# Version: 2.0.1
# Aciklama: Mevcut compose/env dosyalarini koruyan tasinabilir MSSQL yoneticisi
# Bagimli Oldugu Katman: Tool

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Start', 'Stop', 'Restart', 'Down', 'Status', 'Test',
                 'CheckBackup', 'Restore', 'ListDatabases', 'ResetContainer',
                 'ResetAll', 'Logs')]
    [string]$Action = 'Menu',
    [string]$BackupFile = 'logodb.bck',
    [string]$DatabaseName = 'LOGODB',
    [switch]$ForceReplace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptVersion = '2.0.1'
$RootPath = $PSScriptRoot
$EnvPath = Join-Path $RootPath '.env'
$BackupDirectory = Join-Path $RootPath 'backup'
$ComposePath = Join-Path $RootPath 'docker-compose.yml'
foreach ($candidate in @('docker-compose.yml', 'compose.yaml', 'compose.yml')) {
    $candidatePath = Join-Path $RootPath $candidate
    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
        $ComposePath = $candidatePath
        break
    }
}

function Write-FileUtf8 {
    param([string]$Path, [string]$Content)
    # Docker .env ve YAML dosyalari BOM olmadan UTF-8 olarak yazilir.
    [System.IO.File]::WriteAllText($Path, $Content,
        ([System.Text.UTF8Encoding]::new($false)))
}

function Assert-DockerReady {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker komutu bulunamadı. Docker Desktop kurulumunu kontrol edin.'
    }
    $null = & docker info --format '{{.ServerVersion}}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Engine çalışmıyor. Docker Desktop uygulamasını başlatın.'
    }
    $null = & docker compose version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Compose v2 bulunamadı.'
    }
}

function Read-Environment {
    if (-not (Test-Path -LiteralPath $EnvPath -PathType Leaf)) {
        throw ".env bulunamadi: $EnvPath. Ilk kurulum icin -Action Start kullanin."
    }
    $settings = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($EnvPath)) {
        if ($line -match '^\s*(?:#|$)') { continue }
        if ($line -notmatch '^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$') { continue }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2 -and $value[0] -eq "'" -and $value[$value.Length - 1] -eq "'") {
            $value = $value.Substring(1, $value.Length - 2).Replace("\'", "'")
        } elseif ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') {
            $value = $value.Substring(1, $value.Length - 2)
        } else {
            $value = ($value -split '\s+#', 2)[0].Trim()
        }
        $settings[$key] = $value
    }
    foreach ($requiredKey in @('MSSQL_CONTAINER_NAME', 'MSSQL_HOSTNAME', 'MSSQL_IMAGE',
                              'MSSQL_PORT', 'MSSQL_SA_PASSWORD', 'MSSQL_PID', 'MSSQL_VOLUME_NAME')) {
        if (-not $settings.ContainsKey($requiredKey) -or [string]::IsNullOrWhiteSpace($settings[$requiredKey])) {
            throw ".env icinde zorunlu anahtar eksik: $requiredKey"
        }
    }
    if ($settings['MSSQL_PORT'] -notmatch '^\d{1,5}$' -or
        [int]$settings['MSSQL_PORT'] -lt 1 -or [int]$settings['MSSQL_PORT'] -gt 65535) {
        throw '.env icindeki MSSQL_PORT gecersiz.'
    }
    if ($settings['MSSQL_CONTAINER_NAME'] -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$') {
        throw '.env icindeki MSSQL_CONTAINER_NAME gecersiz.'
    }
    return $settings
}

function Read-NewPassword {
    while ($true) {
        $secure = Read-Host 'Yeni SQL sa şifresi (gizli giriş)' -AsSecureString
        $ptr = [IntPtr]::Zero
        try {
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        } finally {
            if ($ptr -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
            }
        }
        if ($password.Length -lt 8 -or $password.Length -gt 128) {
            Write-Warning 'Şifre 8-128 karakter olmalı.'
            continue
        }
        $groups = 0
        if ($password -cmatch '[A-Z]') { $groups++ }
        if ($password -cmatch '[a-z]') { $groups++ }
        if ($password -match '[0-9]') { $groups++ }
        if ($password -match '[^a-zA-Z0-9]') { $groups++ }
        if ($groups -lt 3 -or $password -match '[\r\n]') {
            Write-Warning 'En az 3 karakter grubu (büyük/küçük/rakam/sembol) kullanın.'
            continue
        }
        $confirm = Read-Host 'Şifreyi tekrar girin' -AsSecureString
        $ptr2 = [IntPtr]::Zero
        try {
            $ptr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirm)
            $check = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr2)
        } finally {
            if ($ptr2 -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr2)
            }
        }
        if ($password -cne $check) {
            Write-Warning 'Şifreler eşleşmiyor.'
            continue
        }
        return $password
    }
}

<#
@dev-id MSSQL-CONFIG-010
@purpose Eksik yapilandirmayi ilk calistirmada uretir; var olan dosyalara dokunmaz.
@reason Mevcut container ve kalici volume'a bagli SQL verisinin korunmasi gerekir.
@contract Hazir .env veya compose dosyasi asla uzerine yazilmaz.
#>
function Ensure-Project {
    param([switch]$CreateIfMissing)
    $envExists = Test-Path -LiteralPath $EnvPath -PathType Leaf
    $composeExists = Test-Path -LiteralPath $ComposePath -PathType Leaf
    if (-not $envExists) {
        if (-not $CreateIfMissing) {
            throw 'Henüz kurulum yok. .\MSSQL.ps1 -Action Start ile başlatın.'
        }
        # @dev-id MSSQL-CONFIG-011
        # @purpose Clone edilen repoda mevcut compose yaninda ilk .env dosyasini uretir.
        # @reason Repo compose dosyasi sifirdan kurulumun onunde engel olmamalidir.
        # @contract Eski container/volume varsa yeni SA sifresi uretme ve veriye dokunma.
        # Eski ortam disari tasindiginda mevcut volume'a yeni sifreyle baglanma.
        $existingVolume = @(& docker volume ls -q --filter 'name=^mssql-test-data$')
        $existingContainer = @(& docker container ls -aq --filter 'name=^/mssql-test$')
        if ($existingVolume.Count -gt 0 -or $existingContainer.Count -gt 0) {
            throw 'mssql-test container/volume zaten var. Mevcut .env ve compose dosyalarıyla aynı klasörde çalıştırın; veri korunuyor.'
        }
        Write-Host 'Yeni MSSQL 2022 test kurulumu hazırlanıyor...' -ForegroundColor Cyan
        $password = Read-NewPassword
        # Compose .env icin tek tirnakli literal deger; dolar isareti degistirilmez.
        $escapedPassword = $password.Replace("'", "\'")
        $envContent = @"
# Dosya Yolu: REPO_ROOT/.env (runtime, git'e eklemeyin)
# Amac: Yerel MSSQL Docker test ortami ayarlari
# Modul - Env
# Version: 2.0.1
# Aciklama: Hassas sifreyi yerel makinede saklar
# Bagimli Oldugu Katman: Config
MSSQL_CONTAINER_NAME=mssql-test
MSSQL_HOSTNAME=mssql-test
MSSQL_IMAGE=mcr.microsoft.com/mssql/server:2022-latest
MSSQL_PORT=1433
MSSQL_SA_PASSWORD='$escapedPassword'
MSSQL_PID=Developer
MSSQL_VOLUME_NAME=mssql-test-data
"@
        Write-FileUtf8 -Path $EnvPath -Content $envContent
        # @dev-id MSSQL-CONFIG-012
        # @purpose Kullaniciya sifrenin .env icine kaydedildigini gizli bilgiyi yazmadan bildirir.
        # @reason Ilk kurulumda elle .env duzenlemeye gerek kalmadigi anlasilsin.
        Write-Host 'SQL sa şifresi .env dosyasına kaydedildi.' -ForegroundColor Green
        Write-Warning '.env dosyası açık metin şifre içerir. Dosyayı paylaşmayın veya Git deposuna eklemeyin.'
    }
    if (-not $composeExists) {
        if (-not $CreateIfMissing) {
            throw 'docker-compose.yml bulunamadı. İlk kurulum için -Action Start kullanın.'
        }
        $yaml = @'
# Dosya Yolu: REPO_ROOT/docker-compose.yml (runtime)
# Amac: SQL Server 2022 Docker servisini tanimlar
# Modul - YAML
# Version: 2.0.0
# Aciklama: Kalici named volume ve host backup baglantisi
# Bagimli Oldugu Katman: Config
services:
  mssql-test:
    image: ${MSSQL_IMAGE}
    container_name: ${MSSQL_CONTAINER_NAME}
    hostname: ${MSSQL_HOSTNAME}
    restart: unless-stopped
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: ${MSSQL_SA_PASSWORD}
      MSSQL_PID: ${MSSQL_PID}
    ports:
      - "127.0.0.1:${MSSQL_PORT}:1433"
    volumes:
      - mssql-data:/var/opt/mssql
      - ./backup:/backup
    healthcheck:
      test:
        - CMD-SHELL
        - SQLCMDPASSWORD="$$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -Q "SELECT 1" || exit 1
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
volumes:
  mssql-data:
    name: ${MSSQL_VOLUME_NAME}
'@
        Write-FileUtf8 -Path $ComposePath -Content $yaml
    }
    if (-not (Test-Path -LiteralPath $BackupDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $BackupDirectory -Force
    }
    return (Read-Environment)
}

function Invoke-Compose {
    param([string[]]$DockerArgs)
    & docker compose --project-directory $RootPath --env-file $EnvPath -f $ComposePath @DockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose komutu basarisiz: $($DockerArgs -join ' ')"
    }
}

function Invoke-DockerCommand {
    param([string[]]$DockerArgs)
    & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) { throw 'Docker komutu başarısız.' }
}

<#
@dev-id MSSQL-SQL-010
@purpose Container icindeki sqlcmd islemlerini sifreyi parametreye koymadan yurutur.
@reason Parola process komut satirinda veya terminal gecmisinde gorunmemelidir.
@contract SQLCMDPASSWORD host ortamindan Docker exec ile sifreyi argumana koymadan aktarir.
#>
function Invoke-SqlCommand {
    param(
        [hashtable]$Config,
        [Parameter(Mandatory)][string]$Sql,
        [string[]]$ExtraArgs = @()
    )
    $containerName = $Config['MSSQL_CONTAINER_NAME']
    # Docker -e NAME, sifreyi process komut satirina eklemeden host ortamindan okur.
    $previousPassword = [Environment]::GetEnvironmentVariable('SQLCMDPASSWORD', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('SQLCMDPASSWORD', $Config['MSSQL_SA_PASSWORD'], 'Process')
        $out = @(& docker exec --env SQLCMDPASSWORD $containerName `
            /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -l 8 @ExtraArgs -Q $Sql 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        [Environment]::SetEnvironmentVariable('SQLCMDPASSWORD', $previousPassword, 'Process')
    }
    if ($exitCode -ne 0) {
        $safeMessage = ($out | Out-String).Trim()
        throw "SQL Server sorgusu basarisiz: $safeMessage"
    }
    return $out
}

function Get-Health {
    param([hashtable]$Config)
    $name = $Config['MSSQL_CONTAINER_NAME']
    $health = & docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $name 2>$null
    if ($LASTEXITCODE -ne 0) { return 'not-found' }
    return ([string]$health).Trim()
}

function Wait-SqlReady {
    param([hashtable]$Config)
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $health = Get-Health -Config $Config
        if ($health -eq 'healthy') {
            Invoke-SqlCommand -Config $Config -Sql 'SET NOCOUNT ON; SELECT @@VERSION;' |
                ForEach-Object { Write-Host $_ }
            Write-Host 'SQL Server bağlantısı başarılı.' -ForegroundColor Green
            return
        }
        if ($health -eq 'unhealthy' -or $health -eq 'exited') {
            throw "SQL Server hazir degil: $health. -Action Logs ile loglari kontrol edin."
        }
        Write-Host "SQL Server bekleniyor ($attempt/30). Durum: $health"
        Start-Sleep -Seconds 5
    }
    throw 'SQL Server 150 saniyede hazır olmadı. -Action Logs ile logları kontrol edin.'
}

<#
@dev-id MSSQL-PATH-010
@purpose Kullanici secimi backup dosyasini sadece guvenilir backup klasorunden okur.
@reason Yol gecisi ve Windows junction/symlink uzerinden farkli dosya okunmasini engeller.
@contract BackupFile yalnizca dosya adi olabilir; harici yol ve reparse point reddedilir.
#>
function Resolve-BackupFile {
    param([string]$FileName)
    if ([string]::IsNullOrWhiteSpace($FileName) -or $FileName -in @('.', '..') -or
        $FileName -match '[<>:"/\\|?*\x00-\x1F]' -or
        [System.IO.Path]::GetFileName($FileName) -cne $FileName) {
        throw 'BackupFile sadece backup klasöründeki geçerli dosya adı olabilir.'
    }
    $backupDir = Get-Item -LiteralPath $BackupDirectory -ErrorAction Stop
    if (($backupDir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'backup klasörü symlink veya junction olamaz.'
    }
    $hostPath = Join-Path $BackupDirectory $FileName
    $file = Get-Item -LiteralPath $hostPath -ErrorAction Stop
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Backup dosyası normal bir dosya olmalı.'
    }
    return ('/backup/' + $FileName)
}

function Escape-SqlText {
    param([string]$Text)
    return $Text.Replace("'", "''")
}

function Escape-SqlIdentifier {
    param([string]$Text)
    return $Text.Replace(']', ']]')
}

function Get-BackupFiles {
    param([hashtable]$Config, [string]$FileName)
    $filePath = Resolve-BackupFile -FileName $FileName
    $sqlPath = Escape-SqlText $filePath
    $output = @(Invoke-SqlCommand -Config $Config `
        -Sql "RESTORE FILELISTONLY FROM DISK = N'$sqlPath';" `
        -ExtraArgs @('-h', '-1', '-W', '-s', '|', '-w', '8192'))
    $files = @()
    foreach ($line in $output) {
        $fields = ([string]$line) -split '\|'
        if ($fields.Count -lt 3) { continue }
        $logical = $fields[0].Trim()
        $type = $fields[2].Trim()
        if ($type -notin @('D', 'L')) { continue }
        if ([string]::IsNullOrWhiteSpace($logical)) { continue }
        $files += [pscustomobject]@{ Logical = $logical; Type = $type }
    }
    if (@($files | Where-Object Type -eq 'D').Count -eq 0 -or
        @($files | Where-Object Type -eq 'L').Count -eq 0) {
        throw 'Backup dosyasından data/log mantıksal dosya bilgisi okunamadı.'
    }
    return $files
}

function Assert-DatabaseName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 128 -or $Name -match '[\x00-\x1F]') {
        throw 'Veritabanı adı 1-128 karakter olmalı ve kontrol karakteri içermemelidir.'
    }
}

<#
@dev-id MSSQL-RESTORE-010
@purpose SQL backup dosyasini mantiksal data/log dosyalarini tasiyarak geri yukler.
@reason Var olan DB uzerine yanlislikla yazilmasini ve kalici SINGLE_USER durumunu engeller.
@contract Var olan DB icin ForceReplace + USTUNE YAZ onayi zorunludur.
#>
function Restore-Database {
    param([hashtable]$Config, [string]$FileName, [string]$Name, [bool]$Replace)
    Assert-DatabaseName -Name $Name
    $containerFile = Resolve-BackupFile -FileName $FileName
    $files = @(Get-BackupFiles -Config $Config -FileName $FileName)
    $dbLiteral = Escape-SqlText $Name
    $dbIdentifier = Escape-SqlIdentifier $Name
    $existsResult = @(Invoke-SqlCommand -Config $Config `
        -Sql "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$dbLiteral') IS NULL THEN 0 ELSE 1 END;" `
        -ExtraArgs @('-h', '-1', '-W'))
    $exists = (($existsResult | Out-String) -match '(?m)^\s*1\s*$')
    if ($exists -and -not $Replace) {
        throw "'$Name' zaten var. Uzerine yazmak icin -ForceReplace kullanin."
    }
    if ($exists -and $Replace) {
        $answer = Read-Host "DİKKAT: $Name veritabani UZERINE YAZILACAK. Onay icin USTUNE YAZ girin"
        if ($answer -cne 'USTUNE YAZ') {
            Write-Host 'Restore iptal edildi.'
            return
        }
    }
    # MSSQL data volume icin cakisabilecek dosya adlarini sabit ve temiz tut.
    $diskName = $Name -replace '[^A-Za-z0-9_-]', '_'
    if ($diskName.Length -gt 75) { $diskName = $diskName.Substring(0, 75) }
    if ([string]::IsNullOrWhiteSpace($diskName)) { $diskName = 'database' }
    if ($diskName -cne $Name) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Name)
            $hex = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').Substring(0, 8)
        } finally { $sha.Dispose() }
        $diskName = "${diskName}_$hex"
    }
    $options = @()
    $dataIndex = 0
    $logIndex = 0
    foreach ($entry in $files) {
        if ($entry.Type -eq 'D') {
            $dataIndex++
            $suffix = if ($dataIndex -eq 1) { '.mdf' } else { "_data${dataIndex}.ndf" }
        } else {
            $logIndex++
            $suffix = if ($logIndex -eq 1) { '_log.ldf' } else { "_log${logIndex}.ldf" }
        }
        $logicalName = Escape-SqlText $entry.Logical
        $targetName = Escape-SqlText "/var/opt/mssql/data/$diskName$suffix"
        $options += "MOVE N'$logicalName' TO N'$targetName'"
    }
    $options += 'RECOVERY'
    $options += 'STATS = 5'
    if ($exists -and $Replace) { $options += 'REPLACE' }
    $optionSql = $options -join ",`n    "
    $fileSql = Escape-SqlText $containerFile
    $singleUserSql = if ($exists) {
        "ALTER DATABASE [$dbIdentifier] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;"
    } else { '' }
    $restoreSql = @"
USE [master];
$singleUserSql
RESTORE DATABASE [$dbIdentifier]
FROM DISK = N'$fileSql'
WITH
    $optionSql;
ALTER DATABASE [$dbIdentifier] SET MULTI_USER;
"@
    try {
        Invoke-SqlCommand -Config $Config -Sql $restoreSql |
            ForEach-Object { Write-Host $_ }
        Write-Host "Restore tamamlandi: $Name" -ForegroundColor Green
    } catch {
        $originalError = $_
        if ($exists) {
            try {
                $null = Invoke-SqlCommand -Config $Config `
                    -Sql "USE [master]; ALTER DATABASE [$dbIdentifier] SET MULTI_USER;"
            } catch {
                Write-Warning 'Restore sonrası MULTI_USER otomatik ayarlanamadı. DB durumunu kontrol edin.'
            }
        }
        throw $originalError
    }
}

function Invoke-Action {
    param([string]$SelectedAction, [string]$SelectedBackup, [string]$SelectedDatabase,
          [bool]$SelectedForceReplace)
    Assert-DockerReady
    $canCreate = $SelectedAction -eq 'Start'
    $config = Ensure-Project -CreateIfMissing:$canCreate
    switch ($SelectedAction) {
        'Start' {
            Invoke-Compose -DockerArgs @('config', '--quiet')
            Invoke-Compose -DockerArgs @('up', '-d')
            Write-Host 'MSSQL container başlatıldı.' -ForegroundColor Green
            Invoke-Compose -DockerArgs @('ps')
        }
        'Stop' { Invoke-Compose -DockerArgs @('stop') }
        'Down' { Invoke-Compose -DockerArgs @('down') }
        'Restart' { Invoke-Compose -DockerArgs @('restart') }
        'Status' {
            Invoke-Compose -DockerArgs @('ps', '-a')
            Write-Host "Health: $(Get-Health -Config $config)"
        }
        'Test' { Wait-SqlReady -Config $config }
        'CheckBackup' {
            $file = Resolve-BackupFile -FileName $SelectedBackup
            $escaped = Escape-SqlText $file
            Invoke-SqlCommand -Config $config -Sql "RESTORE HEADERONLY FROM DISK = N'$escaped';" |
                ForEach-Object { Write-Host $_ }
            Invoke-SqlCommand -Config $config -Sql "RESTORE FILELISTONLY FROM DISK = N'$escaped';" |
                ForEach-Object { Write-Host $_ }
        }
        'Restore' {
            Restore-Database -Config $config -FileName $SelectedBackup `
                -Name $SelectedDatabase -Replace $SelectedForceReplace
        }
        'ListDatabases' {
            Invoke-SqlCommand -Config $config -Sql `
                'SET NOCOUNT ON; SELECT name, state_desc, compatibility_level, recovery_model_desc FROM sys.databases ORDER BY name;' |
                ForEach-Object { Write-Host $_ }
        }
        'ResetContainer' {
            Invoke-Compose -DockerArgs @('down')
            Invoke-Compose -DockerArgs @('up', '-d')
            Write-Host 'Container yeniden oluşturuldu. Named volume korundu.'
        }
        'ResetAll' {
            $confirm = Read-Host 'DİKKAT: Tüm SQL verileri silinecek. Onay için SIL yazın'
            if ($confirm -cne 'SIL') { Write-Host 'İşlem iptal edildi.'; return }
            Invoke-Compose -DockerArgs @('down', '-v')
            Invoke-Compose -DockerArgs @('up', '-d')
            Write-Host 'MSSQL sıfırlandı. backup klasörü korundu.' -ForegroundColor Yellow
        }
        'Logs' {
            $name = $config['MSSQL_CONTAINER_NAME']
            Invoke-DockerCommand -DockerArgs @('logs', '--tail', '100', $name)
        }
    }
}

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host "===== MSSQL Docker Yonetimi v$ScriptVersion =====" -ForegroundColor Cyan
        Write-Host ' 1) Başlat / ilk kurulum       2) Durdur'
        Write-Host ' 3) Yeniden başlat            4) Durum / Health'
        Write-Host ' 5) Bağlantı testi            6) Yedek dosyası kontrolü'
        Write-Host ' 7) Backup restore            8) Veritabanlarını listele'
        Write-Host ' 9) Container yenile          10) Container kaldır (veri korunur)'
        Write-Host '11) Son loglar               12) TÜM veriyi sıfırla'
        Write-Host ' 0) Çıkış'
        $choice = Read-Host 'Seçiminiz'
        if ($choice -eq '0') { return }
        $actionMap = @{
            '1' = 'Start'; '2' = 'Stop'; '3' = 'Restart'; '4' = 'Status'
            '5' = 'Test'; '6' = 'CheckBackup'; '7' = 'Restore'
            '8' = 'ListDatabases'; '9' = 'ResetContainer'; '10' = 'Down'
            '11' = 'Logs'; '12' = 'ResetAll'
        }
        if (-not $actionMap.ContainsKey($choice)) {
            Write-Warning 'Geçersiz seçim.'
            continue
        }
        $selectedBackup = $BackupFile
        $selectedDb = $DatabaseName
        $replace = $false
        if ($choice -eq '6' -or $choice -eq '7') {
            $inputFile = Read-Host "Yedek dosyasi [$BackupFile]"
            if (-not [string]::IsNullOrWhiteSpace($inputFile)) { $selectedBackup = $inputFile }
        }
        if ($choice -eq '7') {
            $inputDb = Read-Host "Veritabani adi [$DatabaseName]"
            if (-not [string]::IsNullOrWhiteSpace($inputDb)) { $selectedDb = $inputDb }
            $replace = (Read-Host 'Mevcut DB üzerine yazmaya izin verilsin mi? (E/H)') -eq 'E'
        }
        try {
            Invoke-Action -SelectedAction $actionMap[$choice] -SelectedBackup $selectedBackup `
                -SelectedDatabase $selectedDb -SelectedForceReplace $replace
        } catch {
            Write-Host "HATA: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

if ($Action -eq 'Menu') {
    Show-Menu
} else {
    try {
        Invoke-Action -SelectedAction $Action -SelectedBackup $BackupFile `
            -SelectedDatabase $DatabaseName -SelectedForceReplace ([bool]$ForceReplace)
    } catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}
