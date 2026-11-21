// Jobs: see job.h. Plain C, no ESP-IDF: the same file runs on the relay and inside relay/tools/fake_relay.py.
//
// Two threads use it. The network thread calls job_frame() and only touches a job that isn't running; the job
// thread calls job_execute() and owns the job from "queued" until it sets "done" (its last act).
//
// The table's side of the conversation is in docs/protocol.md; the upload and play rules here are the ones in
// DriftedKit's DriftTable.swift (upload, play) and the answers are TableMessage.reply's.
#include "job.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define SCRIPT_MAX 2048
#define OPS_MAX 32
#define TRANSCRIPT_MAX 8192
#define TRANSCRIPT_TAIL 600     // kept free for the last running state and alarms
#define POINTS_PER_PAGE 40
#define KEEPALIVE_MS 1000       // the table resets its session after about 2 s without a frame from us
#define LINK_TIMEOUT_MS 40000
#define READY_TIMEOUT_MS 20000
#define MAX_LINK_FAILURES 2     // Bluetooth connects that never came up
#define MAX_SESSIONS 3          // links that came up (each starts with a handshake)
#define MAX_RESTARTS 3          // steps started again after the link or the session went
#define MAX_STEPS 64            // steps run, counting the ones a fail_goto jumps to (no endless loops)

enum { J_IDLE, J_RECEIVING, J_QUEUED, J_LINKING, J_HANDSHAKE, J_RUNNING, J_DONE };
enum { P_TIMEOUT, P_MATCH, P_LOST, P_RESET };
enum { R_OK, R_FAIL, R_END, R_LOST, R_RESET };
enum { U_OK, U_REJECTED, U_TIMEOUT, U_NOSTORAGE, U_MISSING, U_READ, U_LOST, U_RESET };

typedef struct {
    uint8_t kind, fail_goto;
    uint16_t len, off;   // body: script[off ..< off + len]
} op_t;

typedef struct {
    uint8_t ran, ok;
    uint16_t value;   // upload: the id it went into. play: the id
    uint16_t count;   // upload: pages sent again. play: how many times play was sent
    uint32_t ms;
} op_result_t;

static job_io_t io;

// The job: written by the network thread until it's queued, then read by the job thread.
static struct {
    volatile int state;
    uint32_t id;
    uint32_t local_time;      // seconds since 1970 in the host's local time, when it sent the job
    int64_t time_at_ms;
    uint16_t linger_ms;
    uint32_t blob_len, blob_crc, blob_got;
    uint8_t nops;
    op_t ops[OPS_MAX];
    uint8_t script[SCRIPT_MAX];
    // Outcome (job thread; read by the network thread once state is J_DONE).
    bool ok, truncated;
    int failed_op;
    const char *stage;        // where it failed: "link", "handshake", "step"
    char error[160];
    uint32_t link_ms, ready_ms, total_ms;
    int rssi, links, handshakes, restarts;
    uint16_t uploaded_id;
    op_result_t res[OPS_MAX];
    uint8_t transcript[TRANSCRIPT_MAX];
    uint16_t transcript_len;
    uint8_t last_state[200], last_state_len;
    uint8_t alarm[3][64], alarm_len[3];
    volatile int pc, percent;
} J;

// One link to the table (job thread only).
static struct {
    uint8_t rx[1024];
    size_t rx_len;
    bool lost, ready, reset_seen;
    int64_t last_write;
    // running state (0x35/1)
    bool have_state;
    uint8_t st_status;
    uint16_t st_pattern;
    int64_t st_at;
    unsigned state_seq, seq_mark;
    uint16_t want_pattern;
    bool draw_hit;
    // upload replies (0x34) for up_id
    uint16_t up_id;
    bool up_started, up_complete, up_failed, up_nostorage, up_missing;
    uint16_t missing[24];
    int nmissing;
    // what an EXPECT step is waiting for
    bool exp_on, exp_hit;
    uint8_t exp_cmd, exp_action, exp_sublen;
    const uint8_t *exp_sub;
} S;

static const uint8_t CONFIRM[] = {0x7B, 0x04, 0xD0, 0x4F};

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
    char line[200];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    if (io.log) io.log(line);
}

static void errf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void errf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(J.error, sizeof J.error, fmt, ap);
    va_end(ap);
    // It goes into JSON as it is.
    for (char *c = J.error; *c; c++)
        if (*c == '"' || *c == '\\' || (unsigned char)*c < 0x20) *c = '\'';
}

static uint32_t crc32_update(uint32_t crc, const uint8_t *d, size_t n) {
    static const uint32_t t[16] = {0x00000000, 0x1DB71064, 0x3B6E20C8, 0x26D930AC, 0x76DC4190, 0x6B6B51F4, 0x4DB26158, 0x5005713C,
                                   0xEDB88320, 0xF00F9344, 0xD6D6A3E8, 0xCB61B38C, 0x9B64C2B0, 0x86D3D2D4, 0xA00AE278, 0xBDBDF21C};
    for (size_t i = 0; i < n; i++) {
        crc ^= d[i];
        crc = t[crc & 15] ^ (crc >> 4);
        crc = t[crc & 15] ^ (crc >> 4);
    }
    return crc;
}

