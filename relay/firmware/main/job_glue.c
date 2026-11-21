// Jobs on the relay: gives job.c (the engine, plain C) the table link, somewhere to keep a pattern, and the
// network, and runs it in its own task.
//
// A pattern's points are kept in flash, in the app slot that isn't running: it is only used during a firmware
// update, it is far bigger than any pattern (1.9 MB; the largest pattern is 0.8 MB), and the relay has too
// little RAM for a large one. The first job after an update overwrites the previous firmware there, so it waits
// until the new firmware has been confirmed (ota_mark_valid_if_healthy), when no rollback can need it any more.
#include <string.h>

#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "job.h"
#include "relay.h"

#define SECTOR 4096

static TaskHandle_t s_task;
static const esp_partition_t *s_part;
static uint32_t s_erased_to;

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

static int rssi(void) { return g_st.table_rssi_valid ? g_st.table_rssi : 0; }

static const char *blob_begin(uint32_t len) {
    if (g_st.ota_running) return "a firmware update is running";
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t state;
    if (esp_ota_get_state_partition(running, &state) == ESP_OK && state == ESP_OTA_IMG_PENDING_VERIFY)
        return "new firmware is still settling in; try again in a minute";
    const esp_partition_t *spare = esp_ota_get_next_update_partition(NULL);
    if (!spare || spare == running) return "no spare flash to keep a pattern in";
    if (len > spare->size) return "pattern too large for the relay";
    s_part = spare;
    s_erased_to = 0;
    return NULL;
}

static bool blob_write(uint32_t offset, const uint8_t *data, size_t len) {
    if (!s_part || offset + len > s_part->size) return false;
    // Erase each sector just before the first write into it (writes come in order).
    while (s_erased_to < offset + len) {
        if (esp_partition_erase_range(s_part, s_erased_to, SECTOR) != ESP_OK) return false;
        s_erased_to += SECTOR;
    }
    return esp_partition_write(s_part, offset, data, len) == ESP_OK;
}

static bool blob_read(uint32_t offset, uint8_t *data, size_t len) {
    return s_part && esp_partition_read(s_part, offset, data, len) == ESP_OK;
}

static void emit(uint8_t type, const void *payload, size_t len) { net_send(type, payload, len); }

static void log_line(const char *line) { relay_log("%s", line); }

static void job_task(void *arg) {
    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        job_execute();
        net_status_changed();
    }
}

void jobs_frame(uint8_t type, const uint8_t *payload, size_t len) {
    if (job_frame(type, payload, len) && s_task) xTaskNotifyGive(s_task);
    net_status_changed();
}

void jobs_start(void) {
    static const job_io_t io = {
        .now_ms = now_ms,
        .link_up = ble_job_link_up,
        .link_down = ble_job_link_down,
        .write = ble_job_write,
        .recv = ble_job_recv,
        .rssi = rssi,
        .blob_begin = blob_begin,
        .blob_write = blob_write,
        .blob_read = blob_read,
        .emit = emit,
        .log = log_line,
    };
    job_init(&io);
    xTaskCreate(job_task, "job", 8192, NULL, 5, &s_task);
}
