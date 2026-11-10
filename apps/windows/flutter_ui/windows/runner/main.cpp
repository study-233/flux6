#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  const bool probe = std::find(command_line_arguments.begin(), command_line_arguments.end(), "--host-probe") != command_line_arguments.end();
#if FREEV6_LIVE
  const bool autostart = std::find(command_line_arguments.begin(), command_line_arguments.end(), "--autostart") != command_line_arguments.end();
  if (!probe && autostart && !HostBridge::AutostartAllowed()) { CoUninitialize(); return EXIT_SUCCESS; }
  HANDLE singleton = probe ? nullptr : CreateMutexW(nullptr, FALSE, L"Local\\freev6-desktop-single-instance");
  const DWORD singleton_error = GetLastError();
  if (!probe && (!singleton || singleton_error == ERROR_ALREADY_EXISTS)) {
    HWND existing = FindWindowW(nullptr, L"FreeV6");
    if (existing) { ShowWindow(existing, SW_RESTORE); SetForegroundWindow(existing); }
    else MessageBoxW(nullptr, L"FreeV6 已在运行。请从系统托盘打开；测试 Flutter 版本前请先退出旧版。", L"FreeV6", MB_OK | MB_ICONINFORMATION);
    if (singleton) CloseHandle(singleton);
    CoUninitialize(); return EXIT_SUCCESS;
  }
#endif
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, probe);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(FREEV6_LIVE ? L"FreeV6" : L"FreeV6 Windows Preview", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
#if FREEV6_LIVE
  if (singleton) CloseHandle(singleton);
#endif
  return probe && !window.probe_passed() ? EXIT_FAILURE : EXIT_SUCCESS;
}
