"""DiffSinger 引擎：OpenUtau 式声库目录 → 8 段 ONNX 推理管线。

移植自 zongzi-svs（契约验证草稿）diffsinger/engine.py，张量契约以线上
模型为准。相对原版的扩展：

- render() 支持 ph_dur_override（:phoneme_timing patch 的挂载点：跳过 dur
  预测，直接采用调用方给的逐音素帧数）；
- render() 支持 curves（曲线 channel 的注入点：pitch(MIDI)/breathiness/
  voicing 逐帧值 + 对应 retake 掩码翻 False = 该帧不重预测）。
"""
import os, json
import numpy as np
import onnxruntime as ort
import soundfile as sf
import yaml


def load_json(path):
    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f)


def load_yaml(path):
    with open(path, 'r', encoding='utf-8') as f:
        return yaml.safe_load(f)


REST_PHONEMES = ('SP', 'AP')


def _is_rest_word(phonemes):
    return all(ph in REST_PHONEMES for _lang, ph in phonemes)


def _phoneme_type(types, lang, ph):
    return types.get(f'{lang}/{ph}') or types.get(ph)


def _word_start_index(phonemes, types):
    """词内元音锚点（OpenUtau ProcessWord 的 isStart 移植）：返回开启音符组的
    音素下标。元音开组；CGV 例外（辅音-glide-元音）由 glide 开组；全无元音
    则首音素开组。一词多锚（音节延留）取第一个，其余并入组内（已知限制）。
    """
    is_vowel = [_phoneme_type(types, lang, ph) == 'vowel' for lang, ph in phonemes]
    is_glide = [_phoneme_type(types, lang, ph) == 'glide' for lang, ph in phonemes]
    if not any(is_vowel):
        return 0
    for i, vowel in enumerate(is_vowel):
        if vowel:
            if i >= 2 and is_glide[i - 1] and not is_vowel[i - 2]:
                return i - 1
            return i
    return 0


