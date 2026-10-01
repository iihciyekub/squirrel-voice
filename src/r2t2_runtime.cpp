// Native Confucius4-R2T2 runtime for Squirrel Voice.
// The llama.cpp/mtmd inference path is adapted from NetEase Youdao's
// Apache-2.0 r2t2_llama/native_ext.cpp, with Python/pybind removed.

#include "r2t2_runtime.h"

#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"
#include "mtmd-helper-common.h"

#include <algorithm>
#include <cmath>
#include <cctype>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace sv {
namespace {

void quiet_log(ggml_log_level level, const char * text, void *) {
    if (level >= GGML_LOG_LEVEL_WARN && text) std::fputs(text, stderr);
}

struct ModelDeleter { void operator()(llama_model * p) const { if (p) llama_model_free(p); } };
struct ContextDeleter { void operator()(llama_context * p) const { if (p) llama_free(p); } };
struct MtmdDeleter { void operator()(mtmd_context * p) const { if (p) mtmd_free(p); } };
struct BitmapDeleter { void operator()(mtmd_bitmap * p) const { if (p) mtmd_bitmap_free(p); } };
struct ChunksDeleter { void operator()(mtmd_input_chunks * p) const { if (p) mtmd_input_chunks_free(p); } };
struct SamplerDeleter { void operator()(llama_sampler * p) const { if (p) llama_sampler_free(p); } };

using model_ptr = std::unique_ptr<llama_model, ModelDeleter>;
using context_ptr = std::unique_ptr<llama_context, ContextDeleter>;
using mtmd_ptr = std::unique_ptr<mtmd_context, MtmdDeleter>;
using bitmap_ptr = std::unique_ptr<mtmd_bitmap, BitmapDeleter>;
using chunks_ptr = std::unique_ptr<mtmd_input_chunks, ChunksDeleter>;
using sampler_ptr = std::unique_ptr<llama_sampler, SamplerDeleter>;

std::string replace_all(std::string value, const std::string & from, const std::string & to) {
    std::size_t pos = 0;
    while ((pos = value.find(from, pos)) != std::string::npos) {
        value.replace(pos, from.size(), to);
        pos += to.size();
    }
    return value;
}

std::string token_piece(const llama_vocab * vocab, llama_token token) {
    std::string out(256, '\0');
    int32_t n = llama_token_to_piece(vocab, token, out.data(), static_cast<int32_t>(out.size()), 0, false);
    if (n < 0) {
        out.resize(static_cast<std::size_t>(-n));
        n = llama_token_to_piece(vocab, token, out.data(), static_cast<int32_t>(out.size()), 0, false);
    }
    if (n <= 0) return {};
    out.resize(static_cast<std::size_t>(n));
    return out;
}

std::string trim_copy(std::string s) {
    auto not_space = [](unsigned char c) { return !std::isspace(c); };
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), not_space));
    s.erase(std::find_if(s.rbegin(), s.rend(), not_space).base(), s.end());
    return s;
}

std::string before_pipe(std::string s) {
    const auto pos = s.find('|');
    if (pos != std::string::npos) s.resize(pos);
    return s;
}

struct ParsedText {
    std::string language;
    std::string text;
};

ParsedText parse_output(std::string raw, const std::string & forced_language) {
    raw = before_pipe(trim_copy(std::move(raw)));
    if (!forced_language.empty()) {
        return {forced_language, raw};
    }
    const std::string tag = "<asr_text>";
    const auto tag_pos = raw.find(tag);
    if (tag_pos == std::string::npos) return {"", ""};
    const std::string meta = raw.substr(0, tag_pos);
    std::string text = trim_copy(raw.substr(tag_pos + tag.size()));
    std::string language;
    const std::string prefix = "language ";
    const auto lang_pos = meta.find(prefix);
    if (lang_pos != std::string::npos) {
        auto value = meta.substr(lang_pos + prefix.size());
        const auto nl = value.find_first_of("\r\n<");
        if (nl != std::string::npos) value.resize(nl);
        language = trim_copy(value);
        if (language == "None") language.clear();
    }
    return {language, text};
}

