#pragma once

#include <functional>
#include <memory>

namespace sv {

class Microphone {
public:
    using Callback = std::function<void(const float *, std::size_t)>;
    Microphone();
    ~Microphone();
    Microphone(const Microphone &) = delete;
    Microphone & operator=(const Microphone &) = delete;
    void start(Callback callback);
    void stop();

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace sv
