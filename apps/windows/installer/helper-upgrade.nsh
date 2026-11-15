; Both installers call this after the new helper has been copied.
Function MigrateLegacyHelper
  Push $R0
  ReadRegStr $R0 HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "FreeV6"
  ${If} $R0 == '"$INSTDIR\freev6-helper.exe" --autostart'
    ClearErrors
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "FreeV6" '"$INSTDIR\flux6-helper.exe" --autostart'
    ${If} ${Errors}
      SetErrorLevel 20
      Abort "无法更新 Flux6 Helper 自启动路径。请重新运行安装器。"
    ${EndIf}
  ${EndIf}

  ${If} ${FileExists} "$INSTDIR\freev6-helper.exe"
    ; A silent update can start just before the old helper releases its image.
    StrCpy $R0 0
    ${Do}
      ClearErrors
      Delete "$INSTDIR\freev6-helper.exe"
      ${IfNot} ${Errors}
        ${ExitDo}
      ${EndIf}
      IntOp $R0 $R0 + 1
      ${If} $R0 >= 30
        SetErrorLevel 20
        Abort "无法移除旧版 freev6-helper.exe。请退出旧版后重新运行安装器。"
      ${EndIf}
      Sleep 1000
    ${Loop}
  ${EndIf}
  Pop $R0
  ClearErrors
FunctionEnd
