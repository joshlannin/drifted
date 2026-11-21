// Throws random and half-broken input at the relay's job engine (relay/firmware/main/job.c): job messages as a
// host might send them, and bytes as a table might, with links that fail and writes that don't go through.
// Built with the address and undefined-behaviour sanitizers (relay/tools/test-job-engine.py does that), so a
// read or write out of bounds, or arithmetic gone wrong, stops it. The engine must also always finish, and
// what it emits must be well formed.
//
// Usage: fuzz-job-engine ITERATIONS [SEED]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../firmware/main/job.h"

static uint64_t s_rng = 88172645463325252ULL;
static uint32_t rnd(void) {
    s_rng ^= s_rng << 13;
    s_rng ^= s_rng >> 7;
    s_rng ^= s_rng << 17;
    return (uint32_t)(s_rng >> 16);
}
static uint32_t upto(uint32_t n) { return n ? rnd() % n : 0; }

static int64_t s_now = 5000;
static uint8_t *s_blob;
static uint32_t s_blob_len;
static long s_emitted, s_results, s_refused, s_writes, s_recvs;
static int s_chaos;   // 0: a table that mostly behaves. Higher: more noise, more drops.

static void die(const char *why) {
    fprintf(stderr, "FAIL: %s\n", why);
    abort();
}

static size_t put_packet(uint8_t *out, uint8_t cmd, int ack, const uint8_t *d, size_t n) {
    out[0] = 0x7B;
    out[1] = (uint8_t)(n + 4);
    out[2] = ack ? cmd | 0x80 : cmd;
    memcpy(out + 3, d, n);
    uint8_t sum = 0;
    for (size_t i = 0; i < n + 3; i++) sum += out[i];
    out[n + 3] = sum;
    return n + 4;
}

/// Something a table might say: mostly the messages the engine acts on, with ids near the ones jobs use.
static size_t table_says(uint8_t *out) {
    uint8_t d[220];
    uint16_t id = (uint16_t)(50000 + upto(4));
    switch (upto(14)) {
    case 0: d[0] = 1; return put_packet(out, 0x50, 0, d, 1);
    case 1: d[0] = 1; return put_packet(out, 0x4F, 0, d, 1);
    case 2: return put_packet(out, 0x50, 1, d, 0);
    case 3: d[0] = 2; return put_packet(out, 0x32, upto(2), d, 1);
    case 4: case 5: case 6: {   // an upload reply
        static const uint8_t actions[] = {1, 2, 2, 3, 3, 5, 6};
        d[0] = actions[upto(sizeof actions)];
        if (d[0] == 1) {
            d[1] = (uint8_t)upto(24);
            for (int i = 0; i < d[1] * 2; i++) d[2 + i] = (uint8_t)rnd();
            return put_packet(out, 0x34, upto(2), d, upto(4) ? 2 + d[1] * 2u : upto(2 + d[1] * 2u));
        }
        d[1] = (uint8_t)id;
        d[2] = (uint8_t)(id >> 8);
        return put_packet(out, 0x34, upto(2), d, upto(8) ? 3 : upto(3));
    }
    case 7: case 8: case 9: {   // a running state, whole or cut short
        size_t n = 0;
        d[n++] = 1;
        d[n++] = 60;
        for (uint32_t k = upto(8); k; k--) d[n++] = (uint8_t)('a' + upto(26));
        d[n++] = 0;
        d[n++] = 1; d[n++] = 2; d[n++] = 3; d[n++] = 50;
        for (uint32_t k = upto(14); k; k--) d[n++] = (uint8_t)('a' + upto(26));
        d[n++] = 0;
        uint16_t pattern = upto(3) ? id : (uint16_t)rnd();
        d[n++] = (uint8_t)pattern; d[n++] = (uint8_t)(pattern >> 8);
        d[n++] = (uint8_t)rnd(); d[n++] = (uint8_t)rnd();
        d[n++] = (uint8_t)upto(3);
        for (int k = 0; k < 12; k++) d[n++] = (uint8_t)rnd();
        return put_packet(out, 0x35, 0, d, upto(6) ? n : upto((uint32_t)n + 1));
    }
    default: {   // any list message, any length
        size_t n = upto(190);
        for (size_t i = 0; i < n; i++) d[i] = (uint8_t)rnd();
        return put_packet(out, (uint8_t)(0x30 + upto(9)), upto(4) == 0, d, n);
    }
    }
}

