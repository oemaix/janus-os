/* SPDX-License-Identifier: Apache-2.0
 * Le Potato keeps the Amlogic FIP at LBA 1, so the primary GPT cannot live
 * there. The backup GPT is what the board reads. This tool writes the DOS
 * table the image needs, moves that backup to the end of a larger card,
 * and grows JANUS_STATE without writing LBA 1. docs/10 §3.6, D-0055.
 */
#define _FILE_OFFSET_BITS 64

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
  SECTOR = 512,
  ENTRY_SIZE = 128,
  HEADER_SIZE = 92,
  MAX_LOGICAL = 8,
  ENTRY_COUNT = 128
};

static const uint8_t HINT_MAGIC[8] = {'J', 'A', 'N', 'U', 'S', 'G', 'P', 'T'};
static const uint8_t EFI_MAGIC[8] = {
    'E', 'F', 'I', ' ', 'P', 'A', 'R', 'T'};

/* EFI System Partition and Linux filesystem, the types sgdisk writes for
 * EF00 and 8300. Mixed-endian on disk. */
static const char *TYPE_EFI = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b";
static const char *TYPE_LINUX = "0fc63daf-8483-4772-8e79-3d69d8477de4";
static const char *DISK_GUID = "4a414e55-5300-4000-8000-000000000000";

static const uint32_t CRC_TABLE[256] = {
    0x00000000, 0x77073096, 0xee0e612c, 0x990951ba, 0x076dc419, 0x706af48f,
    0xe963a535, 0x9e6495a3, 0x0edb8832, 0x79dcb8a4, 0xe0d5e91e, 0x97d2d988,
    0x09b64c2b, 0x7eb17cbd, 0xe7b82d07, 0x90bf1d91, 0x1db71064, 0x6ab020f2,
    0xf3b97148, 0x84be41de, 0x1adad47d, 0x6ddde4eb, 0xf4d4b551, 0x83d385c7,
    0x136c9856, 0x646ba8c0, 0xfd62f97a, 0x8a65c9ec, 0x14015c4f, 0x63066cd9,
    0xfa0f3d63, 0x8d080df5, 0x3b6e20c8, 0x4c69105e, 0xd56041e4, 0xa2677172,
    0x3c03e4d1, 0x4b04d447, 0xd20d85fd, 0xa50ab56b, 0x35b5a8fa, 0x42b2986c,
    0xdbbbc9d6, 0xacbcf940, 0x32d86ce3, 0x45df5c75, 0xdcd60dcf, 0xabd13d59,
    0x26d930ac, 0x51de003a, 0xc8d75180, 0xbfd06116, 0x21b4f4b5, 0x56b3c423,
    0xcfba9599, 0xb8bda50f, 0x2802b89e, 0x5f058808, 0xc60cd9b2, 0xb10be924,
    0x2f6f7c87, 0x58684c11, 0xc1611dab, 0xb6662d3d, 0x76dc4190, 0x01db7106,
    0x98d220bc, 0xefd5102a, 0x71b18589, 0x06b6b51f, 0x9fbfe4a5, 0xe8b8d433,
    0x7807c9a2, 0x0f00f934, 0x9609a88e, 0xe10e9818, 0x7f6a0dbb, 0x086d3d2d,
    0x91646c97, 0xe6635c01, 0x6b6b51f4, 0x1c6c6162, 0x856530d8, 0xf262004e,
    0x6c0695ed, 0x1b01a57b, 0x8208f4c1, 0xf50fc457, 0x65b0d9c6, 0x12b7e950,
    0x8bbeb8ea, 0xfcb9887c, 0x62dd1ddf, 0x15da2d49, 0x8cd37cf3, 0xfbd44c65,
    0x4db26158, 0x3ab551ce, 0xa3bc0074, 0xd4bb30e2, 0x4adfa541, 0x3dd895d7,
    0xa4d1c46d, 0xd3d6f4fb, 0x4369e96a, 0x346ed9fc, 0xad678846, 0xda60b8d0,
    0x44042d73, 0x33031de5, 0xaa0a4c5f, 0xdd0d7cc9, 0x5005713c, 0x270241aa,
    0xbe0b1010, 0xc90c2086, 0x5768b525, 0x206f85b3, 0xb966d409, 0xce61e49f,
    0x5edef90e, 0x29d9c998, 0xb0d09822, 0xc7d7a8b4, 0x59b33d17, 0x2eb40d81,
    0xb7bd5c3b, 0xc0ba6cad, 0xedb88320, 0x9abfb3b6, 0x03b6e20c, 0x74b1d29a,
    0xead54739, 0x9dd277af, 0x04db2615, 0x73dc1683, 0xe3630b12, 0x94643b84,
    0x0d6d6a3e, 0x7a6a5aa8, 0xe40ecf0b, 0x9309ff9d, 0x0a00ae27, 0x7d079eb1,
    0xf00f9344, 0x8708a3d2, 0x1e01f268, 0x6906c2fe, 0xf762575d, 0x806567cb,
    0x196c3671, 0x6e6b06e7, 0xfed41b76, 0x89d32be0, 0x10da7a5a, 0x67dd4acc,
    0xf9b9df6f, 0x8ebeeff9, 0x17b7be43, 0x60b08ed5, 0xd6d6a3e8, 0xa1d1937e,
    0x38d8c2c4, 0x4fdff252, 0xd1bb67f1, 0xa6bc5767, 0x3fb506dd, 0x48b2364b,
    0xd80d2bda, 0xaf0a1b4c, 0x36034af6, 0x41047a60, 0xdf60efc3, 0xa867df55,
    0x316e8eef, 0x4669be79, 0xcb61b38c, 0xbc66831a, 0x256fd2a0, 0x5268e236,
    0xcc0c7795, 0xbb0b4703, 0x220216b9, 0x5505262f, 0xc5ba3bbe, 0xb2bd0b28,
    0x2bb45a92, 0x5cb36a04, 0xc2d7ffa7, 0xb5d0cf31, 0x2cd99e8b, 0x5bdeae1d,
    0x9b64c2b0, 0xec63f226, 0x756aa39c, 0x026d930a, 0x9c0906a9, 0xeb0e363f,
    0x72076785, 0x05005713, 0x95bf4a82, 0xe2b87a14, 0x7bb12bae, 0x0cb61b38,
    0x92d28e9b, 0xe5d5be0d, 0x7cdcefb7, 0x0bdbdf21, 0x86d3d2d4, 0xf1d4e242,
    0x68ddb3f8, 0x1fda836e, 0x81be16cd, 0xf6b9265b, 0x6fb077e1, 0x18b74777,
    0x88085ae6, 0xff0f6a70, 0x66063bca, 0x11010b5c, 0x8f659eff, 0xf862ae69,
    0x616bffd3, 0x166ccf45, 0xa00ae278, 0xd70dd2ee, 0x4e048354, 0x3903b3c2,
    0xa7672661, 0xd06016f7, 0x4969474d, 0x3e6e77db, 0xaed16a4a, 0xd9d65adc,
    0x40df0b66, 0x37d83bf0, 0xa9bcae53, 0xdebb9ec5, 0x47b2cf7f, 0x30b5ffe9,
    0xbdbdf21c, 0xcabac28a, 0x53b39330, 0x24b4a3a6, 0xbad03605, 0xcdd70693,
    0x54de5729, 0x23d967bf, 0xb3667a2e, 0xc4614ab8, 0x5d681b02, 0x2a6f2b94,
    0xb40bbe37, 0xc30c8ea1, 0x5a05df1b, 0x2d02ef8d};

