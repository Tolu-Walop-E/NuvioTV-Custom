#Requires -Version 5.1
<#
.SYNOPSIS
    Build the NuvioTV Tolu fork FullDebug APK for local Windows use.

.PARAMETER Fast
    Use Gradle daemon, build cache, and parallel workers.

.PARAMETER Install
    After a successful build, install/update the APK if exactly one ADB device is connected.

.PARAMETER Clean
    Run Gradle clean before building. Incremental builds stay the default.

.PARAMETER Release
    Build assembleFullRelease with the permanent Tolu keystore outside the repo.
    Debug builds keep using the Android debug keystore.
#>
[CmdletBinding()]
param(
    [switch]$Fast,
    [switch]$Install,
    [switch]$Clean,
    [switch]$Release
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = $PSScriptRoot
$script:LastExternalExit = 0
$RequiredNdk = '27.0.12077973'
$RequiredCompileSdk = 'android-36'
$RequiredPackageId = 'com.nuvio.tv.tolu'
$ReleaseKeystore = Join-Path $env:USERPROFILE '.android\nuvio-tolu-release.jks'
$ReleaseAlias = 'nuvio-tolu'
$ReleaseEnvFile = Join-Path $env:USERPROFILE '.android\nuvio-tolu-release.env'
$BackendValues = [ordered]@{
    'NUVIO_SUPABASE_URL'     = 'https://api.nuvio.tv'
    'NUVIO_SUPABASE_ANON_KEY' = 'sb_publishable_1Clq8rlTVACkdcZuqr6_AD__xUUC_EN'
    'TV_LOGIN_WEB_BASE_URL'  = 'https://nuvio.tv/tv-login'
    'AVATAR_PUBLIC_BASE_URL' = 'https://api.nuvio.tv/storage/v1/object/public/avatars'
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Fail {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    # Windows PowerShell treats native stderr as a terminating error when
    # $ErrorActionPreference is Stop. Java and Gradle write version/progress
    # text to stderr, so relax that only for the child process.
    # Exit code is stored in $script:LastExternalExit. Do not return it:
    # a function's stdout would otherwise become the "return value".
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @ArgumentList
        if ($null -eq $LASTEXITCODE) {
            $script:LastExternalExit = 0
        } else {
            $script:LastExternalExit = $LASTEXITCODE
        }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Get-ExternalText {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return ((& $FilePath @ArgumentList 2>&1 | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Get-JavaMajorVersion {
    param([string]$JavaExe)
    $output = Get-ExternalText -FilePath $JavaExe -ArgumentList @('-version')
    if ($output -match 'version "(\d+)') {
        return [int]$Matches[1]
    }
    return $null
}

function Resolve-JavaHome {
    $candidates = @()
    if ($env:JAVA_HOME) {
        $candidates += $env:JAVA_HOME
    }
    $candidates += @(
        'C:\Program Files\Microsoft\jdk-17.0.19.10-hotspot',
        'C:\Program Files\Eclipse Adoptium\jdk-17',
        'C:\Program Files\Java\jdk-17',
        'C:\Program Files\Android\Android Studio\jbr'
    )

    foreach ($candidateHome in $candidates) {
        if (-not $candidateHome) { continue }
        $javaExe = Join-Path $candidateHome 'bin\java.exe'
        if (Test-Path $javaExe) {
            $major = Get-JavaMajorVersion $javaExe
            if ($major -eq 17) {
                return (Resolve-Path $candidateHome).Path
            }
        }
    }

    $javaOnPath = Get-Command java -ErrorAction SilentlyContinue
    if ($javaOnPath) {
        $major = Get-JavaMajorVersion $javaOnPath.Source
        if ($major -eq 17) {
            $binDir = Split-Path -Parent $javaOnPath.Source
            return (Resolve-Path (Split-Path -Parent $binDir)).Path
        }
        Fail "Java $($major) is on PATH. This project requires JDK 17. Set JAVA_HOME to a JDK 17 install."
    }

    Fail "JDK 17 not found. Install Microsoft OpenJDK 17 or Android Studio's JBR and set JAVA_HOME."
}

function Resolve-AndroidSdk {
    $candidates = @(
        $env:ANDROID_HOME,
        $env:ANDROID_SDK_ROOT,
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
        (Join-Path $env:USERPROFILE 'AppData\Local\Android\Sdk')
    ) | Where-Object { $_ }

    foreach ($sdk in $candidates) {
        if (Test-Path (Join-Path $sdk 'platforms')) {
            return (Resolve-Path $sdk).Path
        }
    }

    Fail "Android SDK not found. Expected %LOCALAPPDATA%\Android\Sdk or ANDROID_HOME."
}

function ConvertTo-PropertiesPath {
    param([string]$Path)
    return ($Path -replace '\\', '/')
}

function Read-PropertiesFile {
    param([string]$Path)
    $map = [ordered]@{}
    if (-not (Test-Path $Path)) {
        return $map
    }

    foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') {
            continue
        }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) {
            continue
        }
        $key = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx + 1)
        $map[$key] = $value
    }
    return $map
}

function Write-PropertiesFile {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Properties
    )

    $lines = @(
        '## Generated by build-local.ps1. Do not commit this file.',
        '# Machine-local Android SDK and Nuvio backend config.'
    )
    foreach ($key in $Properties.Keys) {
        $lines += "$key=$($Properties[$key])"
    }
    $desired = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    if (Test-Path $Path) {
        $current = Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue
        if ($current -eq $desired) {
            return
        }
    }

    $written = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Set-Content -Path $Path -Value $lines -Encoding ASCII
            $written = $true
            break
        } catch {
            Start-Sleep -Milliseconds (200 * $attempt)
        }
    }
    if (-not $written) {
        foreach ($key in @('sdk.dir') + [string[]]$BackendValues.Keys) {
            if (-not $Properties[$key]) {
                Fail "Could not update local.properties and $key is missing."
            }
        }
        Write-Host "local.properties is locked by another process; existing required keys were kept."
    }
}

