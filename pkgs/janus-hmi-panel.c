/* SPDX-License-Identifier: Apache-2.0 */
/* SH1106 128x64 panel and active-low keys for waveshare-1.3-oled-hat.
   docs/10 §4.6, docs/15 §4. stdin frames are text rows; stdout is
   "<name> press" or "<name> release". */
#include "font6x8.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/gpio.h>
#include <linux/spi/spidev.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define WIDTH 128
#define HEIGHT 64
#define COLS 21
#define ROWS 8

static int die(const char *what) {
    fprintf(stderr, "janus-hmi-panel: %s: %s\n", what, strerror(errno));
    return 1;
}

static void copy_trunc(char *dst, size_t dst_len, const char *src) {
    size_t i = 0;
    if (dst_len == 0) {
        return;
    }
    while (src[i] != 0 && i + 1 < dst_len) {
        dst[i] = src[i];
        i++;
    }
    dst[i] = 0;
}

static void render_text(char lines[ROWS][COLS + 1], uint8_t fb[ROWS][WIDTH]) {
    uint8_t pix[HEIGHT][WIDTH];
    memset(pix, 0, sizeof pix);
    memset(fb, 0, ROWS * WIDTH);
    for (int row = 0; row < ROWS; row++) {
        for (int col = 0; lines[row][col] && col < COLS; col++) {
            unsigned char ch = (unsigned char)lines[row][col];
            if (ch < 32 || ch > 126) {
                ch = '?';
            }
            const uint8_t *glyph = &font6x8[(ch - 32) * 8];
            for (int y = 0; y < 8; y++) {
                for (int x = 0; x < 6; x++) {
                    if (glyph[y] & (1u << x)) {
                        int px = col * 6 + x;
                        int py = row * 8 + y;
                        if (px < WIDTH && py < HEIGHT) {
                            pix[py][px] = 1;
                        }
                    }
                }
            }
        }
    }
    for (int page = 0; page < ROWS; page++) {
        for (int x = 0; x < WIDTH; x++) {
            uint8_t byte = 0;
            for (int bit = 0; bit < 8; bit++) {
                if (pix[page * 8 + bit][x]) {
                    byte |= (uint8_t)(1u << bit);
                }
            }
            fb[page][x] = byte;
        }
    }
}

static int self_test(void) {
    if (font6x8[(62 - 32) * 8] != 1) {
        fprintf(stderr, "janus-hmi-panel: font row for '>' is wrong\n");
        return 1;
    }
    char lines[ROWS][COLS + 1];
    memset(lines, 0, sizeof lines);
    memcpy(lines[0], "A", 2);
    uint8_t fb[ROWS][WIDTH];
    render_text(lines, fb);
    /* 'A' is ".###." on the top row, so pixel x=1 is set. */
    if ((fb[0][1] & 1u) == 0 || (fb[0][0] & 1u) != 0) {
        fprintf(stderr, "janus-hmi-panel: 'A' did not land on the panel\n");
        return 1;
    }
    printf("ok\n");
    return 0;
}

struct key {
    char name[32];
    unsigned pin;
    int down;
};

static int gpio_out(const char *chip, unsigned pin, int initial, int *fd_out) {
    int fd = open(chip, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return die(chip);
    }
    struct gpio_v2_line_request req;
    memset(&req, 0, sizeof req);
    req.offsets[0] = pin;
    req.num_lines = 1;
    strncpy(req.consumer, "janus-hmi", sizeof req.consumer - 1);
    req.config.flags = GPIO_V2_LINE_FLAG_OUTPUT;
    req.config.num_attrs = 1;
    req.config.attrs[0].mask = 1;
    req.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
    req.config.attrs[0].attr.values = initial ? 1 : 0;
    if (ioctl(fd, GPIO_V2_GET_LINE_IOCTL, &req) < 0) {
        close(fd);
        return die("gpio output");
    }
    close(fd);
    *fd_out = req.fd;
    return 0;
}

static int gpio_set(int fd, int high) {
    struct gpio_v2_line_values vals;
    memset(&vals, 0, sizeof vals);
    vals.mask = 1;
    vals.bits = high ? 1 : 0;
    if (ioctl(fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &vals) < 0) {
        return die("gpio set");
    }
    return 0;
}

