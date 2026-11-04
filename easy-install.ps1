# Karduno Self-Hosted: configure, check domain routing, and start on Windows.
[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [switch]$SkipDependencies,
    [switch]$PrepareOnly,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Help) {
    Write-Host 'Karduno Self-Hosted - Easy Install'
    Write-Host '  .\easy-install.ps1                    Configure, check domains, pull images, and start'
    Write-Host '  .\easy-install.ps1 -PrepareOnly       Prepare configuration without starting'
    Write-Host '  .\easy-install.ps1 -NonInteractive    Use an existing .env without prompts'
    Write-Host '  .\easy-install.ps1 -SkipDependencies  Do not install missing packages'
    Write-Host 'Missing Docker Desktop can be installed with WinGet. Default setup checks TCP 80/443 and HTTPS.'
    return
}
if ($env:OS -ne 'Windows_NT') {
    throw 'Use bash easy-install.sh on Unix systems.'
}

function Find-Docker {
    $command = Get-Command docker -ErrorAction SilentlyContinue
    if ($command) { return $command }
    foreach ($candidate in @(
        "$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe",
        "$env:LOCALAPPDATA\Programs\DockerDesktop\resources\bin\docker.exe"
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return Get-Command $candidate
        }
    }
    return $null
}

function Read-Value([string]$Label, [string]$Default = '') {
    if ($Default) { $Label += " [$Default]" }
    $answer = Read-Host $Label
    if ([string]::IsNullOrEmpty($answer)) { return $Default }
    return $answer
}
function Test-Domain([string]$Value) {
    if ($Value.Length -gt 253 -or $Value -notmatch '^[a-zA-Z0-9.-]+$' -or
        -not $Value.Contains('.') -or $Value.EndsWith('.')) { return $false }
    foreach ($label in $Value.Split('.')) {
        if ($label.Length -lt 1 -or $label.Length -gt 63 -or $label.StartsWith('-') -or $label.EndsWith('-')) { return $false }
    }
    return $true
}
function Test-Email([string]$Value) { return $Value -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' }
function Read-Domain([string]$Label) {
    do {
        $answer = Read-Value $Label
        if (Test-Domain $answer) { return $answer }
        Write-Host 'Enter a full DNS name without https://, a port, or a path.'
    } while ($true)
}
function Read-Email([string]$Label, [string]$Default = '') {
    do {
        $answer = Read-Value $Label $Default
        if (Test-Email $answer) { return $answer }
        Write-Host 'Enter a valid email address.'
    } while ($true)
}
function Read-Password([string]$Label) {
    $secureValue = Read-Host $Label -AsSecureString
    $buffer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($buffer) }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($buffer)
        $secureValue.Dispose()
    }
}
function Protect-PrivatePath([string]$Path) {
    # Restrict NTFS access to this user, SYSTEM, and local administrators.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $inheritance = 'OICI'
    } else {
        $inheritance = ''
    }
    $descriptor = 'D:P'
    foreach ($sid in @($identity.Value, 'S-1-5-18', 'S-1-5-32-544')) { $descriptor += "(A;$inheritance;FA;;;$sid)" }
    # Change the DACL only; do not request ownership or audit privileges.
    $acl.SetSecurityDescriptorSddlForm($descriptor, [Security.AccessControl.AccessControlSections]::Access)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSObject.Methods.Name -contains 'SetAccessControl') {
        $item.SetAccessControl($acl)
    } else {
        [IO.FileSystemAclExtensions]::SetAccessControl($item, $acl)
    }
}
function Assert-RegularPath([string]$Path) {
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "$Path must not be a symbolic link or junction."
    }
}
function Set-DotenvValue([string]$Path, [string]$Key, [string]$Value) {
    # Compose interpolates dollars, while backslashes and quotes need escaping.
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace('$', '$$')
    $line = $Key + '="' + $escaped + '"'
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $pattern = '(?m)^' + [regex]::Escape($Key) + '=.*$'
    if ([regex]::IsMatch($text, $pattern)) {
        $text = [regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $line })
    } else { $text = $text.TrimEnd("`n") + "`n" + $line + "`n" }
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
}

