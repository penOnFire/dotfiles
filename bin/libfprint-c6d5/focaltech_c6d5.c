/* FocalTech FT9366 USB fingerprint reader (2808:c6d5).
 *
 * The c6d5 uses image capture and FocalTech's host-side WinBio matcher.  It
 * does not use the sensor-template commands used by the older 9e65 driver.
 */

#define FP_COMPONENT "focaltech_c6d5"
#include "drivers_api.h"
#include "ft9366_engine.h"
#include "focaltech_c6d5.h"
#include <stdlib.h>

#define FT_CMD_TIMEOUT       3000
#define FT_EP_OUT            0x01
#define FT_EP_IN             0x82
#define FT_CMD_CONTROL       0x82
#define FT_IMAGE_WIDTH       152
#define FT_IMAGE_HEIGHT      40
#define FT_IMAGE_PIXELS      (FT_IMAGE_WIDTH * FT_IMAGE_HEIGHT)
#define FT_RAW_IMAGE_SIZE    (FT_IMAGE_PIXELS * 2)
#define FT_ENROLL_SAMPLES    10
#define FT_STATUS_PRESENT    0x05

static const FpIdEntry id_table[] = {
  { .vid = 0x2808, .pid = 0xc6d5 },
  { .vid = 0,      .pid = 0      },
};

enum scan_states {
  SCAN_WAIT_DELAY,
  SCAN_WAIT_SEND,
  SCAN_WAIT_RECV,
  SCAN_WAIT_CHECK,
  SCAN_SETTLE,
  SCAN_CAPTURE_SEND,
  SCAN_CAPTURE_RECV,
  SCAN_WAIT_LIFT_DELAY,
  SCAN_WAIT_LIFT_SEND,
  SCAN_WAIT_LIFT_RECV,
  SCAN_WAIT_LIFT_CHECK,
  SCAN_NUM_STATES,
};

struct _FpiDeviceFocaltechC6d5
{
  FpDevice parent;

  FpiSsm *ssm;
  guint8 response[64];
  gsize response_len;
  guint8 last_command;
  guint8 *raw_image;
  guint8 *image;

  FpPrint *print;
  guint8 *verify_template;
  gsize verify_template_len;
  guint enroll_done;
  gboolean verifying;
  gboolean engine_ready;
  gboolean finger_present;
};

G_DEFINE_TYPE (FpiDeviceFocaltechC6d5,
               fpi_device_focaltech_c6d5,
               FP_TYPE_DEVICE)

static guint8
packet_checksum (const guint8 *packet,
                 gsize         len)
{
  guint8 sum = 0;

  for (gsize i = 2; i < len; i++)
    sum ^= packet[i];

  return sum;
}

static guint8 *
build_command (guint8        command,
               const guint8 *args,
               gsize         args_len,
               gsize        *packet_len)
{
  gsize payload_len = 1 + args_len;
  guint8 *packet = g_malloc (3 + payload_len + 1);

  packet[0] = 0x02;
  packet[1] = 0x00;
  packet[2] = payload_len;
  packet[3] = command;
  if (args_len)
    memcpy (packet + 4, args, args_len);
  packet[3 + payload_len] = packet_checksum (packet, 3 + payload_len);
  *packet_len = 4 + payload_len;
  return packet;
}

static void
mark_protocol_error (FpiSsm *ssm,
                     const char *message)
{
  fpi_ssm_mark_failed (ssm,
                       fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO,
                                                 "%s", message));
}

static void
send_cb (FpiUsbTransfer *transfer,
         FpDevice       *device,
         gpointer        user_data,
         GError         *error)
{
  FpiDeviceFocaltechC6d5 *self = FPI_DEVICE_FOCALTECH_C6D5 (device);
  FpiSsm *ssm = transfer->ssm;

  if (!ssm || self->ssm != ssm)
    return;

  if (error)
    {
      fpi_ssm_mark_failed (ssm, error);
      return;
    }

  fpi_ssm_next_state (ssm);
}

