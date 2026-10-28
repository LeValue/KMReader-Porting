#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"
#include "reader_ocr.h"
#include "background_downloads.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project, bool background = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  bool background_;
  bool keep_awake_ = false;
  EXECUTION_STATE previous_execution_ = ES_CONTINUOUS;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> reader_display_channel_;
  std::unique_ptr<BackgroundDownloads> background_downloads_;
  std::unique_ptr<ReaderOcr> reader_ocr_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> privacy_channel_;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
