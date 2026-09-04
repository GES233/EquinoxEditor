"""DiffSinger 音符槽到声学音素边界的纯对齐逻辑。"""

REST_PHONEMES = {"SP", "AP", "EP"}


def is_rest_word(phonemes):
    return all(phone in REST_PHONEMES for _language, phone in phonemes)


def phoneme_type(types, language, phone):
    return types.get(f"{language}/{phone}") or types.get(phone)


def word_parts(word):
    """把词规范化为 `(phonemes, duration_sec, midis, slots)` 四元组。

    线上格式是三元素 `[phonemes, duration_sec, midi]`（midi 词级广播）；
    melisma 展开后是四元素 `[phonemes, duration_sec, midis, slots]`——
    `midis` 逐音素，`slots` 逐成员时长。约定：词的最后 `len(slots) - 1`
    个音素是各成员的延续元音。
    """
    if len(word) == 3:
        phonemes, duration_sec, midi = word
        return phonemes, duration_sec, [midi] * len(phonemes), [duration_sec]
    phonemes, duration_sec, midis, slots = word
    return phonemes, duration_sec, midis, slots


def expand_groups(words, groups, types):
    """把 melisma 组（原 words 下标列表）展开为多 slot 词。

    `groups` 的每项是 `[头下标, 成员下标, ...]`，成员顺序即时间顺序。返回
    `(expanded, owners, remap)`：expanded word 为四元素词；owners 是逐音素
    的原 words 下标（供 note_index 归属）；remap 把原词下标映射到展开后
    下标（overrides 的 word 引用靠它平移）。延续元音取头词中第一个 vowel
    类型音素；头词无元音时报错——音素类型是声库事实，不在调用侧猜测。
    """
    heads = {}
    member_of = {}
    for group in groups or []:
        if len(group) < 2:
            continue
        head, *members = group
        if head in member_of:
            raise ValueError(f"melisma group head is another group's member: {head}")
        for member in members:
            if member in member_of or member in heads:
                raise ValueError(f"melisma group member claimed twice: {member}")
            member_of[member] = group
        heads[head] = group

    expanded = []
    owners = []
    remap = {}
    for index, word in enumerate(words):
        if index in member_of:
            continue
        phonemes, duration_sec, midis, slots = word_parts(word)
        group = heads.get(index)
        if group is None:
            remap[index] = len(expanded)
            expanded.append([list(phonemes), duration_sec, list(midis), list(slots)])
            owners.extend([index] * len(phonemes))
            continue

        vowel = None
        for language, phone in phonemes:
            if phoneme_type(types, language, phone) == "vowel":
                vowel = [language, phone]
                break
        if vowel is None:
            raise ValueError(f"melisma head word has no vowel: {index}")

        member_words = [words[member] for member in group[1:]]
        out_phonemes = [list(pair) for pair in phonemes]
        out_phonemes.extend([list(vowel) for _ in member_words])
        out_midis = list(midis) + [_word_midi(member) for member in member_words]
        out_slots = list(slots) + [word_parts(member)[1] for member in member_words]

        remap[index] = len(expanded)
        expanded.append(
            [out_phonemes, sum(out_slots), out_midis, out_slots]
        )
        owners.extend([index] * len(phonemes))
        owners.extend(group[1:])

    return expanded, owners, remap


def _word_midi(word):
    if len(word) == 3:
        return word[2]
    midis = word[2]
    return midis[0] if midis else 0.0


def note_phonemes(words, owners):
    """按 owner（原词下标）归并展开后的音素序列。

    身份底料的物化形状：`{str(原词下标): [[lang, phone], ...]}`——头词是
    自身音素，melisma 成员词是派生的延续元音单元素序列。owners 为 None
    （无组）时逐词归属自身。
    """
    if owners is None:
        owners = [
            index for index, word in enumerate(words) for _ in word_parts(word)[0]
        ]
    result = {}
    cursor = 0
    for word in words:
        phonemes = word_parts(word)[0]
        for offset, pair in enumerate(phonemes):
            owner = owners[cursor + offset]
            result.setdefault(str(owner), []).append(list(pair))
        cursor += len(phonemes)
    return result


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


