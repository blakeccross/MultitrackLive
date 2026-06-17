#include "../../ThirdParty/rubberband/single/RubberBandSingle.cpp"

#include "PitchShiftBridge.h"

#include <rubberband/rubberband-c.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

static double semitonesToPitchScale(int semitones) {
    return std::pow(2.0, semitones / 12.0);
}

PitchShiftResult pitch_shift_offline(
    const float *const *inputChannels,
    int channelCount,
    int frameCount,
    double sampleRate,
    int semitoneShift
) {
    PitchShiftResult result { nullptr, 0, 0 };
    if (!inputChannels || channelCount <= 0 || frameCount <= 0 || semitoneShift == 0) {
        return result;
    }

    const unsigned int blockSize = 4096;
    const RubberBandOptions options =
        RubberBandOptionProcessOffline |
        RubberBandOptionEngineFiner |
        RubberBandOptionPitchHighQuality |
        RubberBandOptionFormantPreserved |
        RubberBandOptionChannelsTogether;

    RubberBandState state = rubberband_new(
        static_cast<unsigned int>(sampleRate),
        static_cast<unsigned int>(channelCount),
        options,
        1.0,
        semitonesToPitchScale(semitoneShift)
    );

    if (!state) {
        return result;
    }

    rubberband_set_expected_input_duration(state, static_cast<unsigned int>(frameCount));
    rubberband_set_max_process_size(state, blockSize);

    std::vector<const float *> inputPointers(static_cast<size_t>(channelCount));
    std::vector<std::vector<float>> outputChannels(static_cast<size_t>(channelCount));
    for (auto &channel : outputChannels) {
        channel.reserve(static_cast<size_t>(frameCount));
    }

    auto retrieveAvailable = [&]() {
        while (rubberband_available(state) > 0) {
            const unsigned int toRetrieve = std::min(
                blockSize,
                static_cast<unsigned int>(rubberband_available(state))
            );
            std::vector<std::vector<float>> block(
                static_cast<size_t>(channelCount),
                std::vector<float>(toRetrieve)
            );
            std::vector<float *> outputPointers(static_cast<size_t>(channelCount));
            for (int channel = 0; channel < channelCount; ++channel) {
                outputPointers[static_cast<size_t>(channel)] = block[static_cast<size_t>(channel)].data();
            }

            const unsigned int retrieved = rubberband_retrieve(
                state,
                outputPointers.data(),
                toRetrieve
            );

            for (int channel = 0; channel < channelCount; ++channel) {
                auto &destination = outputChannels[static_cast<size_t>(channel)];
                destination.insert(
                    destination.end(),
                    block[static_cast<size_t>(channel)].begin(),
                    block[static_cast<size_t>(channel)].begin() + retrieved
                );
            }
        }
    };

    int position = 0;
    while (position < frameCount) {
        const unsigned int count = std::min(
            blockSize,
            static_cast<unsigned int>(frameCount - position)
        );
        for (int channel = 0; channel < channelCount; ++channel) {
            inputPointers[static_cast<size_t>(channel)] = inputChannels[channel] + position;
        }
        const int isFinal = (position + static_cast<int>(count) >= frameCount) ? 1 : 0;
        rubberband_study(state, inputPointers.data(), count, isFinal);
        position += static_cast<int>(count);
    }
    rubberband_study(state, nullptr, 0, 1);
    rubberband_calculate_stretch(state);

    position = 0;
    while (position < frameCount) {
        const unsigned int count = std::min(
            blockSize,
            static_cast<unsigned int>(frameCount - position)
        );
        for (int channel = 0; channel < channelCount; ++channel) {
            inputPointers[static_cast<size_t>(channel)] = inputChannels[channel] + position;
        }
        const int isFinal = (position + static_cast<int>(count) >= frameCount) ? 1 : 0;
        rubberband_process(state, inputPointers.data(), count, isFinal);
        retrieveAvailable();
        position += static_cast<int>(count);
    }

    rubberband_process(state, nullptr, 0, 1);
    retrieveAvailable();

    rubberband_delete(state);

    if (outputChannels.empty() || outputChannels[0].empty()) {
        return result;
    }

    result.channelCount = channelCount;
    result.frameCount = static_cast<int>(outputChannels[0].size());
    result.channels = new float *[static_cast<size_t>(channelCount)]();
    for (int channel = 0; channel < channelCount; ++channel) {
        result.channels[channel] = new float[static_cast<size_t>(result.frameCount)];
        std::memcpy(
            result.channels[channel],
            outputChannels[static_cast<size_t>(channel)].data(),
            static_cast<size_t>(result.frameCount) * sizeof(float)
        );
    }

    return result;
}

