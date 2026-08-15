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
        note_rest = np.zeros_like(note_midi, dtype=bool)
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

    def render(self, words, out_path, seed=None, ph_dur_override=None, curves=None):
        """render: 完整管线 → wav，返回 {path, sample_rate, frames}"""

        if seed is not None:
            np.random.seed(seed)

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
        note_rest = np.zeros_like(note_midi, dtype=bool)
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

        return {'path': out_path, 'sample_rate': self.sample_rate, 'frames': total_frames}

    def _predict_ph_dur(self, words):
        """dur 两段（语言学编码 + 时长预测），返回逐音素帧数 int64[1, Nph]"""
        tokens_d, langs_d, word_div, word_dur, ph_midi = self._encode(words, self.dur_phonemes, self.dur_langs)
        enc_out, x_masks = self.sess_dur_ling.run(
            ['encoder_out', 'x_masks'],
            {'tokens': tokens_d, 'languages': langs_d, 'word_div': word_div, 'word_dur': word_dur}
        )
        ph_dur_pred = self.sess_dur.run(
            ['ph_dur_pred'],
            {'encoder_out': enc_out, 'x_masks': x_masks, 'ph_midi': ph_midi}
        )[0]
        return np.round(ph_dur_pred).astype(np.int64)  # type: ignore

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
                all_toks.append(phoneme_dict[f'{lang}/{ph}'])
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
