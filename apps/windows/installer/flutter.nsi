; Flux6 0.2 uses the FlClash Windows service. Its binaries must be in Program Files.
Unicode true
ManifestDPIAware true
RequestExecutionLevel admin
SetCompressor /SOLID lzma
!include MUI2.nsh
!include LogicLib.nsh
!include x64.nsh
!define KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Flux6"
Name "Flux6"
OutFile "${OUTPUT}"
InstallDir "$PROGRAMFILES64\Flux6"
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "Flux6"
VIAddVersionKey "FileDescription" "Flux6 Windows Installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "Flux6 contributors"
!define MUI_ICON "${REPO}\assets\branding\icon.ico"
!define MUI_UNICON "${REPO}\assets\branding\icon.ico"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

!macro CheckLocation
  SetRegView 64
  SetShellVarContext all
  StrCpy $INSTDIR "$PROGRAMFILES64\Flux6"
  ; An existing junction would redirect elevated file operations.
  System::Call 'kernel32::GetFileAttributesW(w "$INSTDIR") i.r0'
  ${If} $0 != -1
    IntOp $0 $0 & 0x400
    ${If} $0 != 0
      SetErrorLevel 20
      Abort "安装目录是重解析点。"
    ${EndIf}
  ${EndIf}
!macroend

!macro PrepareFiles
  InitPluginsDir
  SetOutPath "$PLUGINSDIR"
  File /oname=check-install.ps1 "${REPO}\apps\windows\installer\check-install.ps1"
  nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\check-install.ps1" -InstallRoot "$INSTDIR"'
  Pop $0
  Pop $1
  ${If} $0 != 0
    SetErrorLevel 10
    Abort "请先在托盘中退出 Flux6，再重新运行安装程序。"
  ${EndIf}
  ; Only the registered service from the protected Flux6 bundle is eligible.
  ReadRegStr $0 HKLM "SYSTEM\CurrentControlSet\Services\Flux6HelperService" "ImagePath"
  ${If} $0 != ""
    ${IfNot} ${FileExists} "$INSTDIR\Flux6HelperService.exe"
      SetErrorLevel 20
      Abort "请先从原安装中卸载 Flux6 服务。"
    ${EndIf}
    ExecWait '"$INSTDIR\Flux6HelperService.exe" uninstall' $1
    ${If} $1 != 0
      SetErrorLevel 20
      Abort "无法卸载正在使用的 Flux6 服务。"
    ${EndIf}
  ${EndIf}
!macroend

Section "Flux6"
  !insertmacro CheckLocation
  !insertmacro PrepareFiles
  SetOutPath "$INSTDIR"
  ClearErrors
  File /r "${BUNDLE}\*"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  CreateShortcut "$SMPROGRAMS\Flux6.lnk" "$INSTDIR\freev6-desktop.exe"
  WriteRegStr HKLM "${KEY}" "DisplayName" "Flux6"
  WriteRegStr HKLM "${KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${KEY}" "Publisher" "Flux6 contributors"
  WriteRegStr HKLM "${KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${KEY}" "DisplayIcon" "$INSTDIR\freev6-desktop.exe"
  WriteRegStr HKLM "${KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  ${If} ${Errors}
    SetErrorLevel 20
    Abort "写入 Flux6 安装文件或登记信息失败。"
  ${EndIf}
SectionEnd

Section "Uninstall"
  !insertmacro CheckLocation
  !insertmacro PrepareFiles
  ClearErrors
  !include "${UNINSTALL_FILES}"
  ${If} ${Errors}
    SetErrorLevel 20
    Abort "部分文件仍在使用，请退出 Flux6 后重试。"
  ${EndIf}
  Delete "$SMPROGRAMS\Flux6.lnk"
  Delete "$INSTDIR\uninstall.exe"
  DeleteRegKey HKLM "${KEY}"
  RMDir "$INSTDIR"
SectionEnd