static int gpio_in(const char *chip, struct key *keys, int nkeys, int *fd_out) {
    if (nkeys == 0) {
        *fd_out = -1;
        return 0;
    }
    int fd = open(chip, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return die(chip);
    }
    struct gpio_v2_line_request req;
    memset(&req, 0, sizeof req);
    req.num_lines = (uint32_t)nkeys;
    strncpy(req.consumer, "janus-hmi", sizeof req.consumer - 1);
    for (int i = 0; i < nkeys; i++) {
        req.offsets[i] = keys[i].pin;
    }
    req.config.flags = GPIO_V2_LINE_FLAG_INPUT | GPIO_V2_LINE_FLAG_BIAS_PULL_UP;
    if (ioctl(fd, GPIO_V2_GET_LINE_IOCTL, &req) < 0) {
        req.config.flags = GPIO_V2_LINE_FLAG_INPUT;
        if (ioctl(fd, GPIO_V2_GET_LINE_IOCTL, &req) < 0) {
            close(fd);
            return die("gpio input");
        }
    }
    close(fd);
    *fd_out = req.fd;
    return 0;
}

static int spi_open(const char *path) {
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }
    uint8_t mode = SPI_MODE_0;
    uint8_t bits = 8;
    uint32_t speed = 4000000;
    if (ioctl(fd, SPI_IOC_WR_MODE, &mode) < 0 || ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits) < 0 || ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int spi_write(int fd, const uint8_t *buf, size_t len) {
    struct spi_ioc_transfer tr;
    memset(&tr, 0, sizeof tr);
    tr.tx_buf = (uintptr_t)buf;
    tr.len = (uint32_t)len;
    tr.speed_hz = 4000000;
    tr.bits_per_word = 8;
    if (ioctl(fd, SPI_IOC_MESSAGE(1), &tr) < 0) {
        return die("spi");
    }
    return 0;
}

static int cmd(int spi, int dc, uint8_t byte) {
    if (gpio_set(dc, 0)) {
        return 1;
    }
    return spi_write(spi, &byte, 1);
}

static int data(int spi, int dc, const uint8_t *buf, size_t len) {
    if (gpio_set(dc, 1)) {
        return 1;
    }
    return spi_write(spi, buf, len);
}

static int panel_init(int spi, int dc, int reset) {
    if (gpio_set(reset, 0)) {
        return 1;
    }
    usleep(10000);
    if (gpio_set(reset, 1)) {
        return 1;
    }
    usleep(10000);
    static const uint8_t seq[] = {
        0xAE, 0xD5, 0x80, 0xA8, 0x3F, 0xD3, 0x00, 0x40, 0xAD, 0x8B, 0xA1, 0xC8, 0xDA, 0x12, 0x81, 0xCF, 0xD9, 0xF1, 0xDB, 0x40, 0xA4, 0xA6, 0xAF,
    };
    for (size_t i = 0; i < sizeof seq; i++) {
        if (cmd(spi, dc, seq[i])) {
            return 1;
        }
    }
    return 0;
}

static int panel_blit(int spi, int dc, uint8_t fb[ROWS][WIDTH]) {
    for (int page = 0; page < ROWS; page++) {
        /* SH1106 RAM is 132 columns; the 128-wide glass starts at column 2. */
        if (cmd(spi, dc, (uint8_t)(0xB0 | page)) || cmd(spi, dc, 0x02) || cmd(spi, dc, 0x10)) {
            return 1;
        }
        if (data(spi, dc, fb[page], WIDTH)) {
            return 1;
        }
    }
    return 0;
}

