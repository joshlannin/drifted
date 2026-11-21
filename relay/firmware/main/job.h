// Jobs: the relay does a piece of table work by itself.
//
// The relay's Wi-Fi is poor while it holds the table's Bluetooth link (one shared radio), so a host can't be
// relied on to answer the table in time. With a job, the host hands over everything first, while the table is
// released and Wi-Fi is clean: a short script of steps and, for an upload, the pattern's points. The relay then
// links to the table, answers its handshake and init dump itself, runs the steps (send, wait for a reply, upload,
// play and check it started), lets go of the table, and keeps the outcome and what the table said until the host
// collects them. Nothing in between needs the network.
//
// This file and job.c are plain C with no ESP-IDF in them: job_glue.c connects them to Bluetooth, flash and the
// network, and relay/tools/fake_relay.py loads the same code as a library to test hosts without hardware.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// TCP message types (relay/README.md, "Jobs").
enum {
    MSG_JOB_BEGIN = 0x50,       // host → relay: header and steps
    MSG_JOB_DATA = 0x51,        // host → relay: job id, offset, pattern points
    MSG_JOB_RUN = 0x52,         // host → relay: job id; everything is here, go
    MSG_JOB_QUERY = 0x53,       // host → relay: say where the job is (and its result again, if finished)
    MSG_JOB_STATE = 0x58,       // relay → host: JSON
    MSG_JOB_RESULT = 0x59,      // relay → host: JSON
    MSG_JOB_TABLE_DATA = 0x5A,  // relay → host: job id + bytes the table sent during the job
};

// Steps.
enum {
    JOB_OP_SEND = 1,     // packet bytes: write one table packet
    JOB_OP_EXPECT = 2,   // timeout_ms:u16, kind:u8, … : wait for the table to say something
    JOB_OP_PLAY = 3,     // id:u16 (0: the id the last upload went into): start it and check it's drawing
    JOB_OP_UPLOAD = 4,   // points:u32, offset:u32, n:u8, n × id:u16 [, pageGapMs:u8, resendGapMs:u8]: upload, trying the ids in turn
    JOB_OP_WAIT = 5,     // ms:u16
    JOB_OP_END = 6,      // stop here, successfully
};
#define JOB_FAIL_ABORT 0xFF   // a step's fail_goto: the job fails (otherwise: the step to carry on from)
enum {
    JOB_EXPECT_PACKET = 1,    // cmd:u8, action:u8 (0xFF any), n:u8, n bytes that must appear in the packet's data
    JOB_EXPECT_DRAWING = 2,   // id:u16: the running state shows this pattern drawing
};

typedef struct {
    int64_t (*now_ms)(void);
    /// Takes the table: true once linked with notifications on. Always a fresh link.
    bool (*link_up)(int timeout_ms);
    /// done: the job is over (the relay goes back to what it does without one). Otherwise: drop this link; the
    /// job will ask for a new one.
    void (*link_down)(bool done);
    /// Writes one packet to the table. False if the link is gone.
    bool (*write)(const uint8_t *packet, size_t len);
    /// Bytes the table sent, as they arrive (at most `max`, which is at least 600). 0: nothing within
    /// `timeout_ms`. Negative: the link is gone.
    int (*recv)(uint8_t *buf, size_t max, int timeout_ms);
    /// Signal to the table in dBm, 0 if unknown.
    int (*rssi)(void);
    /// Room for `len` bytes of pattern points. NULL if there is; otherwise why not.
    const char *(*blob_begin)(uint32_t len);
    /// Called with rising offsets, no gaps.
    bool (*blob_write)(uint32_t offset, const uint8_t *data, size_t len);
    bool (*blob_read)(uint32_t offset, uint8_t *data, size_t len);
    /// A message for the host (dropped if none is connected: it asks again with MSG_JOB_QUERY).
    void (*emit)(uint8_t type, const void *payload, size_t len);
    void (*log)(const char *line);
} job_io_t;

void job_init(const job_io_t *io);
/// A MSG_JOB_* message from the host. True if a job is now waiting: have the job task call job_execute().
bool job_frame(uint8_t type, const uint8_t *payload, size_t len);
/// Runs the waiting job to its end. Blocks for as long as that takes (seconds to minutes).
void job_execute(void);
/// A job is waiting or running: the table link is the job's.
bool job_busy(void);
/// `"job":{…}` for the relay's STATUS (no braces around it). Returns its length; 0 if there's been no job.
int job_status_json(char *out, size_t outlen);
