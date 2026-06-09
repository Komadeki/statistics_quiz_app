#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
master CSV から meta JSON を生成する

想定フォルダ：
- master: assets_src/csv/meta/deck_unit_master.csv
- out:    assets/decks/meta/

master の列（最低限）：
deck_id, deck_title, unit_no, unit_id, unit_title, assets_src_csv, free_count, status

free_count が空なら free_ratio から算出もできる（任意）。
"""

import argparse
import csv
import json
import os
from dataclasses import dataclass
from typing import Dict, List, Optional


# ---------------- util ----------------

def read_csv_rows(path: str) -> List[Dict[str, str]]:
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        rows = []
        for r in reader:
            rows.append({(k or "").strip(): ("" if v is None else str(v).strip()) for k, v in r.items()})
        return rows

def parse_int(s: str, default: int = 0) -> int:
    try:
        return int((s or "").strip())
    except Exception:
        return default

def safe_filename(s: str) -> str:
    # deck_id 前提なので基本そのまま。念のため。
    return "".join(ch for ch in s if ch.isalnum() or ch in ("_", "-", ".")).strip()

def count_cards_in_unit_csv(path: str) -> int:
    """
    unit CSV の行数（問題数）を数える。
    空行や無効行を厳密判定するのは units 生成側の責務なので、
    meta では「おおよその総行数」で十分ならこれでOK。
    """
    if not path or not os.path.exists(path):
        return 0
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        return sum(1 for _ in reader)

# ---------------- model ----------------

@dataclass
class UnitMeta:
    unit_id: str
    unit_title: str
    unit_no: int
    src_csv: str
    free_count: int
    status: str
    card_count: int = 0

@dataclass
class DeckMeta:
    deck_id: str
    deck_title: str
    status: str
    units: List[UnitMeta]


# ---------------- build ----------------

def build_decks_from_master(
    master_csv: str,
    only_deck: Optional[str],
    with_card_counts: bool,
    default_free_ratio: Optional[float],
) -> List[DeckMeta]:
    rows = read_csv_rows(master_csv)
    if not rows:
        raise ValueError(f"master が空です: {master_csv}")

    # フィルタ
    if only_deck:
        rows = [r for r in rows if r.get("deck_id") == only_deck]
        if not rows:
            raise ValueError(f"deck_id={only_deck} が master に見つかりません。")

    # deck_id ごとに集計
    grouped: Dict[str, List[Dict[str, str]]] = {}
    for r in rows:
        did = r.get("deck_id", "").strip()
        if not did:
            continue
        grouped.setdefault(did, []).append(r)

    decks: List[DeckMeta] = []
    for deck_id, items in grouped.items():
        # 並び順：unit_no → unit_id
        def _sort_key(rr):
            return (parse_int(rr.get("unit_no",""), 9999), rr.get("unit_id",""))
        items.sort(key=_sort_key)

        deck_title = (items[0].get("deck_title") or deck_id).strip()
        deck_status = (items[0].get("status") or "active").strip()

        units: List[UnitMeta] = []
        for r in items:
            unit_id = r.get("unit_id","").strip()
            unit_title = r.get("unit_title","").strip()
            unit_no = parse_int(r.get("unit_no",""), 9999)
            src_csv = r.get("assets_src_csv","").strip()
            status = (r.get("status") or "active").strip()

            if not (unit_id and unit_title):
                raise ValueError(f"master 行が不完全です（unit_id/unit_title 必須）: {r}")

            free_count = parse_int(r.get("free_count",""), 0)

            # free_count が無い運用なら、free_ratio から算出（任意）
            if free_count <= 0 and default_free_ratio is not None:
                n = count_cards_in_unit_csv(src_csv) if with_card_counts else 0
                if n > 0 and default_free_ratio > 0:
                    free_count = max(1, int(round(n * float(default_free_ratio))))

            card_count = count_cards_in_unit_csv(src_csv) if with_card_counts else 0

            units.append(UnitMeta(
                unit_id=unit_id,
                unit_title=unit_title,
                unit_no=unit_no,
                src_csv=src_csv,
                free_count=free_count,
                status=status,
                card_count=card_count,
            ))

        decks.append(DeckMeta(
            deck_id=deck_id,
            deck_title=deck_title,
            status=deck_status,
            units=units,
        ))

    # deck_id で安定ソート
    decks.sort(key=lambda d: d.deck_id)
    return decks


def deck_meta_to_json(deck: DeckMeta, include_src_csv: bool) -> Dict:
    """
    アプリが読む meta の形（おすすめ）
    - unit の cards は持たない
    - freeCount は unit 生成側にも使える
    """
    units = []
    for u in deck.units:
        obj = {
            "unitId": u.unit_id,
            "title": u.unit_title,
            "unitNo": u.unit_no,
            "freeCount": u.free_count,
            "status": u.status,
        }
        # 任意：meta にカード数を入れたいなら
        if u.card_count:
            obj["cardCount"] = u.card_count
        # 任意：CSV パスを meta に残す（通常は不要。ビルド用なら便利）
        if include_src_csv and u.src_csv:
            obj["srcCsv"] = u.src_csv
        units.append(obj)

    return {
        "deckId": deck.deck_id,
        "title": deck.deck_title,
        "status": deck.status,
        "units": units,
    }


def write_meta_files(
    decks: List[DeckMeta],
    out_dir: str,
    file_prefix: str,
    include_src_csv: bool,
) -> List[str]:
    os.makedirs(out_dir, exist_ok=True)
    written = []
    for d in decks:
        name = f"{file_prefix}{safe_filename(d.deck_id)}.json"
        out_path = os.path.join(out_dir, name)
        payload = deck_meta_to_json(d, include_src_csv=include_src_csv)
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        written.append(out_path)
    return written


# ---------------- CLI ----------------

def main():
    ap = argparse.ArgumentParser(description="master CSV → meta JSON 生成")
    ap.add_argument("--master", required=True, help="deck_unit_master.csv のパス")
    ap.add_argument("--out_dir", default="assets/decks/meta", help="出力先ディレクトリ")
    ap.add_argument("--prefix", default="meta_", help="ファイル名プレフィックス（例: meta_）")
    ap.add_argument("--only_deck", default="", help="deck_id を1つに絞る（任意）")
    ap.add_argument("--with_card_counts", action="store_true", help="unit CSV を読んで cardCount を入れる")
    ap.add_argument("--include_src_csv", action="store_true", help="meta に srcCsv を残す（ビルド/デバッグ向け）")
    ap.add_argument("--free_ratio", type=float, default=-1.0,
                    help="free_count が無いときの補助。例: 0.2（with_card_counts と併用推奨）")
    args = ap.parse_args()

    only = args.only_deck.strip() or None
    fr = None if args.free_ratio is None or args.free_ratio <= 0 else float(args.free_ratio)

    decks = build_decks_from_master(
        master_csv=args.master,
        only_deck=only,
        with_card_counts=bool(args.with_card_counts),
        default_free_ratio=fr,
    )

    paths = write_meta_files(
        decks=decks,
        out_dir=args.out_dir,
        file_prefix=args.prefix,
        include_src_csv=bool(args.include_src_csv),
    )

    print(f"OK: meta files={len(paths)}")
    for p in paths:
        print(f" - {p}")


if __name__ == "__main__":
    main()
