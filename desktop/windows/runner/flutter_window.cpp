#include "flutter_window.h"

#include <cwchar>
#include <optional>
#include <shellapi.h>
#include <windowsx.h>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayIcon = 1;
constexpr UINT kToggleService = 1;
constexpr UINT kOpenDashboard = 2;
constexpr UINT kQuit = 3;
constexpr UINT kCopyPairing = 4;
constexpr UINT kCopyAiSetup = 5;

NOTIFYICONDATAW TrayIcon(HWND window) {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = window;
  icon.uID = kTrayIcon;
  return icon;
}

std::wstring FromUtf8(const std::string& text) {
  if (text.empty()) return {};
  const int length = static_cast<int>(text.size());
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.data(), length, nullptr, 0);
  std::wstring result(size, L'\0');
  if (size > 0) {
    MultiByteToWideChar(CP_UTF8, 0, text.data(), length, result.data(), size);
  }
  return result;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) return false;

  HWND window = GetHandle();
  // Keep the native sizing border and window system commands.
  const LONG_PTR style = GetWindowLongPtr(window, GWL_STYLE);
  SetWindowLongPtr(window, GWL_STYLE, style & ~static_cast<LONG_PTR>(WS_CAPTION));
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);

  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  notification_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "com.reareyes/desktop",
          &flutter::StandardMethodCodec::GetInstance());
  notification_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const auto& method = call.method_name();
        HWND window = GetHandle();
        if (method == "messageReceived") {
          NotifyMessage();
        } else if (method == "updateTray") {
          const auto* snapshot =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (snapshot) UpdateTray(*snapshot);
        } else if (method == "dragWindow") {
          POINT point{};
          if ((GetKeyState(VK_LBUTTON) & 0x8000) && GetCursorPos(&point)) {
            ReleaseCapture();
            PostMessage(window, WM_NCLBUTTONDOWN, HTCAPTION,
                        MAKELPARAM(point.x, point.y));
          }
        } else if (method == "maximizeWindow") {
          ShowWindow(window, IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
        } else if (method == "minimizeWindow") {
          ShowWindow(window, SW_MINIMIZE);
        } else if (method == "hideWindow") {
          PostMessage(window, WM_CLOSE, 0, 0);
        } else {
          result->NotImplemented();
          return;
        }
        result->Success();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([this]() { Show(); });
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::AddTrayIcon() {
  auto icon = TrayIcon(GetHandle());
  icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"Robot Eyes");
  notification_icon_added_ = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
  if (notification_icon_added_) {
    icon.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &icon);
  }
}

void FlutterWindow::UpdateTray(const flutter::EncodableMap& snapshot) {
  auto flag = [&snapshot](const char* key) {
    const auto found = snapshot.find(flutter::EncodableValue(std::string(key)));
    const auto* value = found == snapshot.end()
                            ? nullptr
                            : std::get_if<bool>(&found->second);
    return value && *value;
  };
  service_running_ = flag("running");
  service_busy_ = flag("busy");
  can_copy_pairing_ = flag("canCopyPairing");
  can_copy_mcp_ = flag("canCopyMcp");
  const auto found = snapshot.find(flutter::EncodableValue(std::string("rows")));
  if (found == snapshot.end()) return;
  const auto* rows = std::get_if<flutter::EncodableList>(&found->second);
  if (!rows) return;
  tray_rows_.clear();
  for (const auto& row : *rows) {
    if (const auto* value = std::get_if<std::string>(&row)) {
      tray_rows_.push_back(FromUtf8(*value));
    }
  }
}

