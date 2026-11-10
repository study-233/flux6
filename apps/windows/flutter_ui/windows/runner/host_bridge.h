#ifndef FREEV6_HOST_BRIDGE_H_
#define FREEV6_HOST_BRIDGE_H_
#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include <memory>
#include <optional>
#include <string>

class HostBridge {
 public:
  HostBridge(flutter::BinaryMessenger* messenger, HWND window, bool probe);
  ~HostBridge();
  bool probe_passed() const { return probe_passed_; }
  bool should_show() const;
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
  static std::wstring Root();
  static bool AutostartAllowed();
 private:
  bool StartHelper(std::string* error);
  void StopHelper();
  bool SetHotkey(bool enabled);
  void Show();
  void Event(const char* event);
  void PollHelper();
  void AddTray();
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  HANDLE helper_ = nullptr, output_ = nullptr;
  bool probe_, probe_passed_ = false, exiting_ = false, tray_ = false, hotkey_ = false;
  std::string token_;
  int port_ = 0;
  UINT taskbar_created_ = 0;
};
#endif