void pitch_shift_free_result(PitchShiftResult result) {
    if (!result.channels) {
        return;
    }

    for (int channel = 0; channel < result.channelCount; ++channel) {
        delete[] result.channels[channel];
    }
    delete[] result.channels;
}

namespace {

template<typename T>
class SimpleRingBuffer {
public:
    explicit SimpleRingBuffer(size_t capacity)
        : m_capacity(capacity), m_buffer(capacity, T {}) {}

    void reset() {
        m_read = 0;
        m_write = 0;
        m_fill = 0;
        std::fill(m_buffer.begin(), m_buffer.end(), T {});
    }

    void zero(size_t count) {
        const size_t toWrite = std::min(count, m_capacity - m_fill);
        for (size_t index = 0; index < toWrite; ++index) {
            m_buffer[m_write] = T {};
            m_write = (m_write + 1) % m_capacity;
            ++m_fill;
        }
    }

    void write(const T *source, size_t count) {
        for (size_t index = 0; index < count; ++index) {
            if (m_fill >= m_capacity) {
                m_read = (m_read + 1) % m_capacity;
                --m_fill;
            }
            m_buffer[m_write] = source[index];
            m_write = (m_write + 1) % m_capacity;
            ++m_fill;
        }
    }

    size_t read(T *destination, size_t count) {
        const size_t toRead = std::min(count, m_fill);
        for (size_t index = 0; index < toRead; ++index) {
            destination[index] = m_buffer[m_read];
            m_read = (m_read + 1) % m_capacity;
            --m_fill;
        }
        return toRead;
    }

    size_t availableToRead() const { return m_fill; }
    size_t availableToWrite() const { return m_capacity - m_fill; }

private:
    size_t m_capacity;
    size_t m_read = 0;
    size_t m_write = 0;
    size_t m_fill = 0;
    std::vector<T> m_buffer;
};

struct LivePitchStreamImpl {
    RubberBandLiveState state = nullptr;
    unsigned int channelCount = 0;
    unsigned int blockSize = 0;
    unsigned int startDelay = 0;
    int semitones = 0;
    double pitchScale = 1.0;

    std::vector<SimpleRingBuffer<float>> inputRing;
    std::vector<SimpleRingBuffer<float>> outputRing;
    std::vector<std::vector<float>> inputBlock;
    std::vector<std::vector<float>> outputBlock;
    std::vector<float *> inputPointers;
    std::vector<float *> outputPointers;

    explicit LivePitchStreamImpl(unsigned int sampleRate, unsigned int channels)
        : channelCount(channels) {
        const RubberBandOptions options =
            RubberBandLiveOptionWindowMedium |
            RubberBandLiveOptionFormantPreserved |
            RubberBandLiveOptionChannelsTogether;

        state = rubberband_live_new(sampleRate, channels, options);
        if (!state) {
            return;
        }

        blockSize = rubberband_live_get_block_size(state);
        startDelay = rubberband_live_get_start_delay(state);

        inputRing.assign(channels, SimpleRingBuffer<float>(65536));
        outputRing.assign(channels, SimpleRingBuffer<float>(65536));
        inputBlock.assign(channels, std::vector<float>(blockSize, 0.f));
        outputBlock.assign(channels, std::vector<float>(blockSize, 0.f));
        inputPointers.resize(channels);
        outputPointers.resize(channels);

        for (unsigned int channel = 0; channel < channels; ++channel) {
            inputPointers[channel] = inputBlock[channel].data();
            outputPointers[channel] = outputBlock[channel].data();
        }

        prime();
    }

