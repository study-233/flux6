; Independent Flutter installer. No Tauri plugins or process-killing macros.
; Inputs are prepared by scripts/windows/build-flutter.ps1.
Unicode true
ManifestDPIAware true
RequestExecutionLevel admin
SetCompressor /SOLID lzma
!include MUI2.nsh
!include LogicLib.nsh
!include FileFunc.nsh
!include nsDialogs.nsh
!include x64.nsh
!include WordFunc.nsh
!define KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\FreeV6"
Name "FreeV6"
OutFile "${OUTPUT}"
InstallDir "$LOCALAPPDATA\FreeV6"
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "FreeV6"
VIAddVersionKey "FileDescription" "FreeV6 Flutter Windows Installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "FreeV6 contributors"
!define MUI_ICON "${REPO}\assets\branding\icon.ico"
!define MUI_UNICON "${REPO}\assets\branding\icon.ico"
!insertmacro MUI_PAGE_WELCOME
Page custom Consent ConsentLeave
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\freev6-desktop.exe"
!define MUI_FINISHPAGE_RUN_NOTCHECKED
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
UninstPage custom un.DataChoice
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"
Var ConsentControl
Var DeleteData
Var DeleteControl
Var RegistryView
Var Existing
Var Relaunch

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "此安装包需要 64 位 Windows。"
    Abort
  ${EndIf}
  SetShellVarContext current
  StrCpy $RegistryView 32
  SetRegView 32
  ReadRegStr $Existing HKCU "${KEY}" "InstallLocation"
  ${If} $Existing == ""
    SetRegView 64
    ReadRegStr $Existing HKCU "${KEY}" "InstallLocation"
    ${If} $Existing != ""
      StrCpy $RegistryView 64
    ${Else}
      SetRegView 32
    ${EndIf}
  ${EndIf}
  ${If} $Existing != ""
    ; Tauri writes quotes around InstallLocation.
    StrCpy $0 $Existing 1
    ${If} $0 == '$\"'
      StrCpy $Existing $Existing -1 1
    ${EndIf}
    StrCpy $INSTDIR $Existing
  ${Else}
    ; Machine-wide installations need a reviewed migration, not a second entry.
    SetRegView 32
    ReadRegStr $0 HKLM "${KEY}" "InstallLocation"
    SetRegView 64
    ReadRegStr $1 HKLM "${KEY}" "InstallLocation"
    ${If} $0 != ""
    ${OrIf} $1 != ""
      MessageBox MB_OK|MB_ICONSTOP "检测到系统范围的旧安装。请先按迁移说明备份并卸载旧程序（保留应用数据），再安装本版本。" /SD IDOK
      Abort
    ${EndIf}
    SetRegView 32
  ${EndIf}
  ReadRegStr $0 HKCU "${KEY}" "DisplayVersion"
  ${If} $0 != ""
    ${VersionCompare} $0 "${VERSION}" $1
    ${If} $1 == 1
      MessageBox MB_OK|MB_ICONSTOP "已安装版本更新，已阻止降级。" /SD IDOK
      Abort
    ${EndIf}
  ${EndIf}
  StrCpy $Relaunch 0
  ClearErrors
  ${GetOptions} $CMDLINE "/FREEV6REL" $0
  ${IfNot} ${Errors}
    StrCpy $Relaunch 1
  ${EndIf}
FunctionEnd

Function Consent
  !insertmacro MUI_HEADER_TEXT "用户协议与隐私政策" "阅读并同意后继续"
  nsDialogs::Create 1018
  Pop $0
  ${NSD_CreateLabel} 0 0 100% 54u "FreeV6 为免费开源软件。此版本包含 GPLv3 视觉组件及其他开源依赖；各组件许可证随安装包提供。对应源码包应与本安装包一起分发。"
  Pop $0
  ${NSD_CreateLink} 0 62u 85u 16u "用户协议"
  Pop $0
  ${NSD_OnClick} $0 OpenAgreement
  ${NSD_CreateLink} 100u 62u 85u 16u "隐私政策"
  Pop $0
  ${NSD_OnClick} $0 OpenPrivacy
  ${NSD_CreateCheckbox} 0 100u 100% 20u "我已阅读并同意用户协议与隐私政策"
  Pop $ConsentControl
  nsDialogs::Show
FunctionEnd
Function ConsentLeave
  ${NSD_GetState} $ConsentControl $0
  ${If} $0 != ${BST_CHECKED}
    MessageBox MB_OK|MB_ICONEXCLAMATION "请先阅读并勾选同意。"
    Abort
  ${EndIf}
FunctionEnd
Function OpenAgreement
  Pop $0
  ExecShell "open" "https://github.com/study-233/free-v6/blob/main/docs/agreement.md"
FunctionEnd
Function OpenPrivacy
  Pop $0
  ExecShell "open" "https://github.com/study-233/free-v6/blob/main/docs/privacy.md"
FunctionEnd