static void die(const char *msg) {
  fprintf(stderr, "janus-gpt-fix: %s\n", msg);
  exit(1);
}

static void die_errno(const char *msg) {
  fprintf(stderr, "janus-gpt-fix: %s: %s\n", msg, strerror(errno));
  exit(1);
}

static uint32_t efi_crc32(const void *buf, size_t len) {
  const uint8_t *p = buf;
  uint32_t crc = 0xffffffffu;
  size_t i;
  for (i = 0; i < len; i++)
    crc = CRC_TABLE[(crc ^ p[i]) & 0xff] ^ (crc >> 8);
  return crc ^ 0xffffffffu;
}

static uint32_t rd32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static uint64_t rd64(const uint8_t *p) {
  return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32);
}

static void wr32(uint8_t *p, uint32_t v) {
  p[0] = v & 0xff;
  p[1] = (v >> 8) & 0xff;
  p[2] = (v >> 16) & 0xff;
  p[3] = (v >> 24) & 0xff;
}

static void wr64(uint8_t *p, uint64_t v) {
  wr32(p, (uint32_t)v);
  wr32(p + 4, (uint32_t)(v >> 32));
}

static uint64_t parse_u64(const char *s) {
  char *end = NULL;
  unsigned long long v;
  if (s == NULL || s[0] == '\0')
    die("missing number");
  errno = 0;
  v = strtoull(s, &end, 10);
  if (errno || end == s || *end != '\0')
    die("bad number");
  return (uint64_t)v;
}

static int parse_guid(const char *s, uint8_t out[16]) {
  unsigned b[16];
  int n;
  if (s == NULL)
    return -1;
  n = sscanf(s,
             "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             &b[3], &b[2], &b[1], &b[0], &b[5], &b[4], &b[7], &b[6], &b[8],
             &b[9], &b[10], &b[11], &b[12], &b[13], &b[14], &b[15]);
  if (n != 16)
    return -1;
  for (n = 0; n < 16; n++)
    out[n] = (uint8_t)b[n];
  return 0;
}

static void put_name(uint8_t *dst, const char *s) {
  int i;
  memset(dst, 0, 72);
  for (i = 0; s[i] != '\0' && i < 35; i++)
    dst[i * 2] = (uint8_t)s[i];
}

