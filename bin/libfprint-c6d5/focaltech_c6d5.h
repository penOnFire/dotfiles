/* FocalTech FT9366 USB fingerprint reader (2808:c6d5). */
#pragma once

#include "fpi-device.h"
#include "fpi-ssm.h"

G_DECLARE_FINAL_TYPE (FpiDeviceFocaltechC6d5,
                      fpi_device_focaltech_c6d5,
                      FPI,
                      DEVICE_FOCALTECH_C6D5,
                      FpDevice)
