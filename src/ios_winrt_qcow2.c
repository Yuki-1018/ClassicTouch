#include "ios_winrt_qcow2.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define QCOW2_MAGIC             0x514649fbU
#define QCOW2_VERSION_3         3U
#define QCOW2_CLUSTER_BITS      16U
#define QCOW2_CLUSTER_SIZE      (1ULL << QCOW2_CLUSTER_BITS) /* 65536 */
#define QCOW2_L2_ENTRIES        (QCOW2_CLUSTER_SIZE / 8ULL)  /* 8192 */
#define QCOW2_REFCOUNT_ORDER    4U                           /* 16-bit */
#define QCOW2_REFBLOCK_ENTRIES  (QCOW2_CLUSTER_SIZE / 2ULL)  /* 32768 */
#define QCOW2_REFTABLE_ENTRIES  (QCOW2_CLUSTER_SIZE / 8ULL)  /* 8192 */
#define QCOW2_OFLAG_COPIED      (1ULL << 63)
#define QCOW2_HEADER_LEN_V3     104U

static inline void put_be16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)(v & 0xff);
}

static inline void put_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)((v >> 16) & 0xff);
    p[2] = (uint8_t)((v >> 8) & 0xff);
    p[3] = (uint8_t)(v & 0xff);
}

static inline void put_be64(uint8_t *p, uint64_t v) {
    put_be32(p, (uint32_t)(v >> 32));
    put_be32(p + 4, (uint32_t)(v & 0xffffffffU));
}

static inline uint32_t get_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static inline uint64_t get_be64(const uint8_t *p) {
    return ((uint64_t)get_be32(p) << 32) | (uint64_t)get_be32(p + 4);
}

static int pwrite_full(int fd, const void *buf, size_t len, off_t off) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = pwrite(fd, p + done, len - done, off + (off_t)done);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
        if (n == 0) return -EIO;
        done += (size_t)n;
    }
    return 0;
}

static int pread_full(int fd, void *buf, size_t len, off_t off) {
    uint8_t *p = (uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = pread(fd, p + done, len - done, off + (off_t)done);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
        if (n == 0) {
            memset(p + done, 0, len - done);
            return 0;
        }
        done += (size_t)n;
    }
    return 0;
}

static bool is_all_zero(const uint8_t *buf, size_t len) {
    const uint64_t *p = (const uint64_t *)buf;
    size_t n = len / sizeof(uint64_t);
    for (size_t i = 0; i < n; i++) {
        if (p[i] != 0) return false;
    }
    for (size_t i = n * sizeof(uint64_t); i < len; i++) {
        if (buf[i] != 0) return false;
    }
    return true;
}

static void encode_qcow2_header(uint8_t hdr[QCOW2_CLUSTER_SIZE],
                                uint64_t virtual_size,
                                uint32_t l1_size,
                                uint64_t l1_table_offset,
                                uint64_t reftable_offset,
                                uint32_t reftable_clusters) {
    memset(hdr, 0, QCOW2_CLUSTER_SIZE);
    put_be32(hdr + 0,  QCOW2_MAGIC);
    put_be32(hdr + 4,  QCOW2_VERSION_3);
    put_be64(hdr + 8,  0); /* backing_file_offset */
    put_be32(hdr + 16, 0); /* backing_file_size */
    put_be32(hdr + 20, QCOW2_CLUSTER_BITS);
    put_be64(hdr + 24, virtual_size);
    put_be32(hdr + 32, 0); /* crypt_method */
    put_be32(hdr + 36, l1_size);
    put_be64(hdr + 40, l1_table_offset);
    put_be64(hdr + 48, reftable_offset);
    put_be32(hdr + 56, reftable_clusters);
    put_be32(hdr + 60, 0); /* nb_snapshots */
    put_be64(hdr + 64, 0); /* snapshots_offset */
    put_be64(hdr + 72, 0); /* incompatible_features */
    put_be64(hdr + 80, 0); /* compatible_features */
    put_be64(hdr + 88, 0); /* autoclear_features */
    put_be32(hdr + 96, QCOW2_REFCOUNT_ORDER);
    put_be32(hdr + 100, QCOW2_HEADER_LEN_V3);
}