static int64_t now_ms(void) { return s_now; }
static bool link_up(int timeout_ms) {
    if (upto(10 + 30 / (1 + s_chaos)) == 0) { s_now += timeout_ms; return false; }
    s_now += 300;
    return true;
}
static void link_down(bool done) { s_now += 50; }
static bool write_packet(const uint8_t *p, size_t n) {
    s_writes++;
    if (n < 4 || n > 255 || p[0] != 0x7B || p[1] != n) die("the engine wrote something that isn't one packet");
    if ((p[2] & 0x7F) == 0x15 || ((p[2] & 0x7F) == 0x14 && n > 4 && p[3] == 12)) die("a forbidden command was written");
    return upto(400 / (1 + s_chaos) + 20) != 0;
}
static int recv_bytes(uint8_t *buf, size_t max, int timeout_ms) {
    s_recvs++;
    if (max < 600) die("recv buffer smaller than promised");
    uint32_t roll = upto(100);
    if (roll < (uint32_t)(1 + s_chaos)) { s_now += 1; return -1; }
    if (roll < 45) { s_now += timeout_ms > 0 ? timeout_ms : 1; return 0; }
    s_now += 1 + upto(40);
    size_t n = 0;
    if (roll < 90) {
        // One to three packets; now and then cut, or with a byte wrong.
        for (uint32_t k = 1 + upto(3); k && n + 260 < max; k--) n += table_says(buf + n);
        if (upto(12) == 0) n = upto((uint32_t)n + 1);
        if (n && upto(15) == 0) buf[upto((uint32_t)n)] ^= (uint8_t)(1 << upto(8));
    } else {
        n = 1 + upto(599);
        for (size_t i = 0; i < n; i++) buf[i] = upto(4) ? (uint8_t)rnd() : 0x7B;
    }
    return (int)n;
}
static int rssi(void) { return -(int)upto(100); }
static const char *blob_begin(uint32_t len) {
    if (len > (1u << 20)) return "pattern too large for the relay";
    free(s_blob);
    s_blob = malloc(len ? len : 1);
    s_blob_len = len;
    return NULL;
}
static bool blob_write(uint32_t off, const uint8_t *d, size_t n) {
    if (off > s_blob_len || n > s_blob_len - off) die("blob write outside what was asked for");
    memcpy(s_blob + off, d, n);
    return upto(2000) != 0;
}
static bool blob_read(uint32_t off, uint8_t *d, size_t n) {
    if (off > s_blob_len || n > s_blob_len - off) die("blob read outside what was stored");
    memcpy(d, s_blob + off, n);
    return upto(3000) != 0;
}
static void emit(uint8_t type, const void *payload, size_t len) {
    const char *p = payload;
    s_emitted++;
    if (len > 4096) die("a message longer than the protocol allows");
    if (type == MSG_JOB_STATE || type == MSG_JOB_RESULT) {
        if (len < 2 || p[0] != '{' || p[len - 1] != '}') die("JSON that isn't an object");
        int depth = 0, quote = 0;
        for (size_t i = 0; i < len; i++) {
            unsigned char c = (unsigned char)p[i];
            if (c < 0x20 || c > 0x7E) die("JSON with a control or non-ASCII character");
            if (c == '"') quote = !quote;
            if (quote && c == '\\') die("JSON with a backslash");
            if (!quote) depth += (c == '{' || c == '[') - (c == '}' || c == ']');
            if (depth < 0) die("JSON brackets don't match");
        }
        if (depth || quote) die("JSON brackets or quotes don't match");
        if (type == MSG_JOB_RESULT) s_results++;
        if (type == MSG_JOB_STATE && len > 30 && memmem(p, len, "refused", 7)) {
            s_refused++;
            if (getenv("FUZZ_WHY")) fprintf(stderr, "%.*s\n", (int)len, p);
        }
    } else if (type == MSG_JOB_TABLE_DATA) {
        if (len < 4 || len > 4 + 1000) die("table data message of the wrong size");
    } else {
        die("an unknown message type");
    }
}
static void log_line(const char *line) {
    if (strlen(line) > 199) die("a log line longer than its buffer");
}

