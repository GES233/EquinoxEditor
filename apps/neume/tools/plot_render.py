# Plot a neume debug.json dump (`Editor.export_debug/2`): piano-roll with the
# predicted pitch curve overlaid, plus a phoneme/waveform timing panel on a
# shared seconds axis. Vendored+adapted from coconut_intervention's
# examples/plot_render.py — consumes the "neume-debug/1" schema.
#
#     python tools/plot_render.py <debug.json> [-o out.png|out.svg] [--wav render.wav]
#                                [--width-per-sec 0.6]
#                                [--start 1920] [--end 5760]
#                                [--start-beat 4] [--end-beat 12]
#                                [--start-sec 2.0] [--end-sec 6.5]
#                                [--env-density 5000]
#
# 输出格式由 -o 扩展名决定（png/svg/pdf 等 matplotlib 原生格式）；省略 -o
# 时默认 <debug>.png。zoom 范围可用 ticks/beats/seconds 三种单位；省略时
# 若 meta.span 存在则缩放到 span，否则全曲。tick↔sec 换算用 meta.tempos +
# meta.tpqn，变速处理正确。

import argparse
import json
import wave
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import numpy as np

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "sans-serif"]
plt.rcParams["axes.unicode_minus"] = False

# ── tick / beat / sec conversion (multi-tempo, array-safe) ──────────

def tick_to_sec(tick, tempos: list[dict], tpqn: int, total_sec: float):
    tick = np.asarray(tick, dtype=np.float64)
    scalar = tick.ndim == 0
    tick = np.atleast_1d(tick)

    end_tick = _sec_to_tick_scalar(total_sec, tempos, tpqn)

    # 首个 tempo 之前按首段速度线性外推，供歌曲 0 点前的 lead-in/预发音使用。
    first_tick = float(tempos[0]["tick"])
    first_bpm = float(tempos[0]["bpm"])
    sec = np.where(
        tick < first_tick,
        (tick - first_tick) / tpqn * 60.0 / first_bpm,
        0.0,
    )
    for i, entry in enumerate(tempos):
        seg_start = float(entry["tick"])
        seg_bpm   = float(entry["bpm"])
        seg_end   = float(tempos[i + 1]["tick"]) if i + 1 < len(tempos) else end_tick

        hi = np.minimum(tick, seg_end)
        sec += np.maximum(hi - seg_start, 0.0) / tpqn * 60.0 / seg_bpm

    return float(sec[0]) if scalar else sec


def sec_to_tick(sec, tempos: list[dict], tpqn: int, total_sec: float):
    """seconds → tick.  Scalar or ndarray safe.
    Last segment ends at *total_sec*, not infinity."""
    sec = np.asarray(sec, dtype=np.float64)
    scalar = sec.ndim == 0
    sec = np.minimum(np.atleast_1d(sec), total_sec)

    bound = [0.0]
    for i in range(len(tempos) - 1):
        dt = (tempos[i + 1]["tick"] - tempos[i]["tick"]) / tpqn * 60.0 / tempos[i]["bpm"]
        bound.append(bound[-1] + dt)
    bound.append(total_sec)

    # 负秒数同样沿首个 tempo 向前外推，使顶部 beat 轴覆盖预发音。
    first_tick = float(tempos[0]["tick"])
    first_bpm = float(tempos[0]["bpm"])
    result = np.where(
        sec < 0.0,
        first_tick + sec * first_bpm / 60.0 * tpqn,
        0.0,
    )
    for i, entry in enumerate(tempos):
        seg_tick = float(entry["tick"])
        seg_bpm  = float(entry["bpm"])
        if i + 1 < len(tempos):
            mask = (sec >= bound[i]) & (sec < bound[i + 1])
        else:
            mask = (sec >= bound[i]) & (sec <= bound[i + 1])
        result[mask] = seg_tick + (sec[mask] - bound[i]) * seg_bpm / 60.0 * tpqn

    return float(result[0]) if scalar else result


def _sec_to_tick_scalar(sec: float, tempos: list[dict], tpqn: int) -> float:
    """Internal scalar helper (avoids recursion with the array version)."""
    elapsed = 0.0
    for i, entry in enumerate(tempos):
        seg_tick = float(entry["tick"])
        seg_bpm  = float(entry["bpm"])
        if i + 1 < len(tempos):
            seg_end_tick = float(tempos[i + 1]["tick"])
            seg_dur = (seg_end_tick - seg_tick) / tpqn * 60.0 / seg_bpm
            if sec < elapsed + seg_dur:
                return seg_tick + (sec - elapsed) * seg_bpm / 60.0 * tpqn
            elapsed += seg_dur
        else:
            return seg_tick + (sec - elapsed) * seg_bpm / 60.0 * tpqn
    return 0.0