static void
receive_response_cb (FpiUsbTransfer *transfer,
                     FpDevice       *device,
                     gpointer        user_data,
                     GError         *error)
{
  FpiDeviceFocaltechC6d5 *self = FPI_DEVICE_FOCALTECH_C6D5 (device);
  FpiSsm *ssm = transfer->ssm;

  if (!ssm || self->ssm != ssm)
    return;

  if (error)
    {
      fpi_ssm_mark_failed (ssm, error);
      return;
    }

  /* FT9366 returns the status as one raw byte. The normal capture path
   * returns the image directly; neither response is a framed command packet.
   */
  if (transfer->actual_length != 1)
    {
      g_warning ("c6d5: invalid status read for command 0x%02x (%zd bytes)",
                 self->last_command, transfer->actual_length);
      mark_protocol_error (ssm, "Invalid FocalTech finger-status read");
      return;
    }

  self->response_len = MIN (transfer->actual_length,
                            sizeof (self->response));
  memcpy (self->response, transfer->buffer, self->response_len);
  fpi_ssm_next_state (ssm);
}

static void
read_image_cb (FpiUsbTransfer *transfer,
               FpDevice       *device,
               gpointer        user_data,
               GError         *error)
{
  FpiDeviceFocaltechC6d5 *self = FPI_DEVICE_FOCALTECH_C6D5 (device);
  FpiSsm *ssm = transfer->ssm;

  if (!ssm || self->ssm != ssm)
    return;

  if (error)
    {
      fpi_ssm_mark_failed (ssm, error);
      return;
    }

  if (transfer->actual_length != FT_RAW_IMAGE_SIZE)
    {
      g_warning ("c6d5: short raw image read (%zd of %u bytes)",
                 transfer->actual_length, FT_RAW_IMAGE_SIZE);
      mark_protocol_error (ssm, "Incomplete FocalTech image capture");
      return;
    }

  memcpy (self->raw_image, transfer->buffer, FT_RAW_IMAGE_SIZE);
  fpi_ssm_next_state (ssm);
}

static void
send_command (FpDevice                 *device,
              guint8                    command,
              const guint8             *args,
              gsize                     args_len,
              FpiUsbTransferCallback    callback)
{
  FpiDeviceFocaltechC6d5 *self = FPI_DEVICE_FOCALTECH_C6D5 (device);
  FpiUsbTransfer *transfer;
  gsize packet_len;
  guint8 *packet = build_command (command, args, args_len, &packet_len);

  self->last_command = command;
  transfer = fpi_usb_transfer_new (device);
  transfer->ssm = self->ssm;
  fpi_usb_transfer_fill_bulk_full (transfer, FT_EP_OUT,
                                   packet, packet_len, g_free);
  fpi_usb_transfer_submit (transfer, FT_CMD_TIMEOUT,
                           fpi_device_get_cancellable (device),
                           callback, NULL);
}

static void
receive_response (FpDevice *device)
{
  FpiDeviceFocaltechC6d5 *self = FPI_DEVICE_FOCALTECH_C6D5 (device);
  FpiUsbTransfer *transfer = fpi_usb_transfer_new (device);

  transfer->ssm = self->ssm;
  fpi_usb_transfer_fill_bulk (transfer, FT_EP_IN, 1);
  fpi_usb_transfer_submit (transfer, FT_CMD_TIMEOUT,
                           fpi_device_get_cancellable (device),
                           receive_response_cb, NULL);
}

static gboolean
response_has_status (FpiDeviceFocaltechC6d5 *self,
                     guint8                 status)
{
  return self->response_len == 1 && self->response[0] == status;
}

static void
smooth_histogram (gdouble *histogram,
                  guint    len)
{
  gdouble smoothed[256];

  g_assert (len <= G_N_ELEMENTS (smoothed));
  for (guint i = 0; i < len; i++)
    {
      guint first = i > 2 ? i - 2 : 0;
      guint last = MIN (i + 2, len - 1);
      gdouble sum = 0;

      for (guint j = first; j <= last; j++)
        sum += histogram[j];
      smoothed[i] = sum / (last - first + 1);
    }

  memcpy (histogram, smoothed, len * sizeof (smoothed[0]));
}

