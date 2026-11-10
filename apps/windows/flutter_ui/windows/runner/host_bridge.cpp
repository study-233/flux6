#include "host_bridge.h"
#include <flutter/standard_method_codec.h>

HostBridge::HostBridge(flutter::BinaryMessenger* messenger, HWND window, bool probe) {
  using flutter::EncodableMap;
  using flutter::EncodableValue;
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "dev.freev6.windows/v1", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this, window, probe](const auto& call, auto result) {
    if (call.method_name() == "describe") {
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("version"), EncodableValue(1)},
          {EncodableValue("platform"), EncodableValue("windows")},
          {EncodableValue("preview"), EncodableValue(true)}}));
    } else if (call.method_name() == "finishProbe" && probe) {
      const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
      if (args) {
        const auto it = args->find(EncodableValue("ok"));
        if (it != args->end()) {
          const auto* ok = std::get_if<bool>(&it->second);
          probe_passed_ = ok && *ok;
        }
      }
      result->Success();
      PostMessage(window, WM_CLOSE, 0, 0);
    } else {
      result->NotImplemented();
    }
  });
}
