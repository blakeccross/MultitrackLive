#ifndef PitchShiftBridge_h
#define PitchShiftBridge_h

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float **channels;
    int channelCount;
    int frameCount;
} PitchShiftResult;

/// Offline pitch shift preserving duration. Returns empty result on failure or zero shift.
PitchShiftResult pitch_shift_offline(
    const float *const *inputChannels,
    int channelCount,
    int frameCount,
    double sampleRate,
    int semitoneShift
);

void pitch_shift_free_result(PitchShiftResult result);

typedef struct LivePitchStream_ *LivePitchStream;

/// Real-time pitch shifter comparable to high-quality DAW warp engines.
LivePitchStream live_pitch_stream_create(unsigned int sampleRate, unsigned int channelCount);
void live_pitch_stream_destroy(LivePitchStream stream);
void live_pitch_stream_reset(LivePitchStream stream);
void live_pitch_stream_set_semitones(LivePitchStream stream, int semitones);

/// Streams source audio through the live shifter and writes up to `outputFrameCount` frames.
unsigned int live_pitch_stream_process(
    LivePitchStream stream,
    const float *const *inputChannels,
    unsigned int inputFrameCount,
    float *const *outputChannels,
    unsigned int outputFrameCount
);

#ifdef __cplusplus
}
#endif

#endif