static const char *state_name(int s) {
    switch (s) {
    case J_RECEIVING: return "receiving";
    case J_QUEUED: return "queued";
    case J_LINKING: return "linking";
    case J_HANDSHAKE: return "handshake";
    case J_RUNNING: return "running";
    case J_DONE: return "done";
    default: return "idle";
    }
}

// ---- To the host ----

static void emit_state(void) {
    char b[160];
    // "got": how much of the pattern has arrived, so a host cut off part-way can send just the rest.
    int n = snprintf(b, sizeof b, "{\"job\":%lu,\"state\":\"%s\",\"op\":%d,\"ops\":%d,\"progress\":%d,\"got\":%lu}",
                     (unsigned long)J.id, state_name(J.state), J.pc, J.nops, J.percent, (unsigned long)J.blob_got);
    io.emit(MSG_JOB_STATE, b, (size_t)n);
}

static void refuse(uint32_t id, const char *why) {
    char b[200];
    int n = snprintf(b, sizeof b, "{\"job\":%lu,\"state\":\"refused\",\"error\":\"%s\"}", (unsigned long)id, why);
    io.emit(MSG_JOB_STATE, b, (size_t)n);
    logf_("job %lu refused: %s", (unsigned long)id, why);
}

static void emit_result(void) {
    static uint8_t chunk[4 + 1000];
    static char b[2400];
    chunk[0] = J.id & 0xFF; chunk[1] = J.id >> 8 & 0xFF; chunk[2] = J.id >> 16 & 0xFF; chunk[3] = J.id >> 24 & 0xFF;
    for (size_t off = 0; off < J.transcript_len; off += 1000) {
        size_t n = J.transcript_len - off < 1000 ? J.transcript_len - off : 1000;
        memcpy(chunk + 4, J.transcript + off, n);
        io.emit(MSG_JOB_TABLE_DATA, chunk, n + 4);
    }
    int o = snprintf(b, sizeof b,
                     "{\"job\":%lu,\"ok\":%s,\"error\":\"%s\",\"stage\":\"%s\",\"failedOp\":%d,\"linkMs\":%lu,\"readyMs\":%lu,"
                     "\"totalMs\":%lu,\"rssi\":%d,\"links\":%d,\"handshakes\":%d,\"restarts\":%d,\"tableBytes\":%u,"
                     "\"truncated\":%s,\"ops\":[",
                     (unsigned long)J.id, J.ok ? "true" : "false", J.error, J.stage ? J.stage : "", J.failed_op,
                     (unsigned long)J.link_ms, (unsigned long)J.ready_ms, (unsigned long)J.total_ms, J.rssi, J.links,
                     J.handshakes, J.restarts, (unsigned)J.transcript_len, J.truncated ? "true" : "false");
    // Per step: [ran, ok, value, count, ms]
    for (int i = 0; i < J.nops && o < (int)sizeof b - 64; i++)
        o += snprintf(b + o, sizeof b - o, "%s[%d,%d,%u,%u,%lu]", i ? "," : "", J.res[i].ran, J.res[i].ok, J.res[i].value,
                      J.res[i].count, (unsigned long)J.res[i].ms);
    o += snprintf(b + o, sizeof b - o, "]}");
    io.emit(MSG_JOB_RESULT, b, (size_t)o);
}

int job_status_json(char *out, size_t outlen) {
    if (J.state == J_IDLE) return 0;
    return snprintf(out, outlen, "\"job\":{\"id\":%lu,\"state\":\"%s\",\"op\":%d,\"ops\":%d,\"progress\":%d}", (unsigned long)J.id,
                    state_name(J.state), J.pc, J.nops, J.percent);
}

bool job_busy(void) { return J.state >= J_QUEUED && J.state < J_DONE; }

void job_init(const job_io_t *i) {
    io = *i;
    J.state = J_IDLE;
}

// ---- From the host ----

/// Checks one step's body. NULL if it's fine.
static const char *check_op(uint8_t kind, const uint8_t *b, uint16_t len, uint32_t blob_len) {
    switch (kind) {
    case JOB_OP_SEND:
        if (len < 4 || len > 200 || b[0] != 0x7B || b[1] != len) return "a send step isn't one table packet";
        // Never: firmware-update commands (0x15) and the reserved reset (0x14/12).
        if ((b[2] & 0x7F) == 0x15 || ((b[2] & 0x7F) == 0x14 && len > 4 && b[3] == 12)) return "that command is never sent";
        return NULL;
    case JOB_OP_EXPECT:
        if (len >= 5 && b[2] == JOB_EXPECT_DRAWING && len == 5) return NULL;
        if (len >= 6 && b[2] == JOB_EXPECT_PACKET && len == 6 + b[5]) return NULL;
        return "bad expect step";
    case JOB_OP_PLAY:
    case JOB_OP_WAIT:
        return len == 2 ? NULL : "bad step length";
    case JOB_OP_UPLOAD: {
        if (len < 11 || b[8] < 1 || b[8] > 8 || (len != 9 + 2 * b[8] && len != 11 + 2 * b[8])) return "bad upload step";
        uint32_t points = rd32(b), off = rd32(b + 4);
        if (points == 0 || points > 0x3FFFFFFF / 4 || off > blob_len || points * 4 > blob_len - off) return "upload step points outside the data";
        for (int i = 0; i < b[8]; i++)
            if (rd16(b + 9 + 2 * i) == 0) return "pattern id 0";
        return NULL;
    }
    case JOB_OP_END:
        return len == 0 ? NULL : "bad step length";
    default:
        return "unknown step";
    }
}

