#ifndef COPUS_SHIM_H
#define COPUS_SHIM_H
#include <opus.h>

/* opus_*_ctl are variadic and therefore not callable from Swift; thin wrappers. */
int es_opus_encoder_set_bitrate(OpusEncoder *enc, int bitrate);
int es_opus_encoder_set_inband_fec(OpusEncoder *enc, int on);
int es_opus_encoder_set_packet_loss_perc(OpusEncoder *enc, int percent);
int es_opus_encoder_set_complexity(OpusEncoder *enc, int complexity);
int es_opus_encoder_set_signal_music(OpusEncoder *enc);
int es_opus_encoder_set_vbr(OpusEncoder *enc, int on);
int es_opus_encoder_lookahead(OpusEncoder *enc);
int es_opus_decoder_reset(OpusDecoder *dec);

#endif
