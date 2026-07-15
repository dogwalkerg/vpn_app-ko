#include "flutter_window.h"

#include <iphlpapi.h>
#include <wininet.h>

#include <cstdint>
#include <intrin.h>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

constexpr char kSystemProxyChannel[] = "osca/windows_proxy";
constexpr wchar_t kProxyServer[] = L"127.0.0.1:7890";
constexpr wchar_t kProxyBypass[] = L"<local>;localhost;127.*";

std::set<DWORD> ListenerPidsForPort(USHORT port) {
  std::set<DWORD> pids;

  DWORD ipv4_size = 0;
  if (GetExtendedTcpTable(nullptr, &ipv4_size, FALSE, AF_INET,
                          TCP_TABLE_OWNER_PID_LISTENER, 0) ==
      ERROR_INSUFFICIENT_BUFFER) {
    std::vector<unsigned char> buffer(ipv4_size);
    if (GetExtendedTcpTable(buffer.data(), &ipv4_size, FALSE, AF_INET,
                            TCP_TABLE_OWNER_PID_LISTENER, 0) == NO_ERROR) {
      const auto* table =
          reinterpret_cast<const MIB_TCPTABLE_OWNER_PID*>(buffer.data());
      for (DWORD index = 0; index < table->dwNumEntries; ++index) {
        const auto& row = table->table[index];
        const auto local_port =
            _byteswap_ushort(static_cast<USHORT>(row.dwLocalPort));
        const auto* address =
            reinterpret_cast<const unsigned char*>(&row.dwLocalAddr);
        if (local_port == port && address[0] == 127 && address[1] == 0 &&
            address[2] == 0 && address[3] == 1) {
          pids.insert(row.dwOwningPid);
        }
      }
    }
  }

  return pids;
}

bool ProcessPathMatches(DWORD pid, const std::wstring& expected_path) {
  HANDLE process =
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) {
    return false;
  }
  std::vector<wchar_t> actual_path(32768);
  DWORD actual_length = static_cast<DWORD>(actual_path.size());
  const bool read = QueryFullProcessImageNameW(
      process, 0, actual_path.data(), &actual_length);
  CloseHandle(process);
  if (!read) {
    return false;
  }

  std::vector<wchar_t> normalized_expected(32768);
  const DWORD expected_length = GetFullPathNameW(
      expected_path.c_str(), static_cast<DWORD>(normalized_expected.size()),
      normalized_expected.data(), nullptr);
  if (expected_length == 0 ||
      expected_length >= normalized_expected.size()) {
    return false;
  }
  return CompareStringOrdinal(
             actual_path.data(), static_cast<int>(actual_length),
             normalized_expected.data(), static_cast<int>(expected_length),
             TRUE) == CSTR_EQUAL;
}

bool ValidateManagedCore(const std::wstring& expected_path,
                         DWORD expected_pid) {
  const auto mixed_port_pids = ListenerPidsForPort(7890);
  const auto controller_port_pids = ListenerPidsForPort(9090);
  if (mixed_port_pids.size() != 1 || controller_port_pids.size() != 1 ||
      *mixed_port_pids.begin() != *controller_port_pids.begin()) {
    return false;
  }
  const DWORD listener_pid = *mixed_port_pids.begin();
  return (expected_pid == 0 || expected_pid == listener_pid) &&
         ProcessPathMatches(listener_pid, expected_path);
}

struct SystemProxyState {
  bool enabled = false;
  DWORD flags = PROXY_TYPE_DIRECT;
  std::wstring server;
  std::wstring bypass;
  std::wstring auto_config_url;
};

std::optional<SystemProxyState> previous_proxy_state;

bool QuerySystemProxy(SystemProxyState* state, DWORD* error) {
  INTERNET_PER_CONN_OPTIONW options[4] = {};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;

  INTERNET_PER_CONN_OPTION_LISTW list = {};
  list.dwSize = sizeof(list);
  list.dwOptionCount = ARRAYSIZE(options);
  list.pOptions = options;

  DWORD size = sizeof(list);
  if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                            &list, &size)) {
    *error = GetLastError();
    return false;
  }

  state->flags = options[0].Value.dwValue;
  state->enabled = (state->flags & PROXY_TYPE_PROXY) != 0;
  if (options[1].Value.pszValue != nullptr) {
    state->server = options[1].Value.pszValue;
    GlobalFree(options[1].Value.pszValue);
  }
  if (options[2].Value.pszValue != nullptr) {
    state->bypass = options[2].Value.pszValue;
    GlobalFree(options[2].Value.pszValue);
  }
  if (options[3].Value.pszValue != nullptr) {
    state->auto_config_url = options[3].Value.pszValue;
    GlobalFree(options[3].Value.pszValue);
  }
  return true;
}