static void begin(const uint8_t *p, size_t len) {
    if (len < 19) return;
    uint32_t id = rd32(p);
    if (job_busy()) { refuse(id, "busy with another job"); return; }
    uint32_t blob_len = rd32(p + 10);
    uint8_t nops = p[18];
    if (nops > OPS_MAX) { refuse(id, "too many steps"); return; }

    // Check everything before touching the job in memory (the last one's result is still wanted until then).
    size_t at = 19, script_len = 0;
    for (int i = 0; i < nops; i++) {
        if (at + 4 > len) { refuse(id, "steps cut short"); return; }
        uint8_t kind = p[at], go = p[at + 1];
        uint16_t n = rd16(p + at + 2);
        if (at + 4 + n > len) { refuse(id, "steps cut short"); return; }
        if (go != JOB_FAIL_ABORT && go >= nops) { refuse(id, "a step jumps past the end"); return; }
        const char *why = check_op(kind, p + at + 4, n, blob_len);
        if (why) { refuse(id, why); return; }
        script_len += n;
        at += 4 + (size_t)n;
    }
    if (script_len > SCRIPT_MAX) { refuse(id, "steps too long"); return; }
    if (blob_len) {
        const char *why = io.blob_begin(blob_len);
        if (why) { refuse(id, why); return; }
    }

    J.state = J_IDLE;
    J.id = id;
    J.local_time = rd32(p + 4);
    J.time_at_ms = io.now_ms();
    J.linger_ms = rd16(p + 8);
    J.blob_len = blob_len;
    J.blob_crc = rd32(p + 14);
    J.blob_got = 0;
    J.nops = nops;
    at = 19;
    uint16_t off = 0;
    for (int i = 0; i < nops; i++) {
        uint16_t n = rd16(p + at + 2);
        J.ops[i] = (op_t){.kind = p[at], .fail_goto = p[at + 1], .len = n, .off = off};
        memcpy(J.script + off, p + at + 4, n);
        off += n;
        at += 4 + (size_t)n;
    }
    J.pc = 0;
    J.percent = 0;
    J.state = J_RECEIVING;
    emit_state();
}

static void data(const uint8_t *p, size_t len) {
    if (len < 8) return;
    uint32_t id = rd32(p), off = rd32(p + 4);
    size_t n = len - 8;
    if (J.state != J_RECEIVING || id != J.id) return;   // for a job we've given up on: RUN will say so
    if (off != J.blob_got || n > J.blob_len - J.blob_got) {
        J.state = J_IDLE;
        refuse(id, "pattern data out of order");
        return;
    }
    if (n && !io.blob_write(off, p + 8, n)) {
        J.state = J_IDLE;
        refuse(id, "couldn't store the pattern data");
        return;
    }
    J.blob_got += n;
}

static bool run(const uint8_t *p, size_t len) {
    if (len < 4) return false;
    uint32_t id = rd32(p);
    if (id == J.id && J.state >= J_QUEUED) { emit_state(); return false; }   // asked twice
    if (id != J.id || J.state != J_RECEIVING) { refuse(id, "no such job (send it again)"); return false; }
    if (J.blob_got != J.blob_len) {
        J.state = J_IDLE;
        refuse(id, "pattern data incomplete");
        return false;
    }
    uint32_t crc = 0xFFFFFFFF;
    static uint8_t buf[256];
    for (uint32_t off = 0; off < J.blob_len; off += sizeof buf) {
        size_t n = J.blob_len - off < sizeof buf ? J.blob_len - off : sizeof buf;
        if (!io.blob_read(off, buf, n)) { crc = ~J.blob_crc; break; }
        crc = crc32_update(crc, buf, n);
    }
    if (J.blob_len && (crc ^ 0xFFFFFFFF) != J.blob_crc) {
        J.state = J_IDLE;
        refuse(id, "pattern data didn't arrive intact");
        return false;
    }
    J.state = J_QUEUED;
    emit_state();
    return true;
}

bool job_frame(uint8_t type, const uint8_t *p, size_t len) {
    switch (type) {
    case MSG_JOB_BEGIN:
        begin(p, len);
        return false;
    case MSG_JOB_DATA:
        data(p, len);
        return false;
    case MSG_JOB_RUN:
        return run(p, len);
    case MSG_JOB_QUERY:
        if (J.state == J_DONE) emit_result();
        emit_state();
        return false;
    default:
        return false;
    }
}