def align_phonemes(words, phoneme_durations, types, frame_rate, lead_in_sec, owners=None):
    """按 OpenUtau 式元音锚点放置音素。

    `words` 的元素是三元素词或 `word_parts` 归一化的四元素词（melisma 经
    `expand_groups` 展开）。词首辅音并入前一锚点区间，因而在下一音符起点
    前发声；锚点之间的其余音素按预测比例伸缩。开头的休止音素吸收
    padding，头辅音保持预测长度并向前回排。多 slot 词（melisma）的头音素
    锚在词起点，第 k 个延续元音锚在第 k 个成员 slot 的起点。

    `owners` 是逐音素的原始词下标（展开前），用于把边界归属到具体成员
    音符；缺省为逐词自身下标。返回值的帧边界连续、单调，且 `ph_dur` 可
    直接回放给后续模型。组的成立与否由调用侧显式给出（`expand_groups`
    的 `groups` 参数），本函数不靠猜测歌词或音素隐式合并。
    """
    if frame_rate <= 0:
        raise ValueError(f"frame_rate must be positive, got {frame_rate}")
    if lead_in_sec < 0:
        raise ValueError(f"lead_in_sec must be non-negative, got {lead_in_sec}")

    parts = [word_parts(word) for word in words]

    slot_starts = []
    timeline_end = 0.0
    for phonemes, duration_sec, _midis, _slots in parts:
        if not phonemes:
            raise ValueError("word must contain at least one phoneme")
        if duration_sec < 0:
            raise ValueError(f"word duration must be non-negative, got {duration_sec}")
        slot_starts.append(timeline_end)
        timeline_end += duration_sec * frame_rate

    flat = [
        (word_index, phoneme_index, language, phone)
        for word_index, (phonemes, _duration, _midis, _slots) in enumerate(parts)
        for phoneme_index, (language, phone) in enumerate(phonemes)
    ]
    if len(flat) != len(phoneme_durations):
        raise ValueError(
            f"ph_dur length {len(phoneme_durations)} does not match "
            f"phoneme count {len(flat)}"
        )

    if owners is None:
        owners = [word_index for word_index, _local, _lang, _phone in flat]
    if len(owners) != len(flat):
        raise ValueError(
            f"owners length {len(owners)} does not match phoneme count {len(flat)}"
        )

    # 音符序号按 owner（原始词）归属：一个 owner 的音素全是休止符才算休止，
    # 这样 melisma 成员的延续元音把成员计为独立音符。
    note_ordinals = {}
    owner_phones = {}
    for owner, (_word_index, _local, _language, phone) in zip(owners, flat):
        owner_phones.setdefault(owner, []).append(phone)
    for owner, phones in owner_phones.items():
        if not all(phone in REST_PHONEMES for phone in phones):
            note_ordinals[owner] = len(note_ordinals)

    groups = []
    flat_index = 0
    for word_index, (phonemes, _duration, _midis, slots) in enumerate(parts):
        count = len(phonemes)
        indices = list(range(flat_index, flat_index + count))
        word_start = slot_starts[word_index]

        if is_rest_word(phonemes):
            if groups:
                groups[-1]["indices"].extend(indices)
            else:
                groups.append({"anchor": None, "indices": indices})
            flat_index += count
            continue

        continuation_count = len(slots) - 1
        head_count = count - continuation_count
        if head_count < 1:
            raise ValueError("melisma word must retain head phonemes")

        head = indices[:head_count]
        anchor_index = word_start_index(
            [pair for pair in phonemes[:head_count]], types
        )
        prefix = head[:anchor_index]
        anchored = head[anchor_index:]
        if prefix:
            if groups:
                groups[-1]["indices"].extend(prefix)
            else:
                groups.append({"anchor": None, "indices": prefix})
        groups.append({"anchor": word_start, "indices": anchored})

        member_start = word_start + slots[0] * frame_rate
        for position in range(continuation_count):
            vowel_index = indices[head_count + position]
            groups.append({"anchor": member_start, "indices": [vowel_index]})
            member_start += slots[position + 1] * frame_rate

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
                "note_index": note_ordinals.get(owners[flat_index]),
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
