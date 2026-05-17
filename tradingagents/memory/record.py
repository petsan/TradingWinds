"""MemoryRecord — schema for one PM decision + its eventual outcome.

This is the unit of storage shared by the flat-file log (legacy) and the
Qdrant collection (new). Fields with `Optional[...]` default to None while
the trade is pending; they're filled in by the reflection pass on the next
same-ticker run.

The `embedding` field carries the vector during write but is excluded from
serialisation (Qdrant stores the vector separately on the point, not in the
payload; the flat-file path doesn't need it at all).
"""

from typing import Literal, Optional

from pydantic import BaseModel, Field


Rating = Literal["Buy", "Overweight", "Hold", "Underweight", "Sell"]
AssetType = Literal["stock", "crypto"]


class MemoryRecord(BaseModel):
    # Identity / primary key
    record_id: str  # f"{trade_date}:{ticker}"
    ticker: str
    trade_date: str  # ISO "YYYY-MM-DD"
    asset_type: AssetType
    benchmark: str  # "SPY", "^N225", ...

    # Decision payload
    rating: Rating
    decision_markdown: str  # full Portfolio Manager body
    decision_summary: Optional[str] = None  # one-line, for cheap re-ranking

    # Outcome (None while pending)
    raw_return: Optional[float] = None  # e.g. 0.042 → "+4.2%"
    alpha_return: Optional[float] = None
    holding_days: Optional[int] = None
    reflection: Optional[str] = None

    # Filter metadata — written to Qdrant payload, used in retrieval `must`/`should` clauses
    pending: bool = True
    sector: Optional[str] = None
    market_regime: Optional[str] = None  # "risk-on" | "risk-off" | "neutral"
    sentiment_regime: Optional[str] = None
    deep_think_model: Optional[str] = None

    # Schema versioning — bump when filter/payload shape changes
    schema_version: int = 1

    # Vector — populated by the embedder before upsert; excluded from `model_dump()`
    # so the payload written to Qdrant doesn't duplicate the vector data.
    embedding: Optional[list[float]] = Field(default=None, exclude=True)

    @classmethod
    def make_id(cls, trade_date: str, ticker: str) -> str:
        """Canonical record_id = '<trade_date>:<ticker>'."""
        return f"{trade_date}:{ticker}"
