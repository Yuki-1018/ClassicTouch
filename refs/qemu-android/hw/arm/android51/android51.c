/*
 * Android51 Goldfish ARMv7 Machine.
 */
#include "qemu/osdep.h"
#include "android51.h"
#include "android51_host.h"
#include "gpu.h"
#include "qemu/units.h"
#include "qemu/error-report.h"
#include "qapi/error.h"
#include "qapi/visitor.h"
#include "hw/net/smc91c111.h"
#include "hw/arm/machines-qom.h"
#include "system/reset.h"
#include "exec/cpu-common.h"
#include "exec/target_page.h"

void gf_register(Android51State *s, const char *name, int32_t id,
                 uint32_t base, uint32_t size, uint32_t irq, uint32_t irq_count)
{
    g_assert(s->device_count < GF_MAX_DEVICES);
    g_assert(irq < 32 && irq_count <= 32 - irq);
    s->devices[s->device_count++] = (GFDevice){ name, base, size, irq, irq_count, id };
}

void gf_map(Android51State *s, MemoryRegion *mr, const char *name, uint32_t base,
            const MemoryRegionOps *ops, void *opaque)
{
    memory_region_init_io(mr, OBJECT(s), ops, opaque, name, 0x1000);
    memory_region_add_subregion(get_system_memory(), base, mr);
}

static hwaddr gf_translate_vaddr(Android51State *s, uint32_t vaddr)
{
    CPUState *cs = CPU(s->cpu);
    CPUARMState *env = &s->cpu->env;
    if (s->kernel_ttbr0 == 0 && (env->cp15.sctlr_el[1] & 1) && env->cp15.ttbr0_el[1] != 0) {
        s->kernel_ttbr0 = env->cp15.ttbr0_el[1];
    }
    hwaddr page = cpu_get_phys_page_debug(cs, vaddr);
    if (page == (hwaddr)-1 && vaddr >= 0x80000000U && s->kernel_ttbr0 != 0 &&
        env->cp15.ttbr0_el[1] != s->kernel_ttbr0) {
        /* 32-bit ARM splits vmalloc L1 entries lazily from swapper_pg_dir. */
        uint64_t saved = env->cp15.ttbr0_el[1];
        env->cp15.ttbr0_el[1] = s->kernel_ttbr0;
        page = cpu_get_phys_page_debug(cs, vaddr);
        env->cp15.ttbr0_el[1] = saved;
    }
    return page;
}

static void android51_reset(void *opaque)
{
    Android51State *s = opaque;
    s->kernel_ttbr0 = 0;
}

bool gf_guest_virtual(Android51State *s, uint32_t address, void *buffer,
                      size_t length, bool write)
{
    if (length > INT_MAX || length > (1ULL << 32) - address) {
        return false;
    }
    hwaddr page_size = qemu_target_page_size();
    hwaddr page_mask = ~(page_size - 1);
    for (uint64_t cursor = address, end = cursor + length; cursor < end;) {
        hwaddr page = gf_translate_vaddr(s, cursor & page_mask);
        size_t chunk = MIN(end - cursor, page_size - (cursor & ~page_mask));
        uint64_t physical = page + (cursor & ~page_mask);
        if (page == (hwaddr)-1 || physical >= MACHINE(s)->ram_size ||
            chunk > MACHINE(s)->ram_size - physical) {
            return false;
        }
        cursor += chunk;
    }
    uint8_t *buf = (uint8_t *)buffer;
    for (uint64_t cursor = address, end = cursor + length; cursor < end;) {
        hwaddr page = gf_translate_vaddr(s, cursor & page_mask);
        size_t chunk = MIN(end - cursor, page_size - (cursor & ~page_mask));
        uint64_t physical = page + (cursor & ~page_mask);
        if (address_space_rw(&address_space_memory, physical,
                             MEMTXATTRS_UNSPECIFIED, buf, chunk, write) != MEMTX_OK) {
            return false;
        }
        buf += chunk;
        cursor += chunk;
    }
    return true;
}