// ---- The table's side ----

static bool wr(const uint8_t *p, size_t n) {
    if (S.lost) return false;
    if (!io.write(p, n)) {
        S.lost = true;
        return false;
    }
    S.last_write = io.now_ms();
    return true;
}

/// Builds and writes `7B len cmd data… checksum`.
static bool send_cmd(uint8_t cmd, const uint8_t *d, size_t n) {
    uint8_t out[208];
    if (n > 200) return false;
    out[0] = 0x7B;
    out[1] = (uint8_t)(n + 4);
    out[2] = cmd;
    memcpy(out + 3, d, n);
    uint8_t sum = 0;
    for (size_t i = 0; i < n + 3; i++) sum += out[i];
    out[n + 3] = sum;
    return wr(out, n + 4);
}

/// The time the table asks for (0x32/2 → 0x12/2): the host's clock when it sent the job, plus the time since.
static void send_time(void) {
    time_t t = (time_t)J.local_time + (time_t)((io.now_ms() - J.time_at_ms) / 1000);
    struct tm tm;
    gmtime_r(&t, &tm);
    uint8_t d[8] = {2, (uint8_t)(tm.tm_year % 100), (uint8_t)tm.tm_mon, (uint8_t)tm.tm_mday, (uint8_t)tm.tm_hour,
                    (uint8_t)tm.tm_min, (uint8_t)tm.tm_sec, (uint8_t)(tm.tm_wday == 0 ? 7 : tm.tm_wday)};
    send_cmd(0x12, d, sizeof d);
}

/// What the host gets back: the table's lists and upload replies in order, with only the latest running state
/// and alarms (those repeat once or twice a second).
static void record(const uint8_t *raw, size_t len, uint8_t cmd, int action) {
    if (cmd == 0x35) {
        if (len <= sizeof J.last_state) { memcpy(J.last_state, raw, len); J.last_state_len = (uint8_t)len; }
        return;
    }
    if (cmd == 0x37) {
        if (action >= 1 && action <= 3 && len <= sizeof J.alarm[0]) { memcpy(J.alarm[action - 1], raw, len); J.alarm_len[action - 1] = (uint8_t)len; }
        return;
    }
    if (cmd < 0x30 || cmd > 0x38) return;
    if (J.transcript_len + len > TRANSCRIPT_MAX - TRANSCRIPT_TAIL) { J.truncated = true; return; }
    memcpy(J.transcript + J.transcript_len, raw, len);
    J.transcript_len += (uint16_t)len;
}

/// 0x35/1 after the action byte: brightness, colour name, rgb, speed, playlist name, pattern:u16, progress:u16, status.
static void parse_state(const uint8_t *d, int n) {
    int i = 1;
    while (i < n && d[i]) i++;
    i += 1 + 3 + 1;
    while (i < n && d[i]) i++;
    i++;
    if (i + 4 > n) return;
    S.st_pattern = rd16(d + i);
    S.st_status = i + 4 < n ? d[i + 4] : 0xFF;
    S.st_at = io.now_ms();
    S.have_state = true;
    S.state_seq++;
    if (S.want_pattern && S.st_pattern == S.want_pattern && S.st_status == 1) S.draw_hit = true;
}

static void upload_reply(int action, const uint8_t *a, int n) {
    if (action == 1) {
        S.nmissing = 0;
        int count = n >= 1 ? a[0] : 0;
        for (int i = 0; i < count && 1 + 2 * i + 2 <= n && S.nmissing < (int)(sizeof S.missing / sizeof S.missing[0]); i++)
            S.missing[S.nmissing++] = rd16(a + 1 + 2 * i);
        S.up_missing = true;
        return;
    }
    if (n < 2 || rd16(a) != S.up_id) return;
    if (action == 2) S.up_started = true;
    else if (action == 3) S.up_complete = true;
    else if (action == 5) S.up_failed = true;
    else if (action == 6) S.up_nostorage = true;
}

static bool contains(const uint8_t *d, int n, const uint8_t *sub, int m) {
    if (m == 0) return true;
    for (int i = 0; i + m <= n; i++)
        if (memcmp(d + i, sub, (size_t)m) == 0) return true;
    return false;
}

