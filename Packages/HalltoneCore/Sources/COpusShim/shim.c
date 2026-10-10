#include "COpusShim.h"

int es_opus_encoder_set_bitrate(OpusEncoder *enc, int bitrate) { return opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate)); }
int es_opus_encoder_set_inband_fec(OpusEncoder *enc, int on) { return opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(on)); }
int es_opus_encoder_set_packet_loss_perc(OpusEncoder *enc, int percent) { return opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(percent)); }
int es_opus_encoder_set_complexity(OpusEncoder *enc, int complexity) { return opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(complexity)); }
int es_opus_encoder_set_signal_music(OpusEncoder *enc) { return opus_encoder_ctl(enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC)); }
int es_opus_encoder_set_vbr(OpusEncoder *enc, int on) { return opus_encoder_ctl(enc, OPUS_SET_VBR(on)); }
int es_opus_encoder_lookahead(OpusEncoder *enc) { opus_int32 v = 0; opus_encoder_ctl(enc, OPUS_GET_LOOKAHEAD(&v)); return v; }
int es_opus_decoder_reset(OpusDecoder *dec) { return opus_decoder_ctl(dec, OPUS_RESET_STATE); }
