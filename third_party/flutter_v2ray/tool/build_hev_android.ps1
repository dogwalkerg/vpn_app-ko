param(
    [string]$NdkPath = "$env:LOCALAPPDATA\Android\Sdk\ndk\28.2.13676358"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$version = '2.15.0'
$requiredNdkVersion = '28.2.13676358'
$expectedSourceSha256 = '8ebee22282b8f952ebae330c8d9957a5fd1e15fb1aa67e059b8334b2b09c17f6'
$expectedBinarySha256 = @{
    'arm64-v8a'   = 'd43d6e8b21d326897184a92740c8a201395b8ac2553fb737d3c444c2c1312369'
    'armeabi-v7a' = '386e7cd4876c8a8b53d7e50250b31295306ba548129fdae85b54c269a610a58f'
    'x86'         = 'bb2f84c0101c60548ae3946508dfca52d6d53c0a66b9fbaf44d117788ec4ff97'
    'x86_64'      = '453ab8ddcb84d4c01fae08f42da367920eef5114f1a18451e56096a3e376a17d'
}
$url = "https://github.com/heiher/hev-socks5-tunnel/releases/download/$version/hev-socks5-tunnel-$version.tar.xz"
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$workName = "hev-socks5-tunnel-$version-build-$([Guid]::NewGuid().ToString('N'))"
$work = [IO.Path]::GetFullPath((Join-Path $tempRoot $workName))
$archive = Join-Path $work "hev-socks5-tunnel-$version.tar.xz"
$source = Join-Path $work "hev-socks5-tunnel-$version"
$obj = Join-Path $work 'obj'
$libs = Join-Path $work 'libs'
$pluginRoot = Split-Path -Parent $PSScriptRoot
$destination = Join-Path $pluginRoot 'android\src\main\jniLibs'
$ndkBuild = Join-Path $NdkPath 'ndk-build.cmd'
$ndkProperties = Join-Path $NdkPath 'source.properties'

function Assert-SafeWorkPath {
    $resolved = [IO.Path]::GetFullPath($work)
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -ne $workName -or
        -not $workName.StartsWith("hev-socks5-tunnel-$version-build-")) {
        throw "Unsafe temporary work path: $resolved"
    }
}

Assert-SafeWorkPath
$installedNdkVersion = (Get-Content $ndkProperties | Where-Object {
    $_ -match '^Pkg.Revision\s*='
} | Select-Object -First 1).Split('=')[1].Trim()
if ($installedNdkVersion -ne $requiredNdkVersion) {
    throw "Expected Android NDK $requiredNdkVersion, found $installedNdkVersion"
}

try {
    New-Item -ItemType Directory -Force $work | Out-Null
    Invoke-WebRequest -Headers @{
        'User-Agent' = 'Osca native dependency build'
    } -Uri $url -OutFile $archive
    $actualSourceSha256 = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSourceSha256 -ne $expectedSourceSha256) {
        throw "HEV source SHA256 mismatch: $actualSourceSha256"
    }

    tar -xf $archive -C $work
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to extract HEV source (exit code $LASTEXITCODE)"
    }
    & $ndkBuild "NDK_PROJECT_PATH=$source" "APP_BUILD_SCRIPT=$source\Android.mk" `
        "NDK_APPLICATION_MK=$source\Application.mk" "NDK_OUT=$obj" `
        "NDK_LIBS_OUT=$libs" -j ([Environment]::ProcessorCount)
    if ($LASTEXITCODE -ne 0) {
        throw "ndk-build failed with exit code $LASTEXITCODE"
    }

    foreach ($abi in $expectedBinarySha256.Keys) {
        $binary = Join-Path $libs "$abi\libhev-socks5-tunnel.so"
        $actual = (Get-FileHash $binary -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expectedBinarySha256[$abi]) {
            throw "HEV $abi SHA256 mismatch: $actual"
        }
    }
    foreach ($abi in $expectedBinarySha256.Keys) {
        $binary = Join-Path $libs "$abi\libhev-socks5-tunnel.so"
        $abiDestination = Join-Path $destination $abi
        New-Item -ItemType Directory -Force $abiDestination | Out-Null
        Copy-Item -LiteralPath $binary -Destination $abiDestination -Force
        Get-FileHash $binary -Algorithm SHA256
    }
} finally {
    Assert-SafeWorkPath
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