std::string common_prefix(const std::string & a, const std::string & b) {
    const std::size_t n = std::min(a.size(), b.size());
    std::size_t i = 0;
    while (i < n && a[i] == b[i]) ++i;
    // Avoid cutting UTF-8 continuation bytes.
    while (i > 0 && i < a.size() && (static_cast<unsigned char>(a[i]) & 0xC0) == 0x80) --i;
    return a.substr(0, i);
}

} // namespace

class R2T2Runtime::Impl {
public:
    explicit Impl(RuntimeOptions options) : options_(std::move(options)) {
        if (options_.chunk_ms < 80 || options_.chunk_ms > 2000) {
            throw std::invalid_argument("chunk_ms must be in [80, 2000]");
        }
        chunk_samples_ = std::max<std::size_t>(1, static_cast<std::size_t>(16000LL * options_.chunk_ms / 1000));

        llama_log_set(quiet_log, nullptr);
        mtmd_log_set(quiet_log, nullptr);
        llama_backend_init();
        llama_model_params mp = llama_model_default_params();
        mp.n_gpu_layers = options_.n_gpu_layers;
        model_.reset(llama_model_load_from_file(options_.model_path.c_str(), mp));
        if (!model_) throw std::runtime_error("failed to load model: " + options_.model_path);

        llama_context_params cp = llama_context_default_params();
        cp.n_ctx = static_cast<uint32_t>(options_.n_ctx);
        cp.n_batch = static_cast<uint32_t>(options_.n_batch);
        cp.n_ubatch = static_cast<uint32_t>(std::min(options_.n_batch, 512));
        cp.n_seq_max = 1;
        cp.n_threads = options_.n_threads;
        cp.n_threads_batch = options_.n_threads;
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
        cp.offload_kqv = options_.use_gpu;
        context_.reset(llama_init_from_model(model_.get(), cp));
        if (!context_) throw std::runtime_error("failed to create llama context");

        mtmd_context_params mtp = mtmd_context_params_default();
        mtp.use_gpu = options_.use_gpu;
        mtp.n_threads = options_.n_threads;
        mtp.warmup = false;
        mtmd_.reset(mtmd_init_from_file(options_.mmproj_path.c_str(), model_.get(), mtp));
        if (!mtmd_) throw std::runtime_error("failed to load mmproj: " + options_.mmproj_path);
        if (!mtmd_support_audio(mtmd_.get())) throw std::runtime_error("mmproj does not support audio");

        base_prompt_ = "<|im_start|>system\n" + options_.context +
            "<|im_end|>\n<|im_start|>user\n"
            "<|audio_start|><|audio_pad|><|audio_end|>"
            "<|im_end|>\n<|im_start|>assistant\n";
        if (!options_.language.empty()) {
            base_prompt_ += "language " + options_.language + "<asr_text>";
        }
    }

    ~Impl() {
        mtmd_.reset();
        context_.reset();
        model_.reset();
        llama_backend_free();
    }

    StreamUpdate push(const float * samples, std::size_t count) {
        if (samples && count) buffer_.insert(buffer_.end(), samples, samples + count);
        StreamUpdate latest = snapshot();
        while (buffer_.size() >= chunk_samples_) {
            audio_accum_.insert(audio_accum_.end(), buffer_.begin(), buffer_.begin() + static_cast<std::ptrdiff_t>(chunk_samples_));
            buffer_.erase(buffer_.begin(), buffer_.begin() + static_cast<std::ptrdiff_t>(chunk_samples_));
            latest = decode_step(false);
        }
        return latest;
    }

    StreamUpdate finish() {
        if (!buffer_.empty()) {
            audio_accum_.insert(audio_accum_.end(), buffer_.begin(), buffer_.end());
            buffer_.clear();
        }
        if (audio_accum_.empty()) return snapshot();

        // Always run one longer final decode, even when the producer stopped
        // exactly on a chunk boundary. decode_step(true) promotes the complete
        // transcript to stable text and returns only the not-yet-committed
        // suffix, so the input method never loses or duplicates the last words.
        return decode_step(true);
    }