int winrt_qcow2_create_blank(const char *path, uint64_t virtual_size_bytes) {
    if (!path || !*path || virtual_size_bytes < (1ULL << 20) ||
        (virtual_size_bytes % (512ULL * 1024ULL)) != 0) {
        return -EINVAL;
    }

    uint64_t l2_span = QCOW2_L2_ENTRIES * QCOW2_CLUSTER_SIZE; /* 512 MiB */
    uint64_t l1_entries = (virtual_size_bytes + l2_span - 1) / l2_span;
    if (l1_entries == 0 || l1_entries > (1ULL << 24)) {
        return -EINVAL;
    }
    uint64_t l1_bytes = l1_entries * 8ULL;
    uint64_t l1_clusters = (l1_bytes + QCOW2_CLUSTER_SIZE - 1) / QCOW2_CLUSTER_SIZE;

    /* Layout:
     *   Cluster 0: Header
     *   Cluster 1: Refcount Table (1 cluster)
     *   Cluster 2: Refcount Block 0 (1 cluster, covers up to 32768 clusters = 2 GiB)
     *   Cluster 3 .. 3 + l1_clusters - 1: L1 Table (all zeros)
     */
    uint64_t total_clusters = 3ULL + l1_clusters;
    if (total_clusters > QCOW2_REFBLOCK_ENTRIES) {
        return -EINVAL;
    }

    uint8_t *cluster = (uint8_t *)calloc(1, QCOW2_CLUSTER_SIZE);
    if (!cluster) return -ENOMEM;

    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (fd < 0) {
        int err = -errno;
        free(cluster);
        return err;
    }

    int rc = 0;
    /* Cluster 0: Header */
    encode_qcow2_header(cluster, virtual_size_bytes, (uint32_t)l1_entries,
                        3ULL * QCOW2_CLUSTER_SIZE,
                        1ULL * QCOW2_CLUSTER_SIZE, 1U);
    rc = pwrite_full(fd, cluster, QCOW2_CLUSTER_SIZE, 0);

    /* Cluster 1: Refcount Table -> entry[0] = Cluster 2 */
    if (rc == 0) {
        memset(cluster, 0, QCOW2_CLUSTER_SIZE);
        put_be64(cluster, 2ULL * QCOW2_CLUSTER_SIZE);
        rc = pwrite_full(fd, cluster, QCOW2_CLUSTER_SIZE, (off_t)QCOW2_CLUSTER_SIZE);
    }

    /* Cluster 2: Refcount Block 0 -> refcount=1 for clusters 0..total_clusters-1 */
    if (rc == 0) {
        memset(cluster, 0, QCOW2_CLUSTER_SIZE);
        for (uint64_t c = 0; c < total_clusters; c++) {
            put_be16(cluster + c * 2ULL, 1U);
        }
        rc = pwrite_full(fd, cluster, QCOW2_CLUSTER_SIZE, (off_t)(2ULL * QCOW2_CLUSTER_SIZE));
    }

    /* Clusters 3..: Zeroed L1 Table */
    if (rc == 0) {
        memset(cluster, 0, QCOW2_CLUSTER_SIZE);
        for (uint64_t i = 0; i < l1_clusters && rc == 0; i++) {
            rc = pwrite_full(fd, cluster, QCOW2_CLUSTER_SIZE,
                             (off_t)((3ULL + i) * QCOW2_CLUSTER_SIZE));
        }
    }

    if (rc == 0 && fsync(fd) != 0) {
        rc = -errno;
    }
    close(fd);
    free(cluster);
    if (rc != 0) {
        unlink(path);
    }
    return rc;
}