static int open_disk(const char *path) {
  int fd = open(path, O_RDWR);
  if (fd < 0)
    die_errno(path);
  return fd;
}

static uint64_t disk_last(int fd) {
  off_t sz = lseek(fd, 0, SEEK_END);
  if (sz < SECTOR || (sz % SECTOR) != 0)
    die("disk size is not a whole number of 512-byte sectors");
  return (uint64_t)(sz / SECTOR) - 1;
}

static void read_at(int fd, uint64_t lba, void *buf, size_t n) {
  ssize_t got = pread(fd, buf, n, (off_t)lba * SECTOR);
  if (got < 0)
    die_errno("read");
  if ((size_t)got != n)
    die("short read");
}

static void write_at(int fd, uint64_t lba, const void *buf, size_t n) {
  ssize_t put = pwrite(fd, buf, n, (off_t)lba * SECTOR);
  if (put < 0)
    die_errno("write");
  if ((size_t)put != n)
    die("short write");
}

static void seal_header(uint8_t *hdr) {
  uint32_t size = rd32(hdr + 12);
  uint32_t crc;
  if (size < HEADER_SIZE || size > SECTOR)
    die("GPT header size is not 92 bytes");
  wr32(hdr + 16, 0);
  crc = efi_crc32(hdr, size);
  wr32(hdr + 16, crc);
}

static int header_ok(const uint8_t *hdr, uint64_t lba, uint64_t dev_last) {
  uint8_t copy[SECTOR];
  uint32_t size, crc, got;
  uint64_t first, last, entries;
  if (memcmp(hdr, EFI_MAGIC, 8) != 0)
    return 0;
  size = rd32(hdr + 12);
  if (size < HEADER_SIZE || size > SECTOR)
    return 0;
  memcpy(copy, hdr, SECTOR);
  crc = rd32(copy + 16);
  wr32(copy + 16, 0);
  got = efi_crc32(copy, size);
  if (got != crc)
    return 0;
  if (rd64(hdr + 24) != lba)
    return 0;
  first = rd64(hdr + 40);
  last = rd64(hdr + 48);
  entries = rd64(hdr + 72);
  if (first > dev_last || last > dev_last || entries > dev_last)
    return 0;
  if (last < first)
    return 0;
  if (rd32(hdr + 84) != ENTRY_SIZE)
    return 0;
  return 1;
}

static uint64_t entry_sectors_of(const uint8_t *hdr) {
  uint64_t bytes = (uint64_t)rd32(hdr + 80) * rd32(hdr + 84);
  return (bytes + SECTOR - 1) / SECTOR;
}

static int entries_ok(const uint8_t *hdr, const uint8_t *entries) {
  uint64_t bytes = (uint64_t)rd32(hdr + 80) * rd32(hdr + 84);
  return efi_crc32(entries, bytes) == rd32(hdr + 88);
}

/* 0 when the entries match the header. A torn write fails the checksum
 * and the caller rebuilds from the DOS table instead of giving up. */
static int load_entries(int fd, const uint8_t *hdr, uint8_t **out, uint64_t dev_last) {
  uint64_t bytes = (uint64_t)rd32(hdr + 80) * rd32(hdr + 84);
  uint64_t sectors = (bytes + SECTOR - 1) / SECTOR;
  uint64_t at = rd64(hdr + 72);
  uint8_t *buf;
  if (sectors == 0 || at + sectors - 1 > dev_last)
    return -1;
  buf = calloc(1, sectors * SECTOR);
  if (buf == NULL)
    die("out of memory");
  read_at(fd, at, buf, sectors * SECTOR);
  if (!entries_ok(hdr, buf)) {
    free(buf);
    return -1;
  }
  *out = buf;
  return 0;
}

static void read_hint(int fd, uint64_t hint_lba, uint64_t *header_lba) {
  uint8_t sec[SECTOR];
  read_at(fd, hint_lba, sec, SECTOR);
  if (memcmp(sec, HINT_MAGIC, 8) != 0)
    die("GPT hint sector has no JANUSGPT mark");
  *header_lba = rd64(sec + 8);
}

static void write_hint(int fd, uint64_t hint_lba, uint64_t header_lba) {
  uint8_t sec[SECTOR];
  memset(sec, 0, sizeof sec);
  memcpy(sec, HINT_MAGIC, 8);
  wr64(sec + 8, header_lba);
  write_at(fd, hint_lba, sec, SECTOR);
}

static void mbr_slot(uint8_t *ent, int boot, int type, uint32_t start, uint32_t count) {
  memset(ent, 0, 16);
  ent[0] = (uint8_t)boot;
  ent[1] = ent[2] = ent[3] = 0xff;
  ent[4] = (uint8_t)type;
  ent[5] = ent[6] = ent[7] = 0xff;
  wr32(ent + 8, start);
  wr32(ent + 12, count);
}

