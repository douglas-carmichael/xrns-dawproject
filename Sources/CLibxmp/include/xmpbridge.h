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
/* FAR mid-song tempo: translate (mode, fine_change, coarse) to speed + bpm using
 * libxmp's own stateful algorithm (the *fine accumulator is read/clamped/updated
 * in place). FAR carries tempo only through effects, with a coarse→bpm table and
 * fine slides, so we replay the state and call this per change. Returns 0 on ok. */
int xmpb_far_tempo(int mode, int fine_change, int coarse, int *fine, int *speed, int *bpm);
/* xmpb_ev_speed: ticks-per-row if this event sets the speed (via any of libxmp's
 * speed effects, in either effect column), else 0. Some formats (notably 669,
 * which hardcodes mod->bpm/spd) carry the real speed only as an effect, and not
 * always in the first column — so detection must scan both. */
int xmpb_ev_speed(const struct xmp_event *e);

const char *xmpb_ins_name(const struct xmp_module *m, int i);
int xmpb_sub_xpo(const struct xmp_module *m, int i);
int xmpb_sub_sid(const struct xmp_module *m, int i);
int xmpb_ins_nna(const struct xmp_module *m, int i); /* New Note Action: 0=Cut 1=Cont 2=Off 3=Fade */

/* Multi-sample / key-mapped instruments (drum kits, layered XM/IT instruments).
 * An instrument has nsm subinstruments; each key (0..120) maps to one of them
 * via map[key].ins, and each subinstrument points to a sample (sid) with its own
 * transpose (xpo). xmpb_smp_name gives a sample's own name. */
int xmpb_ins_nsm(const struct xmp_module *m, int i);              /* subinstrument count */
int xmpb_map_ins(const struct xmp_module *m, int i, int key);    /* subinstrument index for a key, -1 if out of range */
int xmpb_sub_sid_at(const struct xmp_module *m, int i, int sub); /* sample id of a subinstrument, -1 if invalid */
int xmpb_sub_xpo_at(const struct xmp_module *m, int i, int sub); /* transpose of a subinstrument */
int xmpb_sub_vol_at(const struct xmp_module *m, int i, int sub); /* subinstrument (sample) volume 0..64 */
const char *xmpb_smp_name(const struct xmp_module *m, int s);    /* sample name */

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

/* Playback capture for automated verification: drive libxmp's player and read
 * the live mixer state per tick, so the converter's output can be diffed against
 * the reference playback (per-row, per-channel volume and note). */
int xmpb_play_start(xmp_context c);
int xmpb_play_frame(xmp_context c);   /* advance one tick; caches frame info; <0 at end */
int xmpb_fi_pos(void);                /* order position of the cached frame */
int xmpb_fi_pattern(void);            /* current pattern number */
int xmpb_fi_row(void);                /* row within the pattern */
int xmpb_fi_frame(void);              /* tick within the row (0 = row start) */
int xmpb_fi_loop(void);               /* loop count (>0 once the song has looped) */
int xmpb_fi_chvol(int ch);            /* channel mixer volume */
int xmpb_fi_chnote(int ch);           /* channel note, -1 if idle */

#endif
