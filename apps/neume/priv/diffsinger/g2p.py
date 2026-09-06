"""纯 G2P 函数：dsdict 字典装载、最长匹配分段、假名→罗马音。

不加载 ONNX 或声库文件，字典以 entries 列表注入，可脱离推理环境单测。
字典是声库事实：能查到的才发音，查不到的一律 loud error，不做静默降级。
"""

# --- 假名表（标准 Hepburn；dsdict-ja 同时收 si/ti/tu/hu/zi 变体，键缺失时
# --- 由分段兜底拆成基础拍 + 元音拍） -------------------------------------

_MORA = {
    "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
    "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
    "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
    "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
    "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
    "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
    "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
    "や": "ya", "ゆ": "yu", "よ": "yo",
    "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
    "わ": "wa", "を": "wo",
    "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
    "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
    "だ": "da", "ぢ": "ji", "づ": "zu", "で": "de", "ど": "do",
    "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
    "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
}

# 拗音与外来音组合：两字符优先于单拍查表。
_COMBO = {
    "きゃ": "kya", "きゅ": "kyu", "きょ": "kyo",
    "しゃ": "sha", "しゅ": "shu", "しょ": "sho",
    "ちゃ": "cha", "ちゅ": "chu", "ちょ": "cho",
    "にゃ": "nya", "にゅ": "nyu", "にょ": "nyo",
    "ひゃ": "hya", "ひゅ": "hyu", "ひょ": "hyo",
    "みゃ": "mya", "みゅ": "myu", "みょ": "myo",
    "りゃ": "rya", "りゅ": "ryu", "りょ": "ryo",
    "ぎゃ": "gya", "ぎゅ": "gyu", "ぎょ": "gyo",
    "じゃ": "ja", "じゅ": "ju", "じょ": "jo",
    "ぢゃ": "ja", "ぢゅ": "ju", "ぢょ": "jo",
    "びゃ": "bya", "びゅ": "byu", "びょ": "byo",
    "ぴゃ": "pya", "ぴゅ": "pyu", "ぴょ": "pyo",
    "うぃ": "wi", "うぇ": "we", "うぉ": "wo",
    "てぃ": "ti", "とぅ": "tu", "でぃ": "di", "どぅ": "du",
    "ふぁ": "fa", "ふぃ": "fi", "ふぇ": "fe", "ふぉ": "fo",
    "ゔぁ": "va", "ゔぃ": "vi", "ゔぇ": "ve", "ゔぉ": "vo",
    "しぇ": "she", "ちぇ": "che", "じぇ": "je",
    "つぁ": "tsa", "つぇ": "tse", "つぉ": "tso",
    "いぇ": "ye",
}

# 独立小假名（组合查不到时的自身读音）。
_SMALL = {
    "ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o",
    "ゃ": "ya", "ゅ": "yu", "ょ": "yo",
    "ゎ": "wa",
}

_VOWELS = "aiueo"


def _to_hiragana(char):
    code = ord(char)
    # 片假名 → 平假名（U+30A1–U+30F6 与平假名相差 0x60）；长音符 ー 不在其内。
    if 0x30A1 <= code <= 0x30F6:
        return chr(code - 0x60)
    return char


def kana_to_moras(text):
    """假名字符串 → 罗马音拍序列。促音 っ→"cl"，长音 ー→重复前一拍元音，
    ん→"n"。遇汉字、ASCII 或未收录假名抛 ValueError。"""
    moras = []
    index = 0
    chars = [_to_hiragana(char) for char in text]
    while index < len(chars):
        char = chars[index]
        if char == "っ":
            moras.append("cl")
        elif char == "ー":
            if not moras or moras[-1][-1] not in _VOWELS:
                raise ValueError(f"long vowel mark without preceding vowel: {text}")
            moras.append(moras[-1][-1])
        elif char == "ん":
            moras.append("n")
        elif (
            index + 1 < len(chars)
            and (char + chars[index + 1]) in _COMBO
        ):
            moras.append(_COMBO[char + chars[index + 1]])
            index += 1
        elif char in _MORA:
            moras.append(_MORA[char])
        elif char in _SMALL:
            moras.append(_SMALL[char])
        else:
            raise ValueError(
                f"unsupported kana character: {char!r} in {text!r}; "
                "kanji and non-kana scripts need explicit phonemes"
            )
        index += 1
    return moras


