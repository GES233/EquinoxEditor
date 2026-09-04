"""Neume DiffSinger 常驻推理 worker（NDJSON over stdio）。

启动参数：worker.py <OpenUtau 声库目录>。stdout 只发送协议消息，诊断输出
必须写入 stderr。模型输入按实际 ONNX 端口过滤，因此同一实现可覆盖无
speaker embedding 的旧模型和带 256 维 embedding 的 variance 模型。
"""

import json
import os
import sys

import numpy as np
import onnxruntime as ort
import soundfile as sf
import yaml

from alignment import REST_PHONEMES, align_phonemes, expand_groups, note_phonemes, word_parts

try:
    from pypinyin import Style, pinyin
except ImportError:
    Style, pinyin = None, None


DEFAULT_GLOBALS = {
    "speaker": "Normal",
    "gender": 0.0,
    "velocity": 1.0,
    "depth": 0.6,
    "steps": 20,
    # 全局表现旋钮：variance 预测曲线的乘性系数，1.0 中立（OpenUtau 的
    # 100% 心智）。会话态，直接进 render，不是逐帧曲线干预。
    "energy": 1.0,
    "breathiness": 1.0,
    "voicing": 1.0,
}


def load_json(path):
    with open(path, "r", encoding="utf-8") as file:
        return json.load(file)


def load_yaml(path):
    loader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
    with open(path, "r", encoding="utf-8") as file:
        return yaml.load(file, Loader=loader)


