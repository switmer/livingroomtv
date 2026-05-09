"""Stub for phase 3. Direct LG webOS control lives here when/if CEC falls short."""
from __future__ import annotations


async def on() -> None:
    raise NotImplementedError("LG direct control is phase 3. CEC via Apple TV handles power today.")


async def off() -> None:
    raise NotImplementedError("LG direct control is phase 3. CEC via Apple TV handles power today.")


async def set_input(source: str) -> None:
    raise NotImplementedError("LG direct control is phase 3.")
