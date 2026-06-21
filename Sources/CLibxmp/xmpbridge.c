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

int xmpb_ev_tempo(const struct xmp_event *e) {
	/* MOD Fxx with param >= 0x20 is tempo (BPM); below that it is speed
	 * (ticks/row). S3M/IT Txx carries the BPM directly. */
	if ((e->fxt == FX_SPEED || e->fxt == FX_S3M_BPM || e->fxt == FX_IT_BPM) && e->fxp >= 0x20) return e->fxp;
	if ((e->f2t == FX_SPEED || e->f2t == FX_S3M_BPM || e->f2t == FX_IT_BPM) && e->f2p >= 0x20) return e->f2p;
	return 0;
}