def _place(words, ph_dur, types, frame_rate):
    """元音锚点对齐（OpenUtau ProcessPart 移植，纯函数，不碰模型）。

    words 含句首 SP 词（dur = padding）。规则：

    - 词内锚点之前的音素（词首辅音）并入**前一组**——吃前一词的尾巴；
    - 锚定组按比例拉伸，精确填满相邻锚点之间（元音 onset = 音符起点）；
    - 句首组不拉伸、从首个锚点**倒推**（preutterance），SP 吸收 slack，
      padding 不足时按比例压进 [0, anchor]。

    返回 (boundaries, aligned_ph_dur, lead_in_frames, total_frames)；
    boundaries 元素 {lang, symbol, start_frame, end_frame, note_index}
    （note_index 按非 rest 词序，rest/SP 为 None）。
    """
    # 词槽时间线（帧，float；句首 SP 槽 = [0, padding)）
    slot_starts = []
    t = 0.0
    for _phonemes, dur_sec, _midi in words:
        slot_starts.append(t)
        t += dur_sec * frame_rate
    total = t

    flat = [(w, lang, ph) for w, (phonemes, _d, _m) in enumerate(words) for lang, ph in phonemes]
    if len(flat) != len(ph_dur):
        raise ValueError(f'ph_dur 长度 {len(ph_dur)} 与音素数 {len(flat)} 不符')

    # 非 rest 词 → note 序号
    note_ordinals = {}
    for w, (phonemes, _d, _m) in enumerate(words):
        if not _is_rest_word(phonemes):
            note_ordinals[w] = len(note_ordinals)

    # 分组：{'anchor': float|None（句首组）, 'idxs': [flat 下标]}
    groups = []
    flat_idx = 0
    for w, (phonemes, dur_sec, _midi) in enumerate(words):
        n = len(phonemes)
        if _is_rest_word(phonemes):
            idxs = list(range(flat_idx, flat_idx + n))
            if groups:
                groups[-1]['idxs'] += idxs
            else:
                groups.append({'anchor': None, 'idxs': idxs})
            flat_idx += n
            continue
        start = _word_start_index(phonemes, types)
        pre = list(range(flat_idx, flat_idx + start))
        post = list(range(flat_idx + start, flat_idx + n))
        if pre:
            if groups:
                groups[-1]['idxs'] += pre
            else:
                groups.append({'anchor': None, 'idxs': pre})
        groups.append({'anchor': slot_starts[w], 'idxs': post})
        flat_idx += n

    # 放置（float 帧）
    positions = [None] * len(flat)
    for gi, group in enumerate(groups):
        idxs, anchor = group['idxs'], group['anchor']
        end = groups[gi + 1]['anchor'] if gi + 1 < len(groups) else total
        if anchor is None:
            # 句首组：摘出 SP（吸收 slack），其余不拉伸倒推
            body = idxs
            sp = None
            if idxs and flat[idxs[0]][2] in REST_PHONEMES:
                sp, body = idxs[0], idxs[1:]
            durs = [float(ph_dur[i]) for i in body]
            start = end - sum(durs)
            if start < 0.0:
                scale = end / sum(durs)
                durs = [d * scale for d in durs]
                start = 0.0
            pos = start
            for i, d in zip(body, durs):
                positions[i] = (pos, pos + d)
                pos += d
            if sp is not None:
                positions[sp] = (0.0, start)
        else:
            durs = [float(ph_dur[i]) for i in idxs]
            s = sum(durs)
            ratio = (end - anchor) / s if s > 0 else 1.0
            pos = anchor
            for i, d in zip(idxs, durs):
                positions[i] = (pos, pos + d * ratio)
                pos += d * ratio

    # 整数化：连续单调（下一 start = 上一 end）
    boundaries = []
    aligned = []
    prev = 0
    for i, (w, lang, ph) in enumerate(flat):
        _s, e = positions[i]
        end_i = max(prev, int(round(e)))
        boundaries.append({
            'lang': lang, 'symbol': ph,
            'start_frame': prev, 'end_frame': end_i,
            'note_index': note_ordinals.get(w),
        })
        aligned.append(end_i - prev)
        prev = end_i

    lead_in_frames = 0
    for group in groups:
        if group['anchor'] is not None:
            lead_in_frames = int(round(group['anchor']))
            break

    return boundaries, aligned, lead_in_frames, prev