/* Port of the official FT9366 conversion: negate signed sensor samples,
 * clamp below zero, smooth the 256-bin histogram, select an adaptive upper
 * contrast threshold, then emit an 8-bit grayscale frame for WinBio.
 */
static void
convert_image (FpiDeviceFocaltechC6d5 *self)
{
  gdouble histogram[256] = { 0 };
  gint pixels[FT_IMAGE_PIXELS];
  gint minimum = G_MAXINT;
  gint maximum = G_MININT;
  gdouble low_total = 0;
  gdouble high_total = 0;
  gdouble low_density;
  gint limit;
  gint clip_bin;
  gint clip_value;

  for (guint i = 0; i < FT_IMAGE_PIXELS; i++)
    {
      guint16 raw;
      gint value;

      memcpy (&raw, self->raw_image + i * 2, sizeof (raw));
      value = MAX (-(gint16) GUINT16_FROM_LE (raw), 0);
      pixels[i] = value;
      minimum = MIN (minimum, value);
      maximum = MAX (maximum, value);
    }

  if (maximum <= minimum)
    {
      memset (self->image, 0, FT_IMAGE_PIXELS);
      return;
    }

  for (guint i = 0; i < FT_IMAGE_PIXELS; i++)
    {
      guint bin = (guint) (((gdouble) (pixels[i] - minimum) * 256.0) /
                           (maximum - minimum + 0.000001));
      histogram[MIN (bin, 255)]++;
    }

  for (guint i = 0; i < 3; i++)
    smooth_histogram (histogram, G_N_ELEMENTS (histogram));

  for (guint i = 0; i < 2; i++)
    smooth_histogram (histogram, 250);

  for (guint i = 0; i < 200; i++)
    low_total += histogram[i];
  for (guint i = 200; i < 250; i++)
    high_total += histogram[i];

  if (high_total > low_total * 0.8)
    {
      limit = 200;
      low_density = high_total > 0 ? low_total * 75.0 / high_total : 1.0;
    }
  else
    {
      limit = 250;
      low_density = 1.0;
    }

  clip_bin = limit;
  {
    guint consecutive_low_bins = 0;

    for (gint center = limit - 10; center >= 0; center--)
      {
        gint first = MAX (center - 2, 0);
        gint last = MIN (center + 2, limit);
        gdouble local_density = 0;

        for (gint i = first; i <= last; i++)
          local_density += histogram[i];

        if (low_density > local_density)
          consecutive_low_bins++;
        else if (consecutive_low_bins > 5)
          {
            clip_bin = center;
            break;
          }
        else
          consecutive_low_bins = 0;
      }
  }

  if (clip_bin < 50)
    clip_bin = 250;
  if (limit == 250)
    clip_bin = MIN (clip_bin + 30, 250);

  clip_value = (clip_bin * maximum) / 100;
  if (clip_value <= minimum)
    {
      memset (self->image, 0, FT_IMAGE_PIXELS);
      return;
    }

  for (guint i = 0; i < FT_IMAGE_PIXELS; i++)
    {
      gdouble scaled = ((gdouble) (pixels[i] - minimum) * 255.0) /
                       (clip_value - minimum + 0.000001);

      self->image[i] = CLAMP ((gint) scaled, 0, 255);
    }
}

