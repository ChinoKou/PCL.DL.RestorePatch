# PCL 下载入口补丁

PCL 2.99.0.0 的本地补丁，恢复被常量折叠删除的功能：

- 下载页的版本列表；
- 整合包导入（选文件 + 后台安装）；
- 整合包安装的类型分发（CurseForge / HMCL / MMC / MCBBS / Modrinth / 启动器包 / 压缩包）；
- 版本修改页的 Minecraft 卡片；
- 资源详情页整合包版本的“安装”按钮。

只修改这几个方法，不改动其它逻辑。

## 免责声明

1. 本脚本仅供个人学习、研究与技术交流使用，不得用于商业用途，也不得用于大规模分发、二次打包、售卖或任何形式的牟利行为。
2. 本脚本不是 PCL 官方产物，与 PCL 开发者无关。PCL 及其相关知识产权归成都瓜皮龙科技有限公司所有；本脚本不包含、也不分发 PCL 的任何代码或二进制文件，只读取本机的 PCL 副本并修改其方法体。
3. PCL 移除这些功能是开发者为遵守相关法律法规所做的决定。使用本脚本可能违反当地法律、法规或平台规则，请自行确认所在地区的相关规定，并承担全部后果；本脚本不构成任何形式的授权或担保。
4. 脚本按“现状”提供，不提供任何明示或暗示的担保。使用前请备份原始 exe；因使用本脚本造成的任何直接或间接损失，由使用者自行承担。

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

其余函数：`Get-CecilLibrary` 下载并校验 Cecil；`Open-PclAssembly` 读取 exe 并释放内嵌程序集供解析；`Save-PatchedAssembly` 写 `*.tmp`、替换，并在写后回读校验。

## 用法

1. 将 `PCL.DL.RestorePatch.ps1` 放到 `Plain Craft Launcher 2.exe` 同目录；
2. 执行：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\PCL.DL.RestorePatch.ps1
   ```

3. 生成 `Plain Craft Launcher 2 (dl-restore).exe`，原文件不变。

首次运行从 NuGet 下载 Mono.Cecil 0.11.6（固定版本 + SHA256），释放到 `%TEMP%`，运行结束后删除。