class DiffSingerEngine:
    def __init__(self, root):
        self.root = os.path.abspath(root)
        self.acoustic_cfg = load_yaml(os.path.join(root, "dsconfig.yaml"))
        self.duration_cfg = load_yaml(os.path.join(root, "dsdur", "dsconfig.yaml"))
        self.pitch_cfg = load_yaml(os.path.join(root, "dspitch", "dsconfig.yaml"))
        self.variance_cfg = load_yaml(os.path.join(root, "dsvariance", "dsconfig.yaml"))
        self.vocoder_cfg = load_yaml(os.path.join(root, "dsvocoder", "vocoder.yaml"))

        self.sample_rate = int(self.vocoder_cfg["sample_rate"])
        self.hop_size = int(self.vocoder_cfg["hop_size"])
        self.frame_rate = self.sample_rate / self.hop_size

        self.vocabularies = {
            "duration": self._vocabulary(os.path.join(root, "dsdur"), self.duration_cfg),
            "pitch": self._vocabulary(os.path.join(root, "dspitch"), self.pitch_cfg),
            "variance": self._vocabulary(os.path.join(root, "dsvariance"), self.variance_cfg),
            "acoustic": self._vocabulary(root, self.acoustic_cfg),
        }
        self._sessions = {}
        self.duration_linguistic = self._session(
            self._asset(os.path.join(root, "dsdur"), self.duration_cfg["linguistic"])
        )
        self.duration = self._session(
            self._asset(os.path.join(root, "dsdur"), self.duration_cfg["dur"])
        )
        self.pitch_linguistic = self._session(
            self._asset(os.path.join(root, "dspitch"), self.pitch_cfg["linguistic"])
        )
        self.pitch = self._session(
            self._asset(os.path.join(root, "dspitch"), self.pitch_cfg["pitch"])
        )
        self.variance_linguistic = self._session(
            self._asset(os.path.join(root, "dsvariance"), self.variance_cfg["linguistic"])
        )
        self.variance = self._session(
            self._asset(os.path.join(root, "dsvariance"), self.variance_cfg["variance"])
        )
        self.acoustic = self._session(self._asset(root, self.acoustic_cfg["acoustic"]))
        self.vocoder = self._session(
            self._asset(os.path.join(root, "dsvocoder"), self.vocoder_cfg["model"])
        )

        self.speaker_names = list(self.acoustic_cfg.get("speakers") or [])
        self.embeddings = {name: self._load_embedding(name) for name in self.speaker_names}
        self._g2p = {}
        self.phoneme_types = self._load_phoneme_types()

    @staticmethod
    def _asset(base, relative):
        return os.path.abspath(os.path.join(base, relative))

    def _session(self, path):
        if path not in self._sessions:
            self._sessions[path] = ort.InferenceSession(
                path, providers=["CPUExecutionProvider"]
            )
        return self._sessions[path]

    def _load_embedding(self, name):
        candidates = [
            os.path.join(self.root, "embeds", f"{name}.emb"),
            os.path.join(self.root, f"{name}.emb"),
        ]
        path = next((item for item in candidates if os.path.isfile(item)), None)
        if path is None:
            raise ValueError(f"missing speaker embedding: {name}")
        values = np.fromfile(path, dtype=np.float32)
        if values.size != 256:
            raise ValueError(f"speaker embedding {name}: expected 256, got {values.size}")
        return values

    def _vocabulary(self, base, config):
        return {
            "phonemes": load_json(self._asset(base, config["phonemes"])),
            "languages": load_json(self._asset(base, config["languages"])),
        }

    def _load_phoneme_types(self):
        """从 duration 字典汇总音素类型，作为元音锚点的声库事实。"""
        types = {}
        directory = os.path.join(self.root, "dsdur")
        for filename in sorted(os.listdir(directory)):
            if not filename.startswith("dsdict") or not filename.endswith(
                (".yaml", ".yml")
            ):
                continue
            data = load_yaml(os.path.join(directory, filename)) or {}
            for entry in data.get("symbols") or []:
                symbol = entry.get("symbol")
                if symbol:
                    types[symbol] = entry.get("type")
        return types

    def _speaker(self, globals_, length):
        name = globals_.get("speaker") or self.speaker_names[0]
        if name not in self.embeddings:
            raise ValueError(f"unknown speaker: {name}")
        return np.broadcast_to(self.embeddings[name], (1, length, 256)).copy()

    @staticmethod
    def _run(session, outputs, values):
        expected = {item.name for item in session.get_inputs()}
        missing = expected.difference(values)
        if missing:
            raise ValueError(f"missing ONNX inputs: {sorted(missing)}")
        inputs = {name: value for name, value in values.items() if name in expected}
        return session.run(outputs, inputs)

    def encode_lyrics(self, notes):
        tokens = {}
        for note in notes:
            note_id = str(note["id"])
            lyric = (note.get("lyric") or "").strip()
            language = note.get("language") or "zh"
            if not lyric:
                raise ValueError(f"missing lyric: {note_id}")
            tokens[note_id] = self._encode_lyric(lyric, language, note_id)
        return {"tokens": tokens}

    def _dictionary(self, language):
        if language not in self._g2p:
            path = os.path.join(self.root, "dsdur", f"dsdict-{language}.yaml")
            if not os.path.isfile(path):
                raise ValueError(f"unsupported language: {language}")
            entries = (load_yaml(path) or {}).get("entries") or []
            self._g2p[language] = {
                item["grapheme"]: item["phonemes"] for item in entries
            }
        return self._g2p[language]

    def _encode_lyric(self, lyric, language, note_id):
        dictionary = self._dictionary(language)
        result = []
        for token in lyric.split():
            if token.isascii():
                syllables = [token.lower()]
            elif language == "zh":
                if pinyin is None:
                    raise ValueError("pypinyin is required for Chinese lyrics")
                syllables = [item[0] for item in pinyin(token, style=Style.NORMAL)]
            else:
                raise ValueError(
                    f"non-ascii {language} G2P is unavailable for note {note_id}; "
                    "provide explicit phonemes"
                )

            for syllable in syllables:
                phonemes = dictionary.get(syllable) or dictionary.get(
                    f"{language}/{syllable}"
                )
                if phonemes is None:
                    raise ValueError(
                        f"dictionary miss: {language}/{syllable} (note {note_id})"
                    )
                for symbol in phonemes:
                    if "/" in symbol:
                        lang, phone = symbol.split("/", 1)
                    else:
                        lang, phone = language, symbol
                    result.append([lang, phone])
        return result

    def check(self, words, globals_, overrides=None, groups=None):
        words, owners, remap = self._expand(words, groups)
        overrides = self._remap_overrides(overrides, remap)
        duration_encoded = self._encode(words, "duration")
        predicted = self._duration_forward(
            words, duration_encoded, globals_, overrides or []
        )
        alignment = align_phonemes(
            words,
            predicted[0].tolist(),
            self.phoneme_types,
            self.frame_rate,
            self._lead_in_sec(words),
            owners,
        )
        ph_dur = np.asarray([alignment["ph_dur"]], dtype=np.int64)
        pitch_encoded = self._encode(words, "pitch")
        pitch = self._pitch_forward(
            words, pitch_encoded, ph_dur, globals_, overrides or []
        )
        return {
            "ph_dur": ph_dur[0].tolist(),
            "pitch_pred_midi": pitch[0].tolist(),
            "total_frames": int(ph_dur.sum()),
            "phonemes": alignment["phonemes"],
            "lead_in_sec": alignment["lead_in_sec"],
            "note_phonemes": note_phonemes(words, owners),
        }

    def expand(self, words, groups=None):
        """轻量 probe：只做组展开，返回逐原词（音符）的音素序列。

        身份底料的物化入口（pin 挂载/重挂签名用）：不跑任何模型，
        音素类型是声库事实，由 expand_groups 消费。key 是展开前的
        原 words 下标（字符串），调用侧按 word_indices 归并到音符。
        """
        expanded, owners, _remap = self._expand(words, groups)
        return {"note_phonemes": note_phonemes(expanded, owners)}

    def render(
        self, words, output, globals_, ph_dur=None, pitch_pred=None, overrides=None,
        groups=None,
    ):
        words, _owners, remap = self._expand(words, groups)
        overrides = self._remap_overrides(overrides, remap)
        duration_encoded = self._encode(words, "duration")
        if ph_dur is None:
            ph_dur = self._duration_forward(words, duration_encoded, globals_)
        else:
            ph_dur = np.asarray([ph_dur], dtype=np.int64)

        if pitch_pred is None:
            pitch_encoded = self._encode(words, "pitch")
            pitch_pred = self._pitch_forward(
                words, pitch_encoded, ph_dur, globals_, overrides or []
            )
        else:
            pitch_pred = np.asarray([pitch_pred], dtype=np.float32)

        total_frames = int(ph_dur.sum())
        f0 = self._midi_to_f0(pitch_pred)
        variance_encoded = self._encode(words, "variance")
        variance = self._variance_forward(
            variance_encoded, ph_dur, pitch_pred, globals_
        )
        acoustic_encoded = self._encode(words, "acoustic")
        mel = self._acoustic_forward(
            acoustic_encoded, ph_dur, f0, variance, globals_
        )
        waveform = self._run(self.vocoder, ["waveform"], {"mel": mel, "f0": f0})[0]

        output = os.path.abspath(output)
        os.makedirs(os.path.dirname(output), exist_ok=True)
        sf.write(output, waveform[0], self.sample_rate)
        return {
            "path": output,
            "sample_rate": self.sample_rate,
            "frames": total_frames,
            "samples": int(waveform.shape[-1]),
            "duration_sec": float(waveform.shape[-1]) / self.sample_rate,
        }

    @staticmethod
    def _lead_in_sec(words):
        if words and all(phone in REST_PHONEMES for _language, phone in words[0][0]):
            return float(words[0][1])
        return 0.0

    def _expand(self, words, groups):
        """展开 melisma 组；无组时原样返回（owners/remap 为 None）。"""
        if not groups:
            return words, None, None
        return expand_groups(words, groups, self.phoneme_types)

    @staticmethod
    def _remap_overrides(overrides, remap):
        """overrides 的 note_index 引用展开前词下标，按 remap 平移。"""
        if not overrides or not remap:
            return overrides
        return [
            {**override, "note_index": remap.get(int(override["note_index"]), int(override["note_index"]))}
            if "note_index" in override
            else override
            for override in overrides
        ]

    def _encode(self, words, stage):
        vocabulary = self.vocabularies[stage]
        token_ids, language_ids, phoneme_midis = [], [], []
        word_div, word_dur, rest = [], [], []
        for word in words:
            phonemes, duration_sec, midis, _slots = word_parts(word)
            word_div.append(len(phonemes))
            word_dur.append(int(round(duration_sec * self.frame_rate)))
            is_rest = all(phone in REST_PHONEMES for _lang, phone in phonemes)
            for (language, phone), midi in zip(phonemes, midis):
                token_ids.append(
                    self._phoneme_id(vocabulary["phonemes"], language, phone)
                )
                language_ids.append(vocabulary["languages"][language])
                phoneme_midis.append(midi)
                rest.append(is_rest)
        return {
            "tokens": np.asarray([token_ids], dtype=np.int64),
            "languages": np.asarray([language_ids], dtype=np.int64),
            "word_div": np.asarray([word_div], dtype=np.int64),
            "word_dur": np.asarray([word_dur], dtype=np.int64),
            "ph_midi": np.asarray([phoneme_midis], dtype=np.int64),
            "note_midi": np.asarray([phoneme_midis], dtype=np.float32),
            "note_rest": np.asarray([rest], dtype=bool),
        }

    @staticmethod
    def _phoneme_id(phonemes, language, phone):
        qualified = f"{language}/{phone}"
        if qualified in phonemes:
            return phonemes[qualified]
        if phone in phonemes:
            return phonemes[phone]
        raise ValueError(f"unknown phoneme: {qualified}")

    def _linguistic_forward(self, session, encoded, ph_dur=None):
        values = {
            "tokens": encoded["tokens"],
            "languages": encoded["languages"],
            "word_div": encoded["word_div"],
            "word_dur": encoded["word_dur"],
        }
        if ph_dur is not None:
            values["ph_dur"] = ph_dur
        return self._run(session, ["encoder_out", "x_masks"], values)

    def _duration_forward(self, words, encoded, globals_, overrides=None):
        encoder_out, x_masks = self._linguistic_forward(
            self.duration_linguistic, encoded
        )
        token_count = encoded["tokens"].shape[1]
        predicted = self._run(
            self.duration,
            ["ph_dur_pred"],
            {
                "encoder_out": encoder_out,
                "x_masks": x_masks,
                "ph_midi": encoded["ph_midi"],
                "spk_embed": self._speaker(globals_, token_count),
            },
        )[0]
        return self._fit_durations(words, predicted, overrides or [])

    def _fit_durations(self, words, predicted, overrides):
        result = np.zeros_like(predicted, dtype=np.int64)
        duration_pins = self._duration_pins(words, overrides)
        offset = 0
        for word in words:
            phonemes, duration_sec, _midis, _slots = word_parts(word)
            count = len(phonemes)
            target = int(round(duration_sec * self.frame_rate))
            if target < count:
                raise ValueError(
                    f"word duration has {target} frames for {count} phonemes"
                )
            local_pins = {
                index - offset: frames
                for index, frames in duration_pins.items()
                if offset <= index < offset + count
            }
            free = [index for index in range(count) if index not in local_pins]
            fixed_total = sum(local_pins.values())
            minimum_free = len(free)
            if fixed_total + minimum_free > target:
                raise ValueError(
                    f"duration pins need {fixed_total + minimum_free} frames "
                    f"but word has {target}"
                )
            if not free and fixed_total != target:
                raise ValueError(
                    f"fully pinned word has {fixed_total} frames but needs {target}"
                )

            raw = np.maximum(predicted[0, offset : offset + count][free], 0.0)
            budget = target - fixed_total - minimum_free
            weights = (
                raw / raw.sum()
                if raw.sum() > 0
                else np.full(len(free), 1 / len(free))
            ) if free else np.asarray([], dtype=np.float64)
            exact = weights * budget
            allocated = np.floor(exact).astype(np.int64)
            order = np.argsort(-(exact - allocated))
            for index in range(budget - int(allocated.sum())):
                allocated[order[index % len(free)]] += 1
            for local_index, frames in local_pins.items():
                result[0, offset + local_index] = frames
            for local_index, frames in zip(free, allocated + 1):
                result[0, offset + local_index] = frames
            offset += count
        return result

    def _duration_pins(self, words, overrides):
        offsets = []
        offset = 0
        for word in words:
            phonemes = word[0]
            offsets.append(offset)
            offset += len(phonemes)

        pins = {}
        for override in overrides:
            if override.get("kind") != "duration":
                continue
            word_index = int(override["note_index"])
            if word_index < 0 or word_index >= len(words):
                raise ValueError(f"duration note index out of range: {word_index}")
            count = len(words[word_index][0])
            for phoneme_index, seconds in override["durations"]:
                phoneme_index = int(phoneme_index)
                if phoneme_index < 0 or phoneme_index >= count:
                    raise ValueError(
                        f"duration phoneme index out of range: "
                        f"word={word_index} phoneme={phoneme_index}"
                    )
                global_index = offsets[word_index] + phoneme_index
                if global_index in pins:
                    raise ValueError(
                        f"duplicate duration pin: word={word_index} "
                        f"phoneme={phoneme_index}"
                    )
                pins[global_index] = max(1, int(round(float(seconds) * self.frame_rate)))
        return pins

    def _pitch_forward(self, words, encoded, ph_dur, globals_, overrides):
        encoder_out, _mask = self._linguistic_forward(
            self.pitch_linguistic, encoded, ph_dur
        )
        frames = int(ph_dur.sum())
        steps = np.asarray(int(globals_["steps"]), dtype=np.int64)
        pitch_input, retake = self._pitch_input(words, ph_dur, overrides)

        # 调试：NEUME_DEBUG_DUMP=/path/prefix 时把 pitch 前向的输入/输出落盘。
        dump = os.environ.get("NEUME_DEBUG_DUMP")
        result = self._run(
            self.pitch,
            ["pitch_pred"],
            {
                "encoder_out": encoder_out,
                "ph_dur": ph_dur,
                "note_midi": encoded["note_midi"],
                "note_rest": encoded["note_rest"],
                "note_dur": ph_dur,
                "pitch": pitch_input,
                "expr": np.ones((1, frames), dtype=np.float32),
                "retake": retake,
                "spk_embed": self._speaker(globals_, frames),
                "steps": steps,
            },
        )[0]

        if dump:
            np.savez(
                dump + "_pitch.npz",
                pitch_input=pitch_input,
                retake=retake,
                ph_dur=ph_dur,
                note_midi=encoded["note_midi"],
                note_rest=encoded["note_rest"],
                pitch_pred=result,
            )

        return result

    def _pitch_input(self, words, ph_dur, overrides):
        return build_pitch_input(words, ph_dur, overrides, self.frame_rate)

    def _variance_forward(self, encoded, ph_dur, pitch, globals_):
        encoder_out, _mask = self._linguistic_forward(
            self.variance_linguistic, encoded, ph_dur
        )
        frames = int(ph_dur.sum())
        output_names = [item.name for item in self.variance.get_outputs()]
        channels = [name.removesuffix("_pred") for name in output_names]
        values = {
            "encoder_out": encoder_out,
            "ph_dur": ph_dur,
            "pitch": pitch,
            "retake": np.ones((1, frames, len(output_names)), dtype=bool),
            "spk_embed": self._speaker(globals_, frames),
            "steps": np.asarray(int(globals_["steps"]), dtype=np.int64),
        }
        for channel in channels:
            values[channel] = np.zeros((1, frames), dtype=np.float32)
        outputs = self._run(self.variance, output_names, values)
        return dict(zip(channels, outputs))

    def _acoustic_forward(self, encoded, ph_dur, f0, variance, globals_):
        frames = int(ph_dur.sum())
        zeros = np.zeros((1, frames), dtype=np.float32)

        # 全局旋钮 = 预测曲线的乘性系数（1.0 中立），在 acoustic 消费边界应用。
        def scaled(channel):
            return variance.get(channel, zeros) * float(globals_.get(channel, 1.0))

        values = {
            "tokens": encoded["tokens"],
            "languages": encoded["languages"],
            "durations": ph_dur,
            "f0": f0,
            "energy": scaled("energy"),
            "breathiness": scaled("breathiness"),
            "voicing": scaled("voicing"),
            "tension": variance.get("tension", zeros),
            "falsetto_dev": variance.get("falsetto_dev", zeros),
            "gender": np.full((1, frames), globals_["gender"], dtype=np.float32),
            "velocity": np.full((1, frames), globals_["velocity"], dtype=np.float32),
            "spk_embed": self._speaker(globals_, frames),
            "depth": np.asarray(globals_["depth"], dtype=np.float32),
            "steps": np.asarray(int(globals_["steps"]), dtype=np.int64),
        }
        return self._run(self.acoustic, ["mel"], values)[0]

    @staticmethod
    def _midi_to_f0(midi):
        midi = np.asarray(midi)
        f0 = 440.0 * np.power(2.0, (midi - 69.0) / 12.0)
        f0[midi < 0] = 0.0
        return f0.astype(np.float32)


