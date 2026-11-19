// The NanoC6's RGB LED shows the relay's state; its button releases or retakes the table.
//
//   purple, blinking   needs setup (no Wi-Fi network or token yet)      relay/setup.py
//   red, blinking      can't join Wi-Fi
//   amber, blinking    on Wi-Fi, looking for or connecting to the table
//   cyan               released: the HoMedics app can connect (press the button to take the table back)
//   blue               linked to the table, no host connected
//   green, blinking    host connected, waiting for the table's handshake request
//   green              host connected and talking to the table
//   white, flashing    firmware update in progress
//
// Button: short press releases the table (or takes it back). Hold 3 s: forget the table and pick the strongest.
#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "led_strip.h"
#include "relay.h"

static led_strip_handle_t s_strip;

static void set_rgb(uint8_t r, uint8_t g, uint8_t b) {
    static uint32_t last = 0xFFFFFFFF;
    uint32_t v = (uint32_t)r << 16 | (uint32_t)g << 8 | b;
    if (!s_strip || v == last) return;
    last = v;
    led_strip_set_pixel(s_strip, 0, r, g, b);
    led_strip_refresh(s_strip);
}

static void led_task(void *arg) {
    int held = 0;   // ticks the button has been down
    for (uint32_t tick = 0;; tick++) {
        vTaskDelay(pdMS_TO_TICKS(50));

        bool down = gpio_get_level(PIN_BUTTON) == 0;
        if (down) {
            held++;
            g_st.button_held = held >= 60;
        } else if (held) {
            if (held >= 60) ble_forget();
            else if (held >= 1) ble_set_released(!g_st.released);
            held = 0;
            g_st.button_held = false;
        }

        if (tick % 20 == 0) ota_mark_valid_if_healthy();

        bool slow = (tick / 20) % 2 == 0;   // 1 s on, 1 s off
        bool fast = (tick / 5) % 2 == 0;    // 250 ms
        bool flash = (tick / 2) % 2 == 0;   // 100 ms
        if (g_st.ota_running || g_st.button_held) set_rgb(flash ? 30 : 0, flash ? 30 : 0, flash ? 30 : 0);
        else if (!config_ready()) set_rgb(slow ? 25 : 0, 0, slow ? 30 : 0);
        else if (!g_st.wifi_up) set_rgb(fast ? 40 : 0, 0, 0);
        else if (g_st.released) set_rgb(0, 25, 25);
        else if (g_st.link != LINK_LINKED) set_rgb(slow ? 40 : 0, slow ? 15 : 0, 0);
        else if (!g_st.host_connected) set_rgb(0, 0, 40);
        else if (!g_st.gate_open) set_rgb(0, fast ? 35 : 0, 0);
        else set_rgb(0, 35, 0);
    }
}

void led_start(void) {
    gpio_config_t power = {.pin_bit_mask = 1ULL << PIN_RGB_POWER, .mode = GPIO_MODE_OUTPUT};
    gpio_config(&power);
    gpio_set_level(PIN_RGB_POWER, 1);
    gpio_config_t button = {.pin_bit_mask = 1ULL << PIN_BUTTON, .mode = GPIO_MODE_INPUT, .pull_up_en = GPIO_PULLUP_ENABLE};
    gpio_config(&button);

    led_strip_config_t strip = {
        .strip_gpio_num = PIN_RGB_DATA,
        .max_leds = 1,
        .led_model = LED_MODEL_WS2812,
        .color_component_format = LED_STRIP_COLOR_COMPONENT_FMT_GRB,
    };
    led_strip_rmt_config_t rmt = {.resolution_hz = 10 * 1000 * 1000};
    if (led_strip_new_rmt_device(&strip, &rmt, &s_strip) != ESP_OK) {
        ESP_LOGW("led", "no LED");
        s_strip = NULL;
    }
    xTaskCreate(led_task, "led", 3072, NULL, 2, NULL);
}
