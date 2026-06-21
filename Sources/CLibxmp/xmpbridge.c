#include "xmpbridge.h"
#include "effects.h"

const char *xmpb_mod_name(const struct xmp_module *m) { return m->name; }
const char *xmpb_mod_type(const struct xmp_module *m) { return m->type; }
int xmpb_order(const struct xmp_module *m, int i) { return m->xxo[i]; }

int xmpb_pat_rows(const struct xmp_module *m, int p) { return m->xxp[p]->rows; }
int xmpb_pat_track(const struct xmp_module *m, int p, int ch) { return m->xxp[p]->index[ch]; }
int xmpb_trk_rows(const struct xmp_module *m, int t) { return m->xxt[t]->rows; }
const struct xmp_event *xmpb_event(const struct xmp_module *m, int t, int row) { return &m->xxt[t]->event[row]; }

const char *xmpb_ins_name(const struct xmp_module *m, int i) { return m->xxi[i].name; }
int xmpb_sub_xpo(const struct xmp_module *m, int i) { return m->xxi[i].nsm > 0 ? m->xxi[i].sub[0].xpo : 0; }
int xmpb_sub_sid(const struct xmp_module *m, int i) { return m->xxi[i].nsm > 0 ? m->xxi[i].sub[0].sid : -1; }
int xmpb_ins_nna(const struct xmp_module *m, int i) { return m->xxi[i].nsm > 0 ? m->xxi[i].sub[0].nna : 0; }

int xmpb_ins_nsm(const struct xmp_module *m, int i) { return m->xxi[i].nsm; }
int xmpb_map_ins(const struct xmp_module *m, int i, int key) {
	if (key < 0 || key >= XMP_MAX_KEYS) return -1;
	return m->xxi[i].map[key].ins;
}
int xmpb_sub_sid_at(const struct xmp_module *m, int i, int sub) {
	return (sub >= 0 && sub < m->xxi[i].nsm) ? m->xxi[i].sub[sub].sid : -1;
}
int xmpb_sub_xpo_at(const struct xmp_module *m, int i, int sub) {
	return (sub >= 0 && sub < m->xxi[i].nsm) ? m->xxi[i].sub[sub].xpo : 0;
}
int xmpb_sub_vol_at(const struct xmp_module *m, int i, int sub) {
	return (sub >= 0 && sub < m->xxi[i].nsm) ? m->xxi[i].sub[sub].vol : 64;
}
int xmpb_sub_fin_at(const struct xmp_module *m, int i, int sub) {
	return (sub >= 0 && sub < m->xxi[i].nsm) ? m->xxi[i].sub[sub].fin : 0;
}
const char *xmpb_smp_name(const struct xmp_module *m, int s) { return m->xxs[s].name; }

int xmpb_smp_len(const struct xmp_module *m, int s) { return m->xxs[s].len; }
int xmpb_smp_lps(const struct xmp_module *m, int s) { return m->xxs[s].lps; }
int xmpb_smp_lpe(const struct xmp_module *m, int s) { return m->xxs[s].lpe; }
int xmpb_smp_flg(const struct xmp_module *m, int s) { return m->xxs[s].flg; }
const unsigned char *xmpb_smp_data(const struct xmp_module *m, int s) { return m->xxs[s].data; }
int xmpb_chn_pan(const struct xmp_module *m, int ch) { return m->xxc[ch].pan; }

int xmpb_env_flg(const struct xmp_module *m, int i) { return m->xxi[i].aei.flg; }
int xmpb_env_npt(const struct xmp_module *m, int i) { return m->xxi[i].aei.npt; }
int xmpb_env_sus(const struct xmp_module *m, int i) { return m->xxi[i].aei.sus; }
int xmpb_env_time(const struct xmp_module *m, int i, int p) { return m->xxi[i].aei.data[p * 2]; }
int xmpb_env_val(const struct xmp_module *m, int i, int p) { return m->xxi[i].aei.data[p * 2 + 1]; }

int xmpb_ev_offset(const struct xmp_event *e) {
	if (e->fxt == FX_OFFSET) return e->fxp;
	if (e->f2t == FX_OFFSET) return e->f2p;
	return -1;
}

static int tempo_of(int t, int p) {
	/* MOD Fxx >= 0x20 is tempo (BPM); below that it is speed. S3M/IT Txx is the
	 * BPM directly. ULT FX_ULT_TEMPO splits at 0x30: 30-ff is BPM (CIA). */
	if ((t == FX_SPEED || t == FX_S3M_BPM || t == FX_IT_BPM) && p >= 0x20) return p;
	if (t == FX_ULT_TEMPO && p >= 0x30) return p;
	return 0;
}

int xmpb_ev_tempo(const struct xmp_event *e) {
	int t = tempo_of(e->fxt, e->fxp);
	return t ? t : tempo_of(e->f2t, e->f2p);
}

static int speed_of(int t, int p) {
	/* FX_SPEED is speed only below 0x20 (>= is tempo); the *_SPEED variants
	 * (FX_SPEED_CP = 669, FX_ICE_SPEED, FX_S3M_SPEED) are always speed. ULT
	 * FX_ULT_TEMPO is speed for 01-2f (BPM at 30+, handled by tempo_of). */
	if (t == FX_SPEED && p >= 1 && p < 0x20) return p;
	if ((t == FX_SPEED_CP || t == FX_ICE_SPEED || t == FX_S3M_SPEED) && p >= 1) return p;
	if (t == FX_ULT_TEMPO && p >= 1 && p < 0x30) return p;
	return 0;
}

int xmpb_ev_speed(const struct xmp_event *e) {
	int s = speed_of(e->fxt, e->fxp);
	if (s) return s;
	return speed_of(e->f2t, e->f2p);
}

/* Defined in far_extras.c (compiled into this library). */
extern int libxmp_far_translate_tempo(int mode, int fine_change, int coarse,
                                       int *fine, int *_speed, int *_bpm);
int xmpb_far_tempo(int mode, int fine_change, int coarse, int *fine, int *speed, int *bpm) {
	return libxmp_far_translate_tempo(mode, fine_change, coarse, fine, speed, bpm);
}

/* --- Playback capture for automated verification --- */
static struct xmp_frame_info g_fi;
int xmpb_play_start(xmp_context c) { return xmp_start_player(c, 44100, 0); }
int xmpb_play_frame(xmp_context c) { int r = xmp_play_frame(c); xmp_get_frame_info(c, &g_fi); return r; }
int xmpb_set_position(xmp_context c, int pos) { return xmp_set_position(c, pos); }
int xmpb_ctx_order_count(xmp_context c) {
	struct xmp_module_info mi; xmp_get_module_info(c, &mi);
	return mi.mod ? mi.mod->len : 0;
}
int xmpb_ctx_order(xmp_context c, int i) {
	struct xmp_module_info mi; xmp_get_module_info(c, &mi);
	return (mi.mod && i >= 0 && i < mi.mod->len) ? mi.mod->xxo[i] : -1;
}
int xmpb_fi_pos(void)   { return g_fi.pos; }
int xmpb_fi_pattern(void) { return g_fi.pattern; }
int xmpb_fi_row(void)   { return g_fi.row; }
int xmpb_fi_frame(void) { return g_fi.frame; }
int xmpb_fi_loop(void)  { return g_fi.loop_count; }
int xmpb_fi_chvol(int ch)  { return (ch >= 0 && ch < XMP_MAX_CHANNELS) ? g_fi.channel_info[ch].volume : 0; }
int xmpb_fi_chnote(int ch) { return (ch >= 0 && ch < XMP_MAX_CHANNELS) ? (int)g_fi.channel_info[ch].note : -1; }
