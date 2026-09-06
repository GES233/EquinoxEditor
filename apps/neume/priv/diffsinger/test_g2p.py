"""G2P 纯函数测试；内嵌微型字典，不加载声库或 ONNX。"""

import unittest

from g2p import (
    build_dictionary,
    encode_lyric,
    has_kana,
    kana_to_moras,
    lookup,
)


def make_dictionary(pairs):
    return build_dictionary(
        [{"grapheme": grapheme, "phonemes": phonemes} for grapheme, phonemes in pairs]
    )


EN = make_dictionary(
    [
        ("hello", ["en/hh", "en/ax", "en/l", "en/ow"]),
        ("hell", ["en/hh", "en/eh", "en/l"]),
        ("o", ["en/ow"]),
        ("a", ["en/ey"]),
        ("b", ["en/b"]),
        ("c", ["en/k"]),
        ("x", ["en/k", "en/s"]),
        ("y", ["en/y"]),
        ("z", ["en/z"]),
        ("don't", ["en/d", "en/ow", "en/n", "en/t"]),
        ("ja/n", ["ja/N"]),
    ]
)

JA = make_dictionary(
    [
        ("ha", ["ja/h", "ja/a"]),
        ("ki", ["ja/k", "ja/i"]),
        ("te", ["ja/t", "ja/e"]),
        ("cl", ["cl"]),
        ("ro", ["ja/r", "ja/o"]),
        ("o", ["ja/o"]),
        ("ma", ["ja/m", "ja/a"]),
        ("ho", ["ja/h", "ja/o"]),
        ("n", ["ja/N"]),
        ("kya", ["ja/ky", "ja/a"]),
        ("fu", ["ja/f", "ja/u"]),
        ("yu", ["ja/y", "ja/u"]),
        ("a", ["ja/a"]),
        ("i", ["ja/i"]),
        ("u", ["ja/u"]),
        ("e", ["ja/e"]),
    ]
)

ZH = make_dictionary([("la", ["zh/l", "zh/a"])])


def get_dictionary(language):
    dictionaries = {"en": EN, "ja": JA, "zh": ZH}
    if language not in dictionaries:
        raise ValueError(f"unsupported language: {language}")
    return dictionaries[language]


class KanaTest(unittest.TestCase):
    def test_basic_moras(self):
        self.assertEqual(kana_to_moras("は"), ["ha"])
        self.assertEqual(kana_to_moras("さくら"), ["sa", "ku", "ra"])

    def test_katakana(self):
        self.assertEqual(kana_to_moras("サクラ"), ["sa", "ku", "ra"])

    def test_combo(self):
        self.assertEqual(kana_to_moras("きゃ"), ["kya"])
        self.assertEqual(kana_to_moras("しゅつ"), ["shu", "tsu"])

    def test_geminate(self):
        self.assertEqual(kana_to_moras("きって"), ["ki", "cl", "te"])
        self.assertEqual(kana_to_moras("キット"), ["ki", "cl", "to"])

    def test_long_vowel(self):
        self.assertEqual(kana_to_moras("ローマ"), ["ro", "o", "ma"])
        self.assertEqual(kana_to_moras("おおきい"), ["o", "o", "ki", "i"])

    def test_nasal(self):
        self.assertEqual(kana_to_moras("ほん"), ["ho", "n"])

    def test_kanji_rejected(self):
        with self.assertRaises(ValueError):
            kana_to_moras("桜")

    def test_ascii_rejected(self):
        with self.assertRaises(ValueError):
            kana_to_moras("sakura")

    def test_stray_long_vowel_rejected(self):
        with self.assertRaises(ValueError):
            kana_to_moras("ーあ")
        with self.assertRaises(ValueError):
            kana_to_moras("んー")

    def test_has_kana(self):
        self.assertTrue(has_kana("はろー"))
        self.assertFalse(has_kana("hello"))
        self.assertFalse(has_kana("桜"))