static void on_packet(const uint8_t *raw, size_t len) {
    uint8_t cmd = raw[2] & 0x7F;
    bool ack = (raw[2] & 0x80) != 0;
    const uint8_t *d = raw + 3;
    int n = (int)len - 4;
    int action = n > 0 ? d[0] : -1;

    if (cmd == 0x50 && action == 1) {
        // A new session: what the table said in the old one no longer counts.
        if (S.ready) S.reset_seen = true;
        S.ready = false;
        J.handshakes++;
        J.transcript_len = 0;
        J.truncated = false;
    }
    record(raw, len, cmd, action);
    if (cmd == 0x4F && action == 1) S.ready = true;
    if (cmd == 0x35 && action == 1) parse_state(d + 1, n - 1);
    if (cmd == 0x34 && n >= 1) upload_reply(action, d + 1, n - 1);
    if (S.exp_on && !S.exp_hit && cmd == S.exp_cmd && (S.exp_action == 0xFF || action == S.exp_action) &&
        contains(d, n, S.exp_sub, S.exp_sublen))
        S.exp_hit = true;

    // The answer the table expects. Packets with the ack bit are the table acknowledging us: ConfirmData, never
    // an answer in kind (docs/protocol.md, Session).
    if (ack) {
        if (!(cmd == 0x50 && n == 0)) wr(CONFIRM, sizeof CONFIRM);
    } else if (cmd == 0x50 && action == 1) {
        static const uint8_t yes[] = {0x7B, 0x06, 0x50, 0x02, 0x01, 0xD4};
        wr(yes, sizeof yes);
    } else if (cmd == 0x32 && action == 2) {
        send_time();
    } else if ((cmd >= 0x30 && cmd <= 0x38) || (cmd == 0x4F && action == 1)) {
        wr(CONFIRM, sizeof CONFIRM);
    }
}

/// Reassembles packets from the notification stream (the framing rules of DriftedKit's PacketParser).
static void feed(const uint8_t *d, size_t n) {
    if (n > sizeof S.rx) return;
    if (S.rx_len + n > sizeof S.rx) S.rx_len = 0;
    memcpy(S.rx + S.rx_len, d, n);
    S.rx_len += n;
    size_t off = 0;
    while (S.rx_len - off >= 2) {
        if (S.rx[off] != 0x7B) { off++; continue; }
        uint8_t len = S.rx[off + 1];
        if (len < 4) { off++; continue; }
        if (S.rx_len - off < len) break;
        uint8_t sum = 0;
        for (int i = 0; i < len - 1; i++) sum += S.rx[off + i];
        uint8_t ack_cmd = S.rx[off + 2], check = S.rx[off + len - 1];
        uint8_t alt = (uint8_t)(sum - ack_cmd + (ack_cmd & 0x7F));   // the table also sums without the ack bit
        if (sum == check || alt == check) {
            on_packet(S.rx + off, len);
            off += len;
        } else {
            off++;
        }
    }
    memmove(S.rx, S.rx + off, S.rx_len - off);
    S.rx_len -= off;
}

/// Listens to the table for up to `ms`, answering it, until `pred` holds. Every wait in a job goes through
/// here, so the table is never left without its answers.
static int pump(int ms, bool (*pred)(void)) {
    static uint8_t buf[640];
    int64_t deadline = io.now_ms() + ms;
    for (;;) {
        if (S.lost) return P_LOST;
        if (pred && pred()) return P_MATCH;
        if (S.reset_seen) return P_RESET;
        int64_t now = io.now_ms();
        if (now >= deadline) return P_TIMEOUT;
        if (S.last_write && now - S.last_write >= KEEPALIVE_MS) wr(CONFIRM, sizeof CONFIRM);
        int64_t left = deadline - now;
        int n = io.recv(buf, sizeof buf, left > 100 ? 100 : (int)left);
        if (n < 0) {
            S.lost = true;
            return P_LOST;
        }
        if (n > 0) feed(buf, (size_t)n);
    }
}

/// A plain wait: running out of time is the point.
static int idle(int ms) {
    int p = pump(ms, NULL);
    return p == P_LOST ? R_LOST : p == P_RESET ? R_RESET : R_OK;
}

static bool pred_ready(void) { return S.ready; }
static bool pred_new_state(void) { return S.state_seq != S.seq_mark; }
static bool pred_drawing(void) { return S.draw_hit; }
static bool pred_expect(void) { return S.exp_hit; }
static bool pred_upload_start(void) { return S.up_started || S.up_failed || S.up_nostorage; }
static bool pred_upload_end(void) { return S.up_complete || S.up_missing || S.up_failed || S.up_nostorage; }

// ---- Steps ----

static int op_send(int pc, const uint8_t *b, uint16_t len) {
    if (!wr(b, len)) return R_LOST;
    // An expect straight after listens from this moment, so an answer that comes at once isn't missed.
    if (pc + 1 < J.nops && J.ops[pc + 1].kind == JOB_OP_EXPECT) return R_OK;
    return idle(200);
}

static int op_expect(const uint8_t *b) {
    int timeout = rd16(b), p;
    if (b[2] == JOB_EXPECT_PACKET) {
        S.exp_cmd = b[3];
        S.exp_action = b[4];
        S.exp_sublen = b[5];
        S.exp_sub = b + 6;
        S.exp_hit = false;
        S.exp_on = true;
        p = pump(timeout, pred_expect);
        S.exp_on = false;
    } else {
        S.want_pattern = rd16(b + 3);
        S.draw_hit = false;
        p = pump(timeout, pred_drawing);
        S.want_pattern = 0;
    }
    if (p == P_MATCH) return R_OK;
    if (p == P_LOST) return R_LOST;
    if (p == P_RESET) return R_RESET;
    errf("the table didn't answer as expected within %d s", (timeout + 500) / 1000);
    return R_FAIL;
}