static void
scan_run_state (FpiSsm   *ssm,
                FpDevice *device)
{
  FpiDeviceFocaltechC6d5 *self = FPI_DEVICE_FOCALTECH_C6D5 (device);
  const guint8 get_finger_status[] = { 0x73, 0x01 };
  const guint8 capture_image[] = { 0x76, 0x01 };

  switch (fpi_ssm_get_cur_state (ssm))
    {
    case SCAN_WAIT_DELAY:
      fpi_ssm_next_state_delayed (ssm, 20);
      break;

    case SCAN_WAIT_SEND:
      send_command (device, FT_CMD_CONTROL,
                    get_finger_status, sizeof (get_finger_status), send_cb);
      break;

    case SCAN_WAIT_RECV:
      receive_response (device);
      break;

    case SCAN_WAIT_CHECK:
      if (response_has_status (self, FT_STATUS_PRESENT))
        {
          if (!self->finger_present)
            fpi_device_report_finger_status_changes (device,
                                                      FP_FINGER_STATUS_PRESENT,
                                                      FP_FINGER_STATUS_NEEDED);
          self->finger_present = TRUE;
          fpi_ssm_next_state (ssm);
        }
      else if (self->response_len == 1)
        {
          fpi_ssm_jump_to_state (ssm, SCAN_WAIT_DELAY);
        }
      else
        {
          mark_protocol_error (ssm, "Unexpected finger-status response");
        }
      break;

    case SCAN_SETTLE:
      fpi_ssm_next_state_delayed (ssm, 50);
      break;

    case SCAN_CAPTURE_SEND:
      send_command (device, FT_CMD_CONTROL,
                    capture_image, sizeof (capture_image), send_cb);
      break;

    case SCAN_CAPTURE_RECV:
      {
        FpiUsbTransfer *transfer = fpi_usb_transfer_new (device);
        transfer->ssm = ssm;
        fpi_usb_transfer_fill_bulk (transfer, FT_EP_IN, FT_RAW_IMAGE_SIZE);
        fpi_usb_transfer_submit (transfer, FT_CMD_TIMEOUT,
                                 fpi_device_get_cancellable (device),
                                 read_image_cb, NULL);
      }
      break;

    case SCAN_WAIT_LIFT_DELAY:
      fpi_ssm_next_state_delayed (ssm, 20);
      break;

    case SCAN_WAIT_LIFT_SEND:
      send_command (device, FT_CMD_CONTROL,
                    get_finger_status, sizeof (get_finger_status), send_cb);
      break;

    case SCAN_WAIT_LIFT_RECV:
      receive_response (device);
      break;

    case SCAN_WAIT_LIFT_CHECK:
      if (response_has_status (self, FT_STATUS_PRESENT))
        fpi_ssm_jump_to_state (ssm, SCAN_WAIT_LIFT_DELAY);
      else if (self->response_len == 1)
        {
          self->finger_present = FALSE;
          fpi_device_report_finger_status_changes (device,
                                                    FP_FINGER_STATUS_NEEDED,
                                                    FP_FINGER_STATUS_PRESENT);
          fpi_ssm_mark_completed (ssm);
        }
      else
        mark_protocol_error (ssm, "Unexpected finger-lift response");
      break;

    default:
      g_assert_not_reached ();
    }
}

static void start_scan (FpDevice *device);

