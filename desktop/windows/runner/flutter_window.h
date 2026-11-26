#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>
#include <vector>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  FlutterWindow(const flutter::DartProject& project, bool start_in_tray);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void NotifyMessage();
  void AddTrayIcon();
  void UpdateTray(const flutter::EncodableMap& snapshot);
  void ShowTrayMenu(POINT anchor);

  UINT taskbar_created_ = 0;
  bool tray_menu_open_ = false;
  bool service_running_ = false;
  bool service_busy_ = true;
  bool can_copy_pairing_ = false;
  bool can_copy_mcp_ = false;
  std::vector<std::wstring> tray_rows_ = {L"正在读取服务状态…"};
  bool notification_icon_added_ = false;
  const bool start_in_tray_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> notification_channel_;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