static uint32_t need32(uint64_t v, const char *what) {
  if (v > 0xffffffffu) {
    fprintf(stderr, "janus-gpt-fix: %s does not fit in an MBR sector count\n", what);
    exit(1);
  }
  return (uint32_t)v;
}

struct logical {
  uint64_t start;
  uint64_t sectors;
};

static void write_dos(int fd, uint64_t boot_lba, uint64_t boot_sectors,
                      const struct logical *log, int nlog) {
  uint8_t mbr[SECTOR];
  uint64_t ext, ext_count;
  int i;

  if (nlog < 1)
    die("the DOS table needs at least one logical partition");
  ext = log[0].start - 1;
  ext_count = (log[nlog - 1].start + log[nlog - 1].sectors - 1) - ext + 1;

  read_at(fd, 0, mbr, SECTOR);
  memset(mbr + 446, 0, 64);
  mbr[510] = 0x55;
  mbr[511] = 0xaa;
  mbr_slot(mbr + 446, 0x80, 0x0c, need32(boot_lba, "boot start"),
           need32(boot_sectors, "boot size"));
  mbr_slot(mbr + 462, 0, 0x0f, need32(ext, "extended start"),
           need32(ext_count, "extended size"));
  write_at(fd, 0, mbr, SECTOR);

  for (i = 0; i < nlog; i++) {
    uint8_t ebr[SECTOR];
    uint64_t ebr_lba = log[i].start - 1;
    memset(ebr, 0, sizeof ebr);
    ebr[510] = 0x55;
    ebr[511] = 0xaa;
    mbr_slot(ebr + 446, 0, 0x83, 1, need32(log[i].sectors, "logical size"));
    if (i + 1 < nlog) {
      uint64_t next_ebr = log[i + 1].start - 1;
      uint64_t link = next_ebr - ext;
      uint64_t cover = log[i + 1].sectors + 1;
      mbr_slot(ebr + 462, 0, 0x0f, need32(link, "next EBR"),
               need32(cover, "next logical"));
    }
    write_at(fd, ebr_lba, ebr, SECTOR);
  }
}

static int find_state_ebr(int fd, uint64_t part_start, uint64_t *ebr_lba,
                          uint64_t *prev_lba, uint64_t *ext_start) {
  uint8_t mbr[SECTOR];
  uint64_t ext = 0, here, prev = 0;
  int i, guard;

  read_at(fd, 0, mbr, SECTOR);
  if (mbr[510] != 0x55 || mbr[511] != 0xaa)
    return -1;
  for (i = 0; i < 4; i++) {
    uint8_t *ent = mbr + 446 + 16 * i;
    if (ent[4] == 0x0f || ent[4] == 0x05) {
      ext = rd32(ent + 8);
      break;
    }
  }
  if (ext == 0)
    return -1;
  *ext_start = ext;
  here = ext;
  for (guard = 0; guard < 64; guard++) {
    uint8_t ebr[SECTOR];
    uint32_t rel, next;
    read_at(fd, here, ebr, SECTOR);
    if (ebr[510] != 0x55 || ebr[511] != 0xaa)
      return -1;
    rel = rd32(ebr + 446 + 8);
    if ((uint64_t)here + rel == part_start) {
      *ebr_lba = here;
      *prev_lba = prev;
      return 0;
    }
    next = rd32(ebr + 462 + 8);
    if (ebr[462 + 4] != 0x0f && ebr[462 + 4] != 0x05)
      return -1;
    if (next == 0)
      return -1;
    prev = here;
    here = ext + next;
  }
  return -1;
}

static void update_dos_end(int fd, uint64_t part_start, uint64_t new_end) {
  uint64_t ebr_lba = 0, prev = 0, ext = 0;
  uint8_t ebr[SECTOR];
  uint8_t mbr[SECTOR];
  uint64_t count, ext_count;
  int i;

  if (find_state_ebr(fd, part_start, &ebr_lba, &prev, &ext) != 0)
    die("DOS table has no logical partition at the state start");
  read_at(fd, ebr_lba, ebr, SECTOR);
  count = new_end - part_start + 1;
  wr32(ebr + 446 + 12, need32(count, "grown state"));
  write_at(fd, ebr_lba, ebr, SECTOR);

  if (prev != 0) {
    uint8_t link[SECTOR];
    uint64_t cover = new_end - ebr_lba + 1;
    read_at(fd, prev, link, SECTOR);
    wr32(link + 462 + 12, need32(cover, "grown link"));
    write_at(fd, prev, link, SECTOR);
  }

  read_at(fd, 0, mbr, SECTOR);
  ext_count = new_end - ext + 1;
  for (i = 0; i < 4; i++) {
    uint8_t *ent = mbr + 446 + 16 * i;
    if (ent[4] == 0x0f || ent[4] == 0x05) {
      wr32(ent + 12, need32(ext_count, "grown extended partition"));
      break;
    }
  }
  write_at(fd, 0, mbr, SECTOR);
}

