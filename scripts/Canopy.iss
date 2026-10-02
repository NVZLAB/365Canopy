[Setup]
AppId={{A2290B44-421D-42F2-9F06-7C9E8725D6CB}
AppName=365Canopy Preview
AppVersion=0.1.0-alpha.7
AppPublisher=NVZLAB
DefaultDirName={localappdata}\Programs\365Canopy
DefaultGroupName=365Canopy
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#Output}
OutputBaseFilename=365Canopy-0.1.0-alpha.7-Setup
Compression=lzma2/fast
SolidCompression=yes
SetupIconFile=../design/assets/canopy.ico
UninstallDisplayIcon={app}\365Canopy.exe
CloseApplications=yes
RestartApplications=no

[Files]
Source: "{#Payload}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\365Canopy"; Filename: "{app}\365Canopy.exe"
Name: "{group}\Uninstall 365Canopy"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\365Canopy.exe"; Description: "Launch 365Canopy Preview"; Flags: nowait postinstall skipifsilent unchecked
