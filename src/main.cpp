#include "audio_queue_mic.h"
#include "r2t2_runtime.h"
#include "wav_reader.h"

#include <atomic>
#include <cmath>
#include <chrono>
#include <cstdio>
#include <condition_variable>
#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <mutex>
#include <optional>
#include <queue>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;
namespace {

std::atomic<bool> g_stop{false};
void on_signal(int) { g_stop = true; }

struct Args {
    bool mic = false;
    bool probe = false;
    bool stdio = false;
    std::string wav;
    std::string model_dir;
    std::string model;
    std::string mmproj;
    std::string language = "Chinese";
    std::string context;
    int chunk_ms = 160;
    int threads = 8;
    int max_tokens = 4;
};

void usage() {
    std::cerr <<
        "squirrel-voice - lightweight Confucius4-R2T2 streaming ASR\n\n"
        "Usage:\n"
        "  squirrel-voice --probe [model options]\n"
        "  squirrel-voice --wav FILE [model options]\n"
        "  squirrel-voice --mic [model options]\n"
        "  squirrel-voice --stdio [model options]   # persistent helper protocol\n\n"
        "Options:\n"
        "  --model-dir DIR       directory containing model + mmproj GGUF\n"
        "  --model FILE          explicit language-model GGUF\n"
        "  --mmproj FILE         explicit audio-projector GGUF\n"
        "  --language LANG       Chinese, English, or auto (default Chinese)\n"
        "  --context TEXT        hotword/topic context\n"
        "  --chunk-ms N          80..2000 (default 160)\n"
        "  --threads N           CPU helper threads (default 8)\n"
        "  --max-tokens N        tokens decoded per streaming step (default 4)\n";
}

Args parse_args(int argc, char ** argv) {
    Args a;
    for (int i = 1; i < argc; ++i) {
        const std::string s = argv[i];
        auto value = [&](const char * name) -> std::string {
            if (++i >= argc) throw std::runtime_error(std::string("missing value for ") + name);
            return argv[i];
        };
        if (s == "--mic") a.mic = true;
        else if (s == "--probe") a.probe = true;
        else if (s == "--stdio") a.stdio = true;
        else if (s == "--wav") a.wav = value("--wav");
        else if (s == "--model-dir") a.model_dir = value("--model-dir");
        else if (s == "--model") a.model = value("--model");
        else if (s == "--mmproj") a.mmproj = value("--mmproj");
        else if (s == "--language") { a.language = value("--language"); if (a.language == "auto") a.language.clear(); }
        else if (s == "--context") a.context = value("--context");
        else if (s == "--chunk-ms") a.chunk_ms = std::stoi(value("--chunk-ms"));
        else if (s == "--threads") a.threads = std::stoi(value("--threads"));
        else if (s == "--max-tokens") a.max_tokens = std::stoi(value("--max-tokens"));
        else if (s == "-h" || s == "--help") { usage(); std::exit(0); }
        else throw std::runtime_error("unknown argument: " + s);
    }
    return a;
}

std::vector<fs::path> candidate_model_dirs(const Args & a) {
    std::vector<fs::path> dirs;
    if (!a.model_dir.empty()) dirs.emplace_back(a.model_dir);
    if (const char * env = std::getenv("R2T2_MODEL_DIR"); env && *env) dirs.emplace_back(env);
    const char * home = std::getenv("HOME");
    if (home && *home) {
        dirs.emplace_back(fs::path(home) / ".lmstudio/models/netease-youdao/Confucius4-R2T2-GGUF");
        dirs.emplace_back(fs::path(home) / "Library/Application Support/Squirrel Voice/Models");
        dirs.emplace_back(fs::path(home) / "Models/Confucius4-R2T2-GGUF");
    }
    return dirs;
}

std::pair<std::string, std::string> resolve_models(const Args & a) {
    if (!a.model.empty() && !a.mmproj.empty()) return {a.model, a.mmproj};
    for (const auto & dir : candidate_model_dirs(a)) {
        if (!fs::is_directory(dir)) continue;
        fs::path model = a.model, mmproj = a.mmproj;
        if (model.empty()) {
            // Prefer the smallest official model for an input-method helper.
            // Explicit --model always wins, and F16 remains the final fallback.
            for (const char * name : {
                     "Confucius4-R2T2-Q4_K_M.gguf",
                     "Confucius4-R2T2-Q8_0.gguf",
                     "Confucius4-R2T2-f16.gguf",
                 }) {
                const fs::path candidate = dir / name;
                if (fs::exists(candidate)) { model = candidate; break; }
            }
        }
        if (mmproj.empty()) {
            for (const char * name : {
                     "mmproj-Confucius4-R2T2-Q8_0.gguf",
                     "mmproj-Confucius4-R2T2-f16.gguf",
                 }) {
                const fs::path candidate = dir / name;
                if (fs::exists(candidate)) { mmproj = candidate; break; }
            }
        }
        if (model.empty() || mmproj.empty()) {
            for (const auto & entry : fs::directory_iterator(dir)) {
                if (!entry.is_regular_file() || entry.path().extension() != ".gguf") continue;
                const auto name = entry.path().filename().string();
                if (name.rfind("mmproj", 0) == 0) { if (mmproj.empty()) mmproj = entry.path(); }
                else if (model.empty()) model = entry.path();
            }
        }
        if (!model.empty() && !mmproj.empty() && fs::exists(model) && fs::exists(mmproj)) {
            return {model.string(), mmproj.string()};
        }
    }
    throw std::runtime_error("Confucius4-R2T2 model/mmproj not found; pass --model-dir or R2T2_MODEL_DIR");
}

void emit(const sv::StreamUpdate & u) {
    if (!u.delta.empty()) {
        std::cout << u.delta << std::flush;
    }
}

class LongDictationSegmentPolicy {
public:
    static constexpr std::size_t kSampleRate = 16000;
    static constexpr std::size_t kNaturalCutSamples = 5 * kSampleRate;
    static constexpr std::size_t kPreferredCutSamples = 8 * kSampleRate;
    static constexpr std::size_t kHardCutSamples = 12 * kSampleRate;
    static constexpr std::size_t kNaturalSilenceSamples = 300 * kSampleRate / 1000;
    static constexpr std::size_t kShortSilenceSamples = 100 * kSampleRate / 1000;
    static constexpr double kSilenceRms = 0.012;