static uint32_t crc32z(const uint8_t *d, size_t n) {
    uint32_t c = 0xFFFFFFFF;
    for (size_t i = 0; i < n; i++) {
        c ^= d[i];
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (c & 1 ? 0xEDB88320 : 0);
    }
    return ~c;
}
static void w16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void w32(uint8_t *p, uint32_t v) { w16(p, v); w16(p + 2, v >> 16); }

/// A job a host could really send: up to 12 steps of every kind, with a pattern if it uploads.
static size_t make_job(uint8_t *out, uint32_t id, uint8_t *blob, uint32_t *blob_len) {
    int nops = (int)upto(13);
    uint32_t points = upto(4) ? upto(600) + 1 : upto(4096) + 1;
    *blob_len = 0;
    size_t at = 19;
    for (int i = 0; i < nops; i++) {
        uint8_t *op = out + at, *b = op + 4;
        size_t n = 0;
        uint8_t kind = (uint8_t)(1 + upto(6));
        op[1] = upto(4) ? 0xFF : (uint8_t)upto((uint32_t)nops);
        switch (kind) {
        case JOB_OP_SEND: {
            uint8_t d[60];
            size_t dn = upto(40);
            for (size_t k = 0; k < dn; k++) d[k] = (uint8_t)rnd();
            static const uint8_t cmds[] = {0x10, 0x11, 0x13, 0x14, 0x14, 0x14};
            uint8_t cmd = cmds[upto(sizeof cmds)];
            if (cmd == 0x14 && dn && d[0] == 12) d[0] = 3;
            n = put_packet(b, cmd, 0, d, dn);
            break;
        }
        case JOB_OP_EXPECT:
            w16(b, upto(20000));
            if (upto(2)) {
                b[2] = JOB_EXPECT_DRAWING;
                w16(b + 3, 50000 + upto(4));
                n = 5;
            } else {
                b[2] = JOB_EXPECT_PACKET;
                b[3] = (uint8_t)(0x30 + upto(9));
                b[4] = upto(2) ? 0xFF : (uint8_t)upto(6);
                b[5] = (uint8_t)upto(40);
                for (int k = 0; k < b[5]; k++) b[6 + k] = (uint8_t)rnd();
                n = 6u + b[5];
            }
            break;
        case JOB_OP_PLAY:
            w16(b, upto(3) ? 0 : 50000 + upto(4));
            n = 2;
            break;
        case JOB_OP_UPLOAD: {
            uint32_t off = *blob_len ? upto(*blob_len / 4) * 4 : 0;   // uploads may share points
            if (off + points * 4 > *blob_len) *blob_len = off + points * 4;
            w32(b, points);
            w32(b + 4, off);
            b[8] = (uint8_t)(1 + upto(8));
            for (int k = 0; k < b[8]; k++) w16(b + 9 + 2 * k, 50000 + upto(6));
            n = 9u + 2u * b[8];
            if (upto(3) == 0) { b[n++] = (uint8_t)upto(256); b[n++] = (uint8_t)upto(256); }
            break;
        }
        case JOB_OP_WAIT:
            w16(b, upto(3000));
            n = 2;
            break;
        default:
            n = 0;
            break;
        }
        op[0] = kind;
        w16(op + 2, (uint32_t)n);
        at += 4 + n;
    }
    for (uint32_t i = 0; i < *blob_len; i++) blob[i] = (uint8_t)rnd();
    w32(out, id);
    w32(out + 4, 1800000000u + upto(100000));
    w16(out + 8, upto(3000));
    w32(out + 10, *blob_len);
    w32(out + 14, crc32z(blob, *blob_len));
    out[18] = (uint8_t)nops;
    return at;
}