!macro Guard PREFIX
Function ${PREFIX}Guard
  InitPluginsDir
  SetOutPath "$PLUGINSDIR"
  File /oname=check-install.ps1 "${REPO}\apps\windows\installer\check-install.ps1"
  StrCpy $R8 0
  retry:
    nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\check-install.ps1" -InstallRoot "$INSTDIR"'
    Pop $R0
    Pop $R1
    ${If} $R0 == 0
      Return
    ${EndIf}
    ${If} ${Silent}
      ; The in-app updater launches us just before its owned helper exits.
      IntOp $R8 $R8 + 1
      ${If} $R0 == 10
      ${AndIf} $R8 < 30
        Sleep 1000
        Goto retry
      ${EndIf}
      SetErrorLevel 10
      Quit
    ${EndIf}
    MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "FreeV6 或网络核心仍在运行，或无法检查进程。请从托盘退出并等待连接停止，然后重试。安装器不会强制结束进程。" /SD IDCANCEL IDRETRY retry
    Abort
FunctionEnd
!macroend
!insertmacro Guard ""
!insertmacro Guard "un."

Section "FreeV6"
  ${If} $Existing != ""
  ${AndIf} $INSTDIR != $Existing
    MessageBox MB_OK|MB_ICONSTOP "升级时请保持原安装目录，以保留配置和凭据。" /SD IDOK
    Abort
  ${EndIf}
  Call Guard
  SetOutPath "$INSTDIR"
  ClearErrors
  File /r "${BUNDLE}\*"
  ${If} ${Errors}
    SetErrorLevel 20
    Abort "安装文件复制失败。请保留应用数据并重新运行安装器。"
  ${EndIf}
  WriteUninstaller "$INSTDIR\uninstall.exe"
  ${If} $RegistryView == 64
    SetRegView 64
  ${Else}
    SetRegView 32
  ${EndIf}
  WriteRegStr HKCU "${KEY}" "DisplayName" "FreeV6"
  WriteRegStr HKCU "${KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${KEY}" "DisplayIcon" '$\"$INSTDIR\freev6-desktop.exe$\"'
  WriteRegStr HKCU "${KEY}" "InstallLocation" '$\"$INSTDIR$\"'
  WriteRegStr HKCU "${KEY}" "UninstallString" '$\"$INSTDIR\uninstall.exe$\"'
  WriteRegStr HKCU "${KEY}" "QuietUninstallString" '$\"$INSTDIR\uninstall.exe$\" /S'
  WriteRegStr HKCU "${KEY}" "MainBinaryName" "freev6-desktop.exe"
  WriteRegStr HKCU "${KEY}" "Publisher" "FreeV6 contributors"
  WriteRegDWORD HKCU "${KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${KEY}" "NoRepair" 1
  CreateDirectory "$SMPROGRAMS\FreeV6"
  CreateShortcut "$SMPROGRAMS\FreeV6\FreeV6.lnk" "$INSTDIR\freev6-desktop.exe"
  CreateShortcut "$DESKTOP\FreeV6.lnk" "$INSTDIR\freev6-desktop.exe"
  ${If} ${Silent}
  ${AndIf} $Relaunch == 1
    Exec '"$INSTDIR\freev6-desktop.exe"'
  ${EndIf}
SectionEnd

Function un.onInit
  SetShellVarContext current
  StrCpy $DeleteData 0
FunctionEnd
Function un.DataChoice
  nsDialogs::Create 1018
  Pop $0
  ${NSD_CreateLabel} 0 0 100% 42u "默认保留配置、WARP 凭据、流量历史和运行核心，便于重新安装或回退。自启动项将撤销。"
  Pop $0
  ${NSD_CreateCheckbox} 0 58u 100% 20u "同时删除应用数据（无法恢复）"
  Pop $DeleteControl
  ${NSD_OnClick} $DeleteControl un.DataToggle
  nsDialogs::Show
FunctionEnd
Function un.DataToggle
  Pop $0
  ${NSD_GetState} $DeleteControl $DeleteData
FunctionEnd
Section "Uninstall"
  Call un.Guard
  SetOutPath "$PLUGINSDIR"
  File /oname=remove-autostart.ps1 "${REPO}\apps\windows\installer\remove-autostart.ps1"
  nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\remove-autostart.ps1" -InstallRoot "$INSTDIR"'
  Pop $0
  Pop $1
  ${If} $0 != 0
    SetErrorLevel 20
    Abort "无法撤销自启动，已停止卸载。"
  ${EndIf}
  ; Exact application-owned payload list generated from this build's bundle.
  ClearErrors
  !include "${UNINSTALL_FILES}"
  ${If} ${Errors}
    SetErrorLevel 20
    Abort "部分程序文件仍被占用。请关闭相关程序后重新卸载，应用数据已保留。"
  ${EndIf}
  Delete "$INSTDIR\uninstall.exe"
  Delete "$DESKTOP\FreeV6.lnk"
  Delete "$SMPROGRAMS\FreeV6\FreeV6.lnk"
  RMDir "$SMPROGRAMS\FreeV6"
  SetRegView 32
  DeleteRegKey HKCU "${KEY}"
  SetRegView 64
  DeleteRegKey HKCU "${KEY}"
  ${If} $DeleteData == ${BST_CHECKED}
    RMDir /r "$INSTDIR\config"
    RMDir /r "$INSTDIR\state"
    RMDir /r "$INSTDIR\runtime"
    RMDir /r "$LOCALAPPDATA\dev.freev6.desktop"
    RMDir /r "$APPDATA\dev.freev6.desktop"
    Delete "$INSTDIR\freev6-update-setup.exe"
  ${EndIf}
  RMDir "$INSTDIR"
SectionEnd