static void
scan_complete (FpiSsm   *ssm,
               FpDevice *device,
               GError   *error)
{
  FpiDeviceFocaltechC6d5 *self = FPI_DEVICE_FOCALTECH_C6D5 (device);
  guint32 engine_result;

  self->ssm = NULL;
  if (error)
    {
      if (self->verifying)
        fpi_device_verify_complete (device, error);
      else
        fpi_device_enroll_complete (device, NULL, error);
      return;
    }

  convert_image (self);
  engine_result = ft9366_engine_accept (self->image,
                                         FT_IMAGE_WIDTH,
                                         FT_IMAGE_HEIGHT,
                                         self->verifying ? 2 : 4);
  if (engine_result != 0)
    {
      g_debug ("c6d5: engine rejected frame (HRESULT 0x%08x)",
               engine_result);
      if (self->verifying)
        {
          start_scan (device);
          return;
        }

      {
        GError *retry = fpi_device_retry_new (FP_DEVICE_RETRY_CENTER_FINGER);
        fpi_device_enroll_progress (device, self->enroll_done, NULL, retry);
      }
      start_scan (device);
      return;
    }

  if (self->verifying)
    {
      gboolean match = ft9366_engine_verify (self->verify_template,
                                               self->verify_template_len);
      fpi_device_verify_report (device,
                                match ? FPI_MATCH_SUCCESS : FPI_MATCH_FAIL,
                                NULL, NULL);
      fpi_device_verify_complete (device, NULL);
      return;
    }

  {
    gint update = ft9366_engine_enroll_update ();

    if (update == 2)
      {
        GError *retry = fpi_device_retry_new (FP_DEVICE_RETRY_REMOVE_FINGER);
        fpi_device_enroll_progress (device, self->enroll_done, NULL, retry);
        start_scan (device);
        return;
      }

    self->enroll_done++;
    fpi_device_enroll_progress (device, self->enroll_done, NULL, NULL);

    if (update != 0 && self->enroll_done < FT_ENROLL_SAMPLES)
      {
        start_scan (device);
        return;
      }
  }

  {
    guint8 *template_blob = NULL;
    size_t template_len = 0;
    GVariant *bytes;
    GVariant *data;

    if (ft9366_engine_enroll_commit (&template_blob, &template_len) != 0 ||
        !template_blob || template_len == 0)
      {
        fpi_device_enroll_complete (device, NULL,
          fpi_device_error_new_msg (FP_DEVICE_ERROR_GENERAL,
                                    "FocalTech enrollment commit failed"));
        return;
      }

    bytes = g_variant_new_fixed_array (G_VARIANT_TYPE_BYTE,
                                       template_blob, template_len, 1);
    data = g_variant_new ("(@ay)", bytes);
    fpi_print_set_type (self->print, FPI_PRINT_RAW);
    fpi_print_set_device_stored (self->print, FALSE);
    g_object_set (self->print,
                  "fpi-data", data,
                  "description", "FocalTech FT9366 fingerprint",
                  NULL);
    free (template_blob);
    fpi_device_enroll_complete (device, g_object_ref (self->print), NULL);
  }
}

static void
start_scan (FpDevice *device)
{
  FpiDeviceFocaltechC6d5 *self = FPI_DEVICE_FOCALTECH_C6D5 (device);

  self->ssm = fpi_ssm_new (device, scan_run_state, SCAN_NUM_STATES);
  fpi_ssm_start (self->ssm, scan_complete);
}

static void
focaltech_c6d5_open (FpDevice *device)
{
  FpiDeviceFocaltechC6d5 *self = FPI_DEVICE_FOCALTECH_C6D5 (device);
  GUsbDevice *usb_device = fpi_device_get_usb_device (device);
  g_autoptr(GError) error = NULL;
  const char *dll_path = g_getenv ("FT9366_ENGINE_DLL");

  if (!g_usb_device_claim_interface (usb_device, 0, 0, &error))
    {
      fpi_device_open_complete (device, g_steal_pointer (&error));
      return;
    }

  if (!dll_path)
    dll_path = "/usr/lib/libfprint-2/ftWbioEngineAdapter.dll";

  if (ft9366_engine_open (dll_path) != 0)
    {
      GError *open_error = fpi_device_error_new_msg (
        FP_DEVICE_ERROR_GENERAL,
        "Could not load FocalTech matching engine from %s", dll_path);
      g_usb_device_release_interface (usb_device, 0, 0, NULL);
      fpi_device_open_complete (device, open_error);
      return;
    }

  self->engine_ready = TRUE;
  fpi_device_open_complete (device, NULL);
}

static void
focaltech_c6d5_close (FpDevice *device)
{
  GError *error = NULL;

  g_usb_device_release_interface (fpi_device_get_usb_device (device),
                                  0, 0, &error);
  fpi_device_close_complete (device, error);
}

static gboolean
load_template (FpPrint  *print,
               guint8  **template_out,
               gsize    *template_len_out)
{
  g_autoptr(GVariant) data = NULL;
  g_autoptr(GVariant) bytes = NULL;
  gsize template_len = 0;
  const guint8 *template_data;

  g_object_get (print, "fpi-data", &data, NULL);
  if (!data || !g_variant_check_format_string (data, "(@ay)", FALSE))
    return FALSE;

  g_variant_get (data, "(@ay)", &bytes);
  template_data = g_variant_get_fixed_array (bytes, &template_len, 1);
  if (!template_data || template_len == 0)
    return FALSE;

  *template_out = g_memdup2 (template_data, template_len);
  *template_len_out = template_len;
  return TRUE;
}

