/*
 * Goldfish battery device.
 */
#include "qemu/osdep.h"
#include "android51.h"
#include "system/reset.h"
#include "qemu/main-loop.h"

typedef struct GFBattery {
    Android51State *board;
    MemoryRegion io;
    uint32_t enabled, status;
    int ac_online, bat_status, capacity;
} GFBattery;

static GFBattery *active_battery;

static void battery_irq(GFBattery *s)
{
    qemu_set_irq(s->board->irqs[14], (s->enabled & s->status) != 0);
}

void android51_battery_set_status(int ac_online, int status, int level)
{
    GFBattery *s = active_battery;
    if (!s || !bql_locked()) {
        return;
    }
    int prev_ac = s->ac_online;
    s->ac_online = ac_online ? 1 : 0;
    s->bat_status = status > 0 ? status : 4;
    if (level < 0) level = 0;
    if (level > 100) level = 100;
    s->capacity = level;
    s->status |= 1U;
    if (prev_ac != s->ac_online) {
        s->status |= 2U;
    }
    battery_irq(s);
}

static uint64_t battery_read(void *opaque, hwaddr offset, unsigned size)
{
    GFBattery *s = opaque;
    switch (offset) {
    case 0: {
        uint32_t status = s->status & s->enabled;
        if (status) {
            s->status = 0;
            battery_irq(s);
        }
        return status;
    }
    case 4:  return s->enabled;
    case 8:  return (uint32_t)s->ac_online;
    case 12: return (uint32_t)s->bat_status;
    case 16: return 1; /* POWER_SUPPLY_HEALTH_GOOD */
    case 20: return 1; /* present */
    case 24: return (uint32_t)s->capacity;
    default: return 0;
    }
}

static void battery_write(void *opaque, hwaddr offset, uint64_t value, unsigned size)
{
    GFBattery *s = opaque;
    if (offset == 4) {
        s->enabled = value & 3;
        battery_irq(s);
    }
}

static const MemoryRegionOps battery_ops = {
    .read = battery_read,
    .write = battery_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

static void battery_reset(void *opaque)
{
    GFBattery *s = opaque;
    s->enabled = 0;
    s->status = 3;
    battery_irq(s);
}

void gf_battery_init(Android51State *board)
{
    GFBattery *s = g_new0(GFBattery, 1);
    s->board = board;
    s->ac_online = 1;
    s->bat_status = 4; /* FULL */
    s->capacity = 100;
    active_battery = s;
    gf_map(board, &s->io, "android51.battery", 0xff060000, &battery_ops, s);
    gf_register(board, "goldfish-battery", 0, 0xff060000, 0x1000, 14, 1);
    qemu_register_reset(battery_reset, s);
}