    void reset() {
        segment_samples_ = 0;
        silence_samples_ = 0;
    }

    bool observe(const float * samples, std::size_t count) {
        if (!samples || count == 0) return false;
        double energy = 0.0;
        for (std::size_t i = 0; i < count; ++i) {
            const double value = samples[i];
            energy += value * value;
        }
        const double rms = std::sqrt(energy / static_cast<double>(count));
        segment_samples_ += count;
        if (rms < kSilenceRms) silence_samples_ += count;
        else silence_samples_ = 0;

        if (segment_samples_ >= kHardCutSamples) return true;
        if (segment_samples_ >= kPreferredCutSamples && silence_samples_ >= kShortSilenceSamples) return true;
        return segment_samples_ >= kNaturalCutSamples && silence_samples_ >= kNaturalSilenceSamples;
    }

    bool has_audio() const { return segment_samples_ != 0; }

private:
    std::size_t segment_samples_ = 0;
    std::size_t silence_samples_ = 0;
};

std::string escape_field(const std::string & s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        switch (c) {
            case '\\': out += "\\\\"; break;
            case '\t': out += "\\t"; break;
            case '\r': out += "\\r"; break;
            case '\n': out += "\\n"; break;
            default: out += c; break;
        }
    }
    return out;
}

class StdioVoiceSession {
public:
    explicit StdioVoiceSession(sv::R2T2Runtime & runtime) : runtime_(runtime) {}
    ~StdioVoiceSession() { stop(false); }