function Test-DockerDaemon($Command) {
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command info 2>$null | Out-Null; return $LASTEXITCODE -eq 0 }
    finally { $ErrorActionPreference = $savedPreference }
}

$envTemporary = $null
$secretTemporary = $null
$lockCreated = $false
Push-Location $PSScriptRoot
try {
    foreach ($required in @('.env.example', 'docker-compose.yml', 'scripts/start-app.sh', 'scripts/check-deployment.py')) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw 'Installation files are missing. Download the complete repository.'
        }
    }
    $docker = Find-Docker
    if (-not $docker) {
        if ($SkipDependencies) { throw 'Docker is missing and dependency installation was disabled.' }
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw 'WinGet is unavailable. Install App Installer or Docker Desktop manually, then rerun.'
        }
        Write-Host 'Installing Docker Desktop with WinGet. Windows may request administrator access or a restart.'
        & winget install --id Docker.DockerDesktop --exact --source winget --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -notin @(0, 3010)) { throw 'Docker Desktop installation failed. Complete the installation and rerun.' }
        $docker = Find-Docker
        if (-not $docker) { throw 'Docker is not yet available. Finish installation, reopen PowerShell, and rerun.' }
        Write-Host 'Before starting Karduno, open Docker Desktop and complete its Linux-container/WSL setup.'
    }
    & $docker compose version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose is missing. Repair or update Docker Desktop, then rerun.' }
    if (-not $PrepareOnly -and -not (Test-DockerDaemon $docker)) {
        $desktop = @(
            "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
            "$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $desktop) { throw 'Start Docker with Linux containers and rerun. A WSL installation or Windows restart may be required.' }
        Write-Host 'Starting Docker Desktop and waiting for the Linux container backend...'
        Start-Process -FilePath $desktop -WindowStyle Hidden
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        while (-not (Test-DockerDaemon $docker)) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Docker is not ready. Complete Docker Desktop/WSL setup or reboot if requested, then rerun.' }
            Start-Sleep -Seconds 2
        }
    }

    New-Item -ItemType Directory -Path '.easy-install.lock' -ErrorAction Stop | Out-Null
    $lockCreated = $true
    Write-Host "`nKarduno Self-Hosted - Easy Install`n"
    $newConfig = $false
    if (-not (Test-Path -LiteralPath '.env')) {
        if ($NonInteractive) { throw 'No .env found. Run interactively first, or copy .env.example to .env and fill it in.' }
        Write-Host 'Both domains must point to this server. TCP ports 80 and 443 must be available.'
        $portal = Read-Domain 'Customer portal domain'
        do {
            $admin = Read-Domain 'Administration domain'
            if ($portal -ieq $admin) { Write-Host 'Portal and administration require different domains.' }
        } while ($portal -ieq $admin)
        $adminEmail = Read-Email 'Initial administrator email'
        do {
            $adminPassword = Read-Password 'Administrator password (at least 12 characters)'
            if ($adminPassword.Length -lt 12) { Write-Host 'The password is too short.'; continue }
            $confirmation = Read-Password 'Confirm password'
            if ($adminPassword -cne $confirmation) { Write-Host 'The passwords do not match.' }
        } while ($adminPassword.Length -lt 12 -or $adminPassword -cne $confirmation)
        $acmeEmail = Read-Email 'Contact email for HTTPS certificates' $adminEmail
        $envTemporary = Join-Path $PSScriptRoot ('.env.tmp.' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath '.env.example' -Destination $envTemporary
        Protect-PrivatePath $envTemporary
        $settings = [ordered]@{
            PORTAL_DOMAIN = $portal; ADMIN_DOMAIN = $admin; ACME_EMAIL = $acmeEmail
            INITIAL_ADMIN_EMAIL = $adminEmail; INITIAL_ADMIN_PASSWORD = $adminPassword
        }
        foreach ($entry in $settings.GetEnumerator()) { Set-DotenvValue $envTemporary $entry.Key $entry.Value }
        Move-Item -LiteralPath $envTemporary -Destination '.env'
        $envTemporary = $null
        $newConfig = $true
        Remove-Variable adminPassword, confirmation, settings
        Write-Host '.env has been created.'
    } else {
        Assert-RegularPath '.env'
        if (-not (Test-Path -LiteralPath '.env' -PathType Leaf)) { throw '.env must be a regular file.' }
        Write-Host 'Keeping the existing .env.'
    }
    Protect-PrivatePath (Join-Path $PSScriptRoot '.env')
    if ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '.env')) -match '(?m)^\s*(?:export\s+)?(?:POSTGRES_PASSWORD|JWT_SECRET)\s*=') {
        throw 'Legacy secrets found in .env. Preserve the existing values in secrets/postgres_password and secrets/jwt_secret first, then remove the old variables from .env.'
    }
    $json = & $docker compose config --format json
    if ($LASTEXITCODE -ne 0) { throw 'The .env is incomplete or invalid.' }
    $configuration = ($json -join "`n") | ConvertFrom-Json
    $app = $configuration.services.api.environment
    $proxy = $configuration.services.caddy.environment
    $portal = [string]$proxy.PORTAL_DOMAIN; $admin = [string]$proxy.ADMIN_DOMAIN
    if (-not (Test-Domain $portal) -or -not (Test-Domain $admin)) { throw 'Enter full DNS names without a protocol, port, or path.' }
    if ($portal -ieq $admin) { throw 'Portal and administration require different domains.' }
    if ($portal -like '*.example.com' -or $admin -like '*.example.com') { throw 'Replace the example.com placeholders with your own domains.' }
    if (-not (Test-Email ([string]$proxy.ACME_EMAIL))) { throw 'ACME_EMAIL is not a valid email address.' }
    $project = [string]$configuration.name

    $daemonAvailable = Test-DockerDaemon $docker
    $existingDatabase = ''
    if ($daemonAvailable) {
        $existingDatabase = & $docker volume ls --filter "label=com.docker.compose.project=$project" --filter 'label=com.docker.compose.volume=postgres_data' --format '{{.Name}}'
        if ($LASTEXITCODE -ne 0) { throw 'Could not check existing database volumes.' }
    } elseif (-not $newConfig -and (-not (Test-Path 'secrets/postgres_password') -or -not (Test-Path 'secrets/jwt_secret'))) {
        throw 'Docker is unavailable and an existing .env has missing secrets. Start Docker to check for an existing database first.'
    } else { Write-Host 'Docker is not running or is not accessible. Preparing files only.' }
    # Compose's serialized config escapes dollar signs for round-tripping.
    $bootstrapPassword = ([string]$app.INITIAL_ADMIN_PASSWORD).Replace('$$', '$')
    if (-not $existingDatabase -and (-not (Test-Email ([string]$app.INITIAL_ADMIN_EMAIL)) -or $bootstrapPassword.Length -lt 12)) {
        throw 'Before the first start, set INITIAL_ADMIN_EMAIL and an administrator password with at least 12 characters.'
    }
    Remove-Variable bootstrapPassword
    if (Test-Path -LiteralPath 'secrets') { Assert-RegularPath 'secrets' }
    if ($existingDatabase -and (-not (Test-Path 'secrets/postgres_password') -or -not (Test-Path 'secrets/jwt_secret'))) {
        throw 'An existing database was found but secret files are missing. Restore the original values from your backup.'
    }
    New-Item -ItemType Directory -Path 'secrets' -Force | Out-Null
    Protect-PrivatePath (Join-Path $PSScriptRoot 'secrets')
    foreach ($secret in @('postgres_password', 'jwt_secret')) {
        $path = Join-Path $PSScriptRoot "secrets/$secret"
        if (Test-Path -LiteralPath $path) {
            Assert-RegularPath $path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) {
                throw "$path is not a valid secret file. Restore the original value."
            }
            if ($secret -eq 'jwt_secret' -and [IO.File]::ReadAllText($path).TrimEnd("`r", "`n").Length -lt 32) { throw 'The JWT secret must contain at least 32 characters.' }
            Write-Host "Keeping secrets/$secret unchanged."
        } else {
            $bytes = New-Object byte[] 32
            $random = [Security.Cryptography.RandomNumberGenerator]::Create()
            try { $random.GetBytes($bytes) } finally { $random.Dispose() }
            $value = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
            $secretTemporary = Join-Path $PSScriptRoot ('secrets/.' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($secretTemporary, $value, (New-Object Text.UTF8Encoding($false)))
            Protect-PrivatePath $secretTemporary
            Move-Item -LiteralPath $secretTemporary -Destination $path
            $secretTemporary = $null
            Write-Host "Created secrets/$secret."
        }
        Protect-PrivatePath $path
    }
    Write-Host 'Email delivery is configured in the administration interface.'
    Write-Host "`nInclude .env and secrets/ in your encrypted backup."
    if ($PrepareOnly) {
        Write-Host 'Configuration is ready. No application containers have been started.'
        Write-Host 'To check domains and start, rerun without -PrepareOnly.'
        return
    }
    $runningServices = @(& $docker compose ps --status running --services)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the existing installation.' }
    Write-Host 'Preparing domain checks (downloads the API image if needed)...'
    if ($runningServices -contains 'caddy') {
        Write-Host 'Checking the existing installation through both domains...'
        & $docker compose run --rm --no-deps -T setup-check /venv/bin/python /run/karduno/check-deployment.py verify --timeout 0
        if ($LASTEXITCODE -ne 0) { throw 'The existing domain routes failed verification. Existing services were left running.' }
    } else {
        Write-Host 'Checking DNS and routing to this host on TCP ports 80 and 443...'
        & $docker compose run --rm --no-deps -T --service-ports setup-check
        if ($LASTEXITCODE -ne 0) { throw 'Domain/port checks failed. Check DNS, TCP 80/443, firewall rules, and conflicting web servers before retrying.' }
    }
    Write-Host 'Downloading application and infrastructure images...'
    & $docker compose pull postgres redis api worker admin portal caddy
    if ($LASTEXITCODE -ne 0) { throw 'Image download failed. Check registry availability, network access, and supported architecture. Nothing has been stopped.' }
    if ($runningServices -contains 'worker') {
        & $docker compose stop worker
        if ($LASTEXITCODE -ne 0) { throw 'Could not pause the existing worker before database migrations.' }
    }
    & $docker compose up -d --wait --wait-timeout 300 postgres redis api worker admin portal caddy
    if ($LASTEXITCODE -ne 0) { throw 'Startup failed. Check docker compose ps and docker compose logs --tail 100. Existing data and secrets are preserved.' }
    & $docker compose run --rm --no-deps -T setup-check /venv/bin/python /run/karduno/check-deployment.py verify
    if ($LASTEXITCODE -ne 0) { throw 'Containers started, but public-domain HTTPS/readiness checks failed. Check Caddy logs, DNS, and firewall settings. The stack was left running for diagnosis.' }
    Write-Host 'Karduno is running and domain checks passed from this server.'
    Write-Host "Portal: https://$portal`nAdministration: https://$admin"
    Write-Host 'Also test browser sign-in and email delivery, and check access from another network.'
} finally {
    if ($envTemporary -and (Test-Path -LiteralPath $envTemporary)) { Remove-Item -LiteralPath $envTemporary }
    if ($secretTemporary -and (Test-Path -LiteralPath $secretTemporary)) { Remove-Item -LiteralPath $secretTemporary }
    if ($lockCreated) { [IO.Directory]::Delete((Join-Path $PSScriptRoot '.easy-install.lock')) }
    Pop-Location
}
