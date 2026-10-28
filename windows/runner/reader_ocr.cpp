#include "reader_ocr.h"
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.FileProperties.h>
#include <winrt/Windows.Storage.Streams.h>
#include <algorithm>
#include <cmath>
#include <mutex>
#include <string>
#include <stdexcept>
#include <thread>

using flutter::EncodableValue;
using flutter::EncodableMap;
using flutter::EncodableList;
using Result = flutter::MethodResult<EncodableValue>;
namespace {
struct Reply {
  std::unique_ptr<Result> result;
  EncodableValue value;
  std::string error;
};
std::string StringArg(const EncodableMap& args, const char* key) {
  auto it = args.find(EncodableValue(key));
  if (it == args.end()) return {};
  auto value = std::get_if<std::string>(&it->second);
  return value ? *value : std::string();
}
EncodableValue Capabilities() {
  EncodableList languages;
  for (auto language : winrt::Windows::Media::Ocr::OcrEngine::AvailableRecognizerLanguages()) {
    languages.emplace_back(winrt::to_string(language.LanguageTag()));
  }
  return EncodableValue(EncodableMap{{EncodableValue("languages"), EncodableValue(languages)},
    {EncodableValue("offline"), EncodableValue(true)}});
}
EncodableValue Recognize(const EncodableMap& args) {
  using namespace winrt::Windows::Graphics::Imaging;
  using namespace winrt::Windows::Media::Ocr;
  const auto path = StringArg(args,"path"), language = StringArg(args,"language");
  if (path.empty()) throw std::invalid_argument("Image path is missing.");
  auto file = winrt::Windows::Storage::StorageFile::GetFileFromPathAsync(winrt::to_hstring(path)).get();
  if (file.GetBasicPropertiesAsync().get().Size() > 32ULL * 1024 * 1024) {
    throw std::invalid_argument("Choose an image smaller than 32 MiB.");
  }
  auto stream = file.OpenAsync(winrt::Windows::Storage::FileAccessMode::Read).get();
  auto decoder = BitmapDecoder::CreateAsync(stream).get();
  const double max_size = std::min(4096.0,static_cast<double>(OcrEngine::MaxImageDimension()));
  const double scale = std::min(1.0,max_size / std::max(decoder.PixelWidth(),decoder.PixelHeight()));
  BitmapTransform transform;
  transform.ScaledWidth(std::max(1U,static_cast<uint32_t>(decoder.PixelWidth()*scale)));
  transform.ScaledHeight(std::max(1U,static_cast<uint32_t>(decoder.PixelHeight()*scale)));
  auto bitmap = decoder.GetSoftwareBitmapAsync(BitmapPixelFormat::Bgra8,BitmapAlphaMode::Ignore,
    transform,ExifOrientationMode::RespectExifOrientation,ColorManagementMode::DoNotColorManage).get();
  auto engine = language.empty() || language == "auto" ? OcrEngine::TryCreateFromUserProfileLanguages()
    : OcrEngine::TryCreateFromLanguage(winrt::Windows::Globalization::Language(winrt::to_hstring(language)));
  if (!engine) {
    throw std::runtime_error("Install the selected OCR language in Windows Settings > Time & language > Language & region.");
  }
  auto recognized = engine.RecognizeAsync(bitmap).get();
  EncodableList blocks;
  for (auto line : recognized.Lines()) {
    double left = bitmap.PixelWidth(),top = bitmap.PixelHeight(),right = 0,bottom = 0;
    for (auto word : line.Words()) {
      auto box = word.BoundingRect();
      left=std::min(left,static_cast<double>(box.X)); top=std::min(top,static_cast<double>(box.Y));
      right=std::max(right,static_cast<double>(box.X+box.Width)); bottom=std::max(bottom,static_cast<double>(box.Y+box.Height));
    }
    blocks.emplace_back(EncodableMap{
      {EncodableValue("text"),EncodableValue(winrt::to_string(line.Text()))},
      {EncodableValue("x"),EncodableValue(left)},{EncodableValue("y"),EncodableValue(top)},
      {EncodableValue("width"),EncodableValue(std::max(0.0,right-left))},
      {EncodableValue("height"),EncodableValue(std::max(0.0,bottom-top))}});
  }
  EncodableMap value{
    {EncodableValue("width"),EncodableValue(bitmap.PixelWidth())},
    {EncodableValue("height"),EncodableValue(bitmap.PixelHeight())},
    {EncodableValue("text"),EncodableValue(winrt::to_string(recognized.Text()))},
    {EncodableValue("blocks"),EncodableValue(blocks)}};
  bitmap.Close();stream.Close();
  return EncodableValue(value);
}
}  // namespace

struct ReaderOcr::Shared {
  std::mutex mutex;
  bool alive = true;
  HWND window;
};
UINT ReaderOcr::MessageId() {
  static const UINT id = RegisterWindowMessageW(L"dev.levalue.kmreader.ocr.complete");
  return id;
}
ReaderOcr::ReaderOcr(flutter::BinaryMessenger* messenger, HWND window)
    : shared_(std::make_shared<Shared>()) {
  shared_->window = window;
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(messenger,
    "dev.levalue.kmreader/ocr",&flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([shared=shared_](const auto& call,std::unique_ptr<Result> result) {
    const auto method=call.method_name();
    if (method!="recognize" && method!="capabilities") { result->NotImplemented();return; }
    const auto* arguments = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
    auto args = arguments ? *arguments : EncodableMap();
    std::thread([shared,method,args=std::move(args),result=std::move(result)]() mutable {
      auto reply=std::make_unique<Reply>();reply->result=std::move(result);
      try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        reply->value=method=="capabilities"?Capabilities():Recognize(args);
        winrt::uninit_apartment();
      } catch (const winrt::hresult_error& failure) {
        reply->error=winrt::to_string(failure.message());
      } catch (const std::exception& failure) { reply->error=failure.what(); }
      std::lock_guard<std::mutex> lock(shared->mutex);
      if (shared->alive && PostMessageW(shared->window,ReaderOcr::MessageId(),0,reinterpret_cast<LPARAM>(reply.get()))) {
        reply.release();
      }
    }).detach();
  });
}
void ReaderOcr::Complete(LPARAM payload) {
  std::unique_ptr<Reply> reply(reinterpret_cast<Reply*>(payload));
  if (reply->error.empty()) reply->result->Success(reply->value);
  else reply->result->Error("recognition_failed",reply->error);
}
ReaderOcr::~ReaderOcr() {
  channel_->SetMethodCallHandler(nullptr);
  std::lock_guard<std::mutex> lock(shared_->mutex);
  shared_->alive=false;
  MSG message;
  while (PeekMessageW(&message,shared_->window,MessageId(),MessageId(),PM_REMOVE)) {
    delete reinterpret_cast<Reply*>(message.lParam);
  }
}