void FlutterWindow::ShowTrayMenu(POINT anchor) {
  if (tray_menu_open_) return;
  HWND window = GetHandle();
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  tray_menu_open_ = true;
  AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, L"Robot Eyes");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  for (const auto& row : tray_rows_) {
    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, row.c_str());
  }
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING | (service_busy_ ? MF_GRAYED : MF_ENABLED),
              kToggleService, service_busy_ ? L"切换中…" :
                  (service_running_ ? L"停止服务" : L"启动服务"));
  HMENU copy_menu = CreatePopupMenu();
  if (copy_menu) {
    const UINT pairing_state = can_copy_pairing_ ? MF_ENABLED : MF_GRAYED;
    const UINT mcp_state = can_copy_mcp_ ? MF_ENABLED : MF_GRAYED;
    AppendMenuW(copy_menu, MF_STRING | pairing_state, kCopyPairing, L"手机配对配置");
    AppendMenuW(copy_menu, MF_STRING | mcp_state, kCopyAiSetup, L"复制给 AI 配置");
    const UINT copy_state = can_copy_pairing_ || can_copy_mcp_ ? MF_ENABLED : MF_GRAYED;
    if (!AppendMenuW(menu, MF_POPUP | copy_state, reinterpret_cast<UINT_PTR>(copy_menu),
                     L"复制配置")) {
      DestroyMenu(copy_menu);
    }
  }
  AppendMenuW(menu, MF_STRING, kOpenDashboard, L"打开主窗口");
  AppendMenuW(menu, MF_STRING, kQuit, L"退出");

  NOTIFYICONIDENTIFIER id{};
  id.cbSize = sizeof(id);
  id.hWnd = window;
  id.uID = kTrayIcon;
  TPMPARAMS placement{};
  placement.cbSize = sizeof(placement);
  const bool has_icon_rect =
      SUCCEEDED(Shell_NotifyIconGetRect(&id, &placement.rcExclude));
  if (anchor.x == -1 && anchor.y == -1) {
    if (has_icon_rect) {
      anchor = {placement.rcExclude.right, placement.rcExclude.top};
    } else {
      GetCursorPos(&anchor);
    }
  }

  SetForegroundWindow(window);
  const auto command = TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTALIGN | TPM_BOTTOMALIGN |
                TPM_RIGHTBUTTON | TPM_WORKAREA,
      anchor.x, anchor.y, window, has_icon_rect ? &placement : nullptr);
  PostMessage(window, WM_NULL, 0, 0);
  DestroyMenu(menu);
  tray_menu_open_ = false;

  if (command == kToggleService && !service_busy_ && notification_channel_) {
    notification_channel_->InvokeMethod("toggleService", nullptr);
  } else if (command == kOpenDashboard) {
    ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(window);
  } else if (command == kQuit) {
    DestroyWindow(window);
  }
  const char* configuration = nullptr;
  switch (command) {
    case kCopyPairing: configuration = "pairing"; break;
    case kCopyAiSetup: configuration = "aiSetup"; break;
  }
  if (configuration && notification_channel_) {
    notification_channel_->InvokeMethod(
        "copyConfiguration",
        std::make_unique<flutter::EncodableValue>(std::string(configuration)));
  }
  if (command == 0 && notification_icon_added_) {
    auto icon = TrayIcon(window);
    Shell_NotifyIconW(NIM_SETFOCUS, &icon);
  }
}

void FlutterWindow::NotifyMessage() {
  HWND window = GetHandle();
  if (GetForegroundWindow() == window && IsWindowVisible(window)) return;

  FLASHWINFO flash{sizeof(FLASHWINFO), window, FLASHW_TRAY, 3, 0};
  FlashWindowEx(&flash);

  if (!notification_icon_added_) AddTrayIcon();
  if (!notification_icon_added_) return;
  auto notification = TrayIcon(window);
  notification.uFlags = NIF_INFO;
  wcscpy_s(notification.szInfoTitle, L"Robot Eyes");
  wcscpy_s(notification.szInfo, L"收到一条手机消息");
  notification.dwInfoFlags = NIIF_INFO;
  Shell_NotifyIconW(NIM_MODIFY, &notification);
}

void FlutterWindow::OnDestroy() {
  notification_channel_.reset();
  flutter_controller_.reset();
  Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (taskbar_created_ != 0 && message == taskbar_created_) {
    AddTrayIcon();
    if (!notification_icon_added_ && !IsWindowVisible(hwnd)) Show();
    return 0;
  }

  switch (message) {
    case kTrayMessage: {
      const auto event = LOWORD(lparam);
      if (event == NIN_SELECT || event == NIN_KEYSELECT ||
          event == WM_CONTEXTMENU) {
        ShowTrayMenu({GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam)});
      }
      return 0;
    }
    case WM_CLOSE:
      if (notification_icon_added_) {
        ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      break;
    case WM_GETMINMAXINFO: {
      DefWindowProc(hwnd, message, wparam, lparam);
      const UINT dpi = GetDpiForWindow(hwnd);
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      limits->ptMinTrackSize = {MulDiv(536, dpi, 96), MulDiv(436, dpi, 96)};
      return 0;
    }
    case WM_DESTROY:
      if (notification_icon_added_) {
        auto icon = TrayIcon(hwnd);
        Shell_NotifyIconW(NIM_DELETE, &icon);
        notification_icon_added_ = false;
      }
      break;
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result && message != WM_DESTROY) return *result;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