def build_pitch_input(words, ph_dur, overrides, frame_rate):
    """构造 pitch 模型的 pitch/retake 输入（纯函数，可脱离 ONNX 测试）。

    `pitch` 是**绝对**逐帧曲线：模型图内会减去自身的平滑基线
    （Sub(pitch, base_pitch)），所以未 pin 帧必须填该帧的基准 note midi
    而不是 0——否则基线塌到 0 附近，pin 区相对基线的残差变成 ~64 的
    出分布值，扩散输出在该区发散（大幅正弦状漂移）。
    （图追踪结论见 coconut_intervention priv/fp/probe_retake.py，2026-08-29）

    retake=True 帧自由扩散；pin 覆盖帧 retake=False（强引导而非硬钳制，
    输出贴合 pin 但仍是扩散噪声的函数）。pin 点到词边界之间按端点值
    平铺延伸。
    """
    frames = int(ph_dur.sum())
    pitch_input = np.zeros((1, frames), dtype=np.float32)
    retake = np.ones((1, frames), dtype=bool)
    if not overrides:
        return pitch_input, retake

    ranges = []
    phoneme_offset = 0
    frame_offset = 0
    for word in words:
        phonemes = word[0]
        count = len(phonemes)
        word_frames = int(ph_dur[0, phoneme_offset : phoneme_offset + count].sum())
        # 基准曲线：未 pin 帧填该帧的 note midi（SP/休止 midi<=0 填 0，
        # retake 为真时图内会被掩掉）。
        midi = float(word[2]) if word[2] and word[2] > 0 else 0.0
        pitch_input[0, frame_offset : frame_offset + word_frames] = midi
        ranges.append((frame_offset, frame_offset + word_frames))
        phoneme_offset += count
        frame_offset += word_frames

    for override in overrides:
        if override.get("kind") != "pitch":
            continue
        word_index = int(override["note_index"])
        start, stop = ranges[word_index]
        if stop <= start:
            continue
        points = sorted(
            (
                min(
                    max(int(round(seconds * frame_rate)), start),
                    stop - 1,
                ),
                float(midi),
            )
            for seconds, midi in override["points"]
        )
        if not points:
            continue
        anchors = [(start, points[0][1]), *points, (stop - 1, points[-1][1])]
        anchors.sort(key=lambda item: item[0])
        for (left_frame, left_midi), (right_frame, right_midi) in zip(
            anchors, anchors[1:]
        ):
            width = right_frame - left_frame
            for frame in range(left_frame, right_frame):
                ratio = 0.0 if width == 0 else (frame - left_frame) / width
                pitch_input[0, frame] = left_midi + (
                    right_midi - left_midi
                ) * ratio
                retake[0, frame] = False
        frame, midi = anchors[-1]
        pitch_input[0, frame] = midi
        retake[0, frame] = False

    return pitch_input, retake


