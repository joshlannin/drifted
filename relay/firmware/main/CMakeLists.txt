idf_component_register(
    SRCS "main.c" "config.c" "ble.c" "net.c" "console.c" "led.c" "ota.c"
    INCLUDE_DIRS "."
    REQUIRES bt nvs_flash esp_wifi esp_netif esp_event esp_timer lwip esp_driver_gpio esp_driver_usb_serial_jtag
             app_update esp_https_ota esp_http_client mbedtls)
