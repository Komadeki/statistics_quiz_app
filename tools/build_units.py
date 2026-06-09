def card_from_row(row):
    q = row.get("question","").strip()
    if not q:
        return None

    choices = [row.get("choice1",""), row.get("choice2",""), row.get("choice3",""), row.get("choice4","")]
    choices = [c.strip() for c in choices if c and c.strip()]
    if len(choices) < 2:
        return None

    ans1 = parse_int(row.get("answer_index",""), 1)
    ans0 = max(0, min(len(choices)-1, ans1-1))

    return {
        "question": q,
        "choices": choices,
        "answerIndex": ans0,
        "explanation": row.get("explanation","").strip(),
        "tags": split_tags(row.get("tags","")),
        "importance": parse_int(row.get("importance", row.get("difficulty","")), 2),
        "difficulty": parse_int(row.get("difficulty",""), 2),
    }
