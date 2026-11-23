/*
 * Goldfish output-only audio device (ported from Android_On_iOS to QEMU 10.2 audio_be_*).
 */
#include "qemu/osdep.h"
#include "android51.h"
#include "android51_host.h"
#include "qemu/audio.h"
#include "system/reset.h"
#include "qapi/error.h"
#include "qemu/error-report.h"

typedef struct GFAudio {
    Android51State *board;
    MemoryRegion io;
    AudioBackend *audio_be;
    SWVoiceOut *voice;
    uint32_t address[2], length[2], offset[2], enabled, status;
    uint8_t pcm[2][65536];
    unsigned next;
} GFAudio;

static void audio_irq(GFAudio *s)
{
    qemu_set_irq(s->board->irqs[16], (s->status & s->enabled) != 0);
}

static void audio_callback(void *opaque, int free_bytes)
{
    GFAudio *s = opaque;
    for (unsigned attempt = 0; attempt < 2 && free_bytes > 0; ++attempt) {
        unsigned i = s->next;
        unsigned remaining = s->length[i] - s->offset[i];
        if (remaining) {
            size_t written = audio_be_write(s->audio_be, s->voice,
                                            s->pcm[i] + s->offset[i],
                                            MIN(remaining, (unsigned)free_bytes));
            android51_host_pcm(s->pcm[i] + s->offset[i], written);
            s->offset[i] += written;
            free_bytes -= written;
            if (s->offset[i] != s->length[i]) {
                break;
            }
            s->status |= 1U << i;
            s->offset[i] = s->length[i] = 0;
        }
        s->next ^= 1;
    }
    audio_irq(s);
}

static uint64_t audio_read(void *opaque, hwaddr offset, unsigned size)
{
    GFAudio *s = opaque;
    if (offset == 0) {
        uint32_t status = s->status & s->enabled;
        s->status &= ~status;
        audio_irq(s);
        return status;
    }
    return 0;
}

static void audio_write(void *opaque, hwaddr offset, uint64_t value, unsigned size)
{
    GFAudio *s = opaque;
    switch (offset) {
    case 4:
        s->enabled = value & 3;
        for (unsigned i = 0; i < 2; ++i) {
            if (!s->length[i]) {
                s->status |= 1U << i;
            }
        }
        audio_be_set_active_out(s->audio_be, s->voice, s->enabled != 0);
        break;
    case 8:
        s->address[0] = value;
        break;
    case 12:
        s->address[1] = value;
        break;
    case 16:
    case 20: {
        unsigned i = (offset - 16) / 4;
        if (!value || (value % 4) || value > sizeof(s->pcm[i]) || s->length[i]) {
            break;
        }
        if (!gf_guest_virtual(s->board, s->address[i], s->pcm[i], value, false)) {
            break;
        }
        s->length[i] = value;
        s->offset[i] = 0;
        s->status &= ~(1U << i);
        break;
    }
    }
    audio_irq(s);
}

static const MemoryRegionOps audio_ops = {
    .read = audio_read,
    .write = audio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

static void audio_reset(void *opaque)
{
    GFAudio *s = opaque;
    memset(s->address, 0, sizeof(s->address));
    memset(s->length, 0, sizeof(s->length));
    memset(s->offset, 0, sizeof(s->offset));
    s->next = s->enabled = 0;
    s->status = 3;
    audio_be_set_active_out(s->audio_be, s->voice, false);
    audio_irq(s);
}

void gf_audio_init(Android51State *board)
{
    GFAudio *s = g_new0(GFAudio, 1);
    struct audsettings settings = {
        .freq = 44100,
        .nchannels = 2,
        .fmt = AUDIO_FORMAT_S16,
        .big_endian = false,
    };
    s->board = board;
    if (MACHINE(board)->audiodev) {
        s->audio_be = audio_be_by_name(MACHINE(board)->audiodev, &error_fatal);
    } else {
        s->audio_be = audio_get_default_audio_be(&error_fatal);
    }
    s->voice = audio_be_open_out(s->audio_be, NULL, "goldfish-output", s, audio_callback, &settings);
    if (!s->voice) {
        error_report("android51: cannot open Goldfish PCM output");
        exit(EXIT_FAILURE);
    }
    gf_map(board, &s->io, "android51.audio", 0xff004000, &audio_ops, s);
    gf_register(board, "goldfish_audio", -1, 0xff004000, 0x1000, 16, 1);
    qemu_register_reset(audio_reset, s);
}