def has_kana(text):
    return any(0x3040 <= ord(char) <= 0x30FF for char in text)


# --- 字典 -----------------------------------------------------------------

def build_dictionary(entries):
    """dsdict entries → {"map": grapheme -> phonemes, "max_key": 最长键}。"""
    mapping = {}
    max_key = 0
    for item in entries:
        grapheme = item["grapheme"]
        mapping[grapheme] = item["phonemes"]
        max_key = max(max_key, len(grapheme))
    return {"map": mapping, "max_key": max_key}


def lookup(dictionary, key, language):
    """先裸键后 `lang/` 限定键；命中返回音素符号列表，未命中返回 None。"""
    mapping = dictionary["map"]
    phonemes = mapping.get(key)
    if phonemes is None:
        phonemes = mapping.get(f"{language}/{key}")
    return phonemes


def segment_token(token, dictionary, language):
    """贪心最长匹配把 token 切成字典键序列；返回音素符号列表。

    整词未命中时的 OOV 兜底——字典通常收全部单字母键，最差退化为逐字母
    拼读。存在切不动的字符段时抛 ValueError（带定位），不静默跳过。
    """
    max_key = dictionary["max_key"]
    phonemes = []
    cursor = 0
    while cursor < len(token):
        upper = min(cursor + max_key, len(token))
        for end in range(upper, cursor, -1):
            piece = lookup(dictionary, token[cursor:end], language)
            if piece is not None:
                phonemes.extend(piece)
                cursor = end
                break
        else:
            raise ValueError(
                f"g2p cannot segment: {language}/{token} at "
                f"{token[cursor:]!r} (note requires explicit phonemes)"
            )
    return phonemes


def qualify(symbols, language):
    """音素符号 → [lang, phone]；裸符号归入当前语言。"""
    result = []
    for symbol in symbols:
        if "/" in symbol:
            lang, phone = symbol.split("/", 1)
        else:
            lang, phone = language, symbol
        result.append([lang, phone])
    return result


# --- 歌词编码 ---------------------------------------------------------------

def encode_lyric(lyric, language, get_dictionary, note_id, pinyin=None):
    """单音符歌词 → [[lang, phone], ...]。

    - ASCII：整词查字典（小写），未命中走最长匹配分段（OOV 字母级兜底）；
    - `zh` 非 ASCII：pypinyin 逐音节查字典（pinyin 回调由调用方注入）；
    - 含假名：转罗马音后逐拍查字典（拍键缺失退分段）；
    - 其余文字：loud error，指向显式音素通道。
    """
    result = []
    for token in lyric.split():
        result.extend(_encode_token(token, language, get_dictionary, note_id, pinyin))
    if not result:
        raise ValueError(f"missing lyric: {note_id}")
    return result


def _encode_token(token, language, get_dictionary, note_id, pinyin):
    dictionary = get_dictionary(language)
    if token.isascii():
        syllable = token.lower()
        phonemes = lookup(dictionary, syllable, language)
        if phonemes is None:
            try:
                phonemes = segment_token(syllable, dictionary, language)
            except ValueError as error:
                raise ValueError(f"{error} (note {note_id})") from error
        return qualify(phonemes, language)

    if language == "zh":
        if pinyin is None:
            raise ValueError("pypinyin is required for Chinese lyrics")
        result = []
        for syllable in pinyin(token):
            phonemes = lookup(dictionary, syllable, language)
            if phonemes is None:
                raise ValueError(f"dictionary miss: {language}/{syllable} (note {note_id})")
            result.extend(qualify(phonemes, language))
        return result

    if has_kana(token):
        result = []
        for mora in kana_to_moras(token):
            phonemes = lookup(dictionary, mora, language)
            if phonemes is None:
                try:
                    phonemes = segment_token(mora, dictionary, language)
                except ValueError as error:
                    raise ValueError(f"{error} (note {note_id})") from error
            result.extend(qualify(phonemes, language))
        return result

    raise ValueError(
        f"non-ascii {language} G2P is unavailable for note {note_id}; "
        "provide explicit phonemes"
    )