/// DriftTable.play: after a pause the table ignores the first play or two, so send it until the running state
/// shows the pattern drawing.
static int op_play(const uint8_t *b, op_result_t *res) {
    uint16_t id = rd16(b);
    if (!id) id = J.uploaded_id;
    if (!id) { errf("nothing was uploaded to play"); return R_FAIL; }
    res->value = id;
    int p;
    if (!S.have_state || io.now_ms() - S.st_at > 1500) {
        S.seq_mark = S.state_seq;
        p = pump(1500, pred_new_state);
        if (p == P_LOST) return R_LOST;
        if (p == P_RESET) return R_RESET;
    }
    if (S.have_state && S.st_status != 1 && S.st_pattern != 0 && S.st_pattern != id) {
        logf_("the table is paused in pattern %u; un-pausing before playing %u", S.st_pattern, id);
        const uint8_t play_pause[] = {3};
        if (!send_cmd(0x14, play_pause, 1)) return R_LOST;
        int r = idle(1500);
        if (r != R_OK) return r;
    }
    for (int attempt = 1; attempt <= 4; attempt++) {
        const uint8_t draw[] = {1, (uint8_t)(id & 0xFF), (uint8_t)(id >> 8)};
        S.want_pattern = id;
        S.draw_hit = false;
        res->count = (uint16_t)attempt;
        if (!send_cmd(0x14, draw, sizeof draw)) return R_LOST;
        p = pump(4000, pred_drawing);
        S.want_pattern = 0;
        if (p == P_MATCH) return R_OK;
        if (p == P_LOST) return R_LOST;
        if (p == P_RESET) return R_RESET;
        if (attempt < 4) logf_("the table didn't start pattern %u; sending play again (attempt %d)", id, attempt + 1);
    }
    errf("the table didn't start pattern %u", id);
    return R_FAIL;
}

static char s_stage[80];

/// One upload into `id` (docs/protocol.md, Uploading; DriftTable.upload). `at_start`: it failed before any page.
static int upload_once(uint16_t id, uint32_t npoints, uint32_t off, int page_gap, int resend_gap, op_result_t *res, bool *at_start) {
    uint32_t pages = (npoints + POINTS_PER_PAGE - 1) / POINTS_PER_PAGE;
    uint8_t d[7] = {1, (uint8_t)(id & 0xFF), (uint8_t)(id >> 8), (uint8_t)pages, (uint8_t)(pages >> 8), (uint8_t)(pages >> 16), (uint8_t)(pages >> 24)};
    int p;
    S.up_id = id;
    S.up_started = S.up_complete = S.up_failed = S.up_nostorage = S.up_missing = false;
    *at_start = true;
    snprintf(s_stage, sizeof s_stage, "at Start");
    // The table now and then ignores a Start sent right after another upload: send it up to 3 times.
    for (int attempt = 1;; attempt++) {
        if (!send_cmd(0x13, d, sizeof d)) return U_LOST;
        p = pump(4000, pred_upload_start);
        if (p == P_LOST) return U_LOST;
        if (p == P_RESET) return U_RESET;
        if (S.up_nostorage) return U_NOSTORAGE;
        if (S.up_failed) return U_REJECTED;
        if (S.up_started) break;
        if (attempt == 3) return U_TIMEOUT;
        logf_("no upload start for %u; sending Start again (attempt %d)", id, attempt + 1);
    }
    *at_start = false;

    static uint8_t page[4 + POINTS_PER_PAGE * 4];
    uint16_t list[32];
    int nlist = -1;   // -1: every page
    int delay = page_gap;   // between pages: at 1 ms the table drops its session after End
    uint32_t sent = 0;
    // The table lists at most 20 missing pages per End, so a long upload that loses many needs more rounds.
    int rounds = 6 + (int)(pages / 20 < 30 ? pages / 20 : 30);
    for (int attempt = 1; attempt <= rounds; attempt++) {
        uint32_t count = nlist < 0 ? pages : (uint32_t)nlist;
        for (uint32_t k = 0; k < count; k++) {
            uint32_t i = nlist < 0 ? k : list[k];
            if (S.up_nostorage) return U_NOSTORAGE;
            if (S.up_failed) return U_REJECTED;
            uint32_t n = npoints - i * POINTS_PER_PAGE;
            if (n > POINTS_PER_PAGE) n = POINTS_PER_PAGE;
            page[0] = 1;
            page[1] = (uint8_t)n;
            page[2] = (uint8_t)((i + 1) & 0xFF);
            page[3] = (uint8_t)((i + 1) >> 8);
            if (!io.blob_read(off + i * POINTS_PER_PAGE * 4, page + 4, n * 4)) return U_READ;
            if (!send_cmd(0x53, page, 4 + n * 4)) return U_LOST;
            sent++;
            if (nlist >= 0) res->count++;
            J.percent = (int)(sent >= pages ? 99 : sent * 100 / pages);
            snprintf(s_stage, sizeof s_stage, "after page %lu of %lu", (unsigned long)(i + 1), (unsigned long)pages);
            p = pump(delay, NULL);
            if (p == P_LOST) return U_LOST;
            if (p == P_RESET) return U_RESET;
        }
        p = pump(100, NULL);
        if (p == P_LOST) return U_LOST;
        if (p == P_RESET) return U_RESET;
        S.up_complete = S.up_missing = false;
        d[0] = 2;
        if (!send_cmd(0x13, d, sizeof d)) return U_LOST;
        snprintf(s_stage, sizeof s_stage, "after End");
        p = pump(15000, pred_upload_end);
        if (p == P_LOST) return U_LOST;
        if (p == P_RESET) return U_RESET;
        // Only 0x34/3 means stored. An empty missing list means the last page(s) were lost.
        if (S.up_complete) return U_OK;
        if (S.up_nostorage) return U_NOSTORAGE;
        if (S.up_failed) return U_REJECTED;
        if (!S.up_missing) return U_TIMEOUT;
        nlist = 0;
        if (S.nmissing == 0) {
            uint32_t tail = (uint32_t)(3 * attempt) < pages ? (uint32_t)(3 * attempt) : pages;
            if (tail > sizeof list / sizeof list[0]) tail = sizeof list / sizeof list[0];
            for (uint32_t k = 0; k < tail; k++) list[nlist++] = (uint16_t)(pages - tail + k);
            logf_("the table lost the last page(s); sending the last %lu again (attempt %d)", (unsigned long)tail, attempt);
        } else {
            for (int k = 0; k < S.nmissing; k++)
                if (S.missing[k] >= 1 && S.missing[k] <= pages) list[nlist++] = (uint16_t)(S.missing[k] - 1);
            logf_("the table is missing %d page(s); sending them again (attempt %d)", S.nmissing, attempt);
        }
        delay = resend_gap;
    }
    return U_MISSING;
}

