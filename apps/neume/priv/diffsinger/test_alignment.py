"""音素对齐纯函数测试；不加载声库或 ONNX。"""

import unittest

from alignment import align_phonemes, is_rest_word, word_start_index


TYPES = {
    "SP": "vowel",
    "AP": "vowel",
    "EP": "vowel",
    "zh/s": "fricative",
    "zh/t": "fricative",
    "zh/r": "glide",
    "zh/a": "vowel",
    "zh/u": "vowel",
    "en/k": "fricative",
    "en/ae": "vowel",
    "en/t": "fricative",
}


class AlignmentTest(unittest.TestCase):
    def test_rest_detection_and_anchor_selection(self):
        self.assertTrue(is_rest_word([["zh", "SP"]]))
        self.assertTrue(is_rest_word([["zh", "EP"]]))
        self.assertEqual(word_start_index([["zh", "s"], ["zh", "a"]], TYPES), 1)
        self.assertEqual(
            word_start_index(
                [["zh", "t"], ["zh", "r"], ["zh", "u"]], TYPES
            ),
            1,
        )

    def test_ccv_prefix_is_backtimed_without_cv_assumption(self):
        words = [
            [[['zh', 'SP']], 0.5, 0],
            [[['zh', 's'], ['zh', 't'], ['zh', 'a']], 0.5, 60],
        ]
        result = align_phonemes(words, [30, 8, 12, 40], TYPES, 100.0, 0.5)
        spans = [
            (item["start_frame"], item["end_frame"])
            for item in result["phonemes"]
        ]

        self.assertEqual(spans, [(0, 30), (30, 38), (38, 50), (50, 100)])
        self.assertEqual(result["phonemes"][3]["symbol"], "a")
        self.assertEqual(result["phonemes"][3]["start_frame"], 50)
        self.assertEqual(result["ph_dur"], [30, 8, 12, 50])

    def test_cvc_coda_stays_before_the_next_vowel_anchor(self):
        words = [
            [[['zh', 'SP']], 0.5, 0],
            [[['en', 'k'], ['en', 'ae'], ['en', 't']], 0.5, 60],
            [[['zh', 's'], ['zh', 'u']], 0.5, 62],
        ]
        result = align_phonemes(
            words, [30, 10, 30, 10, 8, 40], TYPES, 100.0, 0.5
        )
        by_symbol = {item["symbol"]: item for item in result["phonemes"]}

        self.assertEqual(by_symbol["ae"]["start_frame"], 50)
        self.assertLess(by_symbol["t"]["start_frame"], 100)
        self.assertEqual(by_symbol["s"]["end_frame"], 100)
        self.assertEqual(by_symbol["u"]["start_frame"], 100)

    def test_initial_gap_rests_absorb_slack_but_lead_in_stays_fixed(self):
        words = [
            [[['zh', 'SP']], 0.5, 0],
            [[['zh', 'SP']], 0.25, 0],
            [[['zh', 's'], ['zh', 'a']], 0.5, 60],
        ]
        result = align_phonemes(words, [45, 20, 10, 40], TYPES, 100.0, 0.5)
        phonemes = result["phonemes"]

        self.assertEqual(phonemes[2]["end_frame"], 75)
        self.assertEqual(phonemes[3]["start_frame"], 75)
        self.assertEqual(result["lead_in_sec"], 0.5)
        self.assertEqual(result["total_frames"], 125)


if __name__ == "__main__":
    unittest.main()