def emit(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def dispatch(engine, request):
    action = request.get("action")
    globals_ = {**DEFAULT_GLOBALS, **(request.get("globals") or {})}
    if action == "encode":
        return engine.encode_lyrics(request["notes"])
    if action == "expand":
        return engine.expand(request["words"], request.get("groups"))
    if action == "check":
        return engine.check(
            request["words"],
            globals_,
            request.get("overrides"),
            request.get("groups"),
        )
    if action == "render":
        return engine.render(
            request["words"],
            request["out_path"],
            globals_,
            ph_dur=request.get("ph_dur"),
            pitch_pred=request.get("pitch_pred_midi"),
            overrides=request.get("overrides"),
            groups=request.get("groups"),
        )
    raise ValueError(f"unknown action: {action}")


def main():
    if len(sys.argv) != 2:
        print("usage: worker.py <voicebank_root>", file=sys.stderr)
        raise SystemExit(2)

    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    engine = DiffSingerEngine(sys.argv[1])
    emit(
        {
            "ready": True,
            "sample_rate": engine.sample_rate,
            "hop_size": engine.hop_size,
            "speakers": engine.speaker_names,
        }
    )

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        request_id = None
        try:
            request = json.loads(line)
            request_id = request.get("id")
            emit({"id": request_id, "ok": True, "result": dispatch(engine, request)})
        except Exception as error:
            emit(
                {
                    "id": request_id,
                    "ok": False,
                    "error": f"{type(error).__name__}: {error}",
                }
            )


if __name__ == "__main__":
    main()
