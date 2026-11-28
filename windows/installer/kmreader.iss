[Setup]
AppId=KMReader-Porting
AppName=KMReader
AppVersion={#AppVersion}
AppPublisher=KMReader contributors
AppPublisherURL=https://github.com/LeValue/KMReader-Porting
AppSupportURL=https://github.com/LeValue/KMReader-Porting/issues
DefaultDirName={autopf}\KMReader
DefaultGroupName=KMReader
DisableDirPage=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\kmreader.exe
CloseApplications=yes
OutputDir={#OutputDir}
OutputBaseFilename=KMReader-{#AppVersion}-windows-x64-setup
Compression=lzma2/fast
SolidCompression=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[CustomMessages]
english.StartMenuShortcut=Create a Start menu shortcut
italian.StartMenuShortcut=Crea un collegamento nel menu Start

[Tasks]
Name: "startmenu"; Description: "{cm:StartMenuShortcut}"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\KMReader"; Filename: "{app}\kmreader.exe"; WorkingDir: "{app}"; Tasks: startmenu
Name: "{autodesktop}\KMReader"; Filename: "{app}\kmreader.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\kmreader.exe"; Description: "{cm:LaunchProgram,KMReader}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
