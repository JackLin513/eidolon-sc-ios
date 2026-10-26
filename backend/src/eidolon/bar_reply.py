"""What the chat model writes of a visit (GLOSSARY.md「光顾」), and its streaming parser.

The model writes a visit a line at a time, hers in Japanese with its Chinese subtitle and
how she looks saying it, the producer's in Chinese only (ADR-0001), as the text turns' reply
format has it but with who says each:

    <her emotion="happy"><ja>いらっしゃい……じゃなくて、こんばんは。</ja><zh>欢迎……不对，晚上好。</zh></her>
    <producer>今天也辛苦了。</producer>
    <her emotion="calm" order="true"><ja>シュガーラッシュをお願い。</ja><zh>请给我一杯 Sugar Rush。</zh></her>

The line she orders in is marked `order="true"`. The parser hands over each line as soon as
it closes, so the first lines reach the browser before the rest is written. It forgives what
it can: her line without a subtitle has its Japanese for one; one without Japanese is left
out, as is the producer's without words; an emotion not of the seven is calm; whatever is
written outside the lines is left out. A line left open as the stream ends is taken as
closed there.
"""

import re
from dataclasses import dataclass
from typing import Literal, get_args

from eidolon.emotion import Emotion

Speaker = Literal["her", "producer"]

_OPENING = re.compile(r"<(her|producer)\b([^>]*)>")
_ATTRIBUTE = re.compile(r'(\w+)\s*=\s*"([^"]*)"')
_STARTS = ("<her", "<producer")


@dataclass(frozen=True)
class BarLine:
    """One line of a visit: hers, in Japanese with its Chinese subtitle, or the producer's,
    in Chinese only (`ja` empty)."""

    speaker: Speaker
    zh: str
    ja: str = ""
    emotion: Emotion = "calm"
    order: bool = False
    """Whether it is a line she orders in."""

    def shown(self) -> dict:
        """As the browser reads it, in a `line` event."""
        if self.speaker == "producer":
            return {"type": "line", "speaker": "producer", "zh": self.zh}
        return {
            "type": "line", "speaker": "her", "emotion": self.emotion, "ja": self.ja,
            "zh": self.zh,
        } | ({"order": True} if self.order else {})

    def written(self) -> str:
        """As the model wrote it, for the prompt of the calls after it."""
        if self.speaker == "producer":
            return f"<producer>{self.zh}</producer>"
        order = ' order="true"' if self.order else ""
        return f'<her emotion="{self.emotion}"{order}><ja>{self.ja}</ja><zh>{self.zh}</zh></her>'


class BarParser:
    """Turns a stream of text chunks into the lines of a visit, each as it closes."""

    def __init__(self) -> None:
        self._buffer = ""

    def feed(self, chunk: str) -> list[BarLine]:
        self._buffer += chunk
        lines = []
        while (taken := self._take()) is not None:
            if taken:
                lines.append(taken)
        return lines

    def finish(self) -> list[BarLine]:
        """What is left at the end of the stream: a line left open, as closed there."""
        left, self._buffer = self._buffer, ""
        opening = _OPENING.search(left)
        if opening is None:
            return []
        speaker = opening.group(1)
        inside = _unclosed(left[opening.end():], f"</{speaker}>")
        line = _line(speaker, opening.group(2), inside)
        return [line] if line else []

    def _take(self) -> BarLine | None | Literal[False]:
        """The next line closed in the buffer, taken out of it; False for one left out; None
        if no line has closed yet, the buffer then holding only what may be the start of
        one."""
        opening = _OPENING.search(self._buffer)
        if opening is None:
            self._buffer = self._buffer[_start_of_tag(self._buffer):]
            return None
        speaker = opening.group(1)
        close = f"</{speaker}>"
        end = self._buffer.find(close, opening.end())
        if end < 0:
            self._buffer = self._buffer[opening.start():]
            return None
        line = _line(speaker, opening.group(2), self._buffer[opening.end():end])
        self._buffer = self._buffer[end + len(close):]
        return line or False


def _line(speaker: str, attributes: str, inside: str) -> BarLine | None:
    """The line written as `inside` between the tags opening with `attributes`; None if it
    has no words to say."""
    if speaker == "producer":
        zh = _without_tags(inside)
        return BarLine("producer", zh) if zh else None
    ja, zh = _within(inside, "ja"), _within(inside, "zh")
    if not ja:
        return None
    named = dict(_ATTRIBUTE.findall(attributes))
    emotion = named.get("emotion", "calm")
    return BarLine(
        "her", zh or ja, ja,
        emotion if emotion in get_args(Emotion) else "calm",  # pyright: ignore[reportArgumentType]
        named.get("order") == "true",
    )


def _within(text: str, tag: str) -> str:
    """What `text` has between `<tag>` and its close, or the end of `text` if left open."""
    start = text.find(f"<{tag}>")
    if start < 0:
        return ""
    return _without_tags(_unclosed(text[start + len(tag) + 2:], f"</{tag}>"))


def _unclosed(text: str, close: str) -> str:
    """`text` up to `close`, or all of it but what may be the start of `close`."""
    end = text.find(close)
    if end >= 0:
        return text[:end]
    return text[:_start_of(text, (close,))]


def _without_tags(text: str) -> str:
    return re.sub(r"<[^>]*>?", "", text).strip()


def _start_of_tag(text: str) -> int:
    """Where what may be the start of a line's opening tag begins at the end of `text`."""
    opens = text.rfind("<")
    if opens >= 0 and ">" not in text[opens:]:
        tail = text[opens:]
        if any(s.startswith(tail) or tail.startswith(s) for s in _STARTS):
            return opens
    return len(text)


def _start_of(text: str, tags: tuple[str, ...]) -> int:
    for size in range(min(len(text), max(len(t) for t in tags) - 1), 0, -1):
        if any(t.startswith(text[-size:]) for t in tags):
            return len(text) - size
    return len(text)
