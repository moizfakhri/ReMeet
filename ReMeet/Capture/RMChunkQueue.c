#include "RMChunkQueue.h"

#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define RM_SLOT_COUNT 256u
#define RM_SLOT_FRAMES 4096u

typedef struct {
    uint64_t hostTime;
    double sampleRate;
    uint32_t frameCount;
    float samples[RM_SLOT_FRAMES];
} RMSlot;

struct RMChunkQueue {
    _Atomic uint32_t head;      // next slot the producer writes
    _Atomic uint32_t tail;      // next slot the consumer reads
    _Atomic uint64_t dropped;
    double ticksPerSecond;
    RMSlot slots[RM_SLOT_COUNT];
};

RMChunkQueue *RMChunkQueueCreate(void) {
    RMChunkQueue *queue = malloc(sizeof(RMChunkQueue));
    if (queue == NULL) abort();
    // Touch every page now so the real-time thread never takes a page fault.
    memset(queue, 0, sizeof(RMChunkQueue));
    atomic_init(&queue->head, 0);
    atomic_init(&queue->tail, 0);
    atomic_init(&queue->dropped, 0);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    queue->ticksPerSecond = 1e9 * (double)timebase.denom / (double)timebase.numer;
    return queue;
}

void RMChunkQueueDestroy(RMChunkQueue *queue) {
    free(queue);
}

uint32_t RMChunkQueuePush(RMChunkQueue *queue,
                          const AudioBufferList *abl,
                          bool interleaved,
                          uint32_t channelsPerFrame,
                          uint32_t maxFrames,
                          uint64_t hostTime,
                          double sampleRate) {
    if (abl->mNumberBuffers == 0 || channelsPerFrame == 0 || sampleRate <= 0) return 0;

    const AudioBuffer *first = &abl->mBuffers[0];
    uint32_t frames = interleaved
        ? first->mDataByteSize / (uint32_t)(sizeof(float) * channelsPerFrame)
        : first->mDataByteSize / (uint32_t)sizeof(float);
    if (frames > maxFrames) frames = maxFrames;

    uint32_t done = 0;
    while (done < frames) {
        uint32_t count = frames - done;
        if (count > RM_SLOT_FRAMES) count = RM_SLOT_FRAMES;

        uint32_t head = atomic_load_explicit(&queue->head, memory_order_relaxed);
        uint32_t tail = atomic_load_explicit(&queue->tail, memory_order_acquire);
        if (head - tail >= RM_SLOT_COUNT) {
            atomic_fetch_add_explicit(&queue->dropped, 1, memory_order_relaxed);
            return done;
        }

        RMSlot *slot = &queue->slots[head % RM_SLOT_COUNT];
        slot->hostTime = hostTime + (uint64_t)((double)done / sampleRate * queue->ticksPerSecond);
        slot->sampleRate = sampleRate;
        slot->frameCount = count;

        if (interleaved) {
            const float *src = (const float *)first->mData;
            if (src == NULL) {
                memset(slot->samples, 0, count * sizeof(float));
            } else if (channelsPerFrame == 1) {
                memcpy(slot->samples, src + done, count * sizeof(float));
            } else {
                const float scale = 1.0f / (float)channelsPerFrame;
                for (uint32_t i = 0; i < count; i++) {
                    const float *frame = src + (size_t)(done + i) * channelsPerFrame;
                    float sum = 0;
                    for (uint32_t c = 0; c < channelsPerFrame; c++) sum += frame[c];
                    slot->samples[i] = sum * scale;
                }
            }
        } else {
            const uint32_t buffers = abl->mNumberBuffers;
            if (buffers == 1) {
                const float *src = (const float *)first->mData;
                if (src == NULL) memset(slot->samples, 0, count * sizeof(float));
                else memcpy(slot->samples, src + done, count * sizeof(float));
            } else {
                const float scale = 1.0f / (float)buffers;
                memset(slot->samples, 0, count * sizeof(float));
                for (uint32_t b = 0; b < buffers; b++) {
                    const float *src = (const float *)abl->mBuffers[b].mData;
                    if (src == NULL) continue;
                    for (uint32_t i = 0; i < count; i++) slot->samples[i] += src[done + i] * scale;
                }
            }
        }

        atomic_store_explicit(&queue->head, head + 1, memory_order_release);
        done += count;
    }
    return done;
}

bool RMChunkQueuePeek(RMChunkQueue *queue, RMChunk *outChunk) {
    uint32_t tail = atomic_load_explicit(&queue->tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&queue->head, memory_order_acquire);
    if (head == tail) return false;
    const RMSlot *slot = &queue->slots[tail % RM_SLOT_COUNT];
    outChunk->hostTime = slot->hostTime;
    outChunk->sampleRate = slot->sampleRate;
    outChunk->frameCount = slot->frameCount;
    outChunk->samples = slot->samples;
    return true;
}

void RMChunkQueuePop(RMChunkQueue *queue) {
    uint32_t tail = atomic_load_explicit(&queue->tail, memory_order_relaxed);
    atomic_store_explicit(&queue->tail, tail + 1, memory_order_release);
}

uint64_t RMChunkQueueDroppedChunks(RMChunkQueue *queue) {
    return atomic_load_explicit(&queue->dropped, memory_order_relaxed);
}