static int parse_gpio(const char *spec, struct key *keys, int *nkeys) {
    char buf[512];
    snprintf(buf, sizeof buf, "%s", spec);
    char *cursor = buf;
    while (cursor && *cursor && *nkeys < 16) {
        char *comma = strchr(cursor, ',');
        if (comma) {
            *comma = 0;
        }
        char *eq = strchr(cursor, '=');
        if (!eq || eq == cursor) {
            fprintf(stderr, "janus-hmi-panel: bad --gpio entry\n");
            return 1;
        }
        *eq = 0;
        struct key *key = &keys[*nkeys];
        copy_trunc(key->name, sizeof key->name, cursor);
        key->pin = (unsigned)strtoul(eq + 1, NULL, 10);
        key->down = 0;
        (*nkeys)++;
        cursor = comma ? comma + 1 : NULL;
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *spi_path = "/dev/spidev0.0";
    const char *chip = "/dev/gpiochip0";
    const char *gpio_spec = "";
    unsigned dc_pin = 24;
    unsigned reset_pin = 25;
    int test = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--self-test")) {
            test = 1;
        } else if (!strcmp(argv[i], "--spi") && i + 1 < argc) {
            spi_path = argv[++i];
        } else if (!strcmp(argv[i], "--chip") && i + 1 < argc) {
            chip = argv[++i];
        } else if (!strcmp(argv[i], "--dc") && i + 1 < argc) {
            dc_pin = (unsigned)strtoul(argv[++i], NULL, 10);
        } else if (!strcmp(argv[i], "--reset") && i + 1 < argc) {
            reset_pin = (unsigned)strtoul(argv[++i], NULL, 10);
        } else if (!strcmp(argv[i], "--gpio") && i + 1 < argc) {
            gpio_spec = argv[++i];
        } else {
            fprintf(stderr, "janus-hmi-panel: unknown argument %s\n", argv[i]);
            return 2;
        }
    }
    if (test) {
        return self_test();
    }

    struct key keys[16];
    int nkeys = 0;
    if (gpio_spec[0] && parse_gpio(gpio_spec, keys, &nkeys)) {
        return 2;
    }
    int dc = -1;
    int reset = -1;
    int inputs = -1;
    if (gpio_out(chip, dc_pin, 0, &dc) || gpio_out(chip, reset_pin, 1, &reset)) {
        return 1;
    }
    if (gpio_in(chip, keys, nkeys, &inputs)) {
        return 1;
    }
    int spi = spi_open(spi_path);
    if (spi < 0) {
        return die(spi_path);
    }
    if (panel_init(spi, dc, reset)) {
        return 1;
    }

    char lines[ROWS][COLS + 1];
    memset(lines, 0, sizeof lines);
    int row = -1;
    char acc[128];
    size_t acc_n = 0;
    uint8_t fb[ROWS][WIDTH];
    struct pollfd fds[2];
    fds[0].fd = STDIN_FILENO;
    fds[0].events = POLLIN;
    fds[1].fd = inputs;
    fds[1].events = 0;

    for (;;) {
        int rc = poll(fds, inputs >= 0 ? 2 : 1, 20);
        if (rc < 0) {
            if (errno == EINTR) {
                continue;
            }
            return die("poll");
        }
        if (inputs >= 0) {
            struct gpio_v2_line_values vals;
            memset(&vals, 0, sizeof vals);
            vals.mask = nkeys >= 64 ? ~0ULL : ((1ULL << nkeys) - 1);
            if (ioctl(inputs, GPIO_V2_LINE_GET_VALUES_IOCTL, &vals) == 0) {
                for (int i = 0; i < nkeys; i++) {
                    int down = (vals.bits & (1ULL << i)) == 0;
                    if (down != keys[i].down) {
                        keys[i].down = down;
                        printf("%s %s\n", keys[i].name, down ? "press" : "release");
                        fflush(stdout);
                    }
                }
            }
        }
        if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
            break;
        }
        if (!(fds[0].revents & POLLIN)) {
            continue;
        }
        char tmp[256];
        ssize_t got = read(STDIN_FILENO, tmp, sizeof tmp);
        if (got == 0) {
            break;
        }
        if (got < 0) {
            if (errno == EINTR) {
                continue;
            }
            return die("read");
        }
        for (ssize_t i = 0; i < got; i++) {
            char ch = tmp[i];
            if (ch == '\r') {
                continue;
            }
            if (ch != '\n') {
                if (acc_n + 1 < sizeof acc) {
                    acc[acc_n++] = ch;
                }
                continue;
            }
            acc[acc_n] = 0;
            acc_n = 0;
            if (!strcmp(acc, "FRAME")) {
                memset(lines, 0, sizeof lines);
                row = 0;
            } else if (!strcmp(acc, "END")) {
                if (row >= 0) {
                    render_text(lines, fb);
                    if (panel_blit(spi, dc, fb)) {
                        return 1;
                    }
                }
                row = -1;
            } else if (!strcmp(acc, "QUIT")) {
                return 0;
            } else if (row >= 0 && row < ROWS) {
                copy_trunc(lines[row], COLS + 1, acc);
                row++;
            }
        }
    }
    return 0;
}