    void start() {
        if (running_) return;
        if (worker_.joinable()) worker_.join();
        runtime_.reset();
        {
            std::lock_guard<std::mutex> lock(queue_mutex_);
            while (!queue_.empty()) queue_.pop();
            stopping_ = false;
        }
        accepting_output_ = true;
        segment_policy_.reset();
        running_ = true;
        worker_ = std::thread([this] { worker_loop(); });
        mic_.start([this](const float * samples, std::size_t count) {
            if (!running_) return;
            if (samples && count > 0) {
                double energy = 0.0;
                for (std::size_t i = 0; i < count; ++i) {
                    const double x = samples[i];
                    energy += x * x;
                }
                const double rms = std::sqrt(energy / static_cast<double>(count));
                // Speech captured by the default macOS input is usually well
                // below full scale. Expand the useful range for the HUD while
                // keeping silence near zero.
                const double level = std::clamp(rms * 8.0, 0.0, 1.0);
                char text[32];
                std::snprintf(text, sizeof(text), "%.3f", level);
                event("L", text);
            }
            {
                std::lock_guard<std::mutex> lock(queue_mutex_);
                queue_.emplace(samples, samples + count);
            }
            queue_cv_.notify_one();
        });
        event("STARTED");
    }

    void stop(bool notify = true) {
        if (!running_) return;
        // STOP is intentionally hard: once the user asks to stop, no queued
        // audio is allowed to produce delayed text afterwards.
        accepting_output_ = false;
        running_ = false;
        mic_.stop();
        {
            std::lock_guard<std::mutex> lock(queue_mutex_);
            stopping_ = true;
            while (!queue_.empty()) queue_.pop();
        }
        queue_cv_.notify_all();
        if (worker_.joinable()) worker_.join();
        if (notify) event("STOPPED");
    }

private:
    void event(const std::string & type, const std::string & value = {}) {
        std::lock_guard<std::mutex> lock(output_mutex_);
        std::cout << type;
        if (!value.empty()) std::cout << '\t' << escape_field(value);
        std::cout << '\n' << std::flush;
    }

    void roll_segment() {
        // A segment rollover is not a user-visible stop. Finalize only the
        // current bounded audio window, emit its not-yet-committed suffix, then
        // reset the ASR state and immediately continue consuming microphone
        // audio from the queue. This prevents audio/history from growing for
        // the entire dictation session while keeping one continuous capture.
        const auto final = runtime_.finish();
        if (accepting_output_ && !final.delta.empty()) event("D", final.delta);
        runtime_.reset();
        segment_policy_.reset();
    }

    void worker_loop() {
        try {
            for (;;) {
                std::vector<float> chunk;
                {
                    std::unique_lock<std::mutex> lock(queue_mutex_);
                    queue_cv_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
                    if (stopping_) {
                        break;
                    } else if (!queue_.empty()) {
                        chunk = std::move(queue_.front());
                        queue_.pop();
                    }
                }
                if (!chunk.empty()) {
                    const auto update = runtime_.push(chunk);
                    if (accepting_output_ && !update.delta.empty()) event("D", update.delta);
                    if (accepting_output_ && segment_policy_.observe(chunk.data(), chunk.size())) roll_segment();
                }
            }
        } catch (const std::exception & e) {
            event("ERROR", e.what());
        }
    }

    sv::R2T2Runtime & runtime_;
    sv::Microphone mic_;
    std::atomic<bool> running_{false};
    std::atomic<bool> accepting_output_{false};
    bool stopping_ = false;
    std::thread worker_;
    std::mutex queue_mutex_;
    std::condition_variable queue_cv_;
    std::queue<std::vector<float>> queue_;
    std::mutex output_mutex_;
    LongDictationSegmentPolicy segment_policy_;
};

} // namespace

