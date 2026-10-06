#ifndef PackageDir
  #define PackageDir "..\..\Releases\Windows\LingoClass"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\Releases\Installers"
#endif
[Setup]
AppId={{F86029F4-7066-48B6-8942-04B2C935B53B}
AppName=LingoClass
AppVersion=2026.10.06
DefaultDirName={localappdata}\Programs\LingoClass
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableWelcomePage=yes
UsePreviousAppDir=no
OutputDir={#OutputDir}
OutputBaseFilename=LingoClass-Setup
SetupIconFile=..\..\Desktop\public\app-icon.ico
UninstallDisplayIcon={app}\LingoClass.exe
Compression=lzma2/fast
SolidCompression=yes
LZMANumBlockThreads=2
CloseApplications=no
WizardStyle=modern
[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
[Messages]
SetupWindowTitle=LingoClass 安装
WizardInstalling=正在安装
InstallingLabel=正在将 LingoClass 和所需依赖安装到您的用户应用目录，请稍候。
FinishedHeadingLabel=安装完成
FinishedLabel=LingoClass 已安装。以后可通过桌面或开始菜单快捷方式打开。
ButtonFinish=完成
ButtonCancel=取消
[Files]
Source: "{#PackageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{userdesktop}\LingoClass"; Filename: "{app}\LingoClass.exe"; WorkingDir: "{app}"
Name: "{userprograms}\LingoClass"; Filename: "{app}\LingoClass.exe"; WorkingDir: "{app}"
[Run]
Filename: "{app}\LingoClass.exe"; Description: "打开 LingoClass"; Flags: nowait postinstall skipifsilent
