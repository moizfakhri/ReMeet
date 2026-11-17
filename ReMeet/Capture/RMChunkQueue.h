// Lock-free single-producer / single-consumer queue of mono Float32 audio chunks.
//
// The producer is a real-time audio callback (Core Audio IOProc or AVAudioEngine tap).
// Push never allocates, locks, or calls into the runtime: it downmixes the incoming
// AudioBufferList to mono and copies it into a preallocated slot. If the queue is full
// the chunk is dropped and counted; the writer later sees the host-time gap and fills
// it with silence, so the file timeline stays aligned.
//
// The consumer (the file-writer queue) drains with Peek/Pop.

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <CoreAudioTypes/CoreAudioTypes.h>

#pragma clang assume_nonnull begin

typedef struct RMChunkQueue RMChunkQueue;

typedef struct {
    uint64_t hostTime;      // mach host time of the first sample in this chunk
    double sampleRate;      // native sample rate of the source
    uint32_t frameCount;
    const float *_Nullable samples;   // mono, valid until RMChunkQueuePop
} RMChunk;

RMChunkQueue *RMChunkQueueCreate(void);
void RMChunkQueueDestroy(RMChunkQueue *queue);

/// Real-time safe. `abl` must hold Float32 samples. Returns the number of frames accepted.
/// `maxFrames` caps the frame count derived from the buffer byte size (pass UINT32_MAX for none).
uint32_t RMChunkQueuePush(RMChunkQueue *queue,
                          const AudioBufferList *abl,
                          bool interleaved,
                          uint32_t channelsPerFrame,
                          uint32_t maxFrames,
                          uint64_t hostTime,
                          double sampleRate);

bool RMChunkQueuePeek(RMChunkQueue *queue, RMChunk *outChunk);
void RMChunkQueuePop(RMChunkQueue *queue);
uint64_t RMChunkQueueDroppedChunks(RMChunkQueue *queue);

#pragma clang assume_nonnull end
