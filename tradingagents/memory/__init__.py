"""Vector-DB RAG memory backend for TradingAgents.

The legacy flat-file decision log lives at `tradingagents.agents.utils.memory`
(`TradingMemoryLog`); this package adds a Qdrant-backed semantic-search
alternative that runs alongside the flat file during the dual-write migration.

Public surface:
- `MemoryRecord` (record.py): Pydantic schema for one decision + outcome.
"""

from tradingagents.memory.record import MemoryRecord

__all__ = ["MemoryRecord"]