def beat_to_tick(beat, tpqn: int):
    return np.asarray(beat, dtype=np.float64) * tpqn

def tick_to_beat(tick, tpqn: int):
    return np.asarray(tick, dtype=np.float64) / tpqn


# ── WAV envelope ───────────────────────────────────────────────────────

def load_wave_envelope(wav_path: Path, n_bins: int):
    """Min/max envelope, vectorised. Returns (t, lo, hi)."""
    with wave.open(str(wav_path), "rb") as w:
        sr = w.getframerate()
        raw = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
        if w.getnchannels() > 1:
            raw = raw.reshape(-1, w.getnchannels()).mean(axis=1)

    samples = raw.astype(np.float64) / (32768.0 / 2.5)
    n_bins  = max(1, min(n_bins, len(samples)))

    bin_size = len(samples) // n_bins
    usable   = bin_size * n_bins
    blocks   = samples[:usable].reshape(n_bins, bin_size)

    lo = blocks.min(axis=1)
    hi = blocks.max(axis=1)
    t  = np.arange(n_bins) * bin_size / sr

    return t, lo, hi


# ── main ───────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("debug_json", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=None,
                    help="输出路径；格式由扩展名决定（png/svg/pdf…），默认 <debug>.png")
    ap.add_argument("--wav", type=Path, default=None,
                    help="render WAV to overlay on the timing panel")
    ap.add_argument("--width-per-sec", type=float, default=0.6,
                    help="figure inches per second of visible audio")
    ap.add_argument("--env-density", type=int, default=200,
                help="envelope columns per visible second (default 200)")

    g = ap.add_argument_group("zoom range (pick at most one unit per edge)")
    g.add_argument("--start",      type=float, default=None, metavar="TICK")
    g.add_argument("--end",        type=float, default=None, metavar="TICK")
    g.add_argument("--start-beat", type=float, default=None, metavar="BEAT")
    g.add_argument("--end-beat",   type=float, default=None, metavar="BEAT")
    g.add_argument("--start-sec",  type=float, default=None, metavar="SEC")
    g.add_argument("--end-sec",    type=float, default=None, metavar="SEC")

    args = ap.parse_args()

    json_path = args.debug_json
    out_path = args.out or json_path.with_suffix(".png")

    with open(json_path, encoding="utf-8") as fh:
        data = json.load(fh)

    meta    = data["meta"]
    tempos  = meta["tempos"]          # [{tick, bpm}, ...]
    tpqn    = meta["tpqn"]            # 480
    # mock 导出没有声库采样参数，统一用 frame_rate。
    fps     = meta.get("frame_rate") or meta["sample_rate"] / meta["hop_size"]
    total_sec = meta["total_sec"]
    # 帧轴原点：第 0 个数组元素对应的歌曲绝对帧（head padding 可为负）。
    f_origin  = meta.get("frames_origin_frame", 0)
    t       = (f_origin + np.arange(meta["total_frames"])) / fps

    # ── resolve visible window → seconds ─────────────────────────────
    # 未显式给 zoom 时，若导出带 span 裁剪则默认缩放到 span。
    span = meta.get("span")
    # 未裁剪的导出保留歌曲 0 点前的 lead-in / 预发音；显式 span 则严格按
    # 用户请求的歌曲区间显示，不把窗外预发音偷偷扩进来。
    frame_lo = f_origin / fps
    frame_hi = (f_origin + meta["total_frames"]) / fps
    span_lo = float(span["start_sec"]) if span else min(0.0, frame_lo)
    span_hi = float(span["end_sec"]) if span else frame_hi

    def resolve(val_tick, val_beat, val_sec, default):
        if val_tick is not None:
            return tick_to_sec(val_tick, tempos, tpqn, total_sec)
        if val_beat is not None:
            return tick_to_sec(beat_to_tick(val_beat, tpqn), tempos, tpqn, total_sec)
        if val_sec is not None:
            return val_sec
        return default
    t_lo = resolve(args.start, args.start_beat, args.start_sec, span_lo)
    t_hi = resolve(args.end,   args.end_beat,   args.end_sec,   span_hi)
    t_lo = max(t_lo, frame_lo)
    t_hi = min(t_hi, frame_hi)
    if t_hi <= t_lo:
        ap.error(f"empty window: {t_lo:.4f}s >= {t_hi:.4f}s")
    visible_sec = t_hi - t_lo

    # ── data prep ────────────────────────────────────────────────────
    f0   = np.array([np.nan if v is None else v for v in data["frames"]["f0_hz"]])
    midi = np.array([np.nan if v is None else v for v in data["frames"]["midi"]])
    midi = np.where(midi < 1, np.nan, midi)
    f0   = np.where(f0 < 1, np.nan, f0)

    raw_midi = None
    frames_raw = data.get("frames_raw") or {}
    if frames_raw.get("midi"):
        raw_midi = np.array([np.nan if v is None else v for v in frames_raw["midi"]])
        raw_midi = np.where(raw_midi < 1, np.nan, raw_midi)
        if not np.isfinite(raw_midi).any():
            raw_midi = None
    phonemes_raw = data.get("phonemes_raw") or []

    # ── figure ───────────────────────────────────────────────────────
    width = max(8, visible_sec * args.width_per_sec)
    fig, (ax_score, ax_ph) = plt.subplots(
        2, 1, figsize=(width, 9), sharex=True,
        gridspec_kw={"height_ratios": [3, 2]},
    )

    # ① piano-roll + pitch curve
    sung  = [n for n in data["notes"] if not n["rest"]]
    rests = [n for n in data["notes"] if n["rest"]]

    for n in rests:
        ax_score.axvspan(n["start_sec"], n["end_sec"], color="0.92", zorder=0)

    midis = [n["midi"] for n in sung if n["midi"] is not None]
    curves = data.get("curves") or []
    curve_vals = [p["value"] for c in curves for p in c.get("points", [])]
    vals = midis + curve_vals
    y_lo, y_hi = (min(vals) - 2, max(vals) + 2) if vals else (48, 72)

    for n in sung:
        if n["midi"] is None:
            continue
        ax_score.add_patch(plt.Rectangle(  # type: ignore
            (n["start_sec"], n["midi"] - 0.4),
            n["end_sec"] - n["start_sec"], 0.8,
            facecolor="#9ecae1", edgecolor="#3182bd", zorder=2,
        ))
        if n["lyric"]:
            ax_score.text(
                (n["start_sec"] + n["end_sec"]) / 2, n["midi"],
                n["lyric"], ha="center", va="center", fontsize=8, zorder=4,
            )

    # Pin 控制点（pitch pin 的「锚定音符 MIDI + cents/100」投影）。
    seen_labels = set()
    for curve in curves:
        pts = curve.get("points") or []
        if pts:
            xs = tick_to_sec(np.array([p["tick"] for p in pts], dtype=float),
                             tempos, tpqn, total_sec)
            ys = np.array([p["value"] for p in pts], dtype=float)
            ax_score.plot(xs, ys, lw=0.7, ls=":", color="#74c476", zorder=2.7)
            lbl = "pin control points" if "cps" not in seen_labels else None
            seen_labels.add("cps")
            ax_score.plot(xs, ys, "o", ms=7, mfc="white", mec="#238b45",
                          mew=1.6, color="#238b45", zorder=4.5, label=lbl)

    # meta.patches：pin 铆钉点标记（解析出的 tick 区间 → 秒）。
    for patch in meta.get("patches") or []:
        span_ticks = patch.get("span_ticks")
        if not span_ticks:
            continue
        s = tick_to_sec(span_ticks[0], tempos, tpqn, total_sec)
        e = tick_to_sec(span_ticks[1], tempos, tpqn, total_sec)
        for x in (s, e):
            ax_score.axvline(x, color="#9467bd", lw=0.8, ls="--", zorder=2.2)
        lbl = f"pin:{patch['channel']}"
        if lbl not in seen_labels:
            seen_labels.add(lbl)
            ax_score.plot([], [], color="#9467bd", ls="--", lw=0.8,
                          label="pin anchors")
        ax_score.text((s + e) / 2, y_hi - 0.5, patch["channel"],
                      ha="center", va="top", fontsize=7, color="#9467bd",
                      zorder=4)

    if raw_midi is not None:
        ax_score.plot(t, raw_midi, lw=0.8, color="#636363", ls="--",
                      zorder=2.5, label="raw pitch (pins off)")
    ax_score.plot(t, midi, lw=1.0, color="#e6550d", zorder=3,
                  label="rendered pitch")
    ax_score.set_ylim(y_lo, y_hi)
    ax_score.set_ylabel("MIDI")
    ax_score.set_yticks(range(int(y_lo) + 1, int(y_hi)))
    ax_score.grid(axis="y", alpha=0.3)
    ax_score.legend(loc="upper right")
    n_pins = len(meta.get("patches") or [])
    ax_score.set_title(
        f"{json_path.stem} — score + pitch  "
        f"({len(sung)} notes"
        + (f", {n_pins} pin{'s' if n_pins > 1 else ''}" if n_pins else "")
        + f", {visible_sec:.2f}s shown)"
    )

    # ② phoneme / waveform panel
    if args.wav:
        n_bins = int(visible_sec * args.env_density)
        t_w, lo, hi = load_wave_envelope(args.wav, n_bins)
        # wav 轴 t=0 ↔ 歌曲 −lead_in（制品音频轴约定）；平移回歌曲轴。
        t_w = t_w - float(meta.get("lead_in_sec") or 0.0)
        amp = 0.5 if phonemes_raw else 1.0
        ax_ph.fill_between(t_w, lo * amp, hi * amp, color="#756bb1",
                           alpha=0.35, lw=0, zorder=0)
        if phonemes_raw:
            ax_ph.axhline(0, color="0.85", lw=0.5, zorder=0.5)

    def draw_lane(segments, y0, h, colors, hatch=None, changed=None):
        for i, p in enumerate(segments):
            if changed is None:
                face = colors[i % 2]
            else:
                face = "#74c476" if changed[i] else "#d9e8f5"
            ax_ph.broken_barh(
                [(p["start_sec"], p["end_sec"] - p["start_sec"])],
                (y0, h),
                facecolors=face, edgecolors="white",
                linewidths=0.3, hatch=hatch, zorder=2,
            )
            vis_lo = max(p["start_sec"], t_lo)
            vis_hi = min(p["end_sec"], t_hi)
            if vis_hi - vis_lo > visible_sec / (width * 10):
                ax_ph.text(
                    (vis_lo + vis_hi) / 2, y0 + h / 2,
                    p["label"], ha="center", va="center",
                    fontsize=7, rotation=90, zorder=3, clip_on=True,
                )

    def changed_mask(override, raw, tol=1e-3):
        return [
            i >= len(raw)
            or abs(p["start_sec"] - raw[i]["start_sec"]) > tol
            or abs(p["end_sec"] - raw[i]["end_sec"]) > tol
            for i, p in enumerate(override)
        ]

    if phonemes_raw:
        draw_lane(phonemes_raw, -0.95, 0.3, ["#d9d9d9", "#f0f0f0"], hatch="//")
        draw_lane(data["phonemes"], 0.62, 0.33, ["#a1d99b", "#c7e9c0"],
                  changed=changed_mask(data["phonemes"], phonemes_raw))
        ticks, labels = [-0.8, 0.785], ["raw", "override"]
        if args.wav:
            ticks.insert(1, 0.0)
            labels.insert(1, "waveform")
        ax_ph.set_yticks(ticks)
        ax_ph.set_yticklabels(labels, fontsize=9)
    else:
        draw_lane(data["phonemes"], 0.55, 0.35, ["#a1d99b", "#c7e9c0"])
        ax_ph.set_yticks([])

    ax_ph.set_ylim(-1.0, 1.0)
    ax_ph.set_xlabel("seconds")
    ax_ph.set_title(
        f"phonemes ({len(data['phonemes'])})"
        + (" + waveform" if args.wav else "")
        + (" — raw vs override" if phonemes_raw else "")
    )

    # ── apply zoom window ────────────────────────────────────────────
    ax_ph.set_xlim(t_lo, t_hi)

    def _s2b(s):
        return tick_to_beat(sec_to_tick(s, tempos, tpqn, total_sec), tpqn)
    def _b2s(b):
        return tick_to_sec(beat_to_tick(b, tpqn), tempos, tpqn, total_sec)
    ax_beat = ax_score.secondary_xaxis("top", functions=(_s2b, _b2s))
    ax_beat.set_xlabel("beat")
    b_lo = int(np.ceil(float(_s2b(max(t_lo, 0.0)))))
    b_hi = int(np.floor(float(_s2b(t_hi))))
    if 0 < b_hi - b_lo <= 64:
        ax_beat.set_xticks(range(b_lo, b_hi + 1))
    ax_ph.set_xlabel("seconds")

    fig.subplots_adjust(left=0.115, right=0.98, top=0.84, bottom=0.08, hspace=0.25)
    fig.savefig(out_path, dpi=110)

    lo_tk = sec_to_tick(t_lo, tempos, tpqn, total_sec)
    hi_tk = sec_to_tick(t_hi, tempos, tpqn, total_sec)
    print(f"wrote {out_path}")
    print(f"  tick {lo_tk:.0f}–{hi_tk:.0f}  beat {_s2b(t_lo):.2f}–{_s2b(t_hi):.2f}"
          f"  {t_lo:.3f}s–{t_hi:.3f}s ({visible_sec:.3f}s)")


if __name__ == "__main__":
    main()