/// Uploads, up to 3 times when the table drops the upload or goes quiet. A rejection at Start can mean that id
/// is stuck "drawing" (docs/failure-modes.md), so the next try uses the next id the host listed.
static int op_upload(const uint8_t *b, uint16_t len, op_result_t *res) {
    uint32_t npoints = rd32(b), off = rd32(b + 4);
    int nids = b[8], idx = 0;
    // Optional after the ids: ms between pages, and between pages sent again (100 and 200 otherwise).
    bool gaps = len == 11 + 2 * nids && b[9 + 2 * nids] && b[10 + 2 * nids];
    int page_gap = gaps ? b[9 + 2 * nids] : 100, resend_gap = gaps ? b[10 + 2 * nids] : 200;
    for (int attempt = 1;; attempt++) {
        uint16_t id = rd16(b + 9 + 2 * idx);
        bool at_start = false;
        res->value = id;
        int u = upload_once(id, npoints, off, page_gap, resend_gap, res, &at_start);
        S.up_id = 0;
        switch (u) {
        case U_OK:
            J.uploaded_id = id;
            J.percent = 100;
            logf_("pattern %u stored on the table (%lu points)", id, (unsigned long)npoints);
            return R_OK;
        case U_LOST: return R_LOST;
        case U_RESET: return R_RESET;
        case U_NOSTORAGE: errf("the table reports not enough storage space"); return R_FAIL;
        case U_MISSING: errf("pages still missing after retries"); return R_FAIL;
        case U_READ: errf("couldn't read the pattern back from the relay's flash"); return R_FAIL;
        default: break;
        }
        if (u == U_REJECTED) errf("the table rejected pattern %u %s", id, s_stage);
        else errf("no answer from the table %s (pattern %u)", s_stage, id);
        if (attempt == 3) return R_FAIL;
        if (u == U_REJECTED && at_start && idx + 1 < nids) idx++;
        logf_("%s; trying again into pattern %u in 2 s (attempt %d of 3)", J.error, rd16(b + 9 + 2 * idx), attempt + 1);
        int r = idle(2000);
        if (r != R_OK) return r;
    }
}

static int run_op(int pc) {
    const op_t *op = &J.ops[pc];
    const uint8_t *b = J.script + op->off;
    op_result_t *res = &J.res[pc];
    res->ran = 1;
    switch (op->kind) {
    case JOB_OP_SEND: return op_send(pc, b, op->len);
    case JOB_OP_EXPECT: return op_expect(b);
    case JOB_OP_PLAY: return op_play(b, res);
    case JOB_OP_UPLOAD:
        res->count = 0;
        return op_upload(b, op->len, res);
    case JOB_OP_WAIT: return idle(rd16(b));
    default: return R_END;
    }
}

static void set_state(int s) {
    J.state = s;
    emit_state();
}