static void
focaltech_c6d5_enroll (FpDevice *device)
{
  FpiDeviceFocaltechC6d5 *self = FPI_DEVICE_FOCALTECH_C6D5 (device);

  if (!self->engine_ready)
    {
      fpi_device_enroll_complete (device, NULL,
        fpi_device_error_new_msg (FP_DEVICE_ERROR_GENERAL,
                                  "FocalTech matching engine is not loaded"));
      return;
    }

  self->verifying = FALSE;
  self->enroll_done = 0;
  g_clear_object (&self->print);
  fpi_device_get_enroll_data (device, &self->print);
  ft9366_engine_enroll_begin ();
  start_scan (device);
}

static void
focaltech_c6d5_verify (FpDevice *device)
{
  FpiDeviceFocaltechC6d5 *self = FPI_DEVICE_FOCALTECH_C6D5 (device);

  if (!self->engine_ready)
    {
      fpi_device_verify_complete (device,
        fpi_device_error_new_msg (FP_DEVICE_ERROR_GENERAL,
                                  "FocalTech matching engine is not loaded"));
      return;
    }

  g_clear_object (&self->print);
  fpi_device_get_verify_data (device, &self->print);
  g_clear_pointer (&self->verify_template, g_free);
  self->verify_template_len = 0;
  if (!load_template (self->print,
                      &self->verify_template,
                      &self->verify_template_len))
    {
      fpi_device_verify_complete (device,
        fpi_device_error_new_msg (FP_DEVICE_ERROR_DATA_INVALID,
                                  "Stored FocalTech template is invalid"));
      return;
    }

  self->verifying = TRUE;
  start_scan (device);
}

static void
focaltech_c6d5_cancel (FpDevice *device)
{
  FpiDeviceFocaltechC6d5 *self = FPI_DEVICE_FOCALTECH_C6D5 (device);

  if (self->ssm)
    {
      fpi_ssm_cancel_delayed_state_change (self->ssm);
      fpi_ssm_mark_failed (self->ssm,
        g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CANCELLED,
                             "FocalTech operation cancelled"));
    }
}

static void
fpi_device_focaltech_c6d5_init (FpiDeviceFocaltechC6d5 *self)
{
  self->raw_image = g_malloc (FT_RAW_IMAGE_SIZE);
  self->image = g_malloc (FT_IMAGE_PIXELS);
}

static void
fpi_device_focaltech_c6d5_finalize (GObject *object)
{
  FpiDeviceFocaltechC6d5 *self = FPI_DEVICE_FOCALTECH_C6D5 (object);

  g_clear_pointer (&self->raw_image, g_free);
  g_clear_pointer (&self->image, g_free);
  g_clear_pointer (&self->verify_template, g_free);
  g_clear_object (&self->print);

  G_OBJECT_CLASS (fpi_device_focaltech_c6d5_parent_class)->finalize (object);
}

static void
fpi_device_focaltech_c6d5_class_init (FpiDeviceFocaltechC6d5Class *klass)
{
  FpDeviceClass *dev_class = FP_DEVICE_CLASS (klass);
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->finalize = fpi_device_focaltech_c6d5_finalize;

  dev_class->id = "focaltech_c6d5";
  dev_class->full_name = "Focaltech Fingerprint Sensor";
  dev_class->type = FP_DEVICE_TYPE_USB;
  dev_class->id_table = id_table;
  dev_class->nr_enroll_stages = FT_ENROLL_SAMPLES;
  dev_class->scan_type = FP_SCAN_TYPE_PRESS;
  dev_class->open = focaltech_c6d5_open;
  dev_class->close = focaltech_c6d5_close;
  dev_class->enroll = focaltech_c6d5_enroll;
  dev_class->verify = focaltech_c6d5_verify;
  dev_class->cancel = focaltech_c6d5_cancel;
  dev_class->features = FP_DEVICE_FEATURE_VERIFY;
}