    void reset() {
        buffer_.clear();
        audio_accum_.clear();
        raw_decoded_.clear();
        text_.clear();
        language_.clear();
        committed_.clear();
        chunk_id_ = 0;
    }

private:
    std::vector<llama_token> tokenize(const std::string & text) const {
        const llama_vocab * vocab = llama_model_get_vocab(model_.get());
        std::vector<llama_token> tokens(std::max<std::size_t>(16, text.size() + 16));
        int32_t n = llama_tokenize(vocab, text.data(), static_cast<int32_t>(text.size()), tokens.data(), static_cast<int32_t>(tokens.size()), false, true);
        if (n < 0) {
            tokens.resize(static_cast<std::size_t>(-n));
            n = llama_tokenize(vocab, text.data(), static_cast<int32_t>(text.size()), tokens.data(), static_cast<int32_t>(tokens.size()), false, true);
        }
        if (n < 0) throw std::runtime_error("llama_tokenize failed");
        tokens.resize(static_cast<std::size_t>(n));
        return tokens;
    }

    std::string detokenize(const std::vector<llama_token> & tokens, std::size_t count) const {
        if (count == 0) return {};
        const llama_vocab * vocab = llama_model_get_vocab(model_.get());
        std::string out;
        for (std::size_t i = 0; i < count; ++i) out += token_piece(vocab, tokens[i]);
        return out;
    }

    std::string rollback_prefix(const std::string & raw) const {
        if (chunk_id_ < options_.unfixed_chunk_num || raw.empty()) return {};
        const auto tokens = tokenize(before_pipe(raw));
        std::size_t k = static_cast<std::size_t>(std::max(0, options_.unfixed_token_num));
        if (k >= tokens.size()) return {};
        for (;;) {
            const std::size_t end = tokens.size() > k ? tokens.size() - k : 0;
            std::string prefix = detokenize(tokens, end);
            if (prefix.find("\xEF\xBF\xBD") == std::string::npos || end == 0) return before_pipe(prefix);
            ++k;
        }
    }

    std::string stable_from_raw(const std::string & raw) const {
        auto tokens = tokenize(before_pipe(raw));
        std::size_t k = static_cast<std::size_t>(std::max(0, options_.unfixed_token_num));
        if (k >= tokens.size()) return {};
        std::string fixed = detokenize(tokens, tokens.size() - k);
        const auto tag = fixed.find("<asr_text>");
        if (tag != std::string::npos) fixed = fixed.substr(tag + std::strlen("<asr_text>"));
        return before_pipe(trim_copy(fixed));
    }

    std::string generate_once(const std::vector<float> & audio, const std::string & prompt, int max_tokens) {
        if (audio.empty()) return {};
        llama_memory_clear(llama_get_memory(context_.get()), true);

        std::string mtmd_prompt = replace_all(prompt,
            "<|audio_start|><|audio_pad|><|audio_end|>", mtmd_default_marker());
        if (mtmd_prompt.find(mtmd_default_marker()) == std::string::npos) {
            throw std::runtime_error("ASR prompt lost audio marker");
        }

        bitmap_ptr bitmap(mtmd_bitmap_init_from_audio(audio.size(), audio.data()));
        if (!bitmap) throw std::runtime_error("mtmd_bitmap_init_from_audio failed");

        mtmd_input_text text{mtmd_prompt.data(), mtmd_prompt.size(), true, true};
        const mtmd_bitmap * bitmaps[] = {bitmap.get()};
        chunks_ptr chunks(mtmd_input_chunks_init());
        const int32_t tr = mtmd_tokenize(mtmd_.get(), chunks.get(), &text, bitmaps, 1);
        if (tr != 0) throw std::runtime_error("mtmd_tokenize failed: " + std::to_string(tr));

        llama_pos n_past = 0;
        const std::size_t n_chunks = mtmd_input_chunks_size(chunks.get());
        for (std::size_t i = 0; i < n_chunks; ++i) {
            const mtmd_input_chunk * chunk = mtmd_input_chunks_get(chunks.get(), i);
            const bool is_last = i + 1 == n_chunks;
            llama_pos new_n_past = n_past;
            int32_t result = 0;
            if (mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT) {
                result = mtmd_helper_eval_chunk_single(mtmd_.get(), context_.get(), chunk,
                    n_past, 0, options_.n_batch, is_last, &new_n_past);
            } else {
                result = mtmd_encode_chunk(mtmd_.get(), chunk);
                if (result == 0) {
                    float * embedding = mtmd_get_output_embd(mtmd_.get());
                    if (!embedding) throw std::runtime_error("mtmd returned null audio embedding");
                    result = mtmd_helper_decode_image_chunk(mtmd_.get(), context_.get(), chunk,
                        embedding, n_past, 0, options_.n_batch, &new_n_past, nullptr, nullptr);
                }
            }
            if (result != 0) throw std::runtime_error("failed to evaluate mtmd chunk: " + std::to_string(result));
            n_past = new_n_past;
        }

        sampler_ptr sampler(llama_sampler_init_greedy());
        if (!sampler) throw std::runtime_error("failed to create greedy sampler");
        const llama_vocab * vocab = llama_model_get_vocab(model_.get());
        std::string generated;
        for (int i = 0; i < max_tokens; ++i) {
            const llama_token token = llama_sampler_sample(sampler.get(), context_.get(), -1);
            llama_sampler_accept(sampler.get(), token);
            if (llama_vocab_is_eog(vocab, token)) break;
            generated += token_piece(vocab, token);
            llama_token next = token;
            llama_batch batch = llama_batch_get_one(&next, 1);
            if (llama_decode(context_.get(), batch) != 0) throw std::runtime_error("llama_decode failed during generation");
            ++n_past;
        }
        return generated;
    }

    StreamUpdate decode_step(bool final) {
        const std::string prefix = rollback_prefix(raw_decoded_);
        const int max_tokens = final ? std::max(options_.max_new_tokens, 16) : options_.max_new_tokens;
        const std::string gen = generate_once(audio_accum_, base_prompt_ + prefix, max_tokens);
        raw_decoded_ = before_pipe(prefix + gen);

        const ParsedText parsed = parse_output(raw_decoded_, options_.language);
        language_ = parsed.language;
        text_ = parsed.text;

        std::string stable = final ? text_ : stable_from_raw(raw_decoded_);
        std::string delta;
        if (stable.rfind(committed_, 0) == 0) {
            delta = stable.substr(committed_.size());
            committed_ = stable;
        } else {
            // Never retract text already exposed to the input method. Keep the
            // common prefix and wait for a later chunk instead of flickering.
            const std::string common = common_prefix(stable, committed_);
            if (common.size() < committed_.size()) stable = committed_;
        }
        ++chunk_id_;
        return {text_, committed_, delta, language_, !delta.empty()};
    }

    StreamUpdate snapshot() const { return {text_, committed_, {}, language_, false}; }

    RuntimeOptions options_;
    model_ptr model_;
    context_ptr context_;
    mtmd_ptr mtmd_;
    std::size_t chunk_samples_ = 2560;
    int chunk_id_ = 0;
    std::vector<float> buffer_;
    std::vector<float> audio_accum_;
    std::string base_prompt_;
    std::string raw_decoded_;
    std::string text_;
    std::string language_;
    std::string committed_;
};

R2T2Runtime::R2T2Runtime(RuntimeOptions options)
    : options_(std::move(options)), impl_(std::make_unique<Impl>(options_)) {}
R2T2Runtime::~R2T2Runtime() = default;
StreamUpdate R2T2Runtime::push(const float * samples, std::size_t count) { return impl_->push(samples, count); }
StreamUpdate R2T2Runtime::finish() { return impl_->finish(); }
void R2T2Runtime::reset() { impl_->reset(); }

} // namespace sv
