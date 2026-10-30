#include "flutter_window.h"

#include <optional>
#include <filesystem>
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
    if(call.method_name()=="getAppIcon") {
      const bool valid=alternate_icon_ && reinterpret_cast<HICON>(SendMessage(GetHandle(),WM_GETICON,ICON_BIG,0))==alternate_icon_;
      result->Success(flutter::EncodableValue(flutter::EncodableMap{{flutter::EncodableValue("name"),flutter::EncodableValue(app_icon_name_)},{flutter::EncodableValue("valid"),flutter::EncodableValue(valid)}}));return;
    }
    if(call.method_name()=="setAppIcon") {
      const auto* name=call.arguments()?std::get_if<std::string>(call.arguments()):nullptr;
      if(!name || (*name!="default" && *name!="classic" && *name!="legacy")) {result->Error("icon","Unknown app icon");return;}
      wchar_t executable[32768];
      const DWORD length=GetModuleFileNameW(nullptr,executable,32768);
      if(length==0 || length>=32768) {result->Error("icon","Cannot locate app icon");return;}
      const auto file=std::filesystem::path(executable).parent_path()/"data"/"flutter_assets"/"assets"/"app_icons"/(*name+".ico");
      const HICON icon=static_cast<HICON>(LoadImageW(nullptr,file.c_str(),IMAGE_ICON,0,0,LR_LOADFROMFILE | LR_DEFAULTSIZE));
      if(!icon) {result->Error("icon","Cannot load app icon");return;}
      SendMessage(GetHandle(),WM_SETICON,ICON_BIG,reinterpret_cast<LPARAM>(icon));
      SendMessage(GetHandle(),WM_SETICON,ICON_SMALL,reinterpret_cast<LPARAM>(icon));
      if(alternate_icon_) DestroyIcon(alternate_icon_);
      alternate_icon_=icon;
      app_icon_name_=*name;
      result->Success();return;
    }
    const auto* enabled=call.arguments()?std::get_if<bool>(call.arguments()):nullptr;
    if(call.method_name()!="setProtected" || !enabled) {result->NotImplemented();return;}
    if(!SetWindowDisplayAffinity(GetHandle(),*enabled?WDA_EXCLUDEFROMCAPTURE:WDA_NONE) && *enabled) {
      SetWindowDisplayAffinity(GetHandle(),WDA_MONITOR);
    }
    result->Success();
  });
  reader_display_channel_=std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
    flutter_controller_->engine()->messenger(),"dev.levalue.kmreader/reader_display",&flutter::StandardMethodCodec::GetInstance());
  reader_display_channel_->SetMethodCallHandler([this](const auto& call,auto result) {
#ifndef NDEBUG
    // Integration tests exercise the real WM_MOUSEWHEEL -> engine path. Never
    // expose synthetic native input in release builds.
    if(call.method_name()=="testMouseWheel") {
      const auto* args=call.arguments()?std::get_if<flutter::EncodableMap>(call.arguments()):nullptr;
      if(!args) {result->Error("input","Expected wheel arguments");return;}
      const auto x=args->find(flutter::EncodableValue("x"));
      const auto y=args->find(flutter::EncodableValue("y"));
      const auto delta=args->find(flutter::EncodableValue("delta"));
      if(x==args->end() || y==args->end() || delta==args->end() ||
          !std::holds_alternative<double>(x->second) || !std::holds_alternative<double>(y->second) ||
          !std::holds_alternative<int32_t>(delta->second)) {result->Error("input","Invalid wheel arguments");return;}
      const auto amount=std::get<int32_t>(delta->second);
      const HWND view=flutter_controller_->view()->GetNativeWindow();
      POINT point{static_cast<LONG>(std::get<double>(x->second)),static_cast<LONG>(std::get<double>(y->second))};
      RECT bounds;GetClientRect(view,&bounds);
      if(!PtInRect(&bounds,point) || amount==0 || amount < -1200 || amount > 1200) {result->Error("input","Wheel input out of bounds");return;}
      POINT previous;GetCursorPos(&previous);
      ClientToScreen(view,&point);SetCursorPos(point.x,point.y);
      SendMessage(view,WM_MOUSEWHEEL,MAKEWPARAM(0,static_cast<WORD>(amount)),MAKELPARAM(point.x,point.y));
      SetCursorPos(previous.x,previous.y);
      result->Success();return;
    }
#endif
    if(call.method_name()=="getKeepAwake") {result->Success(flutter::EncodableValue(keep_awake_));return;}
    const auto* enabled=call.arguments()?std::get_if<bool>(call.arguments()):nullptr;
    if(call.method_name()=="getFullscreen") {result->Success(flutter::EncodableValue(fullscreen_ && (GetWindowLongPtr(GetHandle(),GWL_STYLE) & WS_OVERLAPPEDWINDOW)==0));return;}
    if(call.method_name()=="setFullscreen" && enabled) {
      const HWND window=GetHandle();
      if(*enabled!=fullscreen_) {
        if(*enabled) {
          window_style_=GetWindowLongPtr(window,GWL_STYLE);
          window_placement_.length=sizeof(window_placement_);
          GetWindowPlacement(window,&window_placement_);
          MONITORINFO monitor{sizeof(MONITORINFO)};
          if(GetMonitorInfo(MonitorFromWindow(window,MONITOR_DEFAULTTONEAREST),&monitor)) {
            SetWindowLongPtr(window,GWL_STYLE,window_style_ & ~WS_OVERLAPPEDWINDOW);
            SetWindowPos(window,HWND_TOP,monitor.rcMonitor.left,monitor.rcMonitor.top,
              monitor.rcMonitor.right-monitor.rcMonitor.left,monitor.rcMonitor.bottom-monitor.rcMonitor.top,SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
            fullscreen_=true;
          }
        } else {
          SetWindowLongPtr(window,GWL_STYLE,window_style_);
          SetWindowPlacement(window,&window_placement_);
          SetWindowPos(window,nullptr,0,0,0,0,SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
          fullscreen_=false;
        }
      }
      result->Success();return;
    }
    if(call.method_name()!="setKeepAwake" || !enabled) {result->NotImplemented();return;}
    if(*enabled && !keep_awake_) {
      previous_execution_=SetThreadExecutionState(ES_CONTINUOUS|ES_DISPLAY_REQUIRED|ES_SYSTEM_REQUIRED);
      keep_awake_=previous_execution_!=0;
      if(!keep_awake_) {result->Error("wake_unavailable","Windows could not keep the display awake.");return;}
    } else if(!*enabled && keep_awake_) {
      SetThreadExecutionState(previous_execution_|ES_CONTINUOUS);keep_awake_=false;
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
  if(alternate_icon_) {
    SendMessage(GetHandle(),WM_SETICON,ICON_BIG,0);
    SendMessage(GetHandle(),WM_SETICON,ICON_SMALL,0);
    DestroyIcon(alternate_icon_);alternate_icon_=nullptr;
  }
  if(reader_display_channel_) {reader_display_channel_->SetMethodCallHandler(nullptr);reader_display_channel_.reset();}
  if(keep_awake_) {SetThreadExecutionState(previous_execution_|ES_CONTINUOUS);keep_awake_=false;}
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
