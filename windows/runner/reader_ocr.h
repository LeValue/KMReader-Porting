#ifndef KMREADER_READER_OCR_H_
#define KMREADER_READER_OCR_H_
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <memory>

class ReaderOcr {
 public:
  ReaderOcr(flutter::BinaryMessenger* messenger, HWND window);
  ~ReaderOcr();
  static UINT MessageId();
  static void Complete(LPARAM payload);
 private:
  struct Shared;
  std::shared_ptr<Shared> shared_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
