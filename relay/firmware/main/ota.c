// Firmware updates over the network: the relay downloads an image from an http(s) URL (relay/ota.py serves one)
// into the other app slot and restarts into it. A new image that doesn't get on Wi-Fi and start its server
// within 5 minutes restarts, and the bootloader rolls back to the previous one.
#include <stdio.h>
#include <string.h>

#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_https_ota.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "job.h"
#include "relay.h"

static char s_url[256];

static void ota_task(void *arg) {
    relay_log("updating firmware from %s", s_url);
    esp_http_client_config_t http = {
        .url = s_url,
        .timeout_ms = 15000,
        .keep_alive_enable = true,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };
    esp_https_ota_config_t cfg = {.http_config = &http};
    esp_err_t e = esp_https_ota(&cfg);
    if (e == ESP_OK) {
        relay_log("update written; restarting into it");
        net_result("ota", true, "update written; restarting", NULL);
        printf("ok update written; restarting\n");
        vTaskDelay(pdMS_TO_TICKS(1000));
        esp_restart();
    }
    relay_log("update failed: %s", esp_err_to_name(e));
    net_result("ota", false, esp_err_to_name(e), NULL);
    printf("error: update failed: %s\n", esp_err_to_name(e));
    g_st.ota_running = false;
    net_status_changed();
    vTaskDelete(NULL);
}

bool ota_start(const char *url, char *msg, size_t msglen) {
    if (g_st.ota_running) { snprintf(msg, msglen, "an update is already running"); return false; }
    // A job's pattern sits in the app slot the update is about to be written to.
    if (job_busy()) { snprintf(msg, msglen, "a job is running; try again when it's finished"); return false; }
    if (strncmp(url, "http://", 7) != 0 && strncmp(url, "https://", 8) != 0) { snprintf(msg, msglen, "give an http(s) URL"); return false; }
    if (!g_st.wifi_up) { snprintf(msg, msglen, "Wi-Fi isn't connected"); return false; }
    strlcpy(s_url, url, sizeof s_url);
    g_st.ota_running = true;
    net_status_changed();
    if (xTaskCreate(ota_task, "ota", 8192, NULL, 4, NULL) != pdPASS) {
        g_st.ota_running = false;
        snprintf(msg, msglen, "out of memory");
        return false;
    }
    snprintf(msg, msglen, "downloading; the relay restarts into the new firmware when it's written");
    return true;
}

void ota_mark_valid_if_healthy(void) {
    static bool settled;
    if (settled) return;
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t state;
    if (esp_ota_get_state_partition(running, &state) != ESP_OK || state != ESP_OTA_IMG_PENDING_VERIFY) {
        settled = true;
        return;
    }
    int64_t up = esp_timer_get_time();
    if (g_st.wifi_up && g_st.server_up && up > 20 * 1000000LL) {
        esp_ota_mark_app_valid_cancel_rollback();
        relay_log("new firmware %s is up; keeping it", RELAY_FIRMWARE_VERSION);
        settled = true;
    } else if (up > 5 * 60 * 1000000LL) {
        ESP_LOGE("ota", "new firmware never got online; restarting to roll back");
        esp_restart();
    }
}
