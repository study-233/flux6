// The live host owns only the helper process it creates. Proxy lifecycle and
// network restoration remain in the existing authenticated Go API.
#include <winsock2.h>
#include <ws2tcpip.h>
#include "host_bridge.h"
#include <flutter/standard_method_codec.h>
#include <bcrypt.h>
#include <commdlg.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <algorithm>
#include <array>
#include <cctype>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <map>
#include <vector>
#include "resource.h"

#ifndef FREEV6_LIVE
#define FREEV6_LIVE 0
#endif
namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
constexpr UINT kTray = WM_APP + 10;
constexpr UINT_PTR kPoll = 51;
constexpr int kHotkey = 71;
constexpr wchar_t kTitle[] = L"Flux6";
std::string Utf8(const std::wstring& input) {
  if (input.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, input.data(), static_cast<int>(input.size()), nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, input.data(), static_cast<int>(input.size()), result.data(), size, nullptr, nullptr);
  return result;
}
std::wstring Wide(const std::string& input) {
  if (input.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()), result.data(), size);
  return result;
}
std::string StringArg(const EncodableMap* args, const char* key) {
  if (!args) return {};
  const auto found = args->find(EncodableValue(key));
  if (found == args->end()) return {};
  const auto* value = std::get_if<std::string>(&found->second);
  return value ? *value : std::string();
}
bool BoolArg(const EncodableMap* args, const char* key) {
  if (!args) return false;
  const auto found = args->find(EncodableValue(key));
  if (found == args->end()) return false;
  const auto* value = std::get_if<bool>(&found->second);
  return value && *value;
}
bool SettingsFlag(const char* flag) {
  std::ifstream file(std::filesystem::path(HostBridge::Root()) / L"config" / L"settings.json", std::ios::binary);
  std::string raw((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
  raw.erase(std::remove_if(raw.begin(), raw.end(), [](unsigned char c) { return std::isspace(c) != 0; }), raw.end());
  return raw.find(std::string("\"") + flag + "\":true") != std::string::npos;
}
std::string Hex(const unsigned char* data, size_t length) {
  static constexpr char digits[] = "0123456789abcdef";
  std::string result;
  for (size_t i = 0; i < length; ++i) { result += digits[data[i] >> 4]; result += digits[data[i] & 15]; }
  return result;
}
std::wstring FullPath(const std::wstring& path) {
  std::vector<wchar_t> buffer(32768);
  const DWORD count = GetFullPathNameW(path.c_str(), static_cast<DWORD>(buffer.size()), buffer.data(), nullptr);
  return count > 0 && count < buffer.size() ? std::wstring(buffer.data(), count) : L"";
}
bool SamePath(const std::wstring& a, const std::wstring& b) {
  const auto left = FullPath(a), right = FullPath(b);
  return !left.empty() && !right.empty() && _wcsicmp(left.c_str(), right.c_str()) == 0;
}
// Recheck helper-verified bytes just before elevated execution. The open file
// denies writes/deletion until CreateProcess returns.
HANDLE VerifiedInstaller(const std::wstring& path, std::string expected) {
  if (expected.size() != 64) return INVALID_HANDLE_VALUE;
  PWSTR local = nullptr;
  bool allowed = false;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local))) {
    allowed = SamePath(path, std::wstring(local) + L"\\FreeV6\\freev6-update-setup.exe");
    CoTaskMemFree(local);
  } else {
    wchar_t temp[MAX_PATH + 1] = {};
    const DWORD count = GetTempPathW(MAX_PATH, temp);
    if (count > 0 && count < MAX_PATH) allowed = SamePath(path, std::wstring(temp) + L"freev6-update-setup.exe");
  }
  if (!allowed) return INVALID_HANDLE_VALUE;
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return file;
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  bool ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0;
  DWORD object_size = 0, written = 0;
  if (ok) ok = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&object_size), sizeof(object_size), &written, 0) >= 0;
  std::vector<unsigned char> object(object_size);
  if (ok) ok = BCryptCreateHash(algorithm, &hash, object.data(), object_size, nullptr, 0, 0) >= 0;
  std::array<unsigned char, 65536> buffer{};
  DWORD read = 0;
  while (ok) {
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &read, nullptr)) { ok = false; break; }
    if (read == 0) break;
    ok = BCryptHashData(hash, buffer.data(), read, 0) >= 0;
  }
  std::array<unsigned char, 32> sum{};
  if (ok) ok = BCryptFinishHash(hash, sum.data(), static_cast<ULONG>(sum.size()), 0) >= 0;
  if (hash) BCryptDestroyHash(hash);
  if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
  std::transform(expected.begin(), expected.end(), expected.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  if (!ok || Hex(sum.data(), sum.size()) != expected) { CloseHandle(file); return INVALID_HANDLE_VALUE; }
  return file;
}
std::optional<std::wstring> PickFile(HWND window, const std::string& kind, bool save, DWORD* failure) {
  std::vector<wchar_t> path(32768, L'\0');
  if (save) wcscpy_s(path.data(), path.size(), L"freev6-ui-preferences.json");
  const wchar_t* filter = kind == "image" ? L"PNG / JPEG\0*.png;*.jpg;*.jpeg\0\0" :
    kind == "yaml" ? L"YAML\0*.yaml;*.yml\0All files\0*.*\0\0" : L"JSON\0*.json\0\0";
  OPENFILENAMEW dialog{};
  dialog.lStructSize = sizeof(dialog); dialog.hwndOwner = window; dialog.lpstrFilter = filter;
  dialog.lpstrFile = path.data(); dialog.nMaxFile = static_cast<DWORD>(path.size());
  dialog.lpstrDefExt = kind == "json" ? L"json" : nullptr;
  dialog.Flags = OFN_NOCHANGEDIR | OFN_EXPLORER | OFN_PATHMUSTEXIST | (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
  const BOOL selected = save ? GetSaveFileNameW(&dialog) : GetOpenFileNameW(&dialog);
  *failure = selected ? 0 : CommDlgExtendedError();
  return selected ? std::optional<std::wstring>(path.data()) : std::nullopt;
}
}