int winrt_qcow2_convert_from_raw(const char *src_raw_path,
                                 const char *dst_qcow2_path,
                                 winrt_qcow2_progress_cb progress_cb,
                                 void *ctx) {
    if (!src_raw_path || !*src_raw_path || !dst_qcow2_path || !*dst_qcow2_path) {
        return -EINVAL;
    }

    int sfd = open(src_raw_path, O_RDONLY);
    if (sfd < 0) return -errno;

    struct stat st;
    if (fstat(sfd, &st) != 0) {
        int err = -errno;
        close(sfd);
        return err;
    }
    if (st.st_size < (off_t)(1ULL << 20)) {
        close(sfd);
        return -EINVAL;
    }

    /* Round virtual size up to 512 KiB (SD card alignment requirement). */
    uint64_t raw_size = (uint64_t)st.st_size;
    uint64_t align512k = 512ULL * 1024ULL;
    uint64_t virtual_size = ((raw_size + align512k - 1ULL) / align512k) * align512k;
    uint64_t total_vclusters = (virtual_size + QCOW2_CLUSTER_SIZE - 1ULL) / QCOW2_CLUSTER_SIZE;

    uint64_t l2_span = QCOW2_L2_ENTRIES * QCOW2_CLUSTER_SIZE;
    uint64_t l1_entries = (virtual_size + l2_span - 1ULL) / l2_span;
    uint64_t l1_clusters = (l1_entries * 8ULL + QCOW2_CLUSTER_SIZE - 1ULL) / QCOW2_CLUSTER_SIZE;

    int dfd = open(dst_qcow2_path, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (dfd < 0) {
        int err = -errno;
        close(sfd);
        return err;
    }

    uint64_t *l1_table = (uint64_t *)calloc(l1_entries, sizeof(uint64_t));
    uint8_t *l2_buf = (uint8_t *)malloc(QCOW2_CLUSTER_SIZE);
    uint8_t *io_buf = (uint8_t *)malloc(QCOW2_CLUSTER_SIZE);
    if (!l1_table || !l2_buf || !io_buf) {
        free(l1_table);
        free(l2_buf);
        free(io_buf);
        close(sfd);
        close(dfd);
        unlink(dst_qcow2_path);
        return -ENOMEM;
    }

    /* Layout:
     *   Cluster 0: Header (written at end once refcount table is finalized)
     *   Cluster 1 .. l1_clusters: L1 Table (written at end)
     *   Cluster (1 + l1_clusters) .. : Data clusters + L2 clusters
     *   Trailing: Refcount blocks + Refcount table (at the very end, sized exactly)
     */
    uint64_t l1_offset = 1ULL * QCOW2_CLUSTER_SIZE;
    uint64_t next_cluster = 1ULL + l1_clusters;

    int rc = 0;
    double last_pct = -1.0;

    for (uint64_t l1_idx = 0; l1_idx < l1_entries && rc == 0; l1_idx++) {
        uint64_t vc_start = l1_idx * QCOW2_L2_ENTRIES;
        uint64_t vc_end = vc_start + QCOW2_L2_ENTRIES;
        if (vc_end > total_vclusters) vc_end = total_vclusters;

        memset(l2_buf, 0, QCOW2_CLUSTER_SIZE);
        bool l2_has_data = false;

        uint64_t vc = vc_start;
        while (vc < vc_end && rc == 0) {
            uint64_t src_off = vc * QCOW2_CLUSTER_SIZE;
            if (src_off >= raw_size) break;

#ifdef SEEK_DATA
            off_t data_off = lseek(sfd, (off_t)src_off, SEEK_DATA);
            if (data_off < 0) {
                if (errno == ENXIO) {
                    /* Rest of file is a sparse hole */
                    vc = vc_end;
                    break;
                }
                /* Filesystem doesn't support SEEK_DATA: fall through to pread */
            } else if ((uint64_t)data_off >= (vc + 1ULL) * QCOW2_CLUSTER_SIZE) {
                uint64_t next_vc = (uint64_t)data_off / QCOW2_CLUSTER_SIZE;
                vc = (next_vc < vc_end) ? next_vc : vc_end;
                continue;
            }
#endif

            size_t to_read = QCOW2_CLUSTER_SIZE;
            if (src_off + to_read > raw_size) {
                to_read = (size_t)(raw_size - src_off);
                memset(io_buf + to_read, 0, QCOW2_CLUSTER_SIZE - to_read);
            }
            rc = pread_full(sfd, io_buf, to_read, (off_t)src_off);
            if (rc != 0) break;

            if (!is_all_zero(io_buf, QCOW2_CLUSTER_SIZE)) {
                uint64_t phys_off = next_cluster * QCOW2_CLUSTER_SIZE;
                rc = pwrite_full(dfd, io_buf, QCOW2_CLUSTER_SIZE, (off_t)phys_off);
                if (rc != 0) break;
                next_cluster++;
                put_be64(l2_buf + (vc - vc_start) * 8ULL, QCOW2_OFLAG_COPIED | phys_off);
                l2_has_data = true;
            }
            vc++;
        }

        if (rc == 0 && l2_has_data) {
            uint64_t l2_off = next_cluster * QCOW2_CLUSTER_SIZE;
            rc = pwrite_full(dfd, l2_buf, QCOW2_CLUSTER_SIZE, (off_t)l2_off);
            if (rc == 0) {
                next_cluster++;
                l1_table[l1_idx] = QCOW2_OFLAG_COPIED | l2_off;
            }
        }

        if (progress_cb && rc == 0) {
            double pct = (double)(l1_idx + 1) / (double)l1_entries * 0.95;
            if (pct - last_pct >= 0.02) {
                last_pct = pct;
                progress_cb(pct, ctx);
            }
        }
    }

    /* Write L1 Table */
    if (rc == 0) {
        for (uint64_t ci = 0; ci < l1_clusters && rc == 0; ci++) {
            memset(io_buf, 0, QCOW2_CLUSTER_SIZE);
            uint64_t e_start = ci * (QCOW2_CLUSTER_SIZE / 8ULL);
            uint64_t e_count = QCOW2_CLUSTER_SIZE / 8ULL;
            if (e_start + e_count > l1_entries) e_count = l1_entries - e_start;
            for (uint64_t i = 0; i < e_count; i++) {
                put_be64(io_buf + i * 8ULL, l1_table[e_start + i]);
            }
            rc = pwrite_full(dfd, io_buf, QCOW2_CLUSTER_SIZE,
                             (off_t)(l1_offset + ci * QCOW2_CLUSTER_SIZE));
        }
    }

    /* Compute exact refcount table + refcount blocks at the end of the image */
    uint64_t reftable_clusters = 1ULL;
    uint64_t refblocks = 1ULL;
    uint64_t total_clusters = next_cluster;
    for (int iter = 0; iter < 8; iter++) {
        uint64_t cand_total = next_cluster + reftable_clusters + refblocks;
        uint64_t need_rb = (cand_total + QCOW2_REFBLOCK_ENTRIES - 1ULL) / QCOW2_REFBLOCK_ENTRIES;
        if (need_rb == 0) need_rb = 1ULL;
        uint64_t need_rt = (need_rb + QCOW2_REFTABLE_ENTRIES - 1ULL) / QCOW2_REFTABLE_ENTRIES;
        if (need_rt == 0) need_rt = 1ULL;
        if (need_rb == refblocks && need_rt == reftable_clusters) {
            total_clusters = cand_total;
            break;
        }
        refblocks = need_rb;
        reftable_clusters = need_rt;
        total_clusters = next_cluster + reftable_clusters + refblocks;
    }

    uint64_t reftable_first_cluster = next_cluster;
    uint64_t refblock_first_cluster = next_cluster + reftable_clusters;

    /* Write Refcount Table */
    if (rc == 0) {
        for (uint64_t ti = 0; ti < reftable_clusters && rc == 0; ti++) {
            memset(io_buf, 0, QCOW2_CLUSTER_SIZE);
            uint64_t rb_start = ti * QCOW2_REFTABLE_ENTRIES;
            uint64_t rb_count = QCOW2_REFTABLE_ENTRIES;
            if (rb_start + rb_count > refblocks) rb_count = refblocks - rb_start;
            for (uint64_t i = 0; i < rb_count; i++) {
                uint64_t rb_off = (refblock_first_cluster + rb_start + i) * QCOW2_CLUSTER_SIZE;
                put_be64(io_buf + i * 8ULL, rb_off);
            }
            rc = pwrite_full(dfd, io_buf, QCOW2_CLUSTER_SIZE,
                             (off_t)((reftable_first_cluster + ti) * QCOW2_CLUSTER_SIZE));
        }
    }

    /* Write Refcount Blocks: every cluster 0..total_clusters-1 has refcount 1 */
    if (rc == 0) {
        for (uint64_t bi = 0; bi < refblocks && rc == 0; bi++) {
            memset(io_buf, 0, QCOW2_CLUSTER_SIZE);
            uint64_t c_start = bi * QCOW2_REFBLOCK_ENTRIES;
            uint64_t c_end = c_start + QCOW2_REFBLOCK_ENTRIES;
            if (c_end > total_clusters) c_end = total_clusters;
            for (uint64_t c = c_start; c < c_end; c++) {
                put_be16(io_buf + (c - c_start) * 2ULL, 1U);
            }
            rc = pwrite_full(dfd, io_buf, QCOW2_CLUSTER_SIZE,
                             (off_t)((refblock_first_cluster + bi) * QCOW2_CLUSTER_SIZE));
        }
    }

    /* Write QCOW2 v3 Header at Cluster 0 */
    if (rc == 0) {
        encode_qcow2_header(io_buf, virtual_size, (uint32_t)l1_entries,
                            l1_offset,
                            reftable_first_cluster * QCOW2_CLUSTER_SIZE,
                            (uint32_t)reftable_clusters);
        rc = pwrite_full(dfd, io_buf, QCOW2_CLUSTER_SIZE, 0);
    }

    if (rc == 0 && fsync(dfd) != 0) {
        rc = -errno;
    }

    free(l1_table);
    free(l2_buf);
    free(io_buf);
    close(sfd);
    close(dfd);

    if (rc != 0) {
        unlink(dst_qcow2_path);
    } else if (progress_cb) {
        progress_cb(1.0, ctx);
    }
    return rc;
}

bool winrt_qcow2_read_virtual_size(const char *path, uint64_t *out_virtual_size) {
    if (!path || !*path || !out_virtual_size) return false;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    uint8_t hdr[32];
    ssize_t n = pread(fd, hdr, sizeof(hdr), 0);
    close(fd);
    if (n != (ssize_t)sizeof(hdr)) return false;
    if (get_be32(hdr) != QCOW2_MAGIC) return false;
    uint32_t ver = get_be32(hdr + 4);
    if (ver != 2 && ver != 3) return false;
    *out_virtual_size = get_be64(hdr + 24);
    return true;
}
