#ifndef FREEV6_HOST_BRIDGE_H_
#define FREEV6_HOST_BRIDGE_H_
#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include <memory>

class HostBridge {
 public:
  HostBridge(flutter::BinaryMessenger* messenger, HWND window, bool probe);
  bool probe_passed() const { return probe_passed_; }
 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool probe_passed_ = false;
};
#endif
