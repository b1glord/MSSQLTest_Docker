# Dosya Yolu: REPO_ROOT/tests/test-first-run.ps1
# Amac: Ilk kurulumda gizli sifre girisi ve .env yazma sozlesmesini test eder
# Modul - PowerShell
# Version: 2.0.1
# Aciklama: Docker olmadan gecici dizinde kurulum mantigini dogrular
# Bagimli Oldugu Katman: Tool

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$managerPath = Join-Path $repoRoot 'MSSQL.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $managerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'MSSQL.ps1 syntax check failed.' }

# @dev-id MSSQL-TEST-010
# @purpose Gercek scriptteki ilk kurulum fonksiyonlarini izole edip dener.
# @reason SQL container baslatmadan gercek .env olusturma davranisi dogrulanmali.
$functions = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true))
foreach ($name in @('Write-FileUtf8', 'Read-Environment', 'Read-NewPassword', 'Ensure-Project')) {
    $definitions = @($functions | Where-Object { $_.Name -eq $name })
    if ($definitions.Count -ne 1) { throw "Function not found or ambiguous: $name" }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}

# Testte kullanilan parola gercek bir credential degildir.
$script:TestPassword = 'Unit!$Pass42'
$script:InputCount = 0
$script:ExistingVolume = $false
function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    if (-not $AsSecureString) { throw 'Password input was not hidden.' }
    $script:InputCount++
    return (ConvertTo-SecureString -String $script:TestPassword -AsPlainText -Force)
}

function docker {
    if ($args.Count -lt 2 -or $args[0] -notin @('container', 'volume') -or
        $args[1] -ne 'ls') {
        throw 'Unexpected docker invocation in unit test.'
    }
    if ($script:ExistingVolume -and $args[0] -eq 'volume') {
        'mssql-test-data'
    }
}

$script:RootPath = Join-Path ([IO.Path]::GetTempPath()) (
    'mssql-first-run-' + [Guid]::NewGuid().ToString('N'))
$script:EnvPath = Join-Path $script:RootPath '.env'
$script:BackupDirectory = Join-Path $script:RootPath 'backup'
$script:ComposePath = Join-Path $repoRoot 'docker-compose.yml'
$null = New-Item -ItemType Directory -Path $script:RootPath -Force

try {
    $settings = Ensure-Project -CreateIfMissing
    if (-not (Test-Path -LiteralPath $script:EnvPath -PathType Leaf)) {
        throw 'First startup did not create .env.'
    }
    if ($script:InputCount -ne 2) { throw 'Password and confirmation were not both requested.' }
    if ($settings['MSSQL_SA_PASSWORD'] -cne $script:TestPassword) {
        throw 'Password was not persisted to .env.'
    }
    if (-not (Test-Path -LiteralPath $script:BackupDirectory -PathType Container)) {
        throw 'Backup directory was not created.'
    }
    $firstContent = [IO.File]::ReadAllText($script:EnvPath)
    $script:TestPassword = 'Changed!Pass42'
    $settingsAgain = Ensure-Project -CreateIfMissing
    if ($script:InputCount -ne 2 -or $settingsAgain['MSSQL_SA_PASSWORD'] -cne 'Unit!$Pass42') {
        throw 'Existing .env was unexpectedly overwritten or password re-prompted.'
    }
    if ([IO.File]::ReadAllText($script:EnvPath) -cne $firstContent) {
        throw 'Existing .env content changed.'
    }

    Remove-Item -LiteralPath $script:EnvPath -Force
    $script:ExistingVolume = $true
    $blocked = $false
    try { $null = Ensure-Project -CreateIfMissing } catch { $blocked = $true }
    if (-not $blocked) { throw 'Existing database volume did not block new password creation.' }
    if ($script:InputCount -ne 2 -or (Test-Path -LiteralPath $script:EnvPath)) {
        throw 'Existing volume guard changed the environment or requested a password.'
    }
} finally {
    Remove-Item -LiteralPath $script:RootPath -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS: first-run password prompt, .env persistence, reuse, volume guard.'
