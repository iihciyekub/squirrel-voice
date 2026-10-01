#pragma once

#include <cstddef>
#include <memory>
#include <string>
#include <vector>

namespace sv {

struct RuntimeOptions {
    std::string model_path;
    std::string mmproj_path;
    std::string language = "Chinese"; // empty = auto
    std::string context;
    int chunk_ms = 160;
    int unfixed_chunk_num = 2;
    int unfixed_token_num = 1;
    int max_new_tokens = 4;
    int n_ctx = 32768;
    int n_batch = 8192;
    int n_threads = 8;
    int n_gpu_layers = -1;
    bool use_gpu = true;
};

struct StreamUpdate {
    std::string text;         // current complete transcript
    std::string stable_text;  // current stable prefix
    std::string delta;        // newly-stable text since previous update
    std::string language;
    bool changed = false;
};

class R2T2Runtime {
public:
    explicit R2T2Runtime(RuntimeOptions options);
    ~R2T2Runtime();

    R2T2Runtime(const R2T2Runtime &) = delete;
    R2T2Runtime & operator=(const R2T2Runtime &) = delete;

    StreamUpdate push(const float * samples, std::size_t count);
    StreamUpdate push(const std::vector<float> & samples) {
        return push(samples.data(), samples.size());
    }
    StreamUpdate finish();
    void reset();

    const RuntimeOptions & options() const { return options_; }

private:
    class Impl;
    RuntimeOptions options_;
    std::unique_ptr<Impl> impl_;
};

} // namespace sv