std::wstring HostBridge::Root() {
  std::vector<wchar_t> path(32768);
  const DWORD count = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (count == 0 || count >= path.size()) return L"";
  return std::filesystem::path(std::wstring(path.data(), count)).parent_path().wstring();
}
bool HostBridge::AutostartAllowed() {
  BYTE value[64] = {}; DWORD size = sizeof(value);
  const LSTATUS status = RegGetValueW(HKEY_CURRENT_USER,
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run",
    L"FreeV6", RRF_RT_REG_BINARY, nullptr, value, &size);
  return status != ERROR_SUCCESS || size == 0 || value[0] == 2;
}
bool HostBridge::should_show() const { return !probe_ && (!FREEV6_LIVE || !tray_ || !SettingsFlag("silentStart")); }
HostBridge::HostBridge(flutter::BinaryMessenger* messenger, HWND window, bool probe) : window_(window), probe_(probe) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(messenger,
      "dev.freev6.windows/v1", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
    const auto& method = call.method_name();
    if (method == "describe") {
      result->Success(EncodableValue(EncodableMap{
        {EncodableValue("version"), EncodableValue(1)}, {EncodableValue("platform"), EncodableValue("windows")},
        {EncodableValue("preview"), EncodableValue(FREEV6_LIVE == 0)}}));
    } else if (method == "finishProbe" && probe_) {
      probe_passed_ = BoolArg(args, "ok"); exiting_ = true;
      result->Success(); PostMessageW(window_, WM_CLOSE, 0, 0);
    } else if (!FREEV6_LIVE || probe_) {
      result->Error("preview", "Live operations are disabled in preview/probe mode");
    } else if (method == "bootstrap") {
      std::string error;
      if (!StartHelper(&error)) { result->Error("helper", error); return; }
      result->Success(EncodableValue(EncodableMap{
        {EncodableValue("root"), EncodableValue(Utf8(Root()))}, {EncodableValue("port"), EncodableValue(port_)},
        {EncodableValue("token"), EncodableValue(token_)}, {EncodableValue("appVersion"), EncodableValue(FLUTTER_VERSION)}}));
    } else if (method == "hotkey") {
      if (SetHotkey(BoolArg(args,"enabled"))) result->Success();
      else result->Error("hotkey", "F6 is occupied by another application; the setting was not saved");
    } else if (method == "app.quit") {
      exiting_ = true; result->Success(); PostMessageW(window_, WM_CLOSE, 0, 0);
    } else if (method == "window.show") { Show(); result->Success();
    } else if (method == "file.pick") {
      DWORD failure = 0;
      const auto selected = PickFile(window_, StringArg(args,"kind"), BoolArg(args,"save"), &failure);
      if (failure) result->Error("dialog", "File dialog failed: " + std::to_string(failure));
      else if (selected) result->Success(EncodableValue(Utf8(*selected)));
      else result->Success();
    } else if (method == "external.open") {
      const auto url = StringArg(args,"url");
      if ((url.rfind("https://",0) != 0 && url.rfind("http://",0) != 0) || url.find_first_of("\r\n\0",0,3) != std::string::npos) {
        result->Error("url","Only HTTP(S) links can be opened"); return;
      }
      const auto status = reinterpret_cast<INT_PTR>(ShellExecuteW(window_, L"open", Wide(url).c_str(), nullptr, nullptr, SW_SHOWNORMAL));
      if (status <= 32) result->Error("open", "Unable to open link"); else result->Success();
    } else if (method == "appearance") {
      BOOL dark = BoolArg(args,"dark") ? TRUE : FALSE;
      if (BoolArg(args,"system")) {
        DWORD light = 1, size = sizeof(light);
        RegGetValueW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
          L"AppsUseLightTheme",RRF_RT_REG_DWORD,nullptr,&light,&size);
        dark = light == 0;
      }
      DwmSetWindowAttribute(window_, 20, &dark, sizeof(dark));
      const auto mode = BoolArg(args,"black") && dark ? std::string("default") : StringArg(args,"mode");
      const int backdrop = mode == "mica" ? 2 : mode == "acrylic" ? 3 : 1;
      const HRESULT status = DwmSetWindowAttribute(window_, 38, &backdrop, sizeof(backdrop));
      // Windows 11 uses documented DWM backdrops. Older systems can expose
      // acrylic through the dynamically resolved composition API; no hard
      // dependency is introduced. An unavailable effect falls back to opaque.
      struct Accent { int state; DWORD flags, color, animation; } accent{};
      struct Composition { int attribute; void* data; SIZE_T size; } composition{19,&accent,sizeof(accent)};
      using SetComposition = BOOL(WINAPI*)(HWND,Composition*);
      const auto user32 = GetModuleHandleW(L"user32.dll");
      const auto set_composition = user32 ? reinterpret_cast<SetComposition>(GetProcAddress(user32,"SetWindowCompositionAttribute")) : nullptr;
      if (set_composition) set_composition(window_,&composition);
      std::string actual = SUCCEEDED(status) && backdrop != 1 ? mode : "default";
      if (FAILED(status) && backdrop != 1 && set_composition) {
        accent = {4,2,dark ? 0xcc202020u : 0xccf0f0f0u,0};
        if (set_composition(window_,&composition)) actual = "acrylic";
      }
      const int margin = actual == "default" ? 0 : -1;
      MARGINS margins{margin,margin,margin,margin};
      DwmExtendFrameIntoClientArea(window_,&margins);
      result->Success(EncodableValue(actual));
    } else if (method == "update.apply") {
      const auto path = Wide(StringArg(args,"path"));
      HANDLE verified = VerifiedInstaller(path,StringArg(args,"sha256"));
      if (verified == INVALID_HANDLE_VALUE) { result->Error("update","Installer path or SHA256 verification failed"); return; }
      STARTUPINFOW startup{}; startup.cb = sizeof(startup); PROCESS_INFORMATION process{};
      std::wstring command = L"\"" + path + L"\" /S /FREEV6REL";
      const BOOL launched = CreateProcessW(path.c_str(),command.data(),nullptr,nullptr,FALSE,0,nullptr,Root().c_str(),&startup,&process);
      CloseHandle(verified);
      if (!launched) { result->Error("update","Installer could not start; Flux6 remains open"); return; }
      CloseHandle(process.hThread); CloseHandle(process.hProcess);
      exiting_ = true; result->Success(); PostMessageW(window_,WM_CLOSE,0,0);
    } else result->NotImplemented();
  });
  if (FREEV6_LIVE && !probe_) {
    taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
    AddTray(); SetTimer(window_,kPoll,500,nullptr);
  }
}
HostBridge::~HostBridge() {
  KillTimer(window_,kPoll); SetHotkey(false);
  NOTIFYICONDATAW icon{}; icon.cbSize=sizeof(icon); icon.hWnd=window_; icon.uID=1;
  Shell_NotifyIconW(NIM_DELETE,&icon);
  StopHelper();
}
void HostBridge::Event(const char* value) { channel_->InvokeMethod("event",std::make_unique<EncodableValue>(value)); }
void HostBridge::Show() { ShowWindow(window_,SW_RESTORE); SetForegroundWindow(window_); }
bool HostBridge::SetHotkey(bool enabled) {
  if (enabled == hotkey_) return true;
  if (!enabled) { UnregisterHotKey(window_,kHotkey); hotkey_=false; return true; }
  hotkey_ = RegisterHotKey(window_,kHotkey,MOD_NOREPEAT,VK_F6) != FALSE;
  return hotkey_;
}
void HostBridge::AddTray() {
  NOTIFYICONDATAW icon{}; icon.cbSize=sizeof(icon); icon.hWnd=window_; icon.uID=1;
  icon.uFlags=NIF_MESSAGE|NIF_ICON|NIF_TIP; icon.uCallbackMessage=kTray;
  icon.hIcon=LoadIconW(GetModuleHandleW(nullptr),MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(icon.szTip,kTitle); tray_=Shell_NotifyIconW(NIM_ADD,&icon) != FALSE;
}
std::optional<LRESULT> HostBridge::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (!FREEV6_LIVE || probe_) return std::nullopt;
  if (message == taskbar_created_ && taskbar_created_ != 0) { AddTray(); return 0; }
  if (message == WM_HOTKEY && wparam == kHotkey) { Show(); return 0; }
  if (message == WM_TIMER && wparam == kPoll) { PollHelper(); return 0; }
  if (message == WM_SETTINGCHANGE) Event("appearanceChanged");
  if (message == WM_CLOSE && !exiting_) {
    if (tray_) ShowWindow(window_,SW_HIDE); else Event("exitRequested");
    return 0;
  }
  if (message == kTray) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) Show();
    if (lparam == WM_RBUTTONUP) {
      POINT cursor{}; GetCursorPos(&cursor); HMENU menu=CreatePopupMenu();
      AppendMenuW(menu,MF_STRING,1,L"打开 Flux6"); AppendMenuW(menu,MF_STRING,2,L"退出 Flux6");
      SetForegroundWindow(window_);
      const UINT choice=TrackPopupMenu(menu,TPM_RETURNCMD|TPM_NONOTIFY|TPM_RIGHTBUTTON,cursor.x,cursor.y,0,window_,nullptr);
      DestroyMenu(menu); PostMessageW(window_,WM_NULL,0,0);
      if (choice==1) Show(); if (choice==2) { Show(); Event("exitRequested"); }
    }
    return 0;
  }
  return std::nullopt;
}
bool HostBridge::StartHelper(std::string* error) {
  if (helper_) {
    if (WaitForSingleObject(helper_,0)==WAIT_TIMEOUT) return true;
    StopHelper();
  }
  std::array<unsigned char,32> random{};
  if (BCryptGenRandom(nullptr,random.data(),static_cast<ULONG>(random.size()),BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0) { *error="Unable to create helper credentials"; return false; }
  token_=Hex(random.data(),random.size());
  WSADATA winsock{};
  if (WSAStartup(MAKEWORD(2,2),&winsock)!=0) { *error="Winsock initialization failed"; return false; }
  SOCKET socket_handle=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
  sockaddr_in address{}; address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
  int length=sizeof(address);
  bool bound=socket_handle!=INVALID_SOCKET && bind(socket_handle,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0 && getsockname(socket_handle,reinterpret_cast<sockaddr*>(&address),&length)==0;
  if (bound) port_=ntohs(address.sin_port);
  if (socket_handle!=INVALID_SOCKET) closesocket(socket_handle); WSACleanup();
  if (!bound) { *error="Unable to reserve a loopback port"; return false; }
  // Merge inherited environment without modifying the GUI process environment.
  std::map<std::wstring,std::wstring> environment;
  LPWCH block=GetEnvironmentStringsW();
  if (block) {
    for (const wchar_t* p=block; *p; p+=wcslen(p)+1) {
      std::wstring item(p); const auto equal=item.find(L'=',item[0]==L'=' ? 1:0);
      if (equal!=std::wstring::npos) {
        auto key=item.substr(0,equal);
        std::transform(key.begin(),key.end(),key.begin(),[](wchar_t c){ return static_cast<wchar_t>(towupper(c)); });
        environment[key]=item.substr(equal+1);
      }
    }
    FreeEnvironmentStringsW(block);
  }
  environment[L"FREEV6_ROOT"]=Root(); environment[L"FREEV6_API_TOKEN"]=Wide(token_); environment[L"FREEV6_API_PORT"]=std::to_wstring(port_);
  std::vector<wchar_t> env;
  for (const auto& entry:environment) {
    const auto line=entry.first+L"="+entry.second; env.insert(env.end(),line.begin(),line.end()); env.push_back(L'\0');
  }
  env.push_back(L'\0');
  SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES),nullptr,TRUE};
  HANDLE writer=nullptr;
  if (!CreatePipe(&output_,&writer,&security,0)) { *error="Unable to create helper output pipe"; return false; }
  SetHandleInformation(output_,HANDLE_FLAG_INHERIT,0);
  HANDLE input=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,OPEN_EXISTING,0,nullptr);
  STARTUPINFOW startup{}; startup.cb=sizeof(startup); startup.dwFlags=STARTF_USESTDHANDLES;
  startup.hStdOutput=writer; startup.hStdError=writer; startup.hStdInput=input;
  PROCESS_INFORMATION process{};
  const auto helper=Root()+L"\\freev6-helper.exe";
  std::wstring command=L"\""+helper+L"\"";
  const BOOL launched=CreateProcessW(helper.c_str(),command.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW|CREATE_UNICODE_ENVIRONMENT,env.data(),Root().c_str(),&startup,&process);
  const DWORD failure=GetLastError(); CloseHandle(writer); if(input!=INVALID_HANDLE_VALUE) CloseHandle(input);
  if (!launched) { CloseHandle(output_); output_=nullptr; *error="Helper could not start (Windows error "+std::to_string(failure)+")"; return false; }
  CloseHandle(process.hThread); helper_=process.hProcess; return true;
}
void HostBridge::PollHelper() {
  if (output_) {
    DWORD available=0;
    std::string chunk;
    while (chunk.size()<65536 && PeekNamedPipe(output_,nullptr,0,nullptr,&available,nullptr) && available>0) {
      std::array<char,4096> buffer{}; DWORD read=0;
      if (!ReadFile(output_,buffer.data(),std::min<DWORD>(available,static_cast<DWORD>(buffer.size())),&read,nullptr) || read==0) break;
      chunk.append(buffer.data(),read);
    }
    if (!chunk.empty()) {
      std::error_code error;
      const auto state=std::filesystem::path(Root())/L"state";
      std::filesystem::create_directories(state,error);
      const auto log=state/L"helper.log";
      std::ifstream previous(log,std::ios::binary);
      if (previous) {
        previous.seekg(0,std::ios::end);
        const auto size=previous.tellg();
        previous.seekg(size > std::streamoff(128*1024) ? size-std::streamoff(128*1024) : std::streampos(0));
      }
      std::string text((std::istreambuf_iterator<char>(previous)),std::istreambuf_iterator<char>());
      previous.close(); text+=chunk;
      if (text.size()>256*1024) text.erase(0,text.size()-128*1024);
      std::ofstream file(log,std::ios::binary|std::ios::trunc); file.write(text.data(),static_cast<std::streamsize>(text.size()));
    }
  }
  if (helper_ && WaitForSingleObject(helper_,0)!=WAIT_TIMEOUT) { StopHelper(); Show(); Event("helperExited"); }
}
void HostBridge::StopHelper() {
  if (helper_) {
    if (WaitForSingleObject(helper_,0)==WAIT_TIMEOUT) { TerminateProcess(helper_,0); WaitForSingleObject(helper_,3000); }
    CloseHandle(helper_); helper_=nullptr;
  }
  if (output_) { CloseHandle(output_); output_=nullptr; }
}