bool WriteSystemProxy(const SystemProxyState& desired,
                      SystemProxyState* verified, DWORD* error) {
  INTERNET_PER_CONN_OPTIONW options[4] = {};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = desired.flags;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = const_cast<wchar_t*>(desired.server.c_str());
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue = const_cast<wchar_t*>(desired.bypass.c_str());
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[3].Value.pszValue =
      const_cast<wchar_t*>(desired.auto_config_url.c_str());

  INTERNET_PER_CONN_OPTION_LISTW list = {};
  list.dwSize = sizeof(list);
  list.dwOptionCount = ARRAYSIZE(options);
  list.pOptions = options;

  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                          &list, sizeof(list))) {
    *error = GetLastError();
    return false;
  }
  if (list.dwOptionError != 0) {
    *error = list.dwOptionError;
    return false;
  }
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr,
                          0) ||
      !InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0)) {
    *error = GetLastError();
    return false;
  }

  if (!SendNotifyMessageW(
      HWND_BROADCAST, WM_SETTINGCHANGE, 0,
      reinterpret_cast<LPARAM>(
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"))) {
    *error = GetLastError();
    return false;
  }

  if (!QuerySystemProxy(verified, error)) {
    return false;
  }
  const bool desired_enabled = (desired.flags & PROXY_TYPE_PROXY) != 0;
  if (verified->enabled != desired_enabled ||
      (desired_enabled && verified->server != desired.server)) {
    *error = ERROR_INVALID_DATA;
    return false;
  }
  return true;
}

bool ApplySystemProxy(bool enabled, SystemProxyState* verified, DWORD* error) {
  SystemProxyState desired;
  if (enabled) {
    if (!previous_proxy_state.has_value()) {
      SystemProxyState current;
      if (!QuerySystemProxy(&current, error)) {
        return false;
      }
      if (current.enabled && current.server == kProxyServer) {
        current.enabled = false;
        current.flags = PROXY_TYPE_DIRECT;
      }
      previous_proxy_state = current;
    }
    desired.enabled = true;
    desired.flags = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;
    desired.server = kProxyServer;
    desired.bypass = kProxyBypass;
  } else if (previous_proxy_state.has_value()) {
    desired = previous_proxy_state.value();
  }

  if (!WriteSystemProxy(desired, verified, error)) {
    return false;
  }
  if (!enabled) {
    previous_proxy_state.reset();
  }
  return true;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  system_proxy_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kSystemProxyChannel,
          &flutter::StandardMethodCodec::GetInstance());
  system_proxy_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "validateCore") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_arguments", "Expected a map argument");
            return;
          }
          const auto path_entry =
              arguments->find(flutter::EncodableValue("path"));
          if (path_entry == arguments->end() ||
              !std::holds_alternative<std::string>(path_entry->second)) {
            result->Error("invalid_arguments", "Missing core path");
            return;
          }
          DWORD expected_pid = 0;
          const auto pid_entry =
              arguments->find(flutter::EncodableValue("pid"));
          if (pid_entry != arguments->end()) {
            if (const auto* pid32 =
                    std::get_if<int32_t>(&pid_entry->second)) {
              expected_pid = static_cast<DWORD>(*pid32);
            } else if (const auto* pid64 =
                           std::get_if<int64_t>(&pid_entry->second)) {
              expected_pid = static_cast<DWORD>(*pid64);
            }
          }
          const auto expected_path = Utf16FromUtf8(
              std::get<std::string>(path_entry->second));
          result->Success(flutter::EncodableValue(
              !expected_path.empty() &&
              ValidateManagedCore(expected_path, expected_pid)));
          return;
        }

        if (call.method_name() == "apply") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_arguments", "Expected a map argument");
            return;
          }
          const auto enabled_entry =
              arguments->find(flutter::EncodableValue("enabled"));
          if (enabled_entry == arguments->end() ||
              !std::holds_alternative<bool>(enabled_entry->second)) {
            result->Error("invalid_arguments", "Missing enabled flag");
            return;
          }
          const bool enabled = std::get<bool>(enabled_entry->second);
          SystemProxyState state;
          DWORD error = ERROR_SUCCESS;
          if (!ApplySystemProxy(enabled, &state, &error)) {
            result->Error("system_proxy_failed",
                          "Windows rejected the system proxy settings",
                          flutter::EncodableValue(
                              static_cast<int64_t>(error)));
            return;
          }
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("enabled"),
               flutter::EncodableValue(state.enabled)},
              {flutter::EncodableValue("flags"),
               flutter::EncodableValue(static_cast<int64_t>(state.flags))},
              {flutter::EncodableValue("server"),
               flutter::EncodableValue(Utf8FromUtf16(state.server.c_str()))},
          }));
          return;
        }

        if (call.method_name() == "read") {
          SystemProxyState state;
          DWORD error = ERROR_SUCCESS;
          if (!QuerySystemProxy(&state, &error)) {
            result->Error("system_proxy_query_failed",
                          "Windows could not read the system proxy settings",
                          flutter::EncodableValue(
                              static_cast<int64_t>(error)));
            return;
          }
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("enabled"),
               flutter::EncodableValue(state.enabled)},
              {flutter::EncodableValue("flags"),
               flutter::EncodableValue(static_cast<int64_t>(state.flags))},
              {flutter::EncodableValue("server"),
               flutter::EncodableValue(Utf8FromUtf16(state.server.c_str()))},
          }));
          return;
        }

        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  system_proxy_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
