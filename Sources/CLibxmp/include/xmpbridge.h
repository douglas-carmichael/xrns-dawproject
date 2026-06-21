#ifndef XMPBRIDGE_H
#define XMPBRIDGE_H

#include "xmp.h"

/* Accessors for libxmp's flexible-array-member structures (xxp[]->index[],
 * xxt[]->event[]) and char-array fields, which Swift cannot index directly. */

const char *xmpb_mod_name(const struct xmp_module *m);
const char *xmpb_mod_type(const struct xmp_module *m);
int xmpb_order(const struct xmp_module *m, int i);

int xmpb_pat_rows(const struct xmp_module *m, int p);
int xmpb_pat_track(const struct xmp_module *m, int p, int ch);
int xmpb_trk_rows(const struct xmp_module *m, int t);
const struct xmp_event *xmpb_event(const struct xmp_module *m, int t, int row);

/* Interpret an event's effect columns (keeps libxmp's FX_* constants in C).
 * xmpb_ev_offset: sample-offset parameter (0..255) if this event sets sample
 *   offset (9xx), else -1 — signals a sliced / multi-sound sample.
 * xmpb_ev_tempo: tempo in BPM if this event sets tempo (MOD Fxx >= 0x20, or
 *   S3M/IT Txx), else 0. */
int xmpb_ev_offset(const struct xmp_event *e);
int xmpb_ev_tempo(const struct xmp_event *e);

const char *xmpb_ins_name(const struct xmp_module *m, int i);
int xmpb_sub_xpo(const struct xmp_module *m, int i);
int xmpb_sub_sid(const struct xmp_module *m, int i);
int xmpb_ins_nna(const struct xmp_module *m, int i); /* New Note Action: 0=Cut 1=Cont 2=Off 3=Fade */

int xmpb_smp_len(const struct xmp_module *m, int s);
int xmpb_smp_lps(const struct xmp_module *m, int s);
int xmpb_smp_lpe(const struct xmp_module *m, int s);
int xmpb_smp_flg(const struct xmp_module *m, int s);
const unsigned char *xmpb_smp_data(const struct xmp_module *m, int s);

int xmpb_chn_pan(const struct xmp_module *m, int ch);   /* channel pan 0..255 (128 = centre) */

/* Instrument volume envelope (aei): flags (bit0 = on, bit1 = has sustain),
 * point count, sustain-point index, and per-point time (ticks) / value (0..64). */
int xmpb_env_flg(const struct xmp_module *m, int i);
int xmpb_env_npt(const struct xmp_module *m, int i);
int xmpb_env_sus(const struct xmp_module *m, int i);
int xmpb_env_time(const struct xmp_module *m, int i, int p);
int xmpb_env_val(const struct xmp_module *m, int i, int p);

#endif
