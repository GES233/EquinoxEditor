"""DiffSinger 音符槽到声学音素边界的纯对齐逻辑。"""

REST_PHONEMES = {"SP", "AP", "EP"}


def is_rest_word(phonemes):
    return all(phone in REST_PHONEMES for _language, phone in phonemes)


def phoneme_type(types, language, phone):
    return types.get(f"{language}/{phone}") or types.get(phone)


def word_start_index(phonemes, types):
    """返回与音符起点对齐的词内音素下标。

    默认以第一个元音为锚。对于 C-G-V，glide 与音符起点对齐，只有前面的
    辅音回排；没有元音的特殊音节从首音素开始，不制造虚假的 preutterance。
    """
    vowel_flags = [
        phoneme_type(types, language, phone) == "vowel"
        for language, phone in phonemes
    ]
    glide_flags = [
        phoneme_type(types, language, phone) == "glide"
        for language, phone in phonemes
    ]

    if not any(vowel_flags):
        return 0

    for index, vowel in enumerate(vowel_flags):
        if vowel:
            if index >= 2 and glide_flags[index - 1] and not vowel_flags[index - 2]:
                return index - 1
            return index

    return 0


def align_phonemes(words, phoneme_durations, types, frame_rate, lead_in_sec):
    """按 OpenUtau 式元音锚点放置音素。

    `words` 是 `[[[language, phone], ...], duration_sec, midi]`。词首辅音并入
    前一锚点区间，因而在下一音符起点前发声；锚点之间的其余音素按预测
    比例伸缩。开头的休止音素吸收 padding，头辅音保持预测长度并向前回排。

    返回值的帧边界连续、单调，且 `ph_dur` 可直接回放给后续模型。这里仍
    采用一音符一个音节槽；melisma 需要独立的跨音符音节身份，不在本函数
    中靠猜测歌词或音素来隐式合并。
    """
    if frame_rate <= 0:
        raise ValueError(f"frame_rate must be positive, got {frame_rate}")
    if lead_in_sec < 0:
        raise ValueError(f"lead_in_sec must be non-negative, got {lead_in_sec}")

    slot_starts = []
    timeline_end = 0.0
    for phonemes, duration_sec, _midi in words:
        if not phonemes:
            raise ValueError("word must contain at least one phoneme")
        if duration_sec < 0:
            raise ValueError(f"word duration must be non-negative, got {duration_sec}")
        slot_starts.append(timeline_end)
        timeline_end += duration_sec * frame_rate

    flat = [
        (word_index, phoneme_index, language, phone)
        for word_index, (phonemes, _duration, _midi) in enumerate(words)
        for phoneme_index, (language, phone) in enumerate(phonemes)
    ]
    if len(flat) != len(phoneme_durations):
        raise ValueError(
            f"ph_dur length {len(phoneme_durations)} does not match "
            f"phoneme count {len(flat)}"
        )

    note_ordinals = {}
    for word_index, (phonemes, _duration, _midi) in enumerate(words):
        if not is_rest_word(phonemes):
            note_ordinals[word_index] = len(note_ordinals)

    groups = []
    flat_index = 0
    for word_index, (phonemes, _duration, _midi) in enumerate(words):
        count = len(phonemes)
        indices = list(range(flat_index, flat_index + count))

        if is_rest_word(phonemes):
            if groups:
                groups[-1]["indices"].extend(indices)
            else:
                groups.append({"anchor": None, "indices": indices})
            flat_index += count
            continue

        anchor_index = word_start_index(phonemes, types)
        prefix = indices[:anchor_index]
        anchored = indices[anchor_index:]
        if prefix:
            if groups:
                groups[-1]["indices"].extend(prefix)
            else:
                groups.append({"anchor": None, "indices": prefix})
        groups.append({"anchor": slot_starts[word_index], "indices": anchored})
        flat_index += count

    positions = [None] * len(flat)
    for group_index, group in enumerate(groups):
        indices = group["indices"]
        anchor = group["anchor"]
        end = (
            groups[group_index + 1]["anchor"]
            if group_index + 1 < len(groups)
            else timeline_end
        )

        if anchor is None:
            _place_head_group(positions, indices, flat, phoneme_durations, end)
        else:
            _place_anchored_group(
                positions, indices, phoneme_durations, anchor, end
            )

    boundaries = []
    aligned_durations = []
    previous_end = 0
    for flat_index, (word_index, local_index, language, phone) in enumerate(flat):
        position = positions[flat_index]
        if position is None:
            raise ValueError(f"phoneme {flat_index} was not placed")
        _start, end = position
        end_frame = max(previous_end, int(round(end)))
        boundaries.append(
            {
                "language": language,
                "symbol": phone,
                "type": "rest"
                if phone in REST_PHONEMES
                else phoneme_type(types, language, phone),
                "start_frame": previous_end,
                "end_frame": end_frame,
                "note_index": note_ordinals.get(word_index),
                "phoneme_index": local_index,
            }
        )
        aligned_durations.append(end_frame - previous_end)
        previous_end = end_frame

    lead_in_frames = int(round(lead_in_sec * frame_rate))
    return {
        "phonemes": boundaries,
        "ph_dur": aligned_durations,
        "lead_in_sec": lead_in_frames / frame_rate,
        "total_frames": previous_end,
    }


def _place_head_group(positions, indices, flat, durations, end):
    rest_count = 0
    for index in indices:
        if flat[index][3] not in REST_PHONEMES:
            break
        rest_count += 1

    rest_indices = indices[:rest_count]
    body_indices = indices[rest_count:]
    body_durations = [max(float(durations[index]), 0.0) for index in body_indices]
    body_total = sum(body_durations)

    if body_total > end and body_total > 0:
        scale = end / body_total
        body_durations = [duration * scale for duration in body_durations]
        body_total = end

    body_start = max(0.0, end - body_total)
    _place_scaled(positions, rest_indices, durations, 0.0, body_start)

    cursor = body_start
    for index, duration in zip(body_indices, body_durations):
        positions[index] = (cursor, cursor + duration)
        cursor += duration


def _place_anchored_group(positions, indices, durations, anchor, end):
    _place_scaled(positions, indices, durations, anchor, end)


def _place_scaled(positions, indices, durations, start, end):
    if not indices:
        return

    values = [max(float(durations[index]), 0.0) for index in indices]
    total = sum(values)
    width = max(0.0, end - start)
    if total > 0:
        values = [value * width / total for value in values]
    else:
        values = [width / len(indices)] * len(indices)

    cursor = start
    for index, duration in zip(indices, values):
        positions[index] = (cursor, cursor + duration)
        cursor += duration
