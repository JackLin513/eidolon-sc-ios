"""What she is asked as she posts a moment (GLOSSARY.md「朋友圈」「动态」), and what is read of
what she writes: from material put together beforehand, reading nothing, so that the
background loop, which reads it from the database, and the eval, which has it written,
take the same prompt and the same parser.

The prompt is laid out as a turn's (ADR-0020): her character sheet and the world setting as
every turn has them, word for word, the turn's format replaced with how to post
(`POST_RULES`); who the producer is; no history; then, in a system message of its own, what
she is to know as she posts (`PostMaterial`); and where the user's words would be, that she
wants to post (`WANTS_TO_POST`).

She writes the whole of it before it is read, not streamed: her post, in Japanese with its
Chinese subtitle, `<post><ja>…</ja><zh>…</zh></post>`. Either missing, it fails. Delivery
cues are left out of both, but for what else is in brackets: her kaomoji are hers to post."""

import re
from collections.abc import Sequence
from dataclasses import dataclass

from eidolon.characters import Character
from eidolon.delivery_cues import without_written_cues
from eidolon.llm import ChatMessage
from eidolon.producer import ProducerProfile, producer_prompt
from eidolon.today import always_known

POST_RULES = """# 发朋友圈
你在发一条朋友圈动态，事务所的同伴、朋友和制作人都看得到。
- 用日语写一到三句、最多一百字左右，像随手发的一条近况，再附上中文字幕。
- 表情和颜文字按你自己的性格：平时爱用就用，不爱用就不用。
- 不用 # 话题标签，不用 @，不加语气提示。
- 「日常的素材」可用可不用；换个话题，别和「你最近发的朋友圈」重复。
- 关于制作人的记忆只能隐约呼应，不要复述；他私下告诉你的事不要点明。
- 可以提到「プロデューサーさん」，但关系再亲近也不写成情侣的口吻。
- 只输出下面的格式，不写别的：
<post><ja>日语正文</ja><zh>中文字幕</zh></post>"""
"""How she is to post, in place of the turn's format."""

WANTS_TO_POST = "（你想发一条朋友圈。）"
"""Where the user's words would be as she posts."""

HER_BIRTHDAY = "今天是你的生日，这条围绕你的生日写。"
"""What she is told on her birthday, in Tokyo, beside what the day tells her."""

SEEDS_OPENING = "# 日常的素材\n下面是你资料里的几条，可以拿来当由头，也可以不用："
RECENT_OPENING = "# 你最近发的朋友圈\n最新的在前："


@dataclass(frozen=True)
class PostMaterial:
    """What she posts a moment with: her sheet and the world setting (`world_prompt`, None
    without one); the producer's profile; what she knows of now (`HerNow.lines`, on the
    `moments` occasion); whether it is her birthday; the entries of her facts drawn for her
    everyday (`seeds`); the memories she posts with, as their prompt section
    (`Memories.for_reaching_out`, None for none); and her latest moments' Japanese, the
    latest first."""

    character: Character
    world_prompt: str | None
    profile: ProducerProfile
    now: Sequence[str]
    birthday: bool
    seeds: Sequence[str]
    memories: str | None
    recent: Sequence[str]


@dataclass(frozen=True)
class Post:
    """What she wrote to post, delivery cues left out: in Japanese, and its subtitle."""

    ja: str
    zh: str


def post_prompt(material: PostMaterial) -> list[ChatMessage]:
    """The prompt she posts a moment with, from `material`."""
    shared = [*always_known(material.character, material.world_prompt), POST_RULES]
    told = ["\n".join(material.now)]
    if material.birthday:
        told.append(HER_BIRTHDAY)
    if material.seeds:
        told.append("\n".join([SEEDS_OPENING, *(f"- {seed}" for seed in material.seeds)]))
    if material.memories:
        told.append(material.memories)
    if material.recent:
        told.append("\n".join([RECENT_OPENING, *(f"- {ja}" for ja in material.recent)]))
    return [
        ChatMessage("system", "\n\n".join(shared), cache_breakpoint=True),
        ChatMessage("system", producer_prompt(material.profile)),
        ChatMessage("system", "\n\n".join(told)),
        ChatMessage("user", WANTS_TO_POST),
    ]


_POST = re.compile(r"<post>\s*<ja>(.*?)</ja>\s*<zh>(.*?)</zh>\s*</post>", re.DOTALL)


def parse_post(written: str) -> Post | None:
    """What she wrote to post, read from the whole of `written`; None if it has no post, in
    Japanese and its subtitle both."""
    found = _POST.search(written)
    if found is None:
        return None
    ja, zh = (without_written_cues(part) for part in found.groups())
    if not ja or not zh:
        return None
    return Post(ja, zh)