function Update-LocalProperties {
    param(
        [string]$SdkDir,
        [string]$Path
    )

    $props = Read-PropertiesFile -Path $Path
    $props['sdk.dir'] = ConvertTo-PropertiesPath $SdkDir
    foreach ($key in $BackendValues.Keys) {
        $props[$key] = $BackendValues[$key]
    }
    Write-PropertiesFile -Path $Path -Properties $props

    foreach ($key in @('sdk.dir') + [string[]]$BackendValues.Keys) {
        if (-not $props[$key]) {
            Fail "local.properties is missing $key"
        }
    }

    Write-Host "local.properties ready (sdk.dir + Nuvio backend keys)."
}

function Test-SdkComponent {
    param(
        [string]$SdkDir,
        [string]$RelativePath,
        [string]$Label
    )
    $full = Join-Path $SdkDir $RelativePath
    if (-not (Test-Path $full)) {
        Fail "$Label not found at $full"
    }
    Write-Host "OK  $Label"
    return $full
}

function Get-SdkManager {
    param([string]$SdkDir)
    $candidates = @(
        (Join-Path $SdkDir 'cmdline-tools\latest\bin\sdkmanager.bat'),
        (Join-Path $SdkDir 'cmdline-tools\bin\sdkmanager.bat')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    return $null
}

function Ensure-RequiredNdk {
    param([string]$SdkDir)

    $ndkPath = Join-Path $SdkDir "ndk\$RequiredNdk"
    if (Test-Path $ndkPath) {
        Write-Host "OK  NDK $RequiredNdk"
        return
    }

    $sdkmanager = Get-SdkManager -SdkDir $SdkDir
    if (-not $sdkmanager) {
        Fail "NDK $RequiredNdk is not installed and sdkmanager was not found. In Android Studio: SDK Manager > SDK Tools > NDK (Side by side) $RequiredNdk."
    }

    Write-Host "Installing NDK $RequiredNdk via sdkmanager..."
    Invoke-External -FilePath $sdkmanager -ArgumentList @("--sdk_root=$SdkDir", "ndk;$RequiredNdk")
    if ($script:LastExternalExit -ne 0 -or -not (Test-Path $ndkPath)) {
        Fail "Failed to install NDK $RequiredNdk"
    }
    Write-Host "OK  NDK $RequiredNdk"
}

function Find-UniversalApk {
    param([string]$BuildType)

    $apkDir = Join-Path $RepoRoot "app\build\outputs\apk\full\$BuildType"
    if (-not (Test-Path $apkDir)) {
        Fail "Gradle finished but $apkDir does not exist."
    }

    $apks = @(
        Get-ChildItem -Path $apkDir -Filter '*.apk' -Recurse -File |
            Where-Object { $_.Length -gt 0 } |
            Sort-Object LastWriteTime -Descending
    )

    if ($apks.Count -eq 0) {
        Fail "No APK files found under $apkDir"
    }

    $preferred = $apks | Where-Object { $_.Name -match 'universal' -and $_.Name -match [regex]::Escape($BuildType) } | Select-Object -First 1
    if (-not $preferred) {
        $preferred = $apks | Where-Object { $_.Name -match 'universal' } | Select-Object -First 1
    }
    if (-not $preferred) {
        Fail "Found APKs but none look like a universal $BuildType APK: $($apks.Name -join ', ')"
    }

    return $preferred
}

function Read-DotEnvFile {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path $Path)) {
        return $map
    }
    foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') {
            continue
        }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) {
            continue
        }
        $map[$line.Substring(0, $idx).Trim()] = $line.Substring($idx + 1)
    }
    return $map
}

