param([Parameter(Mandatory=$true)][string]$Config,[switch]$Preview)
$ErrorActionPreference='Stop'
$cfg=Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Preview -and -not $isAdmin) { throw 'Windows desktop acceptance requires UAC elevation' }
Add-Type -AssemblyName System.Windows.Forms,System.Drawing,UIAutomationClient,UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class AcceptanceWin {
 [StructLayout(LayoutKind.Sequential)] public struct RECT {public int L,T,R,B;}
 [StructLayout(LayoutKind.Sequential)] public struct POINT {public int X,Y;}
 [StructLayout(LayoutKind.Sequential)] public struct MINMAX {public POINT Reserved,MaxSize,MaxPosition,MinTrack,MaxTrack;}
 [StructLayout(LayoutKind.Sequential)] public struct ICONID {public uint cbSize;public IntPtr hwnd;public uint id;public Guid guid;}
 public delegate bool EnumProc(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr p);
 [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int w,int height,uint flags);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h,uint m,IntPtr w,ref MINMAX l);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h,ref POINT p);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,UIntPtr extra);
 [DllImport("user32.dll")] public static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
 [DllImport("shell32.dll")] public static extern int Shell_NotifyIconGetRect(ref ICONID id,out RECT r);
}
'@
[AcceptanceWin]::SetProcessDpiAwarenessContext([IntPtr](-4))|Out-Null
$script:window=[IntPtr]::Zero
$script:owned=@()
function Find-AppWindow {
 $processName=if ($Preview -and $cfg.executable) {[IO.Path]::GetFileNameWithoutExtension([string]$cfg.executable)} elseif ($Preview) {'freev6-windows-preview'} else {'freev6-desktop'}
 $matching=@(Get-Process -Name $processName -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq (Join-Path $cfg.installRoot ($processName+'.exe')) })
 $script:owned=@($matching.Id)
 [uint32]$windowPid=0;[AcceptanceWin]::GetWindowThreadProcessId($script:window,[ref]$windowPid)|Out-Null
 if ($script:owned -contains [int]$windowPid) {return $script:window}
 $script:window=[IntPtr]::Zero
 foreach ($process in $matching) {if ($process.MainWindowHandle -ne [IntPtr]::Zero) {$script:window=$process.MainWindowHandle;break}}
 if ($script:window -eq [IntPtr]::Zero) {
   $callback=[AcceptanceWin+EnumProc]{param($h,$p) [uint32]$candidatePid=0;[AcceptanceWin]::GetWindowThreadProcessId($h,[ref]$candidatePid)|Out-Null;$r=[AcceptanceWin+RECT]::new();[AcceptanceWin]::GetWindowRect($h,[ref]$r)|Out-Null;if (($script:owned -contains [int]$candidatePid) -and ($r.R-$r.L) -gt 200 -and ($r.B-$r.T) -gt 200) {$script:window=$h;return $false};return $true}
   [AcceptanceWin]::EnumWindows($callback,[IntPtr]::Zero)|Out-Null
 }
 return $script:window
}
function App-State {
 $h=Find-AppWindow
 if ($h -eq [IntPtr]::Zero) { return @{running=$false} }
 $r=[AcceptanceWin+RECT]::new(); [AcceptanceWin]::GetWindowRect($h,[ref]$r) | Out-Null
 $id=[AcceptanceWin+ICONID]::new(); $id.cbSize=[Runtime.InteropServices.Marshal]::SizeOf($id);$id.hwnd=$h;$id.id=1
 $tray=[AcceptanceWin+RECT]::new();$trayResult=[AcceptanceWin]::Shell_NotifyIconGetRect([ref]$id,[ref]$tray)
 $bounds=[AcceptanceWin+MINMAX]::new();[AcceptanceWin]::SendMessage($h,0x24,[IntPtr]::Zero,[ref]$bounds) | Out-Null
 return @{running=$true;pids=$script:owned;handle=$h.ToInt64();visible=[AcceptanceWin]::IsWindowVisible($h);minimized=[AcceptanceWin]::IsIconic($h);maximized=[AcceptanceWin]::IsZoomed($h);dpi=[AcceptanceWin]::GetDpiForWindow($h);rect=$r;minimum=$bounds.MinTrack;trayResult=$trayResult;tray=$tray}
}
function Native-API($request) {
 $session=Get-Content (Join-Path $cfg.evidenceRoot 'api-session.json') -Raw | ConvertFrom-Json
 if ($request.path -notin @('/settings','/status','/appearance')) {throw 'Controller API path not allowed'}
 $args=@{Uri=('http://127.0.0.1:'+$session.port+'/api/v1'+$request.path);Headers=@{Authorization=('Bearer '+$session.token)};Method=$request.method;TimeoutSec=20}
 if ($request.body) {$args.Body=($request.body|ConvertTo-Json -Depth 8 -Compress);$args.ContentType='application/json'}
 Invoke-RestMethod @args
}
function Run-Action($request) {
 if ($Preview -and $request.action -notin @('state','window','key','click','screenshot','uia','stop')) {throw 'Preview controller only permits window/UI operations'}
 switch ($request.action) {
 'install' {
   $installer=Start-Process -FilePath $cfg.installer -ArgumentList '/S' -PassThru -WindowStyle Hidden
   if (-not $installer.WaitForExit(90000)) {throw 'Installer did not finish; process left for inspection'}
   $installer.Refresh();if ($installer.ExitCode -ne 0) {throw "Installer failed: $($installer.ExitCode)"}
   $native=Join-Path $cfg.installRoot 'freev6-helper.exe'
   if ((Get-FileHash $native -Algorithm SHA256).Hash -ne $cfg.helperHash) {throw 'Installed helper differs from verified package'}
   if (Test-Path (Join-Path $cfg.installRoot 'state')) {throw 'Unexpected existing runtime state; fixture setup stopped'}
   Copy-Item -LiteralPath $native -Destination (Join-Path $cfg.evidenceRoot 'native-helper.exe')
   New-Item -ItemType Directory (Join-Path $cfg.installRoot 'state') | Out-Null
   @{nativeHelper=(Join-Path $cfg.evidenceRoot 'native-helper.exe');evidenceRoot=$cfg.evidenceRoot} | ConvertTo-Json | Set-Content (Join-Path $cfg.installRoot 'state/offline-acceptance.json') -Encoding Ascii
   Copy-Item -LiteralPath $cfg.gateway -Destination $native -Force
   return @{installed=$true;installRoot=$cfg.installRoot;offlineGate=$true}
 }
 'launch' { $launchArgs=@{FilePath=(Join-Path $cfg.installRoot 'freev6-desktop.exe');PassThru=$true};if ($request.arguments) {$launchArgs.ArgumentList=(@($request.arguments) -join ' ')}; $p=Start-Process @launchArgs;Start-Sleep -Milliseconds 1500;return @{launchedPid=$p.Id;state=(App-State)} }
 'state' { return App-State }
 'api' { return Native-API $request }
 'window' {
   $h=Find-AppWindow;if ($h -eq [IntPtr]::Zero) {throw 'No owned window'}
   switch ($request.operation) {
     'minimize' {[AcceptanceWin]::ShowWindow($h,6)|Out-Null}
     'maximize' {[AcceptanceWin]::ShowWindow($h,3)|Out-Null}
     'restore' {[AcceptanceWin]::ShowWindow($h,9)|Out-Null;[AcceptanceWin]::SetForegroundWindow($h)|Out-Null}
     'close' {[AcceptanceWin]::PostMessage($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null}
     'resize' {[AcceptanceWin]::SetWindowPos($h,[IntPtr]::Zero,100,100,[int]$request.width,[int]$request.height,4)|Out-Null}
     'tray-open' {[AcceptanceWin]::PostMessage($h,0x800a,[IntPtr]1,[IntPtr]0x202)|Out-Null}
     'tray-menu' {[AcceptanceWin]::PostMessage($h,0x800a,[IntPtr]1,[IntPtr]0x205)|Out-Null}
   };Start-Sleep -Milliseconds 400;return App-State
 }
 'key' {
   $h=Find-AppWindow;if ($h -eq [IntPtr]::Zero) {throw 'No owned window'}
   if ($request.keys -eq 'F6') { [AcceptanceWin]::keybd_event(0x75,0,0,[UIntPtr]::Zero);[AcceptanceWin]::keybd_event(0x75,0,2,[UIntPtr]::Zero) }
   else { [AcceptanceWin]::SetForegroundWindow($h)|Out-Null;[Windows.Forms.SendKeys]::SendWait([string]$request.keys) }
   Start-Sleep -Milliseconds 400;return App-State
 }
 'click' {
   $h=Find-AppWindow;if ($h -eq [IntPtr]::Zero) {throw 'No owned window'}
   [AcceptanceWin]::SetForegroundWindow($h)|Out-Null
   $point=[AcceptanceWin+POINT]::new();$point.X=[int]$request.x;$point.Y=[int]$request.y
   [AcceptanceWin]::ClientToScreen($h,[ref]$point)|Out-Null;[AcceptanceWin]::SetCursorPos($point.X,$point.Y)|Out-Null
   [AcceptanceWin]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[AcceptanceWin]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
   Start-Sleep -Milliseconds 400;return App-State
 }
 'screenshot' {
   $h=Find-AppWindow;if ($h -eq [IntPtr]::Zero) {throw 'No owned window'}
   if (-not [AcceptanceWin]::IsWindowVisible($h)) {throw 'Owned window is hidden'}
   [AcceptanceWin]::SetForegroundWindow($h)|Out-Null;Start-Sleep -Milliseconds 300
   $r=[AcceptanceWin+RECT]::new();[AcceptanceWin]::GetWindowRect($h,[ref]$r)|Out-Null
   $bitmap=[Drawing.Bitmap]::new($r.R-$r.L,$r.B-$r.T);$graphics=[Drawing.Graphics]::FromImage($bitmap)
   $graphics.CopyFromScreen($r.L,$r.T,0,0,$bitmap.Size)
   $name=[IO.Path]::GetFileName([string]$request.name);$path=Join-Path $cfg.evidenceRoot $name
   $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png);$graphics.Dispose();$bitmap.Dispose();return @{path=$path}
 }
 'uia' {
   $h=Find-AppWindow;$element=[Windows.Automation.AutomationElement]::FromHandle($h)
   $all=$element.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
   $names=@();foreach ($item in $all) {if ($item.Current.Name) {$names+=@{name=$item.Current.Name;type=$item.Current.ControlType.ProgrammaticName;rect=$item.Current.BoundingRectangle.ToString()}};if ($names.Count -ge 200) {break}};return $names
 }
 'autostart' {
   $task=Get-ScheduledTask -TaskName 'FreeV6 Autostart' -ErrorAction SilentlyContinue
   $run=Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name FreeV6 -ErrorAction SilentlyContinue
   return @{task=($task|Select-Object TaskName,State,@{n='actions';e={$_.Actions|Select-Object Execute,Arguments}},@{n='principal';e={$_.Principal|Select-Object UserId,RunLevel,LogonType}});run=$run}
 }
 'task-run' {
   $task=Get-ScheduledTask -TaskName 'FreeV6 Autostart';if ($task.Actions.Execute.Trim('"') -ine (Join-Path $cfg.installRoot 'freev6-desktop.exe')) {throw 'Task is not owned by this installation'}
   Start-ScheduledTask -InputObject $task;Start-Sleep -Seconds 2;return App-State
 }
 'startup-approved' {
   $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
   New-Item -Path $key -Force|Out-Null
   $bytes=New-Object byte[] 12;$bytes[0]=if ($request.enabled) {2} else {3}
   New-ItemProperty -Path $key -Name FreeV6 -PropertyType Binary -Value $bytes -Force|Out-Null;return @{enabled=$request.enabled}
 }
 'restore-helper' {
   if ((App-State).running) {throw 'Owned application must exit before restoring helper'}
   $settings=Get-Content (Join-Path $cfg.installRoot 'config/settings.json') -Raw | ConvertFrom-Json
   if ($settings.autoStart -or (Get-ScheduledTask -TaskName 'FreeV6 Autostart' -ErrorAction SilentlyContinue)) {throw 'Disable test autostart before removing the offline gate'}
   Copy-Item -LiteralPath (Join-Path $cfg.evidenceRoot 'native-helper.exe') -Destination (Join-Path $cfg.installRoot 'freev6-helper.exe') -Force
   Remove-Item -LiteralPath (Join-Path $cfg.installRoot 'state/offline-acceptance.json')
   $actual=(Get-FileHash (Join-Path $cfg.installRoot 'freev6-helper.exe') -Algorithm SHA256).Hash
   if ($actual -ne $cfg.helperHash) {throw 'Native helper restoration hash mismatch'}
   return @{restored=$true;sha256=$actual}
 }
 'stop' { return @{stopping=$true} }
 default {throw 'Unknown acceptance action'}
 }
}
@{pid=$PID;admin=$isAdmin;ready=$true;preview=[bool]$Preview}|ConvertTo-Json|Set-Content (Join-Path $cfg.evidenceRoot 'ready.json') -Encoding UTF8
$deadline=(Get-Date).AddHours(2)
while ((Get-Date) -lt $deadline) {
 foreach ($file in @(Get-ChildItem (Join-Path $cfg.evidenceRoot 'queue') -Filter '*.json'|Sort-Object Name)) {
   $request=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json
   try {$result=Run-Action $request;$reply=@{id=$request.id;ok=$true;result=$result}}
   catch {$reply=@{id=$request.id;ok=$false;error=$_.Exception.Message}}
   $reply|ConvertTo-Json -Depth 12|Set-Content (Join-Path $cfg.evidenceRoot ('responses/'+$request.id+'.json')) -Encoding UTF8
   Remove-Item -LiteralPath $file.FullName
   if ($request.action -eq 'stop') {exit}
 }
 Start-Sleep -Milliseconds 200
}
