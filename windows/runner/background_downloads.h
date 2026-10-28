#ifndef KMREADER_BACKGROUND_DOWNLOADS_H_
#define KMREADER_BACKGROUND_DOWNLOADS_H_
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>

class BackgroundDownloads {
 public:
  explicit BackgroundDownloads(flutter::BinaryMessenger* messenger);
  ~BackgroundDownloads();
 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
