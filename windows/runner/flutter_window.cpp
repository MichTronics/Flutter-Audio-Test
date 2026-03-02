#include "flutter_window.h"

#include <mmsystem.h>
#include <optional>
#include <list>
#include <string>
#include <vector>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

#pragma comment(lib, "winmm.lib")

namespace {

class NativeLoopbackPlayer {
 public:
  NativeLoopbackPlayer() = default;
  ~NativeLoopbackPlayer() { Stop(); }

  bool Start(int sample_rate, int channels, std::string& error) {
    Stop();

    if (channels < 1 || channels > 2) {
      error = "Unsupported channel count";
      return false;
    }

    WAVEFORMATEX format{};
    format.wFormatTag = WAVE_FORMAT_PCM;
    format.nChannels = static_cast<WORD>(channels);
    format.nSamplesPerSec = static_cast<DWORD>(sample_rate);
    format.wBitsPerSample = 16;
    format.nBlockAlign =
        static_cast<WORD>(format.nChannels * (format.wBitsPerSample / 8));
    format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;

    MMRESULT result = waveOutOpen(&wave_out_, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL);
    if (result != MMSYSERR_NOERROR) {
      wave_out_ = nullptr;
      error = "waveOutOpen failed";
      return false;
    }

    started_ = true;
    return true;
  }

  bool Push(const std::vector<uint8_t>& data, std::string& error) {
    if (!started_ || wave_out_ == nullptr) {
      error = "Loopback not started";
      return false;
    }

    if (data.empty()) {
      return true;
    }

    CleanupDoneBuffers();

    auto item = std::make_unique<BufferItem>();
    item->bytes = data;
    ZeroMemory(&item->header, sizeof(WAVEHDR));
    item->header.lpData = reinterpret_cast<LPSTR>(item->bytes.data());
    item->header.dwBufferLength = static_cast<DWORD>(item->bytes.size());

    MMRESULT result = waveOutPrepareHeader(wave_out_, &item->header, sizeof(WAVEHDR));
    if (result != MMSYSERR_NOERROR) {
      error = "waveOutPrepareHeader failed";
      return false;
    }

    result = waveOutWrite(wave_out_, &item->header, sizeof(WAVEHDR));
    if (result != MMSYSERR_NOERROR) {
      waveOutUnprepareHeader(wave_out_, &item->header, sizeof(WAVEHDR));
      error = "waveOutWrite failed";
      return false;
    }

    buffers_.push_back(std::move(item));
    return true;
  }

  void Stop() {
    if (wave_out_ != nullptr) {
      waveOutReset(wave_out_);

      for (auto& item : buffers_) {
        waveOutUnprepareHeader(wave_out_, &item->header, sizeof(WAVEHDR));
      }
      buffers_.clear();

      waveOutClose(wave_out_);
      wave_out_ = nullptr;
    }

    started_ = false;
  }

 private:
  struct BufferItem {
    WAVEHDR header{};
    std::vector<uint8_t> bytes;
  };

  void CleanupDoneBuffers() {
    if (wave_out_ == nullptr) {
      buffers_.clear();
      return;
    }

    for (auto it = buffers_.begin(); it != buffers_.end();) {
      if (((*it)->header.dwFlags & WHDR_DONE) != 0) {
        waveOutUnprepareHeader(wave_out_, &(*it)->header, sizeof(WAVEHDR));
        it = buffers_.erase(it);
      } else {
        ++it;
      }
    }
  }

  HWAVEOUT wave_out_ = nullptr;
  bool started_ = false;
  std::list<std::unique_ptr<BufferItem>> buffers_;
};

bool TryGetInt(const flutter::EncodableMap* map,
               const char* key,
               int& value) {
  if (!map) return false;
  auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) return false;
  if (const auto* v = std::get_if<int>(&it->second)) {
    value = *v;
    return true;
  }
  if (const auto* v64 = std::get_if<int64_t>(&it->second)) {
    value = static_cast<int>(*v64);
    return true;
  }
  return false;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

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

  auto loopback = std::make_shared<NativeLoopbackPlayer>();
  loopback_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "app.audio.loopback",
          &flutter::StandardMethodCodec::GetInstance());

  loopback_channel_->SetMethodCallHandler(
      [loopback](const flutter::MethodCall<flutter::EncodableValue>& call,
                 std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "startLoopback") {
          const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
          int sample_rate = 44100;
          int num_channels = 1;
          TryGetInt(map, "sampleRate", sample_rate);
          TryGetInt(map, "numChannels", num_channels);

          std::string error;
          if (!loopback->Start(sample_rate, num_channels, error)) {
            result->Error("loopback_start_failed", error);
            return;
          }
          result->Success();
          return;
        }

        if (call.method_name() == "pushPcm") {
          const auto* bytes = std::get_if<std::vector<uint8_t>>(call.arguments());
          if (!bytes) {
            result->Error("loopback_push_failed", "Invalid PCM payload");
            return;
          }

          std::string error;
          if (!loopback->Push(*bytes, error)) {
            result->Error("loopback_push_failed", error);
            return;
          }
          result->Success();
          return;
        }

        if (call.method_name() == "stopLoopback") {
          loopback->Stop();
          result->Success();
          return;
        }

        result->NotImplemented();
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  loopback_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
