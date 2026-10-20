<#
免责声明

1. 本脚本仅供个人学习、研究与技术交流使用，不得用于商业用途，也不得用于
   大规模分发、二次打包、售卖或任何形式的牟利行为。
2. 本脚本不是 PCL 官方产物，与 PCL 开发者无关。它只修改本机 PCL 副本的
   方法体；不包含、也不分发 PCL 的任何代码或二进制文件。
3. PCL 移除这些功能是开发者为遵守相关法律法规所做的决定。使用本脚本可能
   违反当地法律、法规或平台规则，请自行确认所在地区的相关规定，并承担
   全部后果；本脚本不构成任何形式的授权或担保。
4. 建议与 Agent 一起分析脚本、确认补丁范围和风险后再使用；不要在不了解
   改动内容的情况下运行来历不明的脚本。
5. 脚本按“现状”提供，不提供任何明示或暗示的担保。使用前请备份原始 exe；
   因使用本脚本造成的任何直接或间接损失，由使用者自行承担。
#>
<#
PCL 2.99.0.0 补丁：恢复下载页版本列表与整合包安装入口。

RestrictMcDownload 是编译期常量，发布版中相关分支已被常量折叠：Select Case
分发和选文件逻辑都不在二进制中，只能重写方法体。

补丁点：

  PCL.PageDownloadInstall.LoaderInit
      删除 "关闭下载" 的 LoaderTask 构造，替换为 ldsfld DlClientListLoader。

  PCL.ModModpack.ModpackInstall(string, string, string)
      保留原有解析代码，把限制 throw 替换为 switch 分发（源码 89~111 行；
      只恢复分发，不恢复每个分支的 Logger.Info）。

  PCL.ModModpack.ModpackInstall()
      重建 SelectFile -> FirstOrDefault -> RunInThread 流程（源码 10~26 行）。

  PCL.PageDownloadModify.LoadInstanceFinished
      CardMinecraft 的 Visibility 由 Collapsed 改为 Visible（源码 315 行）。

  PCL.PageDownloadResourceDetail.InitializeStackResourceVersions
      恢复整合包版本列表的 Install_Click 按钮（源码 275~279 行）。

输入 exe 需为 PCL 2.99.x；版本、方法布局、局部变量、安装器签名或入口结构
不符时在写盘前失败，不会产出半成品。

依赖 Mono.Cecil 0.11.6（NuGet，SHA256 固定），临时目录用完即删。

输出 Plain Craft Launcher 2 (dl-restore).exe，输入文件不改动。
#>

$ErrorActionPreference = 'Stop'

$PclDir     = $PSScriptRoot
$ExePath    = Join-Path $PclDir 'Plain Craft Launcher 2.exe'
$OutputPath = Join-Path $PclDir 'Plain Craft Launcher 2 (dl-restore).exe'
$TmpOutput  = $OutputPath + '.tmp'
$WorkDir    = Join-Path $env:TEMP ('pcl_dl_restore_' + [guid]::NewGuid().ToString('N'))

$CecilVersion     = '0.11.6'
$CecilNupkgSha256 = 'D2A23832AAA948BA9A01ACC42B5726E34C5F995958F1B30D45C0E7C70B3A72D5'
$CecilDllSha256   = 'C41BDB9FFD3C5F6E17D2382C1012D73703E035E3F1100245FDD4E08C8DC6EB5B'

function Stop-WithError {
    param([string]$Message)
    Write-Host ('[错误] ' + $Message) -ForegroundColor Red
    exit 1
}

function Write-Step { param([string]$Message) Write-Host ('[*] ' + $Message) }
function Write-Ok   { param([string]$Message) Write-Host ('[+] ' + $Message) -ForegroundColor Green }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { Stop-WithError ('校验失败：' + $Message) }
}

function Get-Sha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

# 下载并校验 Mono.Cecil，返回 DLL 路径
function Get-CecilLibrary {
    param([string]$WorkDir)

    $dllPath   = Join-Path $WorkDir 'Mono.Cecil.dll'
    $nupkgPath = Join-Path $WorkDir 'mono.cecil.nupkg'
    $urls = @(
        ('https://api.nuget.org/v3-flatcontainer/mono.cecil/{0}/mono.cecil.{0}.nupkg' -f $CecilVersion),
        ('https://www.nuget.org/api/v2/package/Mono.Cecil/{0}' -f $CecilVersion)
    )

    $downloaded = $false
    $lastError = ''
    foreach ($url in $urls) {
        $webClient = New-Object Net.WebClient
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $webClient.DownloadFile($url, $nupkgPath)
            if ((Get-Sha256 $nupkgPath) -eq $CecilNupkgSha256) { $downloaded = $true; break }
            $lastError = 'SHA256 不匹配'
        } catch {
            $lastError = $_.Exception.Message
        } finally {
            $webClient.Dispose()
        }
    }
    if (-not $downloaded) { Stop-WithError ('Mono.Cecil 下载失败：' + $lastError) }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($nupkgPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'lib/net40/Mono.Cecil.dll' } | Select-Object -First 1
        if (-not $entry) { Stop-WithError 'Mono.Cecil 包结构异常' }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dllPath, $true)
    } finally {
        $zip.Dispose()
    }
    if ((Get-Sha256 $dllPath) -ne $CecilDllSha256) { Stop-WithError 'Mono.Cecil.dll 校验不通过' }

    return $dllPath
}

