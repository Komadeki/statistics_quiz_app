# -*- coding: utf-8 -*-

import csv
import json
import os

MASTER_PATH = "assets_src/meta/deck_unit_master.csv"
OUT_DIR = "assets/decks"

REQUIRED_TSV_COLUMNS = [
    "question",
    "choice1",
    "choice2",
    "choice3",
    "choice4",
    "answer_index",
    "explanation",
    "tags",
    "importance",
    "difficulty",
    "is_free",
]

def read_csv(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))

def read_tsv(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f, delimiter="\t"))

def parse_int(value, name, row_no):
    try:
        return int(str(value).strip())
    except Exception:
        raise ValueError(f"{name} が整数ではありません row={row_no}: {value}")

def parse_bool(value, name, row_no):
    s = str(value).strip().lower()
    if s in ("true", "t", "1", "yes", "y"):
        return True
    if s in ("false", "f", "0", "no", "n"):
        return False
    raise ValueError(f"{name} が true/false ではありません row={row_no}: {value}")

def split_tags(value):
    return [x.strip() for x in str(value).split(",") if x.strip()]

def validate_columns(rows, path):
    if not rows:
        raise ValueError(f"TSVが空です: {path}")
    missing = [c for c in REQUIRED_TSV_COLUMNS if c not in rows[0]]
    if missing:
        raise ValueError(f"TSVの列が不足しています: {path} missing={missing}")

def card_from_row(row, row_no, unit_id):
    question = row.get("question", "").strip()
    if not question:
        raise ValueError(f"question が空です row={row_no}")

    choices = [
        row.get("choice1", "").strip(),
        row.get("choice2", "").strip(),
        row.get("choice3", "").strip(),
        row.get("choice4", "").strip(),
    ]

    if any(not c for c in choices):
        raise ValueError(f"choice1〜choice4 に空欄があります row={row_no}: {question}")

    answer_index_1based = parse_int(row.get("answer_index", ""), "answer_index", row_no)
    if answer_index_1based not in (1, 2, 3, 4):
        raise ValueError(f"answer_index は1〜4である必要があります row={row_no}: {answer_index_1based}")

    importance = parse_int(row.get("importance", ""), "importance", row_no)
    difficulty = parse_int(row.get("difficulty", ""), "difficulty", row_no)

    if importance not in (1, 2, 3):
        raise ValueError(f"importance は1〜3である必要があります row={row_no}: {importance}")
    if difficulty not in (1, 2, 3):
        raise ValueError(f"difficulty は1〜3である必要があります row={row_no}: {difficulty}")

    is_free = parse_bool(row.get("is_free", ""), "is_free", row_no)

    tags = split_tags(row.get("tags", ""))
    if not tags:
        tags = [unit_id]
    elif tags[0] != unit_id:
        tags = [unit_id] + [t for t in tags if t != unit_id]

    return {
        "question": question,
        "choices": choices,
        "answerIndex": answer_index_1based - 1,
        "explanation": row.get("explanation", "").strip(),
        "tags": tags,
        "unitId": unit_id,
        "importance": importance,
        "difficulty": difficulty,
        "isPremium": not is_free
    }

def main():
    master_rows = read_csv(MASTER_PATH)
    if not master_rows:
        raise ValueError(f"masterが空です: {MASTER_PATH}")

    decks = {}

    for m in master_rows:
        status = m.get("status", "active").strip()
        if status and status != "active":
            continue

        deck_id = m["deck_id"].strip()
        deck_title = m["deck_title"].strip()
        deck_subtitle = m.get("deck_subtitle", "").strip()
        unit_id = m["unit_id"].strip()
        unit_title = m["unit_title_japanese"].strip()
        unit_no = parse_int(m["unit_no"], "unit_no", 0)
        source_tsv = m["source_tsv"].strip()

        if not os.path.exists(source_tsv):
            raise FileNotFoundError(f"source_tsv が見つかりません: {source_tsv}")

        rows = read_tsv(source_tsv)
        validate_columns(rows, source_tsv)

        cards = []
        for i, row in enumerate(rows, start=2):
            cards.append(card_from_row(row, i, unit_id))

        if deck_id not in decks:
            decks[deck_id] = {
                "id": deck_id,
                "title": deck_title,
                "subtitle": deck_subtitle,
                "isPurchased": False,
                "units": []
            }

        decks[deck_id]["units"].append({
            "id": unit_id,
            "title": unit_title,
            "unitNo": unit_no,
            "cards": cards
        })

    os.makedirs(OUT_DIR, exist_ok=True)

    for deck_id, deck in sorted(decks.items()):
        deck["units"].sort(key=lambda u: (u.get("unitNo", 9999), u["id"]))
        out_path = os.path.join(OUT_DIR, f"deck_{deck_id}.json")
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(deck, f, ensure_ascii=False, indent=2)

        card_count = sum(len(u["cards"]) for u in deck["units"])
        print(f"OK: {out_path} units={len(deck['units'])} cards={card_count}")

if __name__ == "__main__":
    main()