struct part_spec {
  int index;
  const char *name;
  const char *guid;
  const char *type;
};

static const struct part_spec SPEC3[] = {
    {0, "JANUS_BOOT", "4a414e55-5300-4000-8000-000000000001", NULL},
    {1, "JANUS_ROOT", "4a414e55-5300-4000-8000-000000000002", NULL},
    {2, "JANUS_NIX", "4a414e55-5300-4000-8000-000000000003", NULL},
    {3, "JANUS_STATE", "4a414e55-5300-4000-8000-000000000004", NULL},
};

static const struct part_spec SPEC5[] = {
    {0, "JANUS_BOOT", "4a414e55-5300-4000-8000-000000000001", NULL},
    {1, "JANUS_ROOT", "4a414e55-5300-4000-8000-000000000002", NULL},
    {2, "JANUS_NIX", "4a414e55-5300-4000-8000-000000000003", NULL},
    {5, "JANUS_ROOT_B", "4a414e55-5300-4000-8000-000000000006", NULL},
    {6, "JANUS_NIX_B", "4a414e55-5300-4000-8000-000000000007", NULL},
    {3, "JANUS_STATE", "4a414e55-5300-4000-8000-000000000004", NULL},
};

struct dos_part {
  uint64_t start;
  uint64_t end;
};

static int read_dos_parts(int fd, struct dos_part *out, int cap) {
  uint8_t mbr[SECTOR];
  uint64_t ext = 0, here;
  int n = 0, i, guard;

  read_at(fd, 0, mbr, SECTOR);
  if (mbr[510] != 0x55 || mbr[511] != 0xaa)
    die("sector 0 has no MBR signature");
  for (i = 0; i < 4; i++) {
    uint8_t *ent = mbr + 446 + 16 * i;
    if (ent[4] == 0xee)
      die("sector 0 still has a protective GPT entry");
    if (ent[4] == 0x0c) {
      if (n >= cap)
        die("too many DOS partitions");
      out[n].start = rd32(ent + 8);
      out[n].end = out[n].start + rd32(ent + 12) - 1;
      n++;
    } else if (ent[4] == 0x0f || ent[4] == 0x05) {
      ext = rd32(ent + 8);
    }
  }
  if (n != 1 || ext == 0)
    die("sector 0 is not the Le Potato boot plus extended table");
  here = ext;
  for (guard = 0; guard < 64; guard++) {
    uint8_t ebr[SECTOR];
    uint32_t rel, count, next;
    read_at(fd, here, ebr, SECTOR);
    if (ebr[510] != 0x55 || ebr[511] != 0xaa)
      die("an EBR has no signature");
    rel = rd32(ebr + 446 + 8);
    count = rd32(ebr + 446 + 12);
    if (n >= cap)
      die("too many logical partitions");
    out[n].start = here + rel;
    out[n].end = out[n].start + count - 1;
    n++;
    if (ebr[462 + 4] == 0)
      return n;
    next = rd32(ebr + 462 + 8);
    if (next == 0)
      return n;
    here = ext + next;
  }
  die("EBR chain is too long");
  return n;
}

static void fill_entry(uint8_t *ent, const struct part_spec *spec, uint64_t start,
                       uint64_t end) {
  uint8_t type[16], unique[16];
  const char *type_s = spec->index == 0 ? TYPE_EFI : TYPE_LINUX;
  memset(ent, 0, ENTRY_SIZE);
  if (parse_guid(type_s, type) != 0 || parse_guid(spec->guid, unique) != 0)
    die("built-in GUID did not parse");
  memcpy(ent, type, 16);
  memcpy(ent + 16, unique, 16);
  wr64(ent + 32, start);
  wr64(ent + 40, end);
  put_name(ent + 56, spec->name);
}

static void write_backup(int fd, uint64_t dev_last, uint64_t first_usable,
                         const uint8_t disk_guid[16], uint8_t *entries,
                         uint32_t entry_count) {
  uint8_t hdr[SECTOR];
  uint64_t bytes = (uint64_t)entry_count * ENTRY_SIZE;
  uint64_t sectors = (bytes + SECTOR - 1) / SECTOR;
  uint64_t entry_lba;
  uint8_t *block;

  if (dev_last < sectors + first_usable + 1)
    die("disk is too small for a backup GPT");
  entry_lba = dev_last - sectors;
  memset(hdr, 0, sizeof hdr);
  memcpy(hdr, EFI_MAGIC, 8);
  wr32(hdr + 8, 0x00010000);
  wr32(hdr + 12, HEADER_SIZE);
  wr64(hdr + 24, dev_last);
  wr64(hdr + 32, 1);
  wr64(hdr + 40, first_usable);
  wr64(hdr + 48, entry_lba - 1);
  memcpy(hdr + 56, disk_guid, 16);
  wr64(hdr + 72, entry_lba);
  wr32(hdr + 80, entry_count);
  wr32(hdr + 84, ENTRY_SIZE);
  wr32(hdr + 88, efi_crc32(entries, bytes));
  seal_header(hdr);

  block = calloc(1, sectors * SECTOR);
  if (block == NULL)
    die("out of memory");
  memcpy(block, entries, bytes);
  write_at(fd, entry_lba, block, sectors * SECTOR);
  free(block);
  write_at(fd, dev_last, hdr, SECTOR);
}

