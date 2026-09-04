"""pitch/retake 输入构造的纯函数测试；需要 numpy（worker 依赖），不加载 ONNX。"""

import unittest

import numpy as np

from worker import build_pitch_input


# 帧率 10fps 便于口算；词：SP（midi 0）+ 实词 1（midi 60）+ 实词 2（midi 64）。
WORDS = [
    [[["zh", "SP"]], 0.5, 0],
    [[["zh", "l"], ["zh", "a"]], 1.0, 60],
    [[["zh", "s"], ["zh", "i"]], 1.0, 64],
]
# 共 70 帧：SP [0,10)，词1 [10,40)，词2 [40,70)
PH_DUR = np.asarray([[10, 15, 15, 15, 15]], dtype=np.int64)


class PitchInputTest(unittest.TestCase):
    def test_no_overrides_returns_zeros_and_all_retake(self):
        pitch, retake = build_pitch_input(WORDS, PH_DUR, None, 10.0)
        self.assertTrue((pitch == 0).all())
        self.assertTrue(retake.all())

    def test_unpinned_frames_carry_base_note_midi(self):
        # 关键回归：未 pin 帧必须是基准 note midi（图内平滑基线依赖它），
        # 不是 0——否则 pin 区条件残差出分布、输出发散。
        overrides = [
            {"kind": "pitch", "note_index": 2, "points": [[5.0, 66.0]]}
        ]
        pitch, retake = build_pitch_input(WORDS, PH_DUR, overrides, 10.0)

        self.assertTrue((pitch[0, :10] == 0.0).all())  # SP 帧
        self.assertTrue((pitch[0, 10:40] == 60.0).all())  # 词1 未 pin：基准 midi
        self.assertTrue(retake[0, :40].all())

    def test_pinned_frames_interpolate_and_extend_to_word_edges(self):
        overrides = [
            {"kind": "pitch", "note_index": 2, "points": [[5.0, 65.0], [6.0, 63.0]]}
        ]
        pitch, retake = build_pitch_input(WORDS, PH_DUR, overrides, 10.0)

        # 点帧：5.0s→帧 50（65.0），6.0s→帧 60（63.0），区间线性插值；
        # 点到词边界按端点值平铺（帧 40–49 = 65.0，帧 60–69 = 63.0）。
        self.assertTrue((pitch[0, 40:50] == 65.0).all())
        self.assertAlmostEqual(pitch[0, 55], 64.0, places=4)
        self.assertTrue((pitch[0, 60:70] == 63.0).all())
        self.assertFalse(retake[0, 40:70].any())

    def test_points_clamped_into_word_range(self):
        # 点落在词外（别的词的时间）→ 钳回本词范围
        overrides = [
            {"kind": "pitch", "note_index": 2, "points": [[0.0, 70.0]]}
        ]
        pitch, retake = build_pitch_input(WORDS, PH_DUR, overrides, 10.0)

        self.assertTrue((pitch[0, 40:70] == 70.0).all())
        self.assertFalse(retake[0, 40:70].any())
        self.assertTrue((pitch[0, 10:40] == 60.0).all())  # 别的词不受影响

    def test_duration_overrides_do_not_touch_pitch(self):
        overrides = [{"kind": "duration", "note_index": 2, "durations": [[0, 5]]}]
        pitch, retake = build_pitch_input(WORDS, PH_DUR, overrides, 10.0)
        self.assertTrue((pitch[0, 40:70] == 64.0).all())
        self.assertTrue(retake.all())


if __name__ == "__main__":
    unittest.main()