int main(int argc, char ** argv) {
    try {
        const Args args = parse_args(argc, argv);
        if (!args.probe && !args.mic && !args.stdio && args.wav.empty()) { usage(); return 2; }
        const auto [model, mmproj] = resolve_models(args);
        std::cerr << "[squirrel-voice] model  : " << model << "\n"
                  << "[squirrel-voice] mmproj : " << mmproj << "\n"
                  << "[squirrel-voice] chunk  : " << args.chunk_ms << " ms\n";

        sv::RuntimeOptions opt;
        opt.model_path = model;
        opt.mmproj_path = mmproj;
        opt.language = args.language;
        opt.context = args.context;
        opt.chunk_ms = args.chunk_ms;
        opt.n_threads = args.threads;
        opt.max_new_tokens = args.max_tokens;
        sv::R2T2Runtime runtime(opt);
        std::cerr << "[squirrel-voice] runtime ready\n";
        if (args.probe) return 0;

        if (args.stdio) {
            StdioVoiceSession session(runtime);
            std::cout << "READY\n" << std::flush;
            std::string command;
            while (std::getline(std::cin, command)) {
                try {
                    if (command == "START") session.start();
                    else if (command == "STOP") session.stop();
                    else if (command == "PING") std::cout << "PONG\n" << std::flush;
                    else if (command == "QUIT") { session.stop(false); break; }
                    else if (!command.empty()) std::cout << "ERROR\tunknown command\n" << std::flush;
                } catch (const std::exception & e) {
                    std::cout << "ERROR\t" << escape_field(e.what()) << "\n" << std::flush;
                }
            }
            return 0;
        }

        if (!args.wav.empty()) {
            const auto wav = sv::load_wav_16k_mono(args.wav);
            constexpr std::size_t feed = 1600; // 100 ms producer cadence; runtime re-chunks to --chunk-ms.
            LongDictationSegmentPolicy segment_policy;
            for (std::size_t pos = 0; pos < wav.size(); pos += feed) {
                const auto n = std::min(feed, wav.size() - pos);
                emit(runtime.push(wav.data() + pos, n));
                if (segment_policy.observe(wav.data() + pos, n)) {
                    emit(runtime.finish());
                    runtime.reset();
                    segment_policy.reset();
                }
            }
            if (segment_policy.has_audio()) emit(runtime.finish());
            std::cout << "\n";
            return 0;
        }

        std::signal(SIGINT, on_signal);
        std::signal(SIGTERM, on_signal);
        std::mutex mutex;
        std::condition_variable cv;
        std::queue<std::vector<float>> chunks;
        LongDictationSegmentPolicy segment_policy;
        sv::Microphone mic;
        mic.start([&](const float * samples, std::size_t count) {
            {
                std::lock_guard<std::mutex> lock(mutex);
                chunks.emplace(samples, samples + count);
            }
            cv.notify_one();
        });
        std::cerr << "[squirrel-voice] listening; press Ctrl-C to stop\n";

        while (!g_stop) {
            std::vector<float> chunk;
            {
                std::unique_lock<std::mutex> lock(mutex);
                cv.wait_for(lock, std::chrono::milliseconds(100), [&] { return !chunks.empty() || g_stop.load(); });
                if (!chunks.empty()) { chunk = std::move(chunks.front()); chunks.pop(); }
            }
            if (!chunk.empty()) {
                emit(runtime.push(chunk));
                if (segment_policy.observe(chunk.data(), chunk.size())) {
                    emit(runtime.finish());
                    runtime.reset();
                    segment_policy.reset();
                }
            }
        }
        mic.stop();
        if (segment_policy.has_audio()) emit(runtime.finish());
        std::cout << "\n";
        return 0;
    } catch (const std::exception & e) {
        std::cerr << "[squirrel-voice] error: " << e.what() << "\n";
        return 1;
    }
}
