# PCL.DL.RestorePatch

## 关于

本补丁由单个 PowerShell 脚本实现且不含预编译方法体，使用 Mono.Cecil 在目标机器上进行 IL 修补，恢复了 PCL 2.99.0.0 发行版的如下功能：

- 下载页的版本列表；
- 整合包导入（选文件 + 后台安装）；
- 整合包安装的类型分发（CurseForge / HMCL / MMC / MCBBS / Modrinth / 启动器包 / 压缩包）；
- 版本修改页的 Minecraft 卡片；
- 资源详情页整合包版本的“安装”按钮。

只修改这几个方法，不改动其它逻辑。

## 使用

<details open>
<summary><strong>GUI</strong></summary>

GUI 只是套在补丁脚本外面的启动器。核心逻辑全部在 PCL.DL.RestorePatch.ps1 脚本中，GUI 本身不参与修改。

从 [Release](https://github.com/ChinoKou/PCL.DL.RestorePatch/releases/latest) 下载对应版本：

- **标准版**：`PCL.DL.RestorePatch.GUI.exe`，不含 Mono.Cecil，每次开始补丁时从 nuget.org 下载 Mono.Cecil 0.11.6 并校验 SHA256；
- **离线版**：`PCL.DL.RestorePatch.GUI.WithCecil.exe`，内置 Mono.Cecil 0.11.6。

1. 把 PCL 的 exe 拖进窗口，或点击“浏览…”选择；
2. 点击“开始补丁”；
3. 完成后会在 PCL 同目录生成恢复版 `<原文件名> (dl-restore).exe`。

</details>

<details>
<summary><strong>PowerShell 脚本</strong></summary>

把脚本放到 PCL 同目录直接运行，自动使用同目录的 `Plain Craft Launcher 2.exe`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PCL.DL.RestorePatch.ps1
```

也可以传入 exe 或目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PCL.DL.RestorePatch.ps1 "D:\PCL\Plain Craft Launcher 2.exe"
powershell -NoProfile -ExecutionPolicy Bypass -File .\PCL.DL.RestorePatch.ps1 "D:\PCL"
```

输出同样写在输入 exe 同目录。

</details>

## 背景

限制定义在 `ModSecret.vb`：

```vb
Public Const RestrictMcDownload As Boolean = True
```

VB 会把 `Const` 内联到每个使用点，并把死分支折叠掉。发布版里不是“开关被设为 False”，而是相关代码没有生成：

```vb
If RestrictMcDownload Then Throw New Exception("...")
Select Case PackType
    Case 0 : Return InstallPackCurseForge(...)
    ...
End Select
```

`Select Case` 整段不可达，编译器不会为它生成 IL。改元数据里的常量值也没有用——所有使用点在编译时就已经替换成 `True` 了。

受影响的有五处：

| 位置 | 发布版里剩下什么 |
|---|---|
| `PageDownloadInstall.LoaderInit` | 一个只会抛异常的 `LoaderTask` 构造 |
| `ModpackInstall(File, InstanceName, Logo)` | 整合包解析 + 无条件 `throw`（751 字节） |
| `ModpackInstall()` | `Hint` + `return`（19 字节） |
| `PageDownloadModify.LoadInstanceFinished` | `CardMinecraft.Visibility` 硬编码为 `Collapsed` |
| `PageDownloadResourceDetail.InitializeStackResourceVersions` | 只生成 `Save_Click`，`Install_Click` 分支消失 |

这些方法里没有可切换的分支，也没有可跳转的分发代码，只能重写方法体或补回缺失的分支。

## 实现

用 Mono.Cecil 读取目标 exe，通过 `ILProcessor` 修改 IL，再写出新文件；不内嵌预编译的方法体，也不新增方法。

每个补丁点对应一个函数：

| 函数 | 处理 |
|---|---|
| `Invoke-LoaderInitPatch` | 删除 `ldstr "关闭下载"` 到 `newobj LoaderTask` 之间的构造，插入 `ldsfld DlClientListLoader` |
| `Invoke-ModpackDispatchPatch` | 保留解析代码，在限制 `throw` 处插入 `ldloc PackType; switch`（7 个安装器分支），并把 `leave` 和 catch 的 `HandlerEnd` 改到分发起点 |
| `Invoke-ModpackPickerPatch` | 重建方法体：`SelectFile → FirstOrDefault → RunInThread(_Lambda$__0)` |
| `Invoke-CardVisibilityPatch` | `CardMinecraft.Visibility` 前的 `ldc.i4.2` 改为 `ldc.i4.0` |
| `Invoke-ResourceInstallPatch` | 在 `ToListItem` 前插入 `TargetResourceType = ModPack` 判断：整合包用 `Install_Click`（经包装 lambda）+ `Save_Click`，其它资源保持原样 |

## 第三方组件

本程序使用 Mono.Cecil 0.11.6，作者 Jb Evain，按 MIT License 分发。项目地址：https://github.com/jbevain/cecil

## 免责声明

1. 本脚本仅供个人学习、研究与技术交流使用，不得用于商业用途，也不得用于售卖或任何形式的牟利行为。如需二次分发，请仅限个人非商业用途，保留完整免责声明与出处，不得大规模传播或用于商业目的。
2. 本脚本不是 PCL 官方产物，与 PCL 开发者无关。PCL 及其相关知识产权归成都瓜皮龙科技有限公司所有；本脚本不包含、也不分发 PCL 的任何代码或二进制文件，只读取本机的 PCL 副本并修改其方法体。
3. PCL 移除这些功能是开发者为遵守相关法律法规所做的决定。使用本脚本可能违反当地法律、法规或平台规则，请自行确认所在地区的相关规定，并承担全部后果；本脚本不构成任何形式的授权或担保。
4. 脚本按“现状”提供，不提供任何明示或暗示的担保。使用前请备份原始 exe；因使用本脚本造成的任何直接或间接损失，由使用者自行承担。