static void android51_init(MachineState *machine)
{
    Android51State *s = ANDROID51_MACHINE(machine);
    if (machine->ram_size < 128 * MiB || machine->ram_size > 4080 * MiB) {
        error_report("android51: RAM must be between 128 and 4080 MiB (top 16 MiB reserved for MMIO)");
        exit(EXIT_FAILURE);
    }
    if (s->width < 320 || s->width > 1080 || s->height < 480 || s->height > 2400 ||
        (s->width % 2) || (s->height % 2)) {
        error_report("android51: unsupported display dimensions %ux%u", s->width, s->height);
        exit(EXIT_FAILURE);
    }
    if (s->lcd_density < 120 || s->lcd_density > 640) {
        s->lcd_density = 320;
    }

    s->cpu = ARM_CPU(cpu_create(machine->cpu_type));
    memory_region_add_subregion(get_system_memory(), 0, machine->ram);

    gf_platform_init(s);
    gf_register(s, "smc91x", 0, 0xff020000, 0x1000, 10, 1);
    smc91c111_init(0xff020000, s->irqs[10]);
    gf_nand_init(s);

    const char *existing_cmd = machine->kernel_cmdline ? machine->kernel_cmdline : "";
    bool want_gpu = s->gpu_enabled && (strstr(existing_cmd, "qemu.gles=0") == NULL);
    s->gpu_ready = want_gpu ? (ae_gpu_init(s->width, s->height) != 0) : false;

    char *init_msg = g_strdup_printf(
        "[android51] init ram=%lluMB lcd=%ux%u dpi=%u want_gpu=%d gpu_ready=%d err=%s\n",
        (unsigned long long)(machine->ram_size / MiB),
        s->width, s->height, s->lcd_density,
        want_gpu ? 1 : 0, s->gpu_ready ? 1 : 0,
        (!s->gpu_ready && want_gpu && ae_gpu_last_error()) ? ae_gpu_last_error() : "none");
    fprintf(stderr, "%s", init_msg);
    android51_host_serial((const uint8_t *)init_msg, strlen(init_msg));
    g_free(init_msg);

    gf_display_init(s);
    gf_events_init(s);
    gf_battery_init(s);
    gf_pipes_init(s);
    gf_audio_init(s);

    s->boot.ram_size = machine->ram_size;
    s->boot.loader_start = 0;
    s->boot.board_id = 1441;
    s->kernel_ttbr0 = 0;
    qemu_register_reset(android51_reset, s);

    if (strstr(existing_cmd, "qemu.gles=") == NULL) {
        char *cmdline = g_strdup_printf("%s%sqemu.gles=%d",
                                        existing_cmd,
                                        *existing_cmd ? " " : "",
                                        s->gpu_ready ? 1 : 0);
        g_free(machine->kernel_cmdline);
        machine->kernel_cmdline = cmdline;
    }
    arm_load_kernel(s->cpu, machine, &s->boot);
}

static void u32_prop_get(Object *obj, Visitor *v, const char *name, void *opaque, Error **errp)
{
    Android51State *s = ANDROID51_MACHINE(obj);
    uint32_t value = !strcmp(name, "width") ? s->width
                   : (!strcmp(name, "height") ? s->height : s->lcd_density);
    visit_type_uint32(v, name, &value, errp);
}

static void u32_prop_set(Object *obj, Visitor *v, const char *name, void *opaque, Error **errp)
{
    Android51State *s = ANDROID51_MACHINE(obj);
    uint32_t *dst = !strcmp(name, "width") ? &s->width
                  : (!strcmp(name, "height") ? &s->height : &s->lcd_density);
    visit_type_uint32(v, name, dst, errp);
}

static bool gpu_prop_get(Object *obj, Error **errp)
{
    return ANDROID51_MACHINE(obj)->gpu_enabled;
}

static void gpu_prop_set(Object *obj, bool value, Error **errp)
{
    ANDROID51_MACHINE(obj)->gpu_enabled = value;
}

static void android51_instance_init(Object *obj)
{
    Android51State *s = ANDROID51_MACHINE(obj);
    s->width = 750;
    s->height = 1334;
    s->lcd_density = 320;
    s->gpu_enabled = true;
}

static void android51_class_init(ObjectClass *klass, const void *data)
{
    MachineClass *mc = MACHINE_CLASS(klass);
    mc->desc = "Android 4.4/5/6/7 ARMv7 Goldfish";
    mc->init = android51_init;
    mc->default_cpu_type = ARM_CPU_TYPE_NAME("cortex-a8");
    mc->default_ram_id = "android51.ram";
    mc->default_ram_size = 768 * MiB;
    mc->max_cpus = 1;
    mc->default_cpus = 1;
    mc->no_parallel = true;
    mc->no_floppy = true;
    mc->no_cdrom = true;
    mc->ignore_memory_transaction_failures = true;
    machine_add_audiodev_property(mc);
    object_class_property_add(klass, "width", "uint32", u32_prop_get, u32_prop_set, NULL, NULL);
    object_class_property_add(klass, "height", "uint32", u32_prop_get, u32_prop_set, NULL, NULL);
    object_class_property_add(klass, "density", "uint32", u32_prop_get, u32_prop_set, NULL, NULL);
    object_class_property_add_bool(klass, "gpu", gpu_prop_get, gpu_prop_set);
}

static const TypeInfo android51_type = {
    .name = TYPE_ANDROID51_MACHINE,
    .parent = TYPE_MACHINE,
    .instance_size = sizeof(Android51State),
    .class_init = android51_class_init,
    .instance_init = android51_instance_init,
    .interfaces = arm_machine_interfaces,
};

static void android51_register_types(void)
{
    type_register_static(&android51_type);
}

type_init(android51_register_types)