/* 128 entries of 128 bytes occupy the 32 sectors before the header.
 * last_usable is dev_last - 33, and a partition may end on that sector. */
static int overlaps_backup(uint64_t end, uint64_t dev_last) {
  if (dev_last < 33)
    return 1;
  return end > dev_last - 33;
}

static void rebuild_from_dos(int fd, uint64_t dev_last, uint64_t hint_lba) {
  struct dos_part parts[8];
  const struct part_spec *spec;
  int nspec, n, i;
  uint8_t *entries;
  uint8_t disk_guid[16];
  uint64_t bytes;

  n = read_dos_parts(fd, parts, 8);
  if (overlaps_backup(parts[0].end, dev_last))
    die("DOS partitions run into the backup GPT");
  if (n == 4) {
    spec = SPEC3;
    nspec = 4;
  } else if (n == 6) {
    spec = SPEC5;
    nspec = 6;
  } else {
    die("DOS table does not have 4 or 6 Janus partitions");
  }
  if (parse_guid(DISK_GUID, disk_guid) != 0)
    die("disk GUID did not parse");
  bytes = (uint64_t)ENTRY_COUNT * ENTRY_SIZE;
  entries = calloc(1, (bytes + SECTOR - 1) / SECTOR * SECTOR);
  if (entries == NULL)
    die("out of memory");
  for (i = 0; i < nspec; i++) {
    if (parts[i].end < parts[i].start || overlaps_backup(parts[i].end, dev_last))
      die("DOS partition does not fit below the backup GPT");
    fill_entry(entries + spec[i].index * ENTRY_SIZE, &spec[i], parts[i].start,
               parts[i].end);
  }
  write_backup(fd, dev_last, parts[0].start, disk_guid, entries, ENTRY_COUNT);
  free(entries);
  if (fsync(fd) != 0)
    die_errno("fsync");
  write_hint(fd, hint_lba, dev_last);
  if (fsync(fd) != 0)
    die_errno("fsync");
}

static int load_valid(int fd, uint64_t lba, uint64_t dev_last, uint8_t *hdr,
                      uint8_t **entries) {
  read_at(fd, lba, hdr, SECTOR);
  if (!header_ok(hdr, lba, dev_last))
    return 0;
  if (load_entries(fd, hdr, entries, dev_last) != 0)
    return 0;
  return 1;
}

static void move_backup(int fd, uint64_t dev_last, uint64_t hint_lba,
                        uint8_t *hdr, uint8_t *entries) {
  uint64_t sectors = entry_sectors_of(hdr);
  uint64_t entry_lba = dev_last - sectors;
  uint64_t bytes = (uint64_t)rd32(hdr + 80) * rd32(hdr + 84);

  if (entry_lba <= rd64(hdr + 40))
    die("disk is too small to move the backup GPT");
  wr64(hdr + 24, dev_last);
  wr64(hdr + 32, 1);
  wr64(hdr + 48, entry_lba - 1);
  wr64(hdr + 72, entry_lba);
  wr32(hdr + 88, efi_crc32(entries, bytes));
  seal_header(hdr);
  write_at(fd, entry_lba, entries, sectors * SECTOR);
  write_at(fd, dev_last, hdr, SECTOR);
  if (fsync(fd) != 0)
    die_errno("fsync");
  write_hint(fd, hint_lba, dev_last);
  if (fsync(fd) != 0)
    die_errno("fsync");
}

static void cmd_relocate(const char *disk, uint64_t hint_lba) {
  int fd = open_disk(disk);
  uint64_t dev_last = disk_last(fd);
  uint64_t header_lba = 0;
  uint8_t hdr[SECTOR];
  uint8_t *entries = NULL;

  if (hint_lba >= dev_last)
    die("GPT hint sector is not on the disk");
  read_hint(fd, hint_lba, &header_lba);
  if (header_lba > dev_last)
    die("GPT hint points past the end of the disk");
  if (load_valid(fd, header_lba, dev_last, hdr, &entries)) {
    if (header_lba == dev_last) {
      free(entries);
      close(fd);
      return;
    }
    move_backup(fd, dev_last, hint_lba, hdr, entries);
    free(entries);
    close(fd);
    return;
  }
  /* A torn grow leaves the DOS table. Rebuild the backup from that. */
  rebuild_from_dos(fd, dev_last, hint_lba);
  close(fd);
}

