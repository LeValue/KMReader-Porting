#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool background)
    : background_(background), project_(project) {}

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
  background_downloads_=std::make_unique<BackgroundDownloads>(flutter_controller_->engine()->messenger());
  reader_ocr_=std::make_unique<ReaderOcr>(flutter_controller_->engine()->messenger(),GetHandle());
  privacy_channel_=std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
    flutter_controller_->engine()->messenger(),"dev.levalue.kmreader/privacy",&flutter::StandardMethodCodec::GetInstance());
  privacy_channel_->SetMethodCallHandler([this](const auto& call,auto result) {
    const auto* enabled=call.arguments()?std::get_if<bool>(call.arguments()):nullptr;
    if(call.method_name()!="setProtected" || !enabled) {result->NotImplemented();return;}
    if(!SetWindowDisplayAffinity(GetHandle(),*enabled?WDA_EXCLUDEFROMCAPTURE:WDA_NONE) && *enabled) {
      SetWindowDisplayAffinity(GetHandle(),WDA_MONITOR);
    }
    result->Success();
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!background_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  background_downloads_.reset();
  if(privacy_channel_) {privacy_channel_->SetMethodCallHandler(nullptr);privacy_channel_.reset();}
  reader_ocr_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if(message==ReaderOcr::MessageId()) {ReaderOcr::Complete(lparam);return 0;}
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
