"""_group/_place 纯函数单测（不碰 ONNX session）。

数值约定：frame_rate = 100（1 帧 = 10ms），便于口算。
"""
from engine import _is_rest_word, _place, _word_start_index

# 类型表（Qixuan 形状：lang 前缀；SP/AP 按名字识别 rest，不走类型）
TYPES = {
    'SP': 'vowel', 'AP': 'vowel',
    'zh/l': 'fricative', 'zh/iang': 'vowel',
    'zh/h': 'fricative', 'zh/u': 'vowel',
    'zh/c': 'fricative', 'zh/g': 'glide',
}

FRAME_RATE = 100.0


def test_rest_word_detection():
    assert _is_rest_word([['zh', 'SP']])
    assert _is_rest_word([['zh', 'AP']])
    assert not _is_rest_word([['zh', 'l'], ['zh', 'iang']])


def test_word_start_index_vowel_anchor():
    # 元音开组：词首辅音下标 0，锚点是元音
    assert _word_start_index([['zh', 'l'], ['zh', 'iang']], TYPES) == 1
    # 元音开头：锚点就是 0
    assert _word_start_index([['zh', 'iang']], TYPES) == 0


def test_word_start_index_cgv_exception():
    # Consonant-Glide-Vowel：glide 开组（glide onset = 音符起点）
    assert _word_start_index([['zh', 'c'], ['zh', 'g'], ['zh', 'u']], TYPES) == 1


def test_word_start_index_all_consonants():
    # 全无元音：首音素开组（无 preutterance）
    assert _word_start_index([['zh', 'h'], ['zh', 'c']], TYPES) == 0


def test_place_two_notes_with_head_sp():
    words = [
        [[['zh', 'SP']], 0.5, 0],                      # 槽 [0, 50)
        [[['zh', 'l'], ['zh', 'iang']], 0.5, 60],      # 槽 [50, 100)
        [[['zh', 'h'], ['zh', 'u']], 0.5, 62],         # 槽 [100, 150)
    ]
    ph_dur = [40.0, 10.0, 40.0, 8.0, 40.0]

    boundaries, aligned, lead_in, total = _place(words, ph_dur, TYPES, FRAME_RATE)

    spans = [(b['start_frame'], b['end_frame']) for b in boundaries]
    # SP 吸收 slack / 首辅音倒推不拉伸 / 元音 onset == 音符起点
    assert spans == [(0, 40), (40, 50), (50, 92), (92, 100), (100, 150)]
    # 首辅音提前（preutterance）：l 在音符起点 50 之前
    assert boundaries[1]['symbol'] == 'l' and boundaries[1]['start_frame'] < 50
    # 元音锚点：iang 起点 == 词槽起点 50；u 起点 == 100
    assert boundaries[2]['symbol'] == 'iang' and boundaries[2]['start_frame'] == 50
    assert boundaries[4]['symbol'] == 'u' and boundaries[4]['start_frame'] == 100
    # note_index：rest 为 None，其余按非 rest 词序
    assert [b['note_index'] for b in boundaries] == [None, 0, 0, 1, 1]
    # 对齐后 ph_dur 与边界一致，总和 = total
    assert aligned == [e - s for s, e in spans]
    assert lead_in == 50 and total == 150


def test_place_mid_phrase_rest_joins_group():
    # 窗内间隙 SP 并入当前组一起拉伸（吃间隙尾部）
    words = [
        [[['zh', 'SP']], 0.5, 0],
        [[['zh', 'iang']], 0.5, 60],          # 锚点 50，词即元音
        [[['zh', 'SP']], 0.2, 0],             # 间隙 [100, 120)
        [[['zh', 'l'], ['zh', 'u']], 0.5, 62]  # 锚点 120
    ]
    ph_dur = [40.0, 40.0, 20.0, 10.0, 40.0]

    boundaries, aligned, lead_in, total = _place(words, ph_dur, TYPES, FRAME_RATE)

    # 句首组无辅音 → SP 独占 [0, 50)；组 [iang, SP, l] 填满 [50, 120)
    # （sum=70 → ratio=1.0）；u 填 [120, 170)
    spans = [(b['start_frame'], b['end_frame']) for b in boundaries]
    assert spans == [(0, 50), (50, 90), (90, 110), (110, 120), (120, 170)]
    # l 是下一音符的辅音，落在间隙里（preutterance 吃 rest 尾巴）
    assert boundaries[3]['symbol'] == 'l' and boundaries[3]['end_frame'] == 120
    assert [b['note_index'] for b in boundaries] == [None, 0, None, 1, 1]
    assert lead_in == 50 and total == 170


def test_place_head_padding_too_small_clamps():
    # 首辅音预测 60 帧 > padding 50 帧：按比例压进 [0, 50]，SP 归零长
    words = [
        [[['zh', 'SP']], 0.5, 0],
        [[['zh', 'l'], ['zh', 'iang']], 0.5, 60],
    ]
    ph_dur = [40.0, 60.0, 40.0]

    boundaries, _aligned, _lead_in, _total = _place(words, ph_dur, TYPES, FRAME_RATE)

    spans = [(b['start_frame'], b['end_frame']) for b in boundaries]
    assert spans[0] == (0, 0)          # SP 被挤没
    assert spans[1] == (0, 50)         # 辅音占满 padding，元音仍锚 50
    assert spans[2][0] == 50
