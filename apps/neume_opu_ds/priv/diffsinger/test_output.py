"""输出阶段协议：验证 pitch 消费合并后的时长，不重新预测 duration。"""
import unittest
from unittest.mock import Mock

import numpy as np

from worker import DiffSingerEngine, dispatch


class OutputTest(unittest.TestCase):
    def engine(self):
        engine = object.__new__(DiffSingerEngine)
        engine._encode = Mock(return_value={})
        engine._duration_forward = Mock(side_effect=AssertionError("重复预测 duration"))
        engine._pitch_forward = Mock(return_value=np.array([[60.0] * 5], dtype=np.float32))
        return engine

    def test_pitch_consumes_supplied_frames(self):
        engine = self.engine()
        words = [[[["zh", "l"], ["zh", "a"]], 0.5, 60]]
        result = dispatch(engine, {"action": "pitch", "words": words, "ph_dur": [2, 3]})
        np.testing.assert_array_equal(engine._pitch_forward.call_args.args[2], [[2, 3]])
        self.assertEqual(result["pitch_pred_midi"], [60.0] * 5)
        engine._duration_forward.assert_not_called()

    def test_invalid_frames_do_not_reach_model(self):
        engine = self.engine()
        words = [[[["zh", "l"], ["zh", "a"]], 0.5, 60]]
        for frames in ([1], [-1, 6], [0, 0], [1.5, 3], [True, 4]):
            with self.subTest(frames=frames), self.assertRaises(ValueError):
                engine.pitch_output(words, frames, {})
        engine._pitch_forward.assert_not_called()


if __name__ == "__main__":
    unittest.main()
