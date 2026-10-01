#include "audio_queue_mic.h"

#include <AudioToolbox/AudioToolbox.h>

#include <array>
#include <mutex>
#include <stdexcept>
#include <vector>

namespace sv {

class Microphone::Impl {
public:
    ~Impl() { stop(); }

    void start(Callback callback) {
        if (queue_) return;
        callback_ = std::move(callback);

        AudioStreamBasicDescription fmt{};
        fmt.mSampleRate = 16000.0;
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags = kLinearPCMFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        fmt.mBitsPerChannel = 32;
        fmt.mChannelsPerFrame = 1;
        fmt.mFramesPerPacket = 1;
        fmt.mBytesPerFrame = sizeof(float);
        fmt.mBytesPerPacket = sizeof(float);

        OSStatus st = AudioQueueNewInput(&fmt, &Impl::input_callback, this, nullptr, nullptr, 0, &queue_);
        if (st != noErr) throw std::runtime_error("AudioQueueNewInput failed: " + std::to_string(st));

        constexpr UInt32 kBufferBytes = 16000 * sizeof(float) / 10; // 100 ms
        for (auto & buffer : buffers_) {
            st = AudioQueueAllocateBuffer(queue_, kBufferBytes, &buffer);
            if (st != noErr) throw std::runtime_error("AudioQueueAllocateBuffer failed: " + std::to_string(st));
            st = AudioQueueEnqueueBuffer(queue_, buffer, 0, nullptr);
            if (st != noErr) throw std::runtime_error("AudioQueueEnqueueBuffer failed: " + std::to_string(st));
        }
        st = AudioQueueStart(queue_, nullptr);
        if (st != noErr) throw std::runtime_error("AudioQueueStart failed: " + std::to_string(st));
    }

    void stop() {
        if (!queue_) return;
        AudioQueueStop(queue_, true);
        AudioQueueDispose(queue_, true);
        queue_ = nullptr;
        callback_ = {};
        buffers_.fill(nullptr);
    }

private:
    static void input_callback(void * user, AudioQueueRef queue, AudioQueueBufferRef buffer,
                               const AudioTimeStamp *, UInt32, const AudioStreamPacketDescription *) {
        auto * self = static_cast<Impl *>(user);
        if (self->callback_ && buffer->mAudioDataByteSize >= sizeof(float)) {
            const auto * samples = static_cast<const float *>(buffer->mAudioData);
            self->callback_(samples, buffer->mAudioDataByteSize / sizeof(float));
        }
        if (self->queue_ == queue) AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
    }

    AudioQueueRef queue_ = nullptr;
    std::array<AudioQueueBufferRef, 3> buffers_{};
    Callback callback_;
};

Microphone::Microphone() : impl_(std::make_unique<Impl>()) {}
Microphone::~Microphone() = default;
void Microphone::start(Callback callback) { impl_->start(std::move(callback)); }
void Microphone::stop() { impl_->stop(); }

} // namespace sv