static uint8_t *entry_by_guid(uint8_t *entries, const uint8_t *hdr, const uint8_t guid[16],
                              int *index) {
  uint32_t n = rd32(hdr + 80);
  uint32_t i;
  for (i = 0; i < n; i++) {
    uint8_t *ent = entries + (size_t)i * ENTRY_SIZE;
    if (memcmp(ent + 16, guid, 16) == 0) {
      *index = (int)i;
      return ent;
    }
  }
  return NULL;
}

static void cmd_show(const char *disk, uint64_t hint_lba, const char *guid_s) {
  int fd = open_disk(disk);
  uint64_t dev_last = disk_last(fd);
  uint64_t header_lba = 0;
  uint8_t guid[16], hdr[SECTOR];
  uint8_t *entries = NULL;
  uint8_t *ent;
  int index = 0;

  if (parse_guid(guid_s, guid) != 0)
    die("partition GUID is not 8-4-4-4-12 hex");
  read_hint(fd, hint_lba, &header_lba);
  if (!load_valid(fd, header_lba, dev_last, hdr, &entries))
    die("backup GPT at the hint is not valid");
  ent = entry_by_guid(entries, hdr, guid, &index);
  if (ent == NULL)
    die("backup GPT has no entry with that GUID");
  (void)index;
  printf("start=%" PRIu64 "\n", rd64(ent + 32));
  printf("end=%" PRIu64 "\n", rd64(ent + 40));
  printf("last=%" PRIu64 "\n", rd64(hdr + 48));
  free(entries);
  close(fd);
}

static void cmd_set_end(const char *disk, uint64_t hint_lba, const char *guid_s,
                        uint64_t new_end) {
  int fd = open_disk(disk);
  uint64_t dev_last = disk_last(fd);
  uint64_t header_lba = 0;
  uint8_t guid[16], hdr[SECTOR];
  uint8_t *entries = NULL;
  uint8_t *ent;
  uint64_t start, end, last, bytes, sectors;
  int index = 0;

  if (parse_guid(guid_s, guid) != 0)
    die("partition GUID is not 8-4-4-4-12 hex");
  read_hint(fd, hint_lba, &header_lba);
  if (header_lba != dev_last)
    die("backup GPT is not at the end of the disk");
  if (!load_valid(fd, header_lba, dev_last, hdr, &entries))
    die("backup GPT at the end of the disk is not valid");
  ent = entry_by_guid(entries, hdr, guid, &index);
  if (ent == NULL)
    die("backup GPT has no entry with that GUID");
  (void)index;
  start = rd64(ent + 32);
  end = rd64(ent + 40);
  last = rd64(hdr + 48);
  if (new_end < end)
    die("refusing to shrink the state partition");
  if (new_end > last)
    die("new end is past the last usable sector");
  if (new_end == end) {
    free(entries);
    close(fd);
    return;
  }
  /* DOS first. A crash here leaves the old GPT, which still mounts. */
  update_dos_end(fd, start, new_end);
  if (fsync(fd) != 0)
    die_errno("fsync");
  wr64(ent + 40, new_end);
  bytes = (uint64_t)rd32(hdr + 80) * ENTRY_SIZE;
  sectors = entry_sectors_of(hdr);
  wr32(hdr + 88, efi_crc32(entries, bytes));
  seal_header(hdr);
  write_at(fd, rd64(hdr + 72), entries, sectors * SECTOR);
  write_at(fd, header_lba, hdr, SECTOR);
  if (fsync(fd) != 0)
    die_errno("fsync");
  free(entries);
  close(fd);
}