    ~LivePitchStreamImpl() {
        if (state) {
            rubberband_live_delete(state);
        }
    }

    void prime() {
        for (unsigned int channel = 0; channel < channelCount; ++channel) {
            inputRing[channel].reset();
            outputRing[channel].reset();
            inputRing[channel].zero(blockSize);
            if (startDelay > 0) {
                outputRing[channel].zero(startDelay);
            }
        }
    }

    void reset() {
        if (!state) {
            return;
        }
        rubberband_live_reset(state);
        rubberband_live_set_pitch_scale(state, pitchScale);
        prime();
    }

    void setSemitones(int newSemitones) {
        const double newScale = semitonesToPitchScale(newSemitones);
        if (newSemitones == semitones) {
            return;
        }

        semitones = newSemitones;
        pitchScale = newScale;

        if (!state) {
            return;
        }

        rubberband_live_set_pitch_scale(state, pitchScale);
    }

    void pump() {
        if (!state || blockSize == 0 || channelCount == 0) {
            return;
        }

        while (inputRing[0].availableToRead() >= blockSize) {
            for (unsigned int channel = 0; channel < channelCount; ++channel) {
                inputRing[channel].read(inputBlock[channel].data(), blockSize);
            }

            rubberband_live_shift(state, inputPointers.data(), outputPointers.data());

            for (unsigned int channel = 0; channel < channelCount; ++channel) {
                outputRing[channel].write(outputBlock[channel].data(), blockSize);
            }
        }
    }

    unsigned int process(
        const float *const *inputChannels,
        unsigned int inputFrameCount,
        float *const *outputChannels,
        unsigned int outputFrameCount
    ) {
        if (!state || channelCount == 0 || outputFrameCount == 0) {
            return 0;
        }

        if (inputChannels && inputFrameCount > 0) {
            for (unsigned int frame = 0; frame < inputFrameCount; ++frame) {
                for (unsigned int channel = 0; channel < channelCount; ++channel) {
                    const float sample = inputChannels[channel][frame];
                    inputRing[channel].write(&sample, 1);
                }
            }
            pump();
        }

        unsigned int written = 0;
        while (written < outputFrameCount) {
            const unsigned int remaining = outputFrameCount - written;
            unsigned int channelRead = outputFrameCount;

            for (unsigned int channel = 0; channel < channelCount; ++channel) {
                channelRead = std::min(
                    channelRead,
                    static_cast<unsigned int>(outputRing[channel].read(
                        outputChannels[channel] + written,
                        remaining
                    ))
                );
            }

            if (channelRead == 0) {
                break;
            }

            written += channelRead;
        }

        return written;
    }
};

} // namespace

LivePitchStream live_pitch_stream_create(unsigned int sampleRate, unsigned int channelCount) {
    if (channelCount == 0) {
        return nullptr;
    }
    return reinterpret_cast<LivePitchStream>(new LivePitchStreamImpl(sampleRate, channelCount));
}

void live_pitch_stream_destroy(LivePitchStream stream) {
    delete reinterpret_cast<LivePitchStreamImpl *>(stream);
}

void live_pitch_stream_reset(LivePitchStream stream) {
    if (auto *impl = reinterpret_cast<LivePitchStreamImpl *>(stream)) {
        impl->reset();
    }
}

void live_pitch_stream_set_semitones(LivePitchStream stream, int semitones) {
    if (auto *impl = reinterpret_cast<LivePitchStreamImpl *>(stream)) {
        impl->setSemitones(semitones);
    }
}

unsigned int live_pitch_stream_process(
    LivePitchStream stream,
    const float *const *inputChannels,
    unsigned int inputFrameCount,
    float *const *outputChannels,
    unsigned int outputFrameCount
) {
    auto *impl = reinterpret_cast<LivePitchStreamImpl *>(stream);
    if (!impl) {
        return 0;
    }
    return impl->process(inputChannels, inputFrameCount, outputChannels, outputFrameCount);
}

