"""The prompt the upstream Python engine assembles for the oracle scenario.

Runs the real upstream ``ConversationEngine`` against a temporary copy of its content
database, with scripted replies instead of a model and no retrieval, so the same input
always gives the same prompt (ADR-0012). Its output is compared, verbatim, with the
iOS core's (``prompt-oracle``).

Usage:
    uv run --project ../eidolon-sc/backend python tools/oracle/upstream_prompt.py \
        --upstream ../eidolon-sc --scenario tools/oracle/scenario.json --out build/oracle/upstream.json
"""

from __future__ import annotations

import argparse
import asyncio
import json
import shutil
import sys
import tempfile
from collections.abc import AsyncIterator, Sequence
from datetime import datetime
from pathlib import Path


def date(text: str) -> datetime:
    return datetime.fromisoformat(text)


class RecordingLLM:
    """Replies from a script, in order, keeping every prompt it was given."""

    def __init__(self, replies: list[list[str]]) -> None:
        self._replies = list(replies)
        self.prompts: list[list[object]] = []

    def stream(self, messages: Sequence[object], tools: Sequence[object] = (), *,
               forbid_calls: bool = False) -> AsyncIterator[str]:
        self.prompts.append(list(messages))
        reply = self._replies.pop(0) if self._replies else ["<ja>うん</ja><zh>嗯</zh>"]
        return self._stream(reply)

    async def _stream(self, chunks: list[str]) -> AsyncIterator[str]:
        for chunk in chunks:
            yield chunk


def find_reply(history: dict[str, str]) -> list[str]:
    return [f"<ja>{history['ja']}</ja><zh>{history['zh']}</zh>"]


async def run(upstream: Path, scenario: dict) -> list[dict[str, str]]:
    sys.path.insert(0, str(upstream / "backend" / "src"))
    import eidolon.engine
    import eidolon.store
    from eidolon.characters import load_characters
    from eidolon.data_access import Database
    from eidolon.engine import ConversationEngine
    from eidolon.llm import TurnLLMs
    from eidolon.memory import Memories
    from eidolon.store import Store
    from eidolon.titles import Titles
    from eidolon.world import load_world, world_path

    characters_path = upstream / "characters" / "characters.toml"
    characters = load_characters(characters_path)
    world = load_world(world_path(characters_path))

    workdir = Path(tempfile.mkdtemp(prefix="eidolon-oracle-"))
    try:
        database = workdir / "eidolon.db"
        shutil.copy(upstream / "backend" / "data" / "eidolon.db", database)
        db = Database(database)
        try:
            store = Store(db)
            clock_state = {"now": date(scenario["start"])}

            def clock() -> datetime:
                return clock_state["now"]

            # Messages carry the scenario's clock, not the wall clock: the same input is
            # always the same prompt.
            eidolon.engine.timestamp = lambda: clock_state["now"].isoformat()
            eidolon.store._now = lambda: clock_state["now"].isoformat()

            memory = Memories(db, characters, clock)
            titles = Titles(store, characters, {})
            engine = ConversationEngine(
                db, store, characters, {}, memory, titles, clock, world=world
            )

            user = await store.create_user("Oracle Producer")
            conversation = await store.create_conversation(
                user.id, scenario["character_id"]
            )

            llm = RecordingLLM([find_reply(turn) for turn in scenario["history"]])
            llms = TurnLLMs(chat=llm, background=llm)
            for turn in scenario["history"]:
                async for _ in engine.turn(conversation, turn["user"], llms):
                    pass

            clock_state["now"] = date(scenario["now"])
            from eidolon.engine import InCall

            in_call = (
                InCall(0, ())
                if scenario.get("talking") == "inCall"
                else None
            )
            async for _ in engine.turn(
                conversation, scenario["message"], llms,
                device_timezone=scenario["timezone"],
                in_call=in_call,
                voiced_by=scenario.get("voice_model"),
            ):
                pass
            prompt = llm.prompts[-1]
            return [
                {"role": message.role, "content": message.content}
                for message in prompt
            ]
        finally:
            await db.close()
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", default="../eidolon-sc")
    parser.add_argument("--scenario", default="tools/oracle/scenario.json")
    parser.add_argument("--out", default="build/oracle/upstream.json")
    args = parser.parse_args()

    scenario = json.loads(Path(args.scenario).read_text(encoding="utf-8"))
    prompt = asyncio.run(run(Path(args.upstream).resolve(), scenario))
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(prompt, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {out} ({len(prompt)} messages)")


if __name__ == "__main__":
    main()