void job_execute(void) {
    if (J.state != J_QUEUED) return;
    int64_t t0 = io.now_ms();
    J.ok = false;
    J.truncated = false;
    J.failed_op = -1;
    J.stage = "";
    J.error[0] = 0;
    J.link_ms = J.ready_ms = J.total_ms = 0;
    J.rssi = 0;
    J.links = J.handshakes = J.restarts = 0;
    J.uploaded_id = 0;
    memset(J.res, 0, sizeof J.res);
    J.transcript_len = 0;
    J.last_state_len = 0;
    memset(J.alarm_len, 0, sizeof J.alarm_len);
    J.pc = 0;
    J.percent = 0;
    logf_("job %lu: %d step(s)%s", (unsigned long)J.id, J.nops, J.blob_len ? ", with a pattern" : "");

    int pc = 0, steps = 0, link_failures = 0;
    bool finished = false, failed = false;
    while (!finished) {
        set_state(J_LINKING);
        if (!io.link_up(LINK_TIMEOUT_MS)) {
            io.link_down(false);
            if (++link_failures >= MAX_LINK_FAILURES) {
                J.stage = "link";
                errf("couldn't connect to the table over Bluetooth");
                failed = true;
                break;
            }
            continue;
        }
        if (J.links++ == 0) J.link_ms = (uint32_t)(io.now_ms() - t0);
        memset(&S, 0, sizeof S);
        set_state(J_HANDSHAKE);
        // The answers in on_packet do the handshake and the init dump. A table left half-way through an earlier
        // dump never asks for a handshake; answering what it repeats gets it to the end of that dump instead.
        bool lost = pump(READY_TIMEOUT_MS, pred_ready) != P_MATCH;
        if (!lost) {
            if (!J.ready_ms) J.ready_ms = (uint32_t)(io.now_ms() - t0);
            if (io.rssi) J.rssi = io.rssi();
            set_state(J_RUNNING);
        }
        while (!lost && pc < J.nops) {
            if (++steps > MAX_STEPS) {
                J.stage = "step";
                J.failed_op = pc;
                errf("the steps went round in circles");
                failed = true;
                break;
            }
            J.pc = pc;
            int64_t began = io.now_ms();
            int r = run_op(pc);
            J.res[pc].ms += (uint32_t)(io.now_ms() - began);
            if (r == R_OK) {
                J.res[pc].ok = 1;
                pc++;
            } else if (r == R_END) {
                J.res[pc].ok = 1;
                pc = J.nops;
            } else if (r == R_FAIL) {
                J.res[pc].ok = 0;
                if (J.ops[pc].fail_goto == JOB_FAIL_ABORT) {
                    J.stage = "step";
                    J.failed_op = pc;
                    failed = true;
                    break;
                }
                logf_("step %d: %s; carrying on from step %d", pc, J.error, J.ops[pc].fail_goto);
                J.error[0] = 0;
                pc = J.ops[pc].fail_goto;
            } else {
                // The link went, or the table started its session again. Both mean a new handshake, then this
                // step again from its start.
                if (++J.restarts > MAX_RESTARTS) {
                    J.stage = "step";
                    J.failed_op = pc;
                    errf("lost the table %d times", J.restarts);
                    failed = true;
                    break;
                }
                if (r == R_LOST) {
                    lost = true;
                } else {
                    logf_("the table restarted its session during step %d; starting the step again", pc);
                    S.reset_seen = false;
                    lost = pump(READY_TIMEOUT_MS, pred_ready) != P_MATCH;
                }
            }
        }
        if (!lost || failed) {
            if (!S.lost) {
                // A last look at what the table is doing now (a play just sent shows up here).
                if (J.linger_ms) pump(J.linger_ms, NULL);
                if (!S.have_state && !S.lost) { S.seq_mark = S.state_seq; pump(1500, pred_new_state); }
                if (io.rssi && io.rssi()) J.rssi = io.rssi();
            }
            finished = true;
        } else {
            io.link_down(false);
            if (J.links >= MAX_SESSIONS) {
                J.stage = J.ready_ms ? "step" : "handshake";
                if (J.ready_ms) J.failed_op = pc;
                errf(J.ready_ms ? "kept losing the table" : "the table didn't finish its handshake");
                failed = true;
                finished = true;
            } else {
                logf_(J.ready_ms ? "lost the table; linking again" : "no init complete from the table; linking again");
            }
        }
    }
    io.link_down(true);

    // The latest running state and alarms go last, after the lists.
    if (J.last_state_len && J.transcript_len + J.last_state_len <= TRANSCRIPT_MAX) {
        memcpy(J.transcript + J.transcript_len, J.last_state, J.last_state_len);
        J.transcript_len += J.last_state_len;
    }
    for (int i = 0; i < 3; i++)
        if (J.alarm_len[i] && J.transcript_len + J.alarm_len[i] <= TRANSCRIPT_MAX) {
            memcpy(J.transcript + J.transcript_len, J.alarm[i], J.alarm_len[i]);
            J.transcript_len += J.alarm_len[i];
        }
    J.ok = !failed;
    J.total_ms = (uint32_t)(io.now_ms() - t0);
    J.pc = pc;
    if (J.ok) logf_("job %lu done in %lu ms (linked after %lu, ready after %lu)", (unsigned long)J.id, (unsigned long)J.total_ms,
                    (unsigned long)J.link_ms, (unsigned long)J.ready_ms);
    else logf_("job %lu failed after %lu ms: %s", (unsigned long)J.id, (unsigned long)J.total_ms, J.error);
    emit_result();
    J.state = J_DONE;
    emit_state();
}