function Apply-ReleaseSigning {
    if (-not (Test-Path $ReleaseKeystore)) {
        Fail "Permanent release keystore not found at $ReleaseKeystore. It must live outside the repo."
    }

    $fileEnv = Read-DotEnvFile -Path $ReleaseEnvFile
    $keyPassword = $env:NUVIO_RELEASE_KEY_PASSWORD
    if (-not $keyPassword) {
        $keyPassword = $fileEnv['NUVIO_RELEASE_KEY_PASSWORD']
    }
    $storePassword = $env:NUVIO_RELEASE_STORE_PASSWORD
    if (-not $storePassword) {
        $storePassword = $fileEnv['NUVIO_RELEASE_STORE_PASSWORD']
    }
    if (-not $keyPassword -or -not $storePassword) {
        Fail "Release passwords missing. Set NUVIO_RELEASE_KEY_PASSWORD and NUVIO_RELEASE_STORE_PASSWORD, or create $ReleaseEnvFile outside the repo."
    }

    $env:NUVIO_RELEASE_STORE_FILE = $ReleaseKeystore
    $env:NUVIO_RELEASE_KEY_ALIAS = $ReleaseAlias
    $env:NUVIO_RELEASE_KEY_PASSWORD = $keyPassword
    $env:NUVIO_RELEASE_STORE_PASSWORD = $storePassword

    $localPath = Join-Path $RepoRoot 'local.properties'
    $props = Read-PropertiesFile -Path $localPath
    $props['sdk.dir'] = ConvertTo-PropertiesPath (Resolve-AndroidSdk)
    foreach ($key in $BackendValues.Keys) {
        $props[$key] = $BackendValues[$key]
    }
    $props['NUVIO_RELEASE_STORE_FILE'] = ConvertTo-PropertiesPath $ReleaseKeystore
    $props['NUVIO_RELEASE_KEY_ALIAS'] = $ReleaseAlias
    $props['NUVIO_RELEASE_KEY_PASSWORD'] = $keyPassword
    $props['NUVIO_RELEASE_STORE_PASSWORD'] = $storePassword
    Write-PropertiesFile -Path $localPath -Properties $props

    Write-Host "Release signing: $ReleaseKeystore (alias $ReleaseAlias)"
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) {
        return ('{0:N2} GB' -f ($Bytes / 1GB))
    }
    return ('{0:N1} MB' -f ($Bytes / 1MB))
}

function Get-ConnectedAdbDevices {
    param([string]$AdbExe)
    $output = Get-ExternalText -FilePath $AdbExe -ArgumentList @('devices')
    $output = $output -split [Environment]::NewLine
    $devices = @()
    foreach ($line in $output) {
        if ($line -match '^\s*List of devices' -or $line -match '^\s*$') {
            continue
        }
        if ($line -match '^(\S+)\s+device\s*$') {
            $devices += $Matches[1]
        }
    }
    return $devices
}

Write-Step "Verify Java"
$javaHome = Resolve-JavaHome
$env:JAVA_HOME = $javaHome
$env:Path = "$(Join-Path $javaHome 'bin');$env:Path"
Write-Host "JAVA_HOME=$javaHome"
Invoke-External -FilePath (Join-Path $javaHome 'bin\java.exe') -ArgumentList @('-version')

Write-Step "Verify Android SDK"
$androidSdk = Resolve-AndroidSdk
$env:ANDROID_HOME = $androidSdk
$env:ANDROID_SDK_ROOT = $androidSdk
Write-Host "ANDROID_HOME=$androidSdk"
Test-SdkComponent -SdkDir $androidSdk -RelativePath "platforms\$RequiredCompileSdk" -Label "compileSdk 36 ($RequiredCompileSdk)" | Out-Null
Test-SdkComponent -SdkDir $androidSdk -RelativePath 'cmake' -Label 'CMake' | Out-Null
Ensure-RequiredNdk -SdkDir $androidSdk

Write-Step "Write local.properties"
Update-LocalProperties -SdkDir $androidSdk -Path (Join-Path $RepoRoot 'local.properties')
if ($Release) {
    Write-Step "Release signing"
    Apply-ReleaseSigning
}

$wrapper = Join-Path $RepoRoot 'gradlew.bat'
if (-not (Test-Path $wrapper)) {
    Fail "Gradle wrapper missing: $wrapper"
}

