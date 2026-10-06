# Windows 分发

分发 `Releases/Installers/LingoClass-Setup.exe`，不要单独分发内部的 `LingoClass.exe`。

双击安装包会将应用、Python 运行库、模型和前端一起安装到
`%LOCALAPPDATA%\Programs\LingoClass`，不需要管理员权限，并创建桌面与开始菜单快捷方式。
录音、下载的模型和用户设置仍保存在 `%LOCALAPPDATA%\LingoClass`，与安装目录分离。
卸载只删除安装文件，不删除课堂记录。

完整构建使用 `build-windows.ps1`。仅为已有应用目录生成安装包：

```powershell
./build-installer.ps1 -PackageDir '应用目录' -Compiler 'Inno Setup 的 ISCC.exe 路径'
```

编译器默认为项目 `Build/installer-tools/inno/ISCC.exe`。安装包脚本位于
`LingoClass-installer.iss`。安装包包含应用目录的全部文件；若该目录含私人 API 配置，
安装包也包含该配置，只用于授权的私人分发。
