#include "texture_bridge.h"

#include <windows.foundation.h>

#include <algorithm>
#include <atomic>
#include <cassert>
#include <iostream>

#include "util/direct3d11.interop.h"

namespace flutter_inappwebview_plugin
{
  const int kNumBuffers = 3;

  TextureBridge::TextureBridge(GraphicsContext* graphics_context,
    ABI::Windows::UI::Composition::IVisual* visual)
    : graphics_context_(graphics_context)
  {
    callback_state_->owner = this;
    capture_owner_thread_ = GetCurrentThreadId();
    capture_item_ =
      graphics_context_->CreateGraphicsCaptureItemFromVisual(visual);
    assert(capture_item_);

    capture_item_->add_Closed(
      Microsoft::WRL::Callback<ABI::Windows::Foundation::ITypedEventHandler<
      ABI::Windows::Graphics::Capture::GraphicsCaptureItem*,
      IInspectable*>>(
        [](ABI::Windows::Graphics::Capture::IGraphicsCaptureItem* item,
          IInspectable* args) -> HRESULT
        {
          std::cerr << "Capture item was closed." << std::endl;
          return S_OK;
        })
      .Get(),
          &on_closed_token_);
  }

  TextureBridge::~TextureBridge()
  {
    // A free-threaded callback can already be in flight after unsubscription.
    // Fence it before destroying fields; subsequent callbacks see no owner.
    {
      const std::lock_guard<std::mutex> lock(callback_state_->gate);
      callback_state_->owner = nullptr;
    }
    Stop();
    if (capture_item_) {
      capture_item_->remove_Closed(on_closed_token_);
    }
  }

  bool TextureBridge::Start()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (is_running_ || !capture_item_) {
      return false;
    }

    ABI::Windows::Graphics::SizeInt32 size;
    capture_item_->get_Size(&size);

    frame_pool_ = graphics_context_->CreateFreeThreadedCaptureFramePool(
      graphics_context_->device(),
      static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(
        kPixelFormat),
      kNumBuffers, size);
    rendering_stats_.free_threaded = static_cast<bool>(frame_pool_);
    if (!frame_pool_) {
      frame_pool_ = graphics_context_->CreateCaptureFramePool(
        graphics_context_->device(),
        static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(kPixelFormat),
        kNumBuffers, size);
    }
    if (!frame_pool_) return false;

    const std::weak_ptr<CallbackState> weak_state = callback_state_;
    using FrameHandler = ABI::Windows::Foundation::ITypedEventHandler<
      ABI::Windows::Graphics::Capture::Direct3D11CaptureFramePool*, IInspectable*>;
    // CreateFreeThreaded invokes this delegate from its own worker. The default
    // WRL delegate is apartment-bound; explicitly aggregate the free-threaded
    // marshaler so delivery never waits for the platform apartment.
    using AgileFrameHandler = Microsoft::WRL::Implements<
      Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
      FrameHandler, Microsoft::WRL::FtmBase>;
    const auto registered = frame_pool_->add_FrameArrived(
      Microsoft::WRL::Callback<AgileFrameHandler>(
        [weak_state](ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool*
          pool, IInspectable* args) -> HRESULT
        {
          if (auto state = weak_state.lock()) {
            const std::lock_guard<std::mutex> lock(state->gate);
            if (state->owner) state->owner->OnFrameArrived();
          }
          return S_OK;
        }).Get(), &on_frame_arrived_token_);
    if (FAILED(registered)) {
      std::cerr << "Registering capture callback failed: " << registered << std::endl;
      return false;
    }

    if (FAILED(frame_pool_->CreateCaptureSession(capture_item_.get(),
      capture_session_.put()))) {
      std::cerr << "Creating capture session failed." << std::endl;
      return false;
    }

    const auto started = capture_session_->StartCapture();
    rendering_stats_.start_result = started;
    if (SUCCEEDED(started)) {
      is_running_ = true;
      return true;
    }

    std::cerr << "Starting capture failed: " << started << std::endl;
    return false;
  }

  void TextureBridge::Stop()
  {
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureSession> session;
    {
      const std::lock_guard<std::mutex> lock(mutex_);
      session = capture_session_;
      StopInternal();
    }
    // Close may wait for a capture callback. Never hold the callback's mutex
    // while doing so: a worker could be waiting to observe is_running_ == false.
    if (session) {
      if (auto closable = session.try_as<ABI::Windows::Foundation::IClosable>()) {
        closable->Close();
      }
    }
  }

  void TextureBridge::StopInternal()
  {
    if (is_running_) {
      is_running_ = false;
      frame_pool_->remove_FrameArrived(on_frame_arrived_token_);
      capture_session_ = nullptr;
      last_frame_ = nullptr;
      capture_frame_ = nullptr;
    }
  }

  void TextureBridge::OnFrameArrived()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (!is_running_) {
      return;
    }

    bool has_frame = false;

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame>
      frame;
    ++rendering_stats_.callbacks;
    auto hr = frame_pool_->TryGetNextFrame(frame.put());
    rendering_stats_.last_frame_result = hr;
    if (SUCCEEDED(hr) && frame) {
      // Present the newest queued capture instead of accumulating latency.
      for (int i = 1; i < kNumBuffers; ++i) {
        winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame> next;
        if (FAILED(frame_pool_->TryGetNextFrame(next.put())) || !next) break;
        frame = std::move(next);
      }
      winrt::com_ptr<
        ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface>
        frame_surface;

      if (SUCCEEDED(frame->get_Surface(frame_surface.put()))) {
        last_frame_ =
          TryGetDXGIInterfaceFromObject<ID3D11Texture2D>(frame_surface);
        capture_frame_ = std::move(frame);
        ++rendering_stats_.captures;
        if (GetCurrentThreadId() == capture_owner_thread_) ++rendering_stats_.ui_thread_captures;
        has_frame = last_frame_ && !ShouldDropFrame();
      }
    }

    if (needs_update_) {
      ABI::Windows::Graphics::SizeInt32 size;
      capture_item_->get_Size(&size);
      frame_pool_->Recreate(
        graphics_context_->device(),
        static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(
          kPixelFormat),
        kNumBuffers, size);
      needs_update_ = false;
    }

    if (has_frame && frame_available_) {
      ++rendering_stats_.notifications;
      frame_available_();
    }
  }

  bool TextureBridge::ShouldDropFrame()
  {
    if (!frame_duration_.has_value()) {
      return false;
    }
    auto now = std::chrono::high_resolution_clock::now();

    bool should_drop_frame = false;
    if (last_frame_timestamp_.has_value()) {
      auto diff = now - last_frame_timestamp_.value();
      should_drop_frame = diff < frame_duration_.value();
    }

    if (!should_drop_frame) {
      last_frame_timestamp_ = now;
    }
    return should_drop_frame;
  }

  TextureBridge::RenderingStats TextureBridge::GetRenderingStats()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    auto stats = rendering_stats_;
    stats.running = is_running_;
    return stats;
  }

  void TextureBridge::NotifySurfaceSizeChanged()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    needs_update_ = true;
  }

  void TextureBridge::SetFpsLimit(std::optional<int> max_fps)
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    auto value = max_fps.value_or(0);
    if (value != 0) {
      frame_duration_ = FrameDuration(1000.0 / value);
    }
    else {
      frame_duration_.reset();
      last_frame_timestamp_.reset();
    }
  }
}