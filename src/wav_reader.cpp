#include "wav_reader.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <vector>

namespace sv {
namespace {

uint16_t u16(const char * p) { uint16_t v; std::memcpy(&v, p, 2); return v; }
uint32_t u32(const char * p) { uint32_t v; std::memcpy(&v, p, 4); return v; }

std::vector<float> resample_linear(const std::vector<float> & in, uint32_t from, uint32_t to) {
    if (from == to || in.empty()) return in;
    const double ratio = static_cast<double>(from) / static_cast<double>(to);
    const std::size_t out_n = std::max<std::size_t>(1, static_cast<std::size_t>(in.size() / ratio));
    std::vector<float> out(out_n);
    for (std::size_t i = 0; i < out_n; ++i) {
        const double x = i * ratio;
        const std::size_t a = std::min<std::size_t>(static_cast<std::size_t>(x), in.size() - 1);
        const std::size_t b = std::min<std::size_t>(a + 1, in.size() - 1);
        const double t = x - static_cast<double>(a);
        out[i] = static_cast<float>(in[a] * (1.0 - t) + in[b] * t);
    }
    return out;
}

} // namespace

std::vector<float> load_wav_16k_mono(const std::string & path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("cannot open wav: " + path);
    std::vector<char> bytes((std::istreambuf_iterator<char>(f)), {});
    if (bytes.size() < 44 || std::memcmp(bytes.data(), "RIFF", 4) || std::memcmp(bytes.data() + 8, "WAVE", 4)) {
        throw std::runtime_error("unsupported WAV container");
    }
    uint16_t format = 0, channels = 0, bits = 0;
    uint32_t sample_rate = 0;
    const char * data = nullptr;
    std::size_t data_size = 0;
    for (std::size_t p = 12; p + 8 <= bytes.size();) {
        const uint32_t size = u32(bytes.data() + p + 4);
        const std::size_t body = p + 8;
        if (body + size > bytes.size()) break;
        if (!std::memcmp(bytes.data() + p, "fmt ", 4) && size >= 16) {
            format = u16(bytes.data() + body);
            channels = u16(bytes.data() + body + 2);
            sample_rate = u32(bytes.data() + body + 4);
            bits = u16(bytes.data() + body + 14);
        } else if (!std::memcmp(bytes.data() + p, "data", 4)) {
            data = bytes.data() + body;
            data_size = size;
        }
        p = body + size + (size & 1u);
    }
    if (!data || !sample_rate || !channels) throw std::runtime_error("WAV missing fmt/data chunk");
    std::vector<float> mono;
    if (format == 1 && bits == 16) {
        const std::size_t frames = data_size / (sizeof(int16_t) * channels);
        mono.resize(frames);
        const auto * pcm = reinterpret_cast<const int16_t *>(data);
        for (std::size_t i = 0; i < frames; ++i) {
            float sum = 0.f;
            for (uint16_t c = 0; c < channels; ++c) sum += pcm[i * channels + c] / 32768.f;
            mono[i] = sum / channels;
        }
    } else if (format == 3 && bits == 32) {
        const std::size_t frames = data_size / (sizeof(float) * channels);
        mono.resize(frames);
        const auto * pcm = reinterpret_cast<const float *>(data);
        for (std::size_t i = 0; i < frames; ++i) {
            float sum = 0.f;
            for (uint16_t c = 0; c < channels; ++c) sum += pcm[i * channels + c];
            mono[i] = sum / channels;
        }
    } else {
        throw std::runtime_error("WAV must be PCM16 or float32");
    }
    return resample_linear(mono, sample_rate, 16000);
}

} // namespace sv
