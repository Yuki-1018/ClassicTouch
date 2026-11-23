#ifndef IPOD_TOUCH_NOR_SPI_H
#define IPOD_TOUCH_NOR_SPI_H

#include "qemu/osdep.h"
#include "qemu/module.h"
#include "qemu/timer.h"
#include "hw/ssi/ssi.h"
#include "hw/core/hw-error.h"

#define TYPE_IPOD_TOUCH_NOR_SPI                "ipodtouch.norspi"
OBJECT_DECLARE_SIMPLE_TYPE(IPodTouchNORSPIState, IPOD_TOUCH_NOR_SPI)

#define NOR_FLASH_SIZE (1u << 20)
#define NOR_PAGE_SIZE 256
#define NOR_SECTOR_SIZE (64u << 10)
#define NOR_NUM_SECTORS (NOR_FLASH_SIZE / NOR_SECTOR_SIZE)
#define NOR_ERASE_32K 0x52
#define NOR_ERASE_64K 0xd8

#define NOR_WRITE_TO_STATUS_REG 0x1
#define NOR_WRITE_DATA_CMD 0x2
#define NOR_READ_DATA_CMD  0x3
#define NOR_DISABLE_WRITE  0x4
#define NOR_GET_STATUS_CMD 0x5
#define NOR_ENABLE_WRITE   0x6
#define NOR_ERASE_BLOCK    0x20
#define NOR_PROTECT_SECTOR   0x36
#define NOR_UNPROTECT_SECTOR 0x39
#define NOR_READ_SECTOR_PROT 0x3c
#define NOR_ENABLE_WRITE_STATUS 0x50
#define NOR_GLOBAL_UNPROTECT 0x98
#define NOR_GET_JEDECID    0x9F

typedef struct IPodTouchNORSPIState {
    SSIPeripheral ssidev;
    char *nor_path;
    BlockBackend *blk;
    bool restore_pending;
    const char *boot_args;
    uint32_t cur_cmd;
    uint8_t nor_data[NOR_FLASH_SIZE];
    uint32_t nor_size;
    uint8_t write_enabled;
    uint32_t nor_read_ind;
    uint8_t address_bytes, page_offset, stream_offset, status;
    uint16_t data_count;
    uint8_t page[NOR_PAGE_SIZE];
    uint8_t sector_prot[NOR_NUM_SECTORS];
    bool command_active;
    bool nor_initialized;
} IPodTouchNORSPIState;

bool ipod_touch_nor_io_failed(void);
void ipod_touch_nor_spi_open_overlay(IPodTouchNORSPIState *s, const char *path, Error **errp);

#endif