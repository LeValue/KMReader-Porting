#pragma once

#include <windows.graphics.capture.h>
#include <wrl.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <cstdint>
#include <functional>
#include <mutex>
#include <optional>

#include "graphics_context.h"

namespace flutter_inappwebview_plugin
{
  typedef struct {
    size_t width;
    size_t height;
  } Size;

  class TextureBridge {
  public:
    typedef std::function<void()> FrameAvailableCallback;
    typedef std::function<void(Size size)> SurfaceSizeChangedCallback;
    typedef std::chrono::duration<double, std::milli> FrameDuration;

    TextureBridge(GraphicsContext* graphics_context,
      ABI::Windows::UI::Composition::IVisual* visual);
    virtual ~TextureBridge();

    struct RenderingStats {
      bool free_threaded = false, running = false;
      bool capture_interval_supported = false;
      int64_t captures = 0, notifications = 0, surface_requests = 0, gpu_copies = 0;
      int64_t ui_thread_captures = 0, callbacks = 0;
      int32_t last_frame_result = 0, start_result = 0;
      int64_t capture_interval_before_100ns = -1, capture_interval_100ns = -1;
      int32_t capture_interval_result = E_NOTIMPL;
    };
    RenderingStats GetRenderingStats();

    bool Start();
    void Stop();

    void SetOnFrameAvailable(FrameAvailableCallback callback)
    {
      frame_available_ = std::move(callback);
    }

    void SetOnSurfaceSizeChanged(SurfaceSizeChangedCallback callback)
    {
      surface_size_changed_ = std::move(callback);
    }

    void NotifySurfaceSizeChanged();
    void SetFpsLimit(std::optional<int> max_fps);

  protected:
    struct CallbackState {
      std::mutex gate;
      TextureBridge* owner = nullptr;
    };
    std::shared_ptr<CallbackState> callback_state_ = std::make_shared<CallbackState>();
    RenderingStats rendering_stats_;
    DWORD capture_owner_thread_ = 0;
    bool is_running_ = false;

    const GraphicsContext* graphics_context_;
    std::mutex mutex_;
    std::optional<FrameDuration> frame_duration_ = std::nullopt;

    FrameAvailableCallback frame_available_;
    SurfaceSizeChangedCallback surface_size_changed_;
    std::atomic<bool> needs_update_ = false;
    winrt::com_ptr<ID3D11Texture2D> last_frame_;
    // Keep the pooled capture leased until its texture has been copied.
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame> capture_frame_;
    std::optional<std::chrono::high_resolution_clock::time_point>
      last_frame_timestamp_;

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>
      capture_item_;
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
      frame_pool_;
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureSession>
      capture_session_;

    EventRegistrationToken on_closed_token_ = {};
    EventRegistrationToken on_frame_arrived_token_ = {};

    virtual void StopInternal();
    void OnFrameArrived();
    bool ShouldDropFrame();

    // corresponds to DXGI_FORMAT_B8G8R8A8_UNORM
    static constexpr auto kPixelFormat = ABI::Windows::Graphics::DirectX::
      DirectXPixelFormat::DirectXPixelFormat_B8G8R8A8UIntNormalized;
  };
}
