"""Mock do oracle NDVI — em prod consultaria Sentinel-2/MapBiomas.

O scene_id identifica a cena usada; SHA-256 dele vai no evento on-chain
pra qualquer auditor conseguir baixar e recalcular o NDVI.
"""

from __future__ import annotations

import csv
import hashlib
from dataclasses import dataclass
from enum import IntEnum
from pathlib import Path


class Milestone(IntEnum):
    # mesma ordem do enum no contrato, não mudar
    M0 = 0
    M6 = 1
    M12 = 2
    M36 = 3


_NAME_TO_MILESTONE = {m.name: m for m in Milestone}


@dataclass(frozen=True)
class NdviReading:
    project_id: int
    milestone: Milestone
    survival_bps: int
    measured_at: str
    scene_id: str

    @property
    def data_source_hash(self) -> bytes:
        return hashlib.sha256(self.scene_id.encode()).digest()


def load_ndvi_feed(csv_path: Path) -> list[NdviReading]:
    out: list[NdviReading] = []
    with open(csv_path, encoding="utf-8") as fh:
        lines = [ln for ln in fh if not ln.startswith("#")]
    reader = csv.DictReader(lines)
    for row in reader:
        out.append(
            NdviReading(
                project_id=int(row["project_id"]),
                milestone=_NAME_TO_MILESTONE[row["milestone"]],
                survival_bps=int(row["survival_bps"]),
                measured_at=row["measured_at"],
                scene_id=row.get("scene_id", f"MOCK-{row['project_id']}-{row['milestone']}"),
            )
        )
    return out