# 读取目标 exe，并把内嵌的 PCLCS / MeloongCore 等释放到工作目录供 Cecil 解析
function Open-PclAssembly {
    param([string]$ExePath, [string]$WorkDir)

    $libsDir = Join-Path $WorkDir 'libs'
    New-Item -ItemType Directory -Force -Path $libsDir | Out-Null

    $resolver = New-Object Mono.Cecil.DefaultAssemblyResolver
    $resolver.AddSearchDirectory([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory())
    $readerParams = New-Object Mono.Cecil.ReaderParameters
    $readerParams.AssemblyResolver = $resolver
    $readerParams.InMemory = $true
    $asm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($ExePath, $readerParams)
    $mod = $asm.MainModule

    $resources = $mod.Resources | Where-Object { $_.Name -eq 'PCL.Resources.resources' } | Select-Object -First 1
    if ($null -eq $resources) { Stop-WithError '没有找到 PCL.Resources.resources' }
    $stream = $resources.GetResourceStream()
    try {
        $resReader = New-Object System.Resources.ResourceReader($stream)
        try {
            foreach ($resEntry in $resReader) {
                if ($resEntry.Value -is [byte[]]) {
                    $name = [string]$resEntry.Key
                    if ($name -match '^[A-Za-z0-9_.-]+$') {
                        $fileName = if ($name.EndsWith('.dll')) { $name } else { $name + '.dll' }
                        [System.IO.File]::WriteAllBytes((Join-Path $libsDir $fileName), $resEntry.Value)
                    }
                }
            }
        } finally {
            $resReader.Close()
        }
    } finally {
        $stream.Dispose()
    }
    $resolver.AddSearchDirectory($libsDir)

    return [pscustomobject]@{ Assembly = $asm; Module = $mod; Resolver = $resolver }
}

# LoaderInit：删除 "关闭下载" 的 LoaderTask 构造，替换为 ldsfld DlClientListLoader
function Invoke-LoaderInitPatch {
    param([Mono.Cecil.ModuleDefinition]$Module)

    Write-Step 'LoaderInit: ldsfld DlClientListLoader'
    $pageType = $Module.GetType('PCL.PageDownloadInstall')
    Assert-True ($null -ne $pageType) '没有找到 PCL.PageDownloadInstall'
    $loaderInit = $pageType.Methods | Where-Object { $_.Name -eq 'LoaderInit' -and $_.Parameters.Count -eq 0 } | Select-Object -First 1
    Assert-True ($null -ne $loaderInit) '没有找到 LoaderInit'
    $downloadType = $Module.GetType('PCL.ModDownload')
    Assert-True ($null -ne $downloadType) '没有找到 PCL.ModDownload'
    $dlField = $downloadType.Fields | Where-Object { $_.Name -eq 'DlClientListLoader' } | Select-Object -First 1
    Assert-True ($null -ne $dlField) '没有找到 DlClientListLoader'

    $body = $loaderInit.Body
    Assert-True ($loaderInit.HasThis) 'LoaderInit 不是实例方法'
    Assert-True ($body.ExceptionHandlers.Count -eq 0) 'LoaderInit 存在异常处理块'
    $startInstr = $body.Instructions | Where-Object { $_.OpCode.Code -eq $Code::Ldstr -and $_.Operand -eq '关闭下载' } | Select-Object -First 1
    Assert-True ($null -ne $startInstr) 'LoaderInit 找不到 "关闭下载"'
    $ldftnList = New-Object System.Collections.Generic.List[object]
    $cursor = $startInstr
    while ($null -ne $cursor) {
        if ($cursor.OpCode.Code -eq $Code::Ldftn) { $ldftnList.Add($cursor) }
        $cursor = $cursor.Next
    }
    Assert-True ($ldftnList.Count -eq 2) ('LoaderInit ldftn 数量为 ' + $ldftnList.Count)
    # 第二个 ldftn 是 LoadMinecraft_OnFinish 的委托；它前面的 ldarg.0 之后就是保留部分
    $keepStart = $ldftnList[1].Previous
    Assert-True ($keepStart.OpCode.Code -eq $Code::Ldarg_0) 'LoaderInit 保留起点不是 ldarg.0'
    $sawLoaderTask = $false
    $cursor = $startInstr
    while ($cursor -ne $keepStart) {
        if ($cursor.OpCode.Code -eq $Code::Newobj -and $cursor.Operand -is [Mono.Cecil.MethodReference] -and $cursor.Operand.DeclaringType.Name -like 'LoaderTask*') {
            $sawLoaderTask = $true
        }
        $cursor = $cursor.Next
    }
    Assert-True $sawLoaderTask 'LoaderInit 删除区间内没有 LoaderTask 构造'

    $il = $body.GetILProcessor()
    $cursor = $startInstr
    while ($cursor -ne $keepStart) {
        $next = $cursor.Next
        $il.Remove($cursor)
        $cursor = $next
    }
    $il.InsertBefore($keepStart, $Instruction::Create($OpCodes::Ldsfld, $dlField))
}

# ModpackInstall(File, InstanceName, Logo)：保留解析代码，在 throw 位置插入 switch 分发
function Invoke-ModpackDispatchPatch {
    param([Mono.Cecil.ModuleDefinition]$Module)

    Write-Step 'ModpackInstall(3): 插入 switch 分发'
    $modpackType = $Module.GetType('PCL.ModModpack')
    Assert-True ($null -ne $modpackType) '没有找到 PCL.ModModpack'
    $m3 = $modpackType.Methods | Where-Object { $_.Name -eq 'ModpackInstall' -and $_.Parameters.Count -eq 3 } | Select-Object -First 1
    Assert-True ($null -ne $m3) '没有找到 ModpackInstall(File,..)'
    Assert-True ($m3.IsStatic) 'ModpackInstall(File,..) 不是静态方法'
    Assert-True ($m3.ReturnType.FullName -like '*LoaderCombo*') ('ModpackInstall(File,..) 返回类型为 ' + $m3.ReturnType.FullName)
    for ($i = 0; $i -lt 3; $i++) {
        Assert-True ($m3.Parameters[$i].ParameterType.FullName -eq 'System.String') ('ModpackInstall(File,..) 参数 ' + $i + ' 类型不符')
    }
    $body = $m3.Body
    Assert-True ($body.Variables.Count -ge 5) 'ModpackInstall(File,..) 局部变量不足 5 个'

    # 局部变量：0=返回值, 1=ZipArchive, 2=BaseFolder, 4=PackType
    $vars = $body.Variables
    Assert-True ($vars[0].VariableType.FullName -like '*LoaderCombo*') '局部变量 0 类型不符'
    Assert-True ($vars[1].VariableType.FullName -eq 'System.IO.Compression.ZipArchive') '局部变量 1 类型不符'
    Assert-True ($vars[2].VariableType.FullName -eq 'System.String') '局部变量 2 类型不符'
    Assert-True ($vars[4].VariableType.FullName -eq 'System.Int32') '局部变量 4 类型不符'
    $retLocal = $vars[0]
    $archiveLocal = $vars[1]
    $baseLocal = $vars[2]
    $packTypeLocal = $vars[4]

    $throwMatches = @($body.Instructions | Where-Object { $_.OpCode.Code -eq $Code::Ldstr -and $_.Operand -like '为遵守相关法律法规*' })
    Assert-True ($throwMatches.Count -eq 1) ('限制 throw 数量为 ' + $throwMatches.Count)
    $throwStart = $throwMatches[0]
    Assert-True ($throwStart.Next.OpCode.Code -eq $Code::Newobj) '限制 throw 结构不符（newobj）'
    Assert-True ($throwStart.Next.Next.OpCode.Code -eq $Code::Throw) '限制 throw 结构不符（throw）'

    $nullHandlerEnds = 0
    foreach ($eh in $body.ExceptionHandlers) {
        if ($null -eq $eh.HandlerEnd) { $nullHandlerEnds++ }
        Assert-True (-not [object]::ReferenceEquals($eh.TryEnd, $throwStart)) '异常处理块的 TryEnd 指向 throw'
        Assert-True (-not [object]::ReferenceEquals($eh.HandlerStart, $throwStart)) '异常处理块的 HandlerStart 指向 throw'
    }
    Assert-True ($nullHandlerEnds -eq 1) ('空 HandlerEnd 的异常处理块有 ' + $nullHandlerEnds + ' 个')

    $afterFinally = $Instruction::Create($OpCodes::Ldloc, $retLocal)
    $retInstr = $Instruction::Create($OpCodes::Ret)
    $il = $body.GetILProcessor()
    $il.Append($afterFinally)
    $il.Append($retInstr)
    foreach ($eh in $body.ExceptionHandlers) {
        if ($null -eq $eh.HandlerEnd) { $eh.HandlerEnd = $afterFinally }
    }

    # 每个 case：参数顺序对应源码 InstallPackXxx 的签名
    # 0=File(ldarg.0) 1=Archive(ldloc.1) 2=BaseFolder(ldloc.2) 3=InstanceName(ldarg.1) 4=Logo(ldarg.2)
    $argTypes = @{ 0 = 'System.String'; 1 = 'System.IO.Compression.ZipArchive'; 2 = 'System.String'; 3 = 'System.String'; 4 = 'System.String' }
    $cases = @(
        @{ Type = 0;  Method = 'InstallPackCurseForge';   Args = @(0, 1, 2, 3, 4) },
        @{ Type = 1;  Method = 'InstallPackHMCL';         Args = @(0, 1, 2) },
        @{ Type = 2;  Method = 'InstallPackMMC';          Args = @(0, 1, 2) },
        @{ Type = 3;  Method = 'InstallPackMCBBS';        Args = @(0, 1, 2, 3) },
        @{ Type = 4;  Method = 'InstallPackModrinth';     Args = @(0, 1, 2, 3, 4) },
        @{ Type = 9;  Method = 'InstallPackLauncherPack'; Args = @(0, 1, 2) },
        @{ Type = -1; Method = 'InstallPackCompress';     Args = @(0, 1) }
    )
    $caseStart = @{}
    $caseCode = @{}
    foreach ($case in $cases) {
        $installer = $modpackType.Methods | Where-Object { $_.Name -eq $case.Method } | Select-Object -First 1
        Assert-True ($null -ne $installer) ('没有找到 ' + $case.Method)
        Assert-True ($installer.IsStatic) ($case.Method + ' 不是静态方法')
        Assert-True ($installer.Parameters.Count -eq $case.Args.Count) ($case.Method + ' 参数数量不符')
        for ($i = 0; $i -lt $case.Args.Count; $i++) {
            Assert-True ($installer.Parameters[$i].ParameterType.FullName -eq $argTypes[$case.Args[$i]]) ($case.Method + ' 参数 ' + $i + ' 类型不符')
        }
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($argKind in $case.Args) {
            switch ($argKind) {
                0 { $list.Add($Instruction::Create($OpCodes::Ldarg_0)) }
                1 { $list.Add($Instruction::Create($OpCodes::Ldloc, $archiveLocal)) }
                2 { $list.Add($Instruction::Create($OpCodes::Ldloc, $baseLocal)) }
                3 { $list.Add($Instruction::Create($OpCodes::Ldarg_1)) }
                4 { $list.Add($Instruction::Create($OpCodes::Ldarg_2)) }
            }
        }
        $list.Add($Instruction::Create($OpCodes::Call, $installer))
        $list.Add($Instruction::Create($OpCodes::Stloc, $retLocal))
        $list.Add($Instruction::Create($OpCodes::Leave, $afterFinally))
        $caseCode[$case.Type] = $list
        $caseStart[$case.Type] = $list[0]
    }

    $switchTargets = New-Object 'Mono.Cecil.Cil.Instruction[]' 10
    for ($i = 0; $i -lt 10; $i++) {
        if ($caseStart.ContainsKey($i)) { $switchTargets[$i] = $caseStart[$i] }
        else { $switchTargets[$i] = $caseStart[-1] }
    }
    $ldPackType = $Instruction::Create($OpCodes::Ldloc, $packTypeLocal)
    $switchInstr = $Instruction::Create($OpCodes::Switch, $switchTargets)
    $brDefault = $Instruction::Create($OpCodes::Br, $caseStart[-1])

    $il.InsertBefore($throwStart, $ldPackType)
    $il.InsertBefore($throwStart, $switchInstr)
    $il.InsertBefore($throwStart, $brDefault)
    foreach ($typeKey in @(0, 1, 2, 3, 4, 9, -1)) {
        foreach ($instr in $caseCode[$typeKey]) { $il.InsertBefore($throwStart, $instr) }
    }

    # 原来所有 leave 都跳到 throw 开头，现在改跳到分发开头
    foreach ($instr in $body.Instructions) {
        if ($instr.Operand -is [Mono.Cecil.Cil.Instruction] -and [object]::ReferenceEquals($instr.Operand, $throwStart)) {
            $instr.Operand = $ldPackType
        }
    }
    # catch 处理块的 HandlerEnd 原本指向 throw；插入分发后要收回到分发开头
    foreach ($eh in $body.ExceptionHandlers) {
        if ($null -ne $eh.HandlerEnd -and [object]::ReferenceEquals($eh.HandlerEnd, $throwStart)) {
            $eh.HandlerEnd = $ldPackType
        }
    }
}

# ModpackInstall()：重建选文件 + 后台安装
function Invoke-ModpackPickerPatch {
    param([Mono.Cecil.ModuleDefinition]$Module)

    Write-Step 'ModpackInstall(0): 重建 SelectFile 流程'
    $modpackType = $Module.GetType('PCL.ModModpack')
    Assert-True ($null -ne $modpackType) '没有找到 PCL.ModModpack'
    $m0 = $modpackType.Methods | Where-Object { $_.Name -eq 'ModpackInstall' -and $_.Parameters.Count -eq 0 } | Select-Object -First 1
    Assert-True ($null -ne $m0) '没有找到 ModpackInstall()'
    $body = $m0.Body
    Assert-True ($m0.IsStatic) 'ModpackInstall() 不是静态方法'
    Assert-True ($m0.ReturnType.FullName -eq 'System.Void') 'ModpackInstall() 返回类型不符'
    Assert-True ($body.ExceptionHandlers.Count -eq 0) 'ModpackInstall() 存在异常处理块'
    Assert-True ($body.Variables.Count -eq 1) ('ModpackInstall() 局部变量数量为 ' + $body.Variables.Count)
    Assert-True ($body.Variables[0].VariableType.FullName -like '*_Closure$__0-0') 'ModpackInstall() 局部变量类型不符'

    $closureType = $modpackType.NestedTypes | Where-Object { $_.Name -eq '_Closure$__0-0' } | Select-Object -First 1
    Assert-True ($null -ne $closureType) '没有找到闭包类 _Closure$__0-0'
    $closureCtor = $closureType.Methods | Where-Object { $_.Name -eq '.ctor' } | Select-Object -First 1
    $lambda = $closureType.Methods | Where-Object { $_.Name -eq '_Lambda$__0' } | Select-Object -First 1
    $fileField = $closureType.Fields | Where-Object { $_.Name -eq '$VB$Local_File' } | Select-Object -First 1
    Assert-True ($null -ne $closureCtor) '闭包类缺少 .ctor'
    Assert-True ($null -ne $lambda) '闭包类缺少 _Lambda$__0'
    Assert-True ($null -ne $fileField) '闭包类缺少 $VB$Local_File'

    # 从已有的 SelectFile 调用点借用方法引用，避免手工拼签名
    $javaType = $Module.GetType('PCL.ModJava')
    Assert-True ($null -ne $javaType) '没有找到 PCL.ModJava'
    $mj = $javaType.Methods | Where-Object { $_.Name -eq 'ManuallyImportJava' } | Select-Object -First 1
    Assert-True ($null -ne $mj) '没有找到 ModJava.ManuallyImportJava'
    Assert-True ($mj.HasBody) 'ManuallyImportJava 没有方法体'
    $refs = @{}
    foreach ($instr in $mj.Body.Instructions) {
        $op = $instr.Operand
        if (-not ($op -is [Mono.Cecil.MethodReference])) { continue }
        if ($op.Name -eq 'SelectFile' -and $op.DeclaringType.Name -eq 'Dialogs' -and $op.Parameters.Count -eq 4 -and $op.ReturnType.FullName -eq 'System.Collections.Generic.List`1<System.String>') {
            $refs['SelectFile'] = $op
        } elseif ($op.Name -eq 'FirstOrDefault' -and $op -is [Mono.Cecil.GenericInstanceMethod] -and $op.GenericArguments.Count -eq 1 -and $op.GenericArguments[0].FullName -eq 'System.String' -and $op.Parameters.Count -eq 1 -and $op.Parameters[0].ParameterType.FullName.Contains('IEnumerable`1<!!0>')) {
            $refs['FirstOrDefault'] = $op
        } elseif ($op.Name -eq 'IsNullOrEmpty' -and $op.DeclaringType.FullName -eq 'System.String' -and $op.Parameters.Count -eq 1 -and $op.Parameters[0].ParameterType.FullName -eq 'System.String' -and $op.ReturnType.FullName -eq 'System.Boolean') {
            $refs['IsNullOrEmpty'] = $op
        } elseif ($op.Name -eq 'op_Implicit' -and $op.Parameters.Count -eq 1 -and $op.Parameters[0].ParameterType -is [Mono.Cecil.GenericParameter] -and $op.Parameters[0].ParameterType.Position -eq 1 -and $op.ReturnType.FullName -like '*OneOf*') {
            $refs['OpImplicit'] = $op
        } elseif ($op.Name -eq '.ctor' -and $op.DeclaringType.Name -eq 'Nullable`1' -and $op.Parameters.Count -eq 1) {
            $refs['NullableCtor'] = $op
        }
    }
    foreach ($key in @('SelectFile', 'FirstOrDefault', 'IsNullOrEmpty', 'OpImplicit', 'NullableCtor')) {
        Assert-True ($refs.ContainsKey($key)) ('没有找到引用：' + $key)
    }

    # Action::.ctor 从任意一个 newobj 借用
    $actionCtor = $null
    foreach ($type in $Module.GetTypes()) {
        foreach ($method in $type.Methods) {
            if (-not $method.HasBody) { continue }
            foreach ($instr in $method.Body.Instructions) {
                $op = $instr.Operand
                if ($instr.OpCode.Code -eq $Code::Newobj -and $op -is [Mono.Cecil.MethodReference] -and $op.DeclaringType.FullName -eq 'System.Action' -and $op.Parameters.Count -eq 2) {
                    $actionCtor = $op
                    break
                }
            }
            if ($null -ne $actionCtor) { break }
        }
        if ($null -ne $actionCtor) { break }
    }
    Assert-True ($null -ne $actionCtor) '没有找到 System.Action::.ctor 引用'

    $baseType = $Module.GetType('PCL.ModBase')
    Assert-True ($null -ne $baseType) '没有找到 PCL.ModBase'
    $runInThread = $baseType.Methods | Where-Object { $_.Name -eq 'RunInThread' -and $_.Parameters.Count -eq 1 } | Select-Object -First 1
    Assert-True ($null -ne $runInThread) '没有找到 RunInThread'
    Assert-True ($runInThread.IsStatic) 'RunInThread 不是静态方法'
    Assert-True ($runInThread.Parameters[0].ParameterType.FullName -eq 'System.Action') 'RunInThread 参数类型不符'

    $body.Instructions.Clear()
    $il = $body.GetILProcessor()
    $closureLocal = $body.Variables[0]
    $pickRet = $Instruction::Create($OpCodes::Ret)

    $il.Emit($OpCodes::Newobj, $closureCtor)
    $il.Emit($OpCodes::Stloc, $closureLocal)
    $il.Emit($OpCodes::Ldloc, $closureLocal)
    $il.Emit($OpCodes::Ldstr, '选择整合包压缩文件')
    $il.Emit($OpCodes::Ldc_I4_0)
    $il.Emit($OpCodes::Ldnull)
    $il.Emit($OpCodes::Ldstr, '整合包文件|*.zip;*.rar;*.mrpack')
    $il.Emit($OpCodes::Call, $refs['OpImplicit'])
    $il.Emit($OpCodes::Newobj, $refs['NullableCtor'])
    $il.Emit($OpCodes::Call, $refs['SelectFile'])
    $il.Emit($OpCodes::Call, $refs['FirstOrDefault'])
    $il.Emit($OpCodes::Stfld, $fileField)
    $il.Emit($OpCodes::Ldloc, $closureLocal)
    $il.Emit($OpCodes::Ldfld, $fileField)
    $il.Emit($OpCodes::Call, $refs['IsNullOrEmpty'])
    $il.Emit($OpCodes::Brtrue, $pickRet)
    $il.Emit($OpCodes::Ldloc, $closureLocal)
    $il.Emit($OpCodes::Ldftn, $lambda)
    $il.Emit($OpCodes::Newobj, $actionCtor)
    $il.Emit($OpCodes::Call, $runInThread)
    $il.Append($pickRet)
}

# PageDownloadModify.LoadInstanceFinished：CardMinecraft 的 Visibility 由 Collapsed 改为 Visible
function Invoke-CardVisibilityPatch {
    param([Mono.Cecil.ModuleDefinition]$Module)

    Write-Step 'PageDownloadModify: CardMinecraft 可见性'
    $modifyType = $Module.GetType('PCL.PageDownloadModify')
    Assert-True ($null -ne $modifyType) '没有找到 PCL.PageDownloadModify'
    $loadFinished = $modifyType.Methods | Where-Object { $_.Name -eq 'LoadInstanceFinished' } | Select-Object -First 1
    Assert-True ($null -ne $loadFinished) '没有找到 LoadInstanceFinished'

    $visibilitySites = 0
    $tracked = $loadFinished.Body.Instructions
    for ($i = 0; $i + 2 -lt $tracked.Count; $i++) {
        $operand = $tracked[$i].Operand
        if ($operand -is [Mono.Cecil.MethodReference] -and $operand.Name -eq 'get_CardMinecraft' -and
            $tracked[$i + 1].OpCode.Code -eq $Code::Ldc_I4_2 -and
            $tracked[$i + 2].Operand -is [Mono.Cecil.MethodReference] -and $tracked[$i + 2].Operand.Name -eq 'set_Visibility') {
            $tracked[$i + 1].OpCode = $OpCodes::Ldc_I4_0
            $visibilitySites++
        }
    }
    Assert-True ($visibilitySites -eq 1) ('CardMinecraft 可见性补丁点数量为 ' + $visibilitySites)
}

# PageDownloadResourceDetail.InitializeStackResourceVersions：恢复整合包版本的 Install_Click 按钮
function Invoke-ResourceInstallPatch {
    param([Mono.Cecil.ModuleDefinition]$Module, [string]$LibsDir)

    Write-Step 'PageDownloadResourceDetail: 整合包安装按钮'
    $detailType = $Module.GetType('PCL.PageDownloadResourceDetail')
    Assert-True ($null -ne $detailType) '没有找到 PCL.PageDownloadResourceDetail'
    $initStack = $detailType.Methods | Where-Object { $_.Name -eq 'InitializeStackResourceVersions' } | Select-Object -First 1
    Assert-True ($null -ne $initStack) '没有找到 InitializeStackResourceVersions'
    $targetField = $detailType.Fields | Where-Object { $_.Name -eq 'TargetResourceType' } | Select-Object -First 1
    Assert-True ($null -ne $targetField) '没有找到 TargetResourceType'
    Assert-True ($targetField.FieldType.FullName -eq 'PCLCS.ResourceTypes') 'TargetResourceType 类型不符'
    $saveClick = $detailType.Methods | Where-Object { $_.Name -eq 'Save_Click' } | Select-Object -First 1
    $installClick = $detailType.Methods | Where-Object { $_.Name -eq 'Install_Click' } | Select-Object -First 1
    Assert-True ($null -ne $saveClick -and $null -ne $installClick) '缺少 Save_Click / Install_Click'

    # Install_Click 参数是 MyListItem，而 MyListItem/ClickEventHandler 是 (Object, MouseButtonEventArgs)，
    # 需要编译器生成的包装 lambda：它 castclass 到 MyListItem 后再调用 Install_Click
    $installLambda = $null
    foreach ($candidate in $detailType.Methods) {
        if (-not $candidate.HasBody -or $candidate.Parameters.Count -ne 2) { continue }
        foreach ($instr in $candidate.Body.Instructions) {
            if ($instr.OpCode.Code -eq $Code::Call -and $instr.Operand -is [Mono.Cecil.MethodReference] -and $instr.Operand.Name -eq 'Install_Click') {
                $installLambda = $candidate
                break
            }
        }
        if ($null -ne $installLambda) { break }
    }
    Assert-True ($null -ne $installLambda) '没有找到 Install_Click 的委托包装方法'

    $iconButtonType = $Module.GetType('PCL.MyIconButton')
    Assert-True ($null -ne $iconButtonType) '没有找到 PCL.MyIconButton'
    $iconClickHandler = $iconButtonType.NestedTypes | Where-Object { $_.Name -eq 'ClickEventHandler' } | Select-Object -First 1
    Assert-True ($null -ne $iconClickHandler) '没有找到 MyIconButton/ClickEventHandler'
    $iconDelegateCtor = $iconClickHandler.Methods | Where-Object { $_.Name -eq '.ctor' } | Select-Object -First 1
    Assert-True ($null -ne $iconDelegateCtor) '没有找到 MyIconButton/ClickEventHandler 构造函数'

    # ModPack 的枚举值在 PCLCS.dll 里，从释放出来的程序集读取
    $pclcsPath = Join-Path $LibsDir 'PCLCS.dll'
    Assert-True (Test-Path -LiteralPath $pclcsPath) '没有找到 PCLCS.dll'
    $pclcsAsm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($pclcsPath)
    try {
        $resourceTypes = $pclcsAsm.MainModule.GetType('PCLCS.ResourceTypes')
        Assert-True ($null -ne $resourceTypes) 'PCLCS 里没有 ResourceTypes'
        $modPackField = $resourceTypes.Fields | Where-Object { $_.Name -eq 'ModPack' } | Select-Object -First 1
        Assert-True ($null -ne $modPackField) 'ResourceTypes 里没有 ModPack'
        $modPackValue = [int]$modPackField.Constant
    } finally {
        $pclcsAsm.Dispose()
    }

    $body = $initStack.Body
    $il = $body.GetILProcessor()
    $toListInstr = $null
    foreach ($instr in $body.Instructions) {
        if ($instr.OpCode.Code -eq $Code::Callvirt -and $instr.Operand -is [Mono.Cecil.MethodReference] -and $instr.Operand.Name -eq 'ToListItem') {
            $toListInstr = $instr
            break
        }
    }
    Assert-True ($null -ne $toListInstr) '没有找到 ToListItem 调用'
    # 现有形状：ldloc Version; ldarg.0; ldftn Save_Click; newobj; ldnull; ldloc HasDuplicates; callvirt ToListItem
    $isBadInstr = $toListInstr.Previous
    $nullArgInstr = $isBadInstr.Previous
    $delegateNewInstr = $nullArgInstr.Previous
    $ldftnSaveInstr = $delegateNewInstr.Previous
    $ldarg0Instr = $ldftnSaveInstr.Previous
    Assert-True ($nullArgInstr.OpCode.Code -eq $Code::Ldnull) 'ToListItem 参数结构不符（ldnull）'
    Assert-True ($delegateNewInstr.OpCode.Code -eq $Code::Newobj) 'ToListItem 参数结构不符（newobj）'
    Assert-True ($ldftnSaveInstr.OpCode.Code -eq $Code::Ldftn) 'ToListItem 参数结构不符（ldftn）'
    Assert-True ($ldarg0Instr.OpCode.Code -eq $Code::Ldarg_0) 'ToListItem 参数结构不符（ldarg.0）'
    $delegateCtor = $delegateNewInstr.Operand
    Assert-True ($delegateCtor -is [Mono.Cecil.MethodReference]) 'ClickEventHandler 构造函数引用缺失'

    # 整合包：ClickHandler=Install_Click（经包装 lambda），SaveAsButtonHandler=Save_Click；其它资源保持原样
    $modFirst = $Instruction::Create($OpCodes::Ldarg_0)
    $check = @(
        $Instruction::Create($OpCodes::Ldarg_0),
        $Instruction::Create($OpCodes::Ldfld, $targetField),
        $Instruction::Create($OpCodes::Ldc_I4, $modPackValue),
        $Instruction::Create($OpCodes::Beq, $modFirst)
    )
    $nonMod = @(
        $Instruction::Create($OpCodes::Ldarg_0),
        $Instruction::Create($OpCodes::Ldftn, $saveClick),
        $Instruction::Create($OpCodes::Newobj, $delegateCtor),
        $Instruction::Create($OpCodes::Ldnull),
        $Instruction::Create($OpCodes::Br, $isBadInstr)
    )
    $modBlock = @(
        $modFirst,
        $Instruction::Create($OpCodes::Ldftn, $installLambda),
        $Instruction::Create($OpCodes::Newobj, $delegateCtor),
        $Instruction::Create($OpCodes::Ldarg_0),
        $Instruction::Create($OpCodes::Ldftn, $saveClick),
        $Instruction::Create($OpCodes::Newobj, $iconDelegateCtor)
    )
    foreach ($instr in ($check + $nonMod + $modBlock)) { $il.InsertBefore($ldarg0Instr, $instr) }
    foreach ($instr in @($ldarg0Instr, $ldftnSaveInstr, $delegateNewInstr, $nullArgInstr)) { $il.Remove($instr) }
    $body.MaxStackSize = [Math]::Max($body.MaxStackSize, 8)
}

# 写出补丁后的程序集，并回读校验五个入口
function Save-PatchedAssembly {
    param([Mono.Cecil.AssemblyDefinition]$Assembly, [string]$TmpPath, [string]$OutputPath)

    Write-Step ('写出 ' + $OutputPath)
    $Assembly.Write($TmpPath)
    $Assembly.Dispose()
    Move-Item -LiteralPath $TmpPath -Destination $OutputPath -Force

    $check = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($OutputPath)
    try {
        $checkMod = $check.MainModule
        $checkType = $checkMod.GetType('PCL.ModModpack')
        Assert-True ($null -ne $checkType) '回读：PCL.ModModpack 缺失'
        $check3 = $checkType.Methods | Where-Object { $_.Name -eq 'ModpackInstall' -and $_.Parameters.Count -eq 3 } | Select-Object -First 1
        $check0 = $checkType.Methods | Where-Object { $_.Name -eq 'ModpackInstall' -and $_.Parameters.Count -eq 0 } | Select-Object -First 1
        Assert-True ($null -ne $check3 -and $null -ne $check0) '回读：ModpackInstall 缺失'
        Assert-True ($check3.Body.ExceptionHandlers.Count -eq 3) '回读：异常处理块数量异常'
        $hasSwitch = $false
        foreach ($instr in $check3.Body.Instructions) { if ($instr.OpCode.Code -eq $Code::Switch) { $hasSwitch = $true } }
        Assert-True $hasSwitch '回读：分发 switch 缺失'
        $hasSelect = $false
        foreach ($instr in $check0.Body.Instructions) {
            if ($instr.OpCode.Code -eq $Code::Call -and $instr.Operand -is [Mono.Cecil.MethodReference] -and $instr.Operand.Name -eq 'SelectFile') { $hasSelect = $true }
        }
        Assert-True $hasSelect '回读：SelectFile 调用缺失'

        $checkPage = $checkMod.GetType('PCL.PageDownloadInstall')
        Assert-True ($null -ne $checkPage) '回读：PCL.PageDownloadInstall 缺失'
        $checkLoader = $checkPage.Methods | Where-Object { $_.Name -eq 'LoaderInit' -and $_.Parameters.Count -eq 0 } | Select-Object -First 1
        Assert-True ($null -ne $checkLoader) '回读：LoaderInit 缺失'
        $hasLdsfld = $false
        foreach ($instr in $checkLoader.Body.Instructions) {
            if ($instr.OpCode.Code -eq $Code::Ldsfld -and $instr.Operand -is [Mono.Cecil.FieldReference] -and $instr.Operand.Name -eq 'DlClientListLoader') { $hasLdsfld = $true }
        }
        Assert-True $hasLdsfld '回读：LoaderInit 补丁缺失'

        $checkModify = $checkMod.GetType('PCL.PageDownloadModify')
        Assert-True ($null -ne $checkModify) '回读：PCL.PageDownloadModify 缺失'
        $checkFinished = $checkModify.Methods | Where-Object { $_.Name -eq 'LoadInstanceFinished' } | Select-Object -First 1
        Assert-True ($null -ne $checkFinished) '回读：LoadInstanceFinished 缺失'
        $cardVisible = $false
        $finishedInstr = $checkFinished.Body.Instructions
        for ($i = 0; $i + 2 -lt $finishedInstr.Count; $i++) {
            if ($finishedInstr[$i].Operand -is [Mono.Cecil.MethodReference] -and $finishedInstr[$i].Operand.Name -eq 'get_CardMinecraft' -and
                $finishedInstr[$i + 1].OpCode.Code -eq $Code::Ldc_I4_0 -and
                $finishedInstr[$i + 2].Operand -is [Mono.Cecil.MethodReference] -and $finishedInstr[$i + 2].Operand.Name -eq 'set_Visibility') {
                $cardVisible = $true
            }
        }
        Assert-True $cardVisible '回读：CardMinecraft 可见性补丁缺失'

        $checkDetail = $checkMod.GetType('PCL.PageDownloadResourceDetail')
        Assert-True ($null -ne $checkDetail) '回读：PCL.PageDownloadResourceDetail 缺失'
        $checkStack = $checkDetail.Methods | Where-Object { $_.Name -eq 'InitializeStackResourceVersions' } | Select-Object -First 1
        Assert-True ($null -ne $checkStack) '回读：InitializeStackResourceVersions 缺失'
        $hasInstall = $false
        foreach ($instr in $checkStack.Body.Instructions) {
            if ($instr.OpCode.Code -ne $Code::Ldftn) { continue }
            $targetMethod = $instr.Operand
            if (-not ($targetMethod -is [Mono.Cecil.MethodDefinition]) -or -not $targetMethod.HasBody) { continue }
            foreach ($inner in $targetMethod.Body.Instructions) {
                if ($inner.OpCode.Code -eq $Code::Call -and $inner.Operand -is [Mono.Cecil.MethodReference] -and $inner.Operand.Name -eq 'Install_Click') { $hasInstall = $true }
            }
        }
        Assert-True $hasInstall '回读：Install_Click 分支缺失'
    } finally {
        $check.Dispose()
    }
}

# ---------------- 主流程 ----------------

if (-not (Test-Path -LiteralPath $ExePath)) {
    Stop-WithError ('没有找到 ' + $ExePath)
}

# 提前检查输出是否被占用，避免下载、解析、扫描全部做完才失败
if (Test-Path -LiteralPath $OutputPath) {
    try {
        $probe = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $probe.Dispose()
    } catch {
        Stop-WithError ('输出文件正被占用，请先关闭正在运行的 PCL：' + $OutputPath)
    }
}

$asm = $null
$resolver = $null
try {
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

    Write-Step '准备 Mono.Cecil'
    $cecilDll = Get-CecilLibrary -WorkDir $WorkDir
    Add-Type -Path $cecilDll
    $script:Code = [Mono.Cecil.Cil.Code]
    $script:OpCodes = [Mono.Cecil.Cil.OpCodes]
    $script:Instruction = [Mono.Cecil.Cil.Instruction]

    Write-Step ('读取 ' + $ExePath)
    $context = Open-PclAssembly -ExePath $ExePath -WorkDir $WorkDir
    $asm = $context.Assembly
    $resolver = $context.Resolver
    if ($asm.Name.Version.ToString() -notlike '2.99.*') {
        Stop-WithError ('只支持 PCL 2.99.x，当前版本为 ' + $asm.Name.Version)
    }

    Invoke-LoaderInitPatch -Module $context.Module
    Invoke-ModpackDispatchPatch -Module $context.Module
    Invoke-ModpackPickerPatch -Module $context.Module
    Invoke-CardVisibilityPatch -Module $context.Module
    Invoke-ResourceInstallPatch -Module $context.Module -LibsDir (Join-Path $WorkDir 'libs')

    Save-PatchedAssembly -Assembly $asm -TmpPath $TmpOutput -OutputPath $OutputPath
    $asm = $null

    Write-Ok ('输出 ' + $OutputPath)
    Write-Host ('    输出 SHA256: ' + (Get-Sha256 $OutputPath))
    Write-Host ('    输出大小: ' + (Get-Item -LiteralPath $OutputPath).Length + ' 字节')
}
catch {
    $line = $_.InvocationInfo.ScriptLineNumber
    Stop-WithError ('行 ' + $line + ': ' + $_.Exception.GetType().Name + ': ' + $_.Exception.Message)
}
finally {
    if ($null -ne $asm) { $asm.Dispose() }
    if ($null -ne $resolver) { $resolver.Dispose() }
    if (Test-Path -LiteralPath $TmpOutput) { Remove-Item -LiteralPath $TmpOutput -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