class EnglishTest(unittest.TestCase):
    def test_whole_word(self):
        self.assertEqual(
            encode_lyric("hello", "en", get_dictionary, "n1"),
            [["en", "hh"], ["en", "ax"], ["en", "l"], ["en", "ow"]],
        )

    def test_case_fallback(self):
        self.assertEqual(encode_lyric("HELLO", "en", get_dictionary, "n1")[0], ["en", "hh"])

    def test_contraction(self):
        self.assertEqual(encode_lyric("don't", "en", get_dictionary, "n1")[-1], ["en", "t"])

    def test_oov_not_guessed_from_subwords(self):
        with self.assertRaisesRegex(ValueError, "dictionary miss.*note n1"):
            encode_lyric("hella", "en", get_dictionary, "n1")

    def test_oov_not_guessed_from_letters(self):
        with self.assertRaisesRegex(ValueError, "dictionary miss.*note n1"):
            encode_lyric("xyz", "en", get_dictionary, "n1")

    def test_kana_does_not_override_language(self):
        with self.assertRaisesRegex(ValueError, "non-ascii en.*note n1"):
            encode_lyric("あ", "en", get_dictionary, "n1")

    def test_unresolvable_char(self):
        with self.assertRaises(ValueError):
            encode_lyric("hello7", "en", get_dictionary, "n1")

    def test_cross_language_symbols(self):
        # 字典值里的 lang/ 限定符号保留其语言标签。
        self.assertEqual(lookup(EN, "ja/n", "en"), ["ja/N"])


class JapaneseTest(unittest.TestCase):
    def test_kana_lyric(self):
        self.assertEqual(encode_lyric("は", "ja", get_dictionary, "n1"), [["ja", "h"], ["ja", "a"]])

    def test_geminate_lyric(self):
        self.assertEqual(
            encode_lyric("きって", "ja", get_dictionary, "n1"),
            [["ja", "k"], ["ja", "i"], ["ja", "cl"], ["ja", "t"], ["ja", "e"]],
        )

    def test_long_vowel_lyric(self):
        self.assertEqual(
            encode_lyric("ローマ", "ja", get_dictionary, "n1"),
            [["ja", "r"], ["ja", "o"], ["ja", "o"], ["ja", "m"], ["ja", "a"]],
        )

    def test_combo_lyric(self):
        self.assertEqual(
            encode_lyric("きゃ", "ja", get_dictionary, "n1"), [["ja", "ky"], ["ja", "a"]]
        )

    def test_missing_mora_not_segmented(self):
        dictionary = make_dictionary([("ky", ["ky"]), ("o", ["o"])])
        with self.assertRaisesRegex(ValueError, "dictionary miss.*note n1"):
            encode_lyric("きょ", "ja", lambda language: dictionary, "n1")

    def test_romaji_passthrough(self):
        # ASCII 罗马音歌词本来就是字典键，直接整词命中。
        self.assertEqual(
            encode_lyric("kya", "ja", get_dictionary, "n1"), [["ja", "ky"], ["ja", "a"]]
        )

    def test_kanji_rejected(self):
        with self.assertRaisesRegex(ValueError, "explicit phonemes"):
            encode_lyric("桜", "ja", get_dictionary, "n1")


class ChineseTest(unittest.TestCase):
    def test_pinyin_path(self):
        encoded = encode_lyric("啦", "zh", get_dictionary, "n1", pinyin=lambda token: ["la"])
        self.assertEqual(encoded, [["zh", "l"], ["zh", "a"]])

    def test_pinyin_required(self):
        with self.assertRaises(ValueError):
            encode_lyric("啦", "zh", get_dictionary, "n1")

    def test_dictionary_miss(self):
        with self.assertRaisesRegex(ValueError, "dictionary miss"):
            encode_lyric("喵", "zh", get_dictionary, "n1", pinyin=lambda token: ["miao"])


class EdgeTest(unittest.TestCase):
    def test_empty_lyric(self):
        with self.assertRaises(ValueError):
            encode_lyric("  ", "en", get_dictionary, "n1")

    def test_unsupported_language(self):
        with self.assertRaises(ValueError):
            encode_lyric("hello", "fr", get_dictionary, "n1")

    def test_multi_token(self):
        self.assertEqual(
            encode_lyric("hello don't", "en", get_dictionary, "n1")[0], ["en", "hh"]
        )

if __name__ == "__main__":
    unittest.main()