int main(int argc, char **argv) {
    long iterations = argc > 1 ? atol(argv[1]) : 20000;
    if (argc > 2) s_rng ^= (uint64_t)atol(argv[2]) * 0x9E3779B97F4A7C15ULL;
    static const job_io_t io = {now_ms, link_up, link_down, write_packet, recv_bytes, rssi, blob_begin, blob_write, blob_read, emit, log_line};
    job_init(&io);
    static uint8_t frame[5000], blob[13 * 4096 * 4 + 16], piece[4100];
    long executed = 0;
    for (long it = 0; it < iterations; it++) {
        uint32_t id = rnd(), blob_len = 0;
        s_chaos = (int)upto(4) * (int)upto(4);
        size_t n = make_job(frame, id, blob, &blob_len);
        uint32_t style = upto(10);
        if (style == 0) {   // nonsense of any length, as any job message
            n = upto(4200);
            for (size_t i = 0; i < n; i++) frame[i] = (uint8_t)rnd();
            job_frame((uint8_t)(MSG_JOB_BEGIN + upto(4)), frame, n);
            continue;
        }
        if (style == 1) n = upto((uint32_t)n + 1);                                         // cut short
        if (style == 2) for (uint32_t k = 1 + upto(4); k; k--) frame[upto((uint32_t)n)] = (uint8_t)rnd();   // a few bytes wrong
        job_frame(MSG_JOB_BEGIN, frame, n);
        // The pattern: in order, or (now and then) with a piece missing, repeated, or for another job.
        for (uint32_t off = 0; off < blob_len;) {
            uint32_t len = blob_len - off < 3600 ? blob_len - off : 3600;
            uint32_t trick = upto(40);
            w32(piece, trick == 0 ? id + 1 : id);
            w32(piece + 4, trick == 1 ? off + 4 : off);
            memcpy(piece + 8, blob + off, len);
            job_frame(MSG_JOB_DATA, piece, trick == 2 ? upto(8) : 8 + len);
            if (trick == 3) job_frame(MSG_JOB_DATA, piece, 8 + len);
            if (upto(30) == 0) job_frame(MSG_JOB_QUERY, piece, 0);
            off += len;
        }
        // "Run": now and then for another job, cut short, or sent twice.
        for (int ask = 0; ask < 2; ask++) {
            if (ask == 1 && upto(5)) break;
            w32(piece, upto(30) ? id : id + 1);
            if (!job_frame(MSG_JOB_RUN, piece, upto(30) ? 4 : upto(4))) continue;
            long before = s_results;
            int64_t began = s_now;
            if (!job_busy()) die("a job waiting to run isn't reported as busy");
            job_execute();
            executed++;
            if (s_results != before + 1) die("a job ended without exactly one result");
            if (job_busy()) die("still busy after the job ended");
            if (s_now - began > 4 * 3600 * 1000LL) die("a job took more than 4 hours of its own time");
            char status[200];
            int sn = job_status_json(status, sizeof status);
            if (sn <= 0 || sn >= (int)sizeof status) die("status JSON doesn't fit");
            job_frame(MSG_JOB_QUERY, piece, 0);
            if (s_results != before + 2) die("a finished job's result wasn't sent again when asked");
        }
    }
    printf("%ld job messages, %ld jobs run to the end (%ld refused), %ld writes, %ld reads: no fault\n", iterations, executed, s_refused, s_writes, s_recvs);
    return 0;
}