class DiffSingerEngine:
    def __init__(self, model_root) -> None:
        self.root = model_root
        self.acoustic_cfg = load_yaml(os.path.join(model_root, 'dsconfig.yaml'))
        self.dur_cfg = load_yaml(os.path.join(model_root, 'dsdur/dsconfig.yaml'))
        self.pitch_cfg = load_yaml(os.path.join(model_root, 'dspitch/dsconfig.yaml'))
        self.var_cfg = load_yaml(os.path.join(model_root, 'dsvariance/dsconfig.yaml'))
        self.vocoder_cfg = load_yaml(os.path.join(model_root, 'dsvocoder/vocoder.yaml'))

        # 音素/语言字典（各模型家族各自一套，同一 words 会被编码 4 次）
        self.dur_phonemes = load_json(os.path.join(model_root, 'dsdur', self.dur_cfg['phonemes']))
        self.dur_langs = load_json(os.path.join(model_root, 'dsdur', self.dur_cfg['languages']))
        self.pitch_phonemes = load_json(os.path.join(model_root, 'dspitch', self.pitch_cfg['phonemes']))
        self.pitch_langs = load_json(os.path.join(model_root, 'dspitch', self.pitch_cfg['languages']))
        self.var_phonemes = load_json(os.path.join(model_root, 'dsvariance', self.var_cfg['phonemes']))
        self.var_langs = load_json(os.path.join(model_root, 'dsvariance', self.var_cfg['languages']))
        self.acoustic_phonemes = load_json(os.path.join(model_root, self.acoustic_cfg['phonemes']))
        self.acoustic_langs = load_json(os.path.join(model_root, self.acoustic_cfg['languages']))

        # ONNX sessions（8 段管线）
        self.sess_dur_ling = self._make_session(os.path.join(model_root, 'dsdur', self.dur_cfg['linguistic']))
        self.sess_dur = self._make_session(os.path.join(model_root, 'dsdur', self.dur_cfg['dur']))
        self.sess_pitch_ling = self._make_session(os.path.join(model_root, 'dspitch', self.pitch_cfg['linguistic']))
        self.sess_pitch = self._make_session(os.path.join(model_root, 'dspitch', self.pitch_cfg['pitch']))
        self.sess_var_ling = self._make_session(os.path.join(model_root, 'dsvariance', self.var_cfg['linguistic']))
        self.sess_var = self._make_session(os.path.join(model_root, 'dsvariance', self.var_cfg['variance']))
        self.sess_acoustic = self._make_session(os.path.join(model_root, self.acoustic_cfg['acoustic']))
        self.sess_vocoder = self._make_session(os.path.join(model_root, 'dsvocoder', self.vocoder_cfg['model']))

        self.sample_rate = self.vocoder_cfg['sample_rate']
        self.hop_size = self.vocoder_cfg['hop_size']
        self.frame_rate = self.sample_rate / self.hop_size

        # 音素类型表（对齐分组用）：dsdur/dsdict*.yaml 的 symbols
        self.symbol_types = self._load_symbol_types()

    def _load_symbol_types(self):
        types = {}
        dsdur_dir = os.path.join(self.root, 'dsdur')
        for fname in sorted(os.listdir(dsdur_dir)):
            if fname.startswith('dsdict') and fname.endswith(('.yaml', '.yml')):
                data = load_yaml(os.path.join(dsdur_dir, fname)) or {}
                for entry in data.get('symbols') or []:
                    types[entry['symbol']] = entry.get('type')
        return types

    def _make_session(self, path):
        return ort.InferenceSession(path, providers=['CPUExecutionProvider'])

    def check(self, words):
        """check: 编码 + dur + pitch 前向（确定性）"""
        ph_dur = self._predict_ph_dur(words)

        # pitch 用 pitch 字典
        tokens_p, langs_p, _, _, _ = self._encode(words, self.pitch_phonemes, self.pitch_langs)
        enc_out_p, _ = self.sess_pitch_ling.run(
            ['encoder_out', 'x_masks'],
            {'tokens': tokens_p, 'languages': langs_p, 'ph_dur': ph_dur}
        )
        total_frames = int(ph_dur.sum())
        note_midi = np.array([[w[2] for w in words for _ in w[0]]], dtype=np.float32)
        # SP/AP 词标 rest（pitch 模型的休止输入）
        note_rest = np.array(
            [[any(ph in REST_PHONEMES for _l, ph in w[0]) for w in words for _ in w[0]]],
            dtype=bool)
        note_dur = ph_dur
        pitch_in = np.zeros((1, total_frames), dtype=np.float32)
        expr = np.ones((1, total_frames), dtype=np.float32)
        retake = np.ones((1, total_frames), dtype=bool)
        steps = np.array(20, dtype=np.int64)

        pitch_pred = self.sess_pitch.run(
            ['pitch_pred'],
            {
                'encoder_out': enc_out_p, 'ph_dur': ph_dur,
                'note_midi': note_midi, 'note_rest': note_rest, 'note_dur': note_dur,
                'pitch': pitch_in, 'expr': expr, 'retake': retake, 'steps': steps
            }
        )[0]

        return {
            'ph_dur': ph_dur[0].tolist(),
            'pitch_pred_midi': pitch_pred[0].tolist(),  # type: ignore
            'total_frames': total_frames,
        }

    def render(self, words, out_path, seed=None, ph_dur_override=None, curves=None, lead_in_sec=None):
        """render: 完整管线 → wav，返回 {path, sample_rate, frames, lead_in_sec}

        lead_in_sec：wav 第 0 帧早于窗口起点的时长（preutterance/SP padding）。
        缺省 = 句首 SP 词的 dur（无则 0.0）；有 ph_dur_override 时调用方必须
        显式传（来自 align 的 lead_in_sec），本函数只透传不发明。
        """

        if seed is not None:
            np.random.seed(seed)

        if lead_in_sec is None:
            lead_in_sec = words[0][1] if words and _is_rest_word(words[0][0]) else 0.0

        curves = curves or {}

        # 1. dur（有 override 就跳过预测——:phoneme_timing patch 的挂载点）
        if ph_dur_override is None:
            ph_dur = self._predict_ph_dur(words)
        else:
            ph_dur = np.array([ph_dur_override], dtype=np.int64)

        # 2. pitch (pitch 字典)
        tokens_p, langs_p, _, _, _ = self._encode(words, self.pitch_phonemes, self.pitch_langs)
        enc_out_p, _ = self.sess_pitch_ling.run(
            ['encoder_out', 'x_masks'],
            {'tokens': tokens_p, 'languages': langs_p, 'ph_dur': ph_dur}
        )
        total_frames = int(ph_dur.sum())
        note_midi = np.array([[w[2] for w in words for _ in w[0]]], dtype=np.float32)
        # SP/AP 词标 rest（pitch 模型的休止输入）
        note_rest = np.array(
            [[any(ph in REST_PHONEMES for _l, ph in w[0]) for w in words for _ in w[0]]],
            dtype=bool)
        note_dur = ph_dur
        steps = np.array(20, dtype=np.int64)

        # 曲线注入（pitch）：用户提供逐帧 MIDI 值，retake 翻 False
        pitch_in = np.zeros((1, total_frames), dtype=np.float32)
        expr = np.ones((1, total_frames), dtype=np.float32)
        retake = np.ones((1, total_frames), dtype=bool)
        if 'pitch' in curves:
            pitch_in = self._curve_array(curves['pitch'], total_frames, 'pitch')
            retake[:] = False

        pitch_pred = self.sess_pitch.run(
            ['pitch_pred'],
            {
                'encoder_out': enc_out_p, 'ph_dur': ph_dur,
                'note_midi': note_midi, 'note_rest': note_rest, 'note_dur': note_dur,
                'pitch': pitch_in, 'expr': expr, 'retake': retake, 'steps': steps
            }
        )[0]
        f0 = self._midi_to_f0(pitch_pred)

        # 3. variance (variance 字典)
        tokens_v, langs_v, _, _, _ = self._encode(words, self.var_phonemes, self.var_langs)
        enc_out_v, _ = self.sess_var_ling.run(
            ['encoder_out', 'x_masks'],
            {'tokens': tokens_v, 'languages': langs_v, 'ph_dur': ph_dur}
        )
        # 曲线注入（breathiness/voicing）：retake[…, 0/1] 对应两路
        breathiness_in = np.zeros((1, total_frames), dtype=np.float32)
        voicing_in = np.zeros((1, total_frames), dtype=np.float32)
        var_retake = np.ones((1, total_frames, 2), dtype=bool)
        if 'breathiness' in curves:
            breathiness_in = self._curve_array(curves['breathiness'], total_frames, 'breathiness')
            var_retake[:, :, 0] = False
        if 'voicing' in curves:
            voicing_in = self._curve_array(curves['voicing'], total_frames, 'voicing')
            var_retake[:, :, 1] = False

        breathiness_pred, voicing_pred = self.sess_var.run(
            ['breathiness_pred', 'voicing_pred'],
            {
                'encoder_out': enc_out_v, 'ph_dur': ph_dur, 'pitch': pitch_pred,
                'breathiness': breathiness_in, 'voicing': voicing_in,
                'retake': var_retake, 'steps': steps
            }
        )

        # 4. acoustic (acoustic 字典)
        tokens_a, langs_a, _, _, _ = self._encode(words, self.acoustic_phonemes, self.acoustic_langs)
        gender = np.zeros((1, total_frames), dtype=np.float32)
        velocity = np.ones((1, total_frames), dtype=np.float32)
        depth = np.array(1.0, dtype=np.float32)
        # 这里是 f0 不是 MIDI
        mel = self.sess_acoustic.run(
            ['mel'],
            {
                'tokens': tokens_a, 'languages': langs_a, 'durations': ph_dur,
                'f0': f0,
                'breathiness': breathiness_pred, 'voicing': voicing_pred,
                'gender': gender, 'velocity': velocity, 'depth': depth, 'steps': steps
            }
        )[0]

        # 5. vocoder
        waveform = self.sess_vocoder.run(
            ['waveform'],
            {'mel': mel, 'f0': f0}
        )[0]

        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        sf.write(out_path, waveform[0], self.sample_rate)  # type: ignore

        return {'path': out_path, 'sample_rate': self.sample_rate,
                'frames': total_frames, 'lead_in_sec': lead_in_sec}

    def align(self, words):
        """对齐：predict（编码 + dur，无扩散，廉价）+ 元音锚点放置。

        返回 {phonemes: [{lang, symbol, start_frame, end_frame, note_index}],
              ph_dur: 对齐后逐音素帧数, lead_in_sec, total_frames}。
        返回的 ph_dur 可经 render 的 ph_dur_override 回放——对齐边界即
        渲染真相。
        """
        ph_dur_float = self._dur_frames_float(words)
        boundaries, aligned, lead_in_frames, total_frames = _place(
            words, list(ph_dur_float), self.symbol_types, self.frame_rate
        )
        return {
            'phonemes': boundaries,
            'ph_dur': aligned,
            'lead_in_sec': lead_in_frames / self.frame_rate,
            'total_frames': total_frames,
        }

    def _dur_frames_float(self, words):
        """dur 两段（语言学编码 + 时长预测），返回逐音素帧数 float[1, Nph]"""
        tokens_d, langs_d, word_div, word_dur, ph_midi = self._encode(words, self.dur_phonemes, self.dur_langs)
        enc_out, x_masks = self.sess_dur_ling.run(
            ['encoder_out', 'x_masks'],
            {'tokens': tokens_d, 'languages': langs_d, 'word_div': word_div, 'word_dur': word_dur}
        )
        ph_dur_pred = self.sess_dur.run(
            ['ph_dur_pred'],
            {'encoder_out': enc_out, 'x_masks': x_masks, 'ph_midi': ph_midi}
        )[0]
        return ph_dur_pred[0]

    def _predict_ph_dur(self, words):
        """round 后的逐音素帧数 int64[1, Nph]（check/render 默认路径用）"""
        return np.round(self._dur_frames_float(words)).astype(np.int64)[None, :]

    def _curve_array(self, values, total_frames, name):
        arr = np.array([values], dtype=np.float32)
        if arr.shape[1] != total_frames:
            raise ValueError(f'curve {name}: 期望 {total_frames} 帧，实得 {arr.shape[1]}')
        return arr

    def _encode(self, words: list, phoneme_dict: dict, lang_dict: dict):
        """把 [[phonemes, dur_sec, midi], ...] 编码成模型输入（phonemes = [[lang, ph], ...]）"""

        all_langs, all_toks, all_midis = [], [], []
        word_div, word_dur = [], []
        for phonemes, dur_sec, midi in words:
            ph_count = len(phonemes)
            word_div.append(ph_count)
            word_dur.append(int(round(dur_sec * self.sample_rate / self.hop_size)))
            for lang, ph in phonemes:
                all_langs.append(lang_dict[lang])
                # SP/AP 在字典里是无 lang 前缀的全局 token
                key = f'{lang}/{ph}'
                all_toks.append(phoneme_dict[key] if key in phoneme_dict else phoneme_dict[ph])
                all_midis.append(midi)

        return (
            np.array([all_toks], dtype=np.int64),
            np.array([all_langs], dtype=np.int64),
            np.array([word_div], dtype=np.int64),
            np.array([word_dur], dtype=np.int64),
            np.array([all_midis], dtype=np.int64),
        )

    def _midi_to_f0(self, midi):
        midi = np.asarray(midi)
        f0 = 440.0 * np.power(2.0, (midi - 69.0) / 12.0)
        f0[midi < 0] = 0.0
        return f0
