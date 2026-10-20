[CmdletBinding()]
param(
    [string]$CecilDll
)

$ErrorActionPreference = 'Stop'

# 构建常量
$CecilVersion = '0.11.6'
$CecilNupkgSha256 = 'D2A23832AAA948BA9A01ACC42B5726E34C5F995958F1B30D45C0E7C70B3A72D5'
$CecilDllSha256 = 'C41BDB9FFD3C5F6E17D2382C1012D73703E035E3F1100245FDD4E08C8DC6EB5B'
$CecilUrls = @(
    ('https://api.nuget.org/v3-flatcontainer/mono.cecil/{0}/mono.cecil.{0}.nupkg' -f $CecilVersion),
    ('https://www.nuget.org/api/v2/package/Mono.Cecil/{0}' -f $CecilVersion)
)
$Net48Framework = 'net48'
$StandardExeName = 'PCL.DL.RestorePatch.GUI.exe'
$BundledExeName = 'PCL.DL.RestorePatch.GUI.WithCecil.exe'
$StandardConfiguration = 'Release'
$OfflineConfiguration = 'ReleaseWithCecil'

$projectPath = Join-Path $PSScriptRoot 'PCL.DL.RestorePatch.GUI\PCL.DL.RestorePatch.GUI.csproj'
$projectDir = Split-Path -Parent $projectPath

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Compress-Deflate {
    param([string]$SourcePath, [string]$DestinationPath)

    $source = [System.IO.File]::OpenRead($SourcePath)
    try {
        $destination = [System.IO.File]::Create($DestinationPath)
        try {
            $deflate = New-Object System.IO.Compression.DeflateStream($destination, [System.IO.Compression.CompressionLevel]::Optimal, $true)
            try {
                $source.CopyTo($deflate)
            } finally {
                $deflate.Dispose()
            }
        } finally {
            $destination.Dispose()
        }
    } finally {
        $source.Dispose()
    }
}

function Resolve-CecilDll {
    param([string]$Path, [string]$WorkDir)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
        if ((Get-FileSha256 $resolved) -ne $CecilDllSha256) {
            throw ('指定的 Mono.Cecil.dll SHA256 不匹配：' + $resolved)
        }
        Write-Host ('[*] 使用指定的 Mono.Cecil: ' + $resolved)
        return $resolved
    }

    $nupkgPath = Join-Path $WorkDir 'mono.cecil.nupkg'
    $dllPath = Join-Path $WorkDir 'Mono.Cecil.dll'
    $downloaded = $false
    $lastError = ''

    foreach ($url in $CecilUrls) {
        $webClient = New-Object Net.WebClient
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Write-Host ('[*] 下载 ' + $url)
            $webClient.DownloadFile($url, $nupkgPath)
            if ((Get-FileSha256 $nupkgPath) -eq $CecilNupkgSha256) {
                $downloaded = $true
                break
            }
            $lastError = 'SHA256 不匹配'
            Remove-Item -LiteralPath $nupkgPath -Force -ErrorAction SilentlyContinue
        } catch {
            $lastError = $_.Exception.Message
        } finally {
            $webClient.Dispose()
        }
    }
    if (-not $downloaded) {
        throw ('Mono.Cecil 下载失败：' + $lastError)
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($nupkgPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'lib/net40/Mono.Cecil.dll' } | Select-Object -First 1
        if ($null -eq $entry) {
            throw 'Mono.Cecil 包结构异常：缺少 lib/net40/Mono.Cecil.dll'
        }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dllPath, $true)
    } finally {
        $zip.Dispose()
    }

    if ((Get-FileSha256 $dllPath) -ne $CecilDllSha256) {
        throw 'Mono.Cecil.dll 校验不通过'
    }

    return $dllPath
}

function Invoke-GuiBuild {
    param(
        [string]$BuildConfiguration,
        [string]$Framework,
        [string]$CecilCompressedPath
    )

    $arguments = @(
        'publish',
        $projectPath,
        '-c', $BuildConfiguration,
        '-f', $Framework,
        '--nologo',
        '-v:minimal'
    )
    if (-not [string]::IsNullOrWhiteSpace($CecilCompressedPath)) {
        $arguments += ('-p:CecilCompressedPath=' + $CecilCompressedPath)
    }

    & $script:dotnet @arguments
    if ($LASTEXITCODE -ne 0) {
        throw ('构建失败：' + $BuildConfiguration)
    }
}

$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
if ($null -eq $dotnetCommand) {
    throw '没有找到 dotnet。请安装 .NET SDK 10+，或把 dotnet 加入 PATH。'
}
$script:dotnet = $dotnetCommand.Source
Write-Host ('[*] 编译工具: ' + $script:dotnet)

Write-Host ('[*] 构建标准版（' + $StandardConfiguration + '/' + $Net48Framework + '）')
Invoke-GuiBuild -BuildConfiguration $StandardConfiguration -Framework $Net48Framework

$workDir = Join-Path $env:TEMP ('pcl_gui_build_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
try {
    $cecilDll = Resolve-CecilDll -Path $CecilDll -WorkDir $workDir
    $cecilCompressed = Join-Path $workDir 'Mono.Cecil.dll.deflate'
    Compress-Deflate -SourcePath $cecilDll -DestinationPath $cecilCompressed
    Write-Host ('[*] Mono.Cecil: ' + (Get-Item -LiteralPath $cecilDll).Length + ' -> ' + (Get-Item -LiteralPath $cecilCompressed).Length + ' 字节')

    Write-Host ('[*] 构建离线版（' + $OfflineConfiguration + '/' + $Net48Framework + '）')
    Invoke-GuiBuild -BuildConfiguration $OfflineConfiguration -Framework $Net48Framework -CecilCompressedPath $cecilCompressed

    $standardExe = Join-Path $projectDir ('bin\' + $StandardConfiguration + '\' + $Net48Framework + '\publish\' + $StandardExeName)
    $offlineExe = Join-Path $projectDir ('bin\' + $OfflineConfiguration + '\' + $Net48Framework + '\publish\' + $BundledExeName)
    if (-not (Test-Path -LiteralPath $standardExe -PathType Leaf)) {
        throw ('没有找到标准版产物：' + $standardExe)
    }
    if (-not (Test-Path -LiteralPath $offlineExe -PathType Leaf)) {
        throw ('没有找到离线版产物：' + $offlineExe)
    }

    Write-Host ''
    Write-Host '[+] 构建完成'
    foreach ($file in @($standardExe, $offlineExe)) {
        $item = Get-Item -LiteralPath $file
        Write-Host ('    ' + $item.FullName)
        Write-Host ('      大小: ' + $item.Length + ' 字节')
        Write-Host ('      SHA256: ' + (Get-FileSha256 $file))
    }
} finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}