static void cmd_prepare(int argc, char **argv) {
  const char *disk = NULL;
  uint64_t hint = 0, first = 0, boot_lba = 0, boot_sectors = 0;
  int have_hint = 0, have_first = 0, have_boot = 0, have_boot_n = 0;
  struct logical log[MAX_LOGICAL];
  int nlog = 0, i, fd;
  uint64_t dev_last, boot_end;
  uint8_t hdr[SECTOR];
  uint8_t *entries = NULL;

  for (i = 0; i < argc; i++) {
    const char *a = argv[i];
    if (strcmp(a, "--hint-lba") == 0 || strcmp(a, "--first-usable") == 0 ||
        strcmp(a, "--boot-lba") == 0 || strcmp(a, "--boot-sectors") == 0 ||
        strcmp(a, "--logical") == 0) {
      if (i + 1 >= argc)
        die("option needs a value");
      if (strcmp(a, "--hint-lba") == 0) {
        hint = parse_u64(argv[++i]);
        have_hint = 1;
      } else if (strcmp(a, "--first-usable") == 0) {
        first = parse_u64(argv[++i]);
        have_first = 1;
      } else if (strcmp(a, "--boot-lba") == 0) {
        boot_lba = parse_u64(argv[++i]);
        have_boot = 1;
      } else if (strcmp(a, "--boot-sectors") == 0) {
        boot_sectors = parse_u64(argv[++i]);
        have_boot_n = 1;
      } else {
        char *colon;
        if (nlog >= MAX_LOGICAL)
          die("too many logical partitions");
        colon = strchr(argv[++i], ':');
        if (colon == NULL)
          die("logical partition is START:SECTORS");
        *colon = '\0';
        log[nlog].start = parse_u64(argv[i]);
        log[nlog].sectors = parse_u64(colon + 1);
        nlog++;
      }
    } else if (a[0] == '-') {
      die("unknown option");
    } else if (disk == NULL) {
      disk = a;
    } else {
      die("one disk path");
    }
  }
  if (disk == NULL || !have_hint || !have_first || !have_boot || !have_boot_n || nlog < 1)
    die("prepare needs the disk, hint, first usable, boot, and logicals");
  if (hint + 1 != boot_lba || hint < 2)
    die("hint sector is not the sector before the boot partition");
  if (first != boot_lba)
    die("first usable sector is not the boot partition");
  if (boot_sectors == 0)
    die("boot partition is empty");
  boot_end = boot_lba + boot_sectors - 1;
  for (i = 0; i < nlog; i++) {
    if (log[i].sectors == 0 || log[i].start < 2)
      die("logical partition is empty");
    if (log[i].start - 1 <= boot_end)
      die("logical partition overlaps the boot partition");
    if (i > 0 && log[i].start <= log[i - 1].start + log[i - 1].sectors)
      die("logical partitions overlap");
  }

  fd = open_disk(disk);
  dev_last = disk_last(fd);
  if (log[nlog - 1].start + log[nlog - 1].sectors >= dev_last)
    die("last partition runs into the backup GPT");
  read_at(fd, dev_last, hdr, SECTOR);
  if (!header_ok(hdr, dev_last, dev_last))
    die("image has no backup GPT at its last sector");
  if (load_entries(fd, hdr, &entries, dev_last) != 0)
    die("backup GPT entries failed the checksum");
  {
    uint32_t nent = rd32(hdr + 80);
    uint32_t ei;
    int saw_boot = 0;
    for (ei = 0; ei < nent; ei++) {
      uint64_t st = rd64(entries + (size_t)ei * ENTRY_SIZE + 32);
      uint64_t en = rd64(entries + (size_t)ei * ENTRY_SIZE + 40);
      int zero = 1;
      int b;
      for (b = 0; b < 16; b++) {
        if (entries[(size_t)ei * ENTRY_SIZE + b] != 0)
          zero = 0;
      }
      if (zero)
        continue;
      if (st < first)
        die("a GPT partition starts in the firmware gap");
      if (st == boot_lba)
        saw_boot = 1;
      (void)en;
    }
    if (!saw_boot)
      die("backup GPT has no boot partition at the DOS boot start");
    for (i = 0; i < nlog; i++) {
      int saw = 0;
      for (ei = 0; ei < nent; ei++) {
        if (rd64(entries + (size_t)ei * ENTRY_SIZE + 32) == log[i].start)
          saw = 1;
      }
      if (!saw)
        die("backup GPT has no partition at a logical start");
    }
  }
  wr64(hdr + 40, first);
  seal_header(hdr);
  write_at(fd, dev_last, hdr, SECTOR);
  write_dos(fd, boot_lba, boot_sectors, log, nlog);
  write_hint(fd, hint, dev_last);
  if (fsync(fd) != 0)
    die_errno("fsync");
  free(entries);
  close(fd);
}

static void usage(void) {
  fprintf(stderr,
          "usage: janus-gpt-fix prepare DISK --hint-lba N --first-usable N\n"
          "           --boot-lba N --boot-sectors N --logical START:SECTORS ...\n"
          "       janus-gpt-fix relocate DISK HINT_LBA\n"
          "       janus-gpt-fix show DISK HINT_LBA GUID\n"
          "       janus-gpt-fix set-end DISK HINT_LBA GUID END_LBA\n");
  exit(1);
}

int main(int argc, char **argv) {
  /* ISO-HDLC CRC-32 of the check string. Catches a bad table at startup. */
  if (efi_crc32("123456789", 9) != 0xcbf43926u)
    die("CRC32 self-check failed");
  if (argc < 2)
    usage();
  if (strcmp(argv[1], "prepare") == 0)
    cmd_prepare(argc - 2, argv + 2);
  else if (strcmp(argv[1], "relocate") == 0 && argc == 4)
    cmd_relocate(argv[2], parse_u64(argv[3]));
  else if (strcmp(argv[1], "show") == 0 && argc == 5)
    cmd_show(argv[2], parse_u64(argv[3]), argv[4]);
  else if (strcmp(argv[1], "set-end") == 0 && argc == 6)
    cmd_set_end(argv[2], parse_u64(argv[3]), argv[4], parse_u64(argv[5]));
  else
    usage();
  return 0;
}