Write-Step "Gradle wrapper"
Invoke-External -FilePath $wrapper -ArgumentList @('--version')
if ($script:LastExternalExit -ne 0) {
    Fail "Gradle wrapper failed"
}

$gradleArgs = @()
if ($Clean) {
    Write-Step "Clean"
    Invoke-External -FilePath $wrapper -ArgumentList @('clean', '--stacktrace')
    if ($script:LastExternalExit -ne 0) {
        Fail "Gradle clean failed"
    }
}

$buildType = 'debug'
$assembleTask = ':app:assembleFullDebug'
$latestName = 'NuvioTV-Tolu-latest.apk'
$stampPrefix = 'NuvioTV-Tolu'
$signingNote = 'Android debug keystore %USERPROFILE%\.android\debug.keystore (persistent debug cert; cannot OTA over a release-signed install)'
if ($Release) {
    $buildType = 'release'
    $assembleTask = ':app:assembleFullRelease'
    $latestName = 'NuvioTV-Tolu-release-latest.apk'
    $stampPrefix = 'NuvioTV-Tolu-release'
    $signingNote = "Permanent Tolu release keystore $ReleaseKeystore (alias $ReleaseAlias). This is the OTA certificate."
}

$gradleArgs += $assembleTask
if ($Fast) {
    $gradleArgs += @('--daemon', '--build-cache', '--parallel')
}
$gradleArgs += '--stacktrace'

Write-Step "Build $($gradleArgs -join ' ')"
$buildStarted = Get-Date
Invoke-External -FilePath $wrapper -ArgumentList $gradleArgs
if ($script:LastExternalExit -ne 0) {
    Fail "Gradle $assembleTask failed"
}
$buildDuration = (Get-Date) - $buildStarted

Write-Step "Collect APK"
$sourceApk = Find-UniversalApk -BuildType $buildType
$buildsDir = Join-Path $RepoRoot 'builds'
New-Item -ItemType Directory -Force -Path $buildsDir | Out-Null

$stamp = Get-Date -Format 'yyyy-MM-dd-HHmm'
$stampedName = "$stampPrefix-$stamp.apk"
$latestPath = Join-Path $buildsDir $latestName
$stampedPath = Join-Path $buildsDir $stampedName

Copy-Item -Path $sourceApk.FullName -Destination $latestPath -Force
Copy-Item -Path $sourceApk.FullName -Destination $stampedPath -Force

$hash = (Get-FileHash -Algorithm SHA256 -Path $latestPath).Hash
$size = Format-FileSize $sourceApk.Length

Write-Host ""
Write-Host "BUILD SUCCESS" -ForegroundColor Green
Write-Host "APK: $((Resolve-Path $latestPath).Path)"
Write-Host "Copy: $((Resolve-Path $stampedPath).Path)"
Write-Host "Source: $($sourceApk.FullName)"
Write-Host "Package ID: $RequiredPackageId"
Write-Host "Size: $size"
Write-Host "SHA256: $hash"
Write-Host ("Duration: {0:mm\:ss}" -f $buildDuration)
Write-Host "Signing: $signingNote"

if ($Install) {
    Write-Step "ADB install"
    $adb = Join-Path $androidSdk 'platform-tools\adb.exe'
    if (-not (Test-Path $adb)) {
        Write-Host "adb not found at $adb. Build succeeded; install skipped."
        Write-Host "For a Shield on the same LAN: adb connect <shield-ip>:5555"
        exit 0
    }

    Invoke-External -FilePath $adb -ArgumentList @('devices')
    $devices = @(Get-ConnectedAdbDevices -AdbExe $adb)
    if ($devices.Count -eq 1) {
        Write-Host "Installing/updating on $($devices[0]) (adb install -r, no uninstall)..."
        Invoke-External -FilePath $adb -ArgumentList @('install', '-r', $latestPath)
        if ($script:LastExternalExit -ne 0) {
            Fail "adb install failed. The APK is still at $latestPath"
        }
        Write-Host "Installed $RequiredPackageId on $($devices[0])"
    }
    elseif ($devices.Count -eq 0) {
        Write-Host "No ADB device connected. Build succeeded; install skipped."
        Write-Host "Nvidia Shield over the network:"
        Write-Host "  1. Settings > Device Preferences > About > Build (click 7 times) to enable Developer options"
        Write-Host "  2. Developer options > Network debugging / ADB over network"
        Write-Host "  3. adb connect <shield-ip>:5555"
        Write-Host "  4. .\build-local.ps1 -Install"
    }
    else {
        Write-Host "Multiple ADB devices connected ($($devices -join ', ')). Build succeeded; install skipped."
        Write-Host "Install manually with: `"$adb`" -s <serial> install -r `"$latestPath`""
    }
}
