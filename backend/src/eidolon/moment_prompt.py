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
cues are left out of both, but for what else is in brackets: her kaomoji are hers to post.
Then where she is, `<place>…</place>`: one of the places she was given (`PostMaterial.places`)
by its identifier, or none. One she was not given, or none written where she was given any,
is made do without: the moment has no place, none drawn in its stead, and it is told
(`Post.degraded`, `PLACE`).

She is told of her circle (`PostMaterial.circle`), those who may like and comment on her
moment: each by identifier and name, what her facts say of her, and how she speaks (her
sheet's sections in `SPEAKS`). She writes who likes it, `<likes>…</likes>`, and each comment,
in the order they show, `<comment from="…"><ja>…</ja><zh>…</zh></comment>`, naming them by
identifier, though their names and short names will do. Each part is made do without on its
own, and told: a list of likes not written is no one's (`NO_LIKES`); one not in her circle
is left out (`OUTSIDE_LIKER`), as is a comment by one, or without its Japanese or its subtitle
(`BROKEN_COMMENT`); those over as many as `LIKES` and `COMMENTS`, or on her birthday
`BIRTHDAY_LIKES` and `BIRTHDAY_COMMENTS`, are left out, the last first (`LIKES_OVER`,
`COMMENTS_OVER`)."""

import re
from collections import Counter
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field

from eidolon.characters import Character, parse_facts
from eidolon.delivery_cues import without_written_cues
from eidolon.llm import ChatMessage
from eidolon.place_pool import Place
from eidolon.producer import ProducerProfile, producer_prompt
from eidolon.today import always_known

POST_RULES = """# 发朋友圈
你在发一条朋友圈动态，事务所的同伴、朋友和制作人都看得到。
- 用日语写一到三句、最多一百字左右，像随手发的一条近况，再附上中文字幕。
- 表情和颜文字按你自己的性格：平时爱用就用，不爱用就不用。
- 不用 # 话题标签，不用 @，不加语气提示。
- 有「今天做完的工作」时，把这几项串成一条写；「日常的素材」可用可不用。
- 换个话题，别和「你最近发的朋友圈」重复。
- 关于制作人的记忆只能隐约呼应，不要复述；他私下告诉你的事不要点明。
- 可以提到「プロデューサーさん」，但关系再亲近也不写成情侣的口吻。
- 「此刻」里没写天气时，正文别提天气和冷热。
- 地点只能从「地点候选」里挑一个，写它的 id；在家、在宿舍，或者候选里没有合适的，写 none。
- 正文里提不提地名随你，要提就用日语自然地写。
- 标了「你的卡面在这里拍过」的候选，只借那里的景，不说「这是我那张卡拍的地方」。
- 「圈子成员」里的人会来赞、来评论，人数照那一节说的；名单里只写她们的 id。
- 每条评论用评论的人自己的口吻（照她的自称、称呼和口癖），一两句、最多四十字左右，日语加中文字幕。
- 评论只回应正文里写出来的东西，以及她和你之间的关系；正文里没写的事不提，不对制作人说话。
- 评论按出现的先后写，后面的可以顺着前面的接一句。
- 只输出下面的格式，不写别的：
<post><ja>日语正文</ja><zh>中文字幕</zh></post>
<place>候选的 id 或 none</place>
<likes>来赞的人的 id，用逗号隔开</likes>
<comment from="评论的人的 id"><ja>日语</ja><zh>中文字幕</zh></comment>（一条评论一个，没人评论就不写）"""
"""How she is to post, in place of the turn's format."""

WANTS_TO_POST = "（你想发一条朋友圈。）"
"""Where the user's words would be as she posts."""

HER_BIRTHDAY = "今天是你的生日，这条围绕你的生日写。"
"""What she is told on her birthday, in Tokyo, beside what the day tells her."""

JOBS_OPENING = "# 今天做完的工作\n制作人今天给你排的、你都做完了："
SEEDS_OPENING = "# 日常的素材\n下面是你资料里的几条，可以拿来当由头，也可以不用："
RECENT_OPENING = "# 你最近发的朋友圈\n最新的在前："
CIRCLE_OPENING = "# 圈子成员\n下面这几位会看到这条动态。挑 1 到 {likes} 位来赞，0 到 {comments} 位来评论："
NO_CIRCLE = "# 圈子成员\n这次没有人会来，<likes> 留空，不写 <comment>。"
PLACES_OPENING = "# 地点候选\n你这会儿可能在下面某一处，也可能哪儿都没去："
NO_PLACES = "# 地点候选\n这次没有候选，写 none。"

RELATION = "你资料里关于她的："
"""What opens what her facts say of one of her circle."""

SPEAKS = (("自称", "她的自称："), ("对他人的称呼", "她对他人的称呼："), ("口癖", "她的口癖："))
"""The sections of the sheet of one of her circle she is told, by heading, and what opens
each."""

LIKES, COMMENTS = 6, 3
"""How many likes and comments are kept at most."""

BIRTHDAY_LIKES, BIRTHDAY_COMMENTS = 10, 6
"""How many likes and comments are kept at most on her birthday."""

HOLY_SITE = "（你的卡面在这里拍过）"
"""What marks a place she is given that is her holy site."""

NONE = "none"
"""What she writes for being at none of the places."""

PLACE = "place"
"""What `Post.degraded` names a place made do without by."""

NO_LIKES = "likes"
"""What `Post.degraded` names a list of likes not written by."""

OUTSIDE_LIKER = "liker"
"""What `Post.degraded` names one liking it who is not in her circle by."""

BROKEN_COMMENT = "comment"
"""What `Post.degraded` names a comment by one not in her circle, or broken, by."""

LIKES_OVER, COMMENTS_OVER = "likes_over", "comments_over"
"""What `Post.degraded` names likes and comments over as many as are kept by."""


@dataclass(frozen=True)
class Member:
    """One of her circle, and what her facts say of her, the section on her without its
    heading (None for none)."""

    character: Character
    relation: str | None = None


@dataclass(frozen=True)
class PostMaterial:
    """What she posts a moment with: her sheet and the world setting (`world_prompt`, None
    without one); the producer's profile; what she knows of now (`HerNow.lines`, on the
    `moments` occasion); whether it is her birthday; the entries of her facts drawn for her
    everyday (`seeds`); the memories she posts with, as their prompt section
    (`Memories.for_reaching_out`, None for none); her latest moments' Japanese, the
    latest first; the places she may be at; of her work moment, her jobs done that day,
    each its name and what it is, in the order done, in place of seeds; and her circle."""

    character: Character
    world_prompt: str | None
    profile: ProducerProfile
    now: Sequence[str]
    birthday: bool
    seeds: Sequence[str]
    memories: str | None
    recent: Sequence[str]
    places: Sequence[Place] = ()
    jobs: Sequence[str] = ()
    circle: Sequence[Member] = ()


@dataclass(frozen=True)
class Comment:
    """A comment on her moment by one of her circle, delivery cues left out: in Japanese,
    and its subtitle."""

    character_id: str
    ja: str
    zh: str


@dataclass(frozen=True)
class Post:
    """What she wrote to post, delivery cues left out: in Japanese, and its subtitle; the
    place she was at, of those given, None for none; who of her circle likes it, by
    identifier; the comments on it, in the order they show; and which parts of what she wrote
    were made do without, and how many of each."""

    ja: str
    zh: str
    place: Place | None = None
    likes: Sequence[str] = ()
    comments: Sequence[Comment] = ()
    degraded: Mapping[str, int] = field(default_factory=dict)


def post_prompt(material: PostMaterial) -> list[ChatMessage]:
    """The prompt she posts a moment with, from `material`."""
    shared = [*always_known(material.character, material.world_prompt), POST_RULES]
    told = ["\n".join(material.now)]
    if material.birthday:
        told.append(HER_BIRTHDAY)
    if material.jobs:
        told.append("\n".join([JOBS_OPENING, *(f"- {job}" for job in material.jobs)]))
    if material.seeds:
        told.append("\n".join([SEEDS_OPENING, *(f"- {seed}" for seed in material.seeds)]))
    if material.memories:
        told.append(material.memories)
    if material.recent:
        told.append("\n".join([RECENT_OPENING, *(f"- {ja}" for ja in material.recent)]))
    told.append(_circle(material.circle, material.birthday))
    told.append(
        "\n".join([PLACES_OPENING, *(_candidate(p, material.character.id) for p in material.places)])
        if material.places else NO_PLACES
    )
    return [
        ChatMessage("system", "\n\n".join(shared), cache_breakpoint=True),
        ChatMessage("system", producer_prompt(material.profile)),
        ChatMessage("system", "\n\n".join(told)),
        ChatMessage("user", WANTS_TO_POST),
    ]


def _circle(circle: Sequence[Member], birthday: bool) -> str:
    """Her circle as she is told it, and how many of them may like and comment."""
    if not circle:
        return NO_CIRCLE
    likes, comments = _most(birthday)
    lines = [CIRCLE_OPENING.format(likes=likes, comments=comments)]
    for member in circle:
        lines.append(f"## {member.character.id}：{member.character.name}")
        if member.relation:
            lines += [RELATION, member.relation]
        sections = sheet_sections(member.character.sheet)
        for heading, opening in SPEAKS:
            if heading in sections:
                lines += [opening, sections[heading]]
    return "\n".join(lines)


def sheet_sections(sheet: str) -> dict[str, str]:
    """What is under each heading of `sheet`, by the heading alone."""
    return {fact.headings[-1]: fact.body for fact in parse_facts(sheet) if fact.headings}


def _candidate(place: Place, character_id: str) -> str:
    """A place she may be at, as she is told it: marked if it is her holy site."""
    holy = HOLY_SITE if place.source is not None and character_id in place.idols else ""
    return f"- {place.id}：{place.name}（{place.area}）{place.note}{holy}"


def _most(birthday: bool) -> tuple[int, int]:
    """How many likes and comments are kept at most, on her birthday or not."""
    return (BIRTHDAY_LIKES, BIRTHDAY_COMMENTS) if birthday else (LIKES, COMMENTS)


_POST = re.compile(r"<post>\s*<ja>(.*?)</ja>\s*<zh>(.*?)</zh>\s*</post>", re.DOTALL)
_PLACE = re.compile(r"<place>(.*?)</place>", re.DOTALL)
_LIKES = re.compile(r"<likes>(.*?)</likes>", re.DOTALL)
_BETWEEN_NAMES = re.compile(r"[\s,，、`]+")
_COMMENT = re.compile(
    r"""<comment\s+from\s*=\s*["']?([^"'>]*?)["']?\s*>(.*?)</comment>""", re.DOTALL
)
_JA = re.compile(r"<ja>(.*?)</ja>", re.DOTALL)
_ZH = re.compile(r"<zh>(.*?)</zh>", re.DOTALL)


def parse_post(written: str, material: PostMaterial) -> Post | None:
    """What she wrote to post, read from the whole of `written`, as she was told `material`:
    the places she was given, her circle, whether it is her birthday. None if it has no post,
    in Japanese and its subtitle both."""
    found = _POST.search(written)
    if found is None:
        return None
    ja, zh = (without_written_cues(part) for part in found.groups())
    if not ja or not zh:
        return None
    degraded: Counter[str] = Counter()
    at = _PLACE.search(written)
    chosen = at[1].strip() if at else None
    place = next((p for p in material.places if p.id == chosen), None)
    if place is None and chosen != NONE and (chosen is not None or bool(material.places)):
        degraded[PLACE] += 1
    known = {
        name: m.character.id
        for m in material.circle
        for name in (m.character.id, m.character.name, m.character.short_name) if name
    }
    likes: list[str] = []
    listed = _LIKES.search(written)
    if listed is None:
        degraded[NO_LIKES] += 1
    else:
        for name in _BETWEEN_NAMES.split(listed[1]):
            if name in known:
                if known[name] not in likes:
                    likes.append(known[name])
            elif name and name != NONE:
                degraded[OUTSIDE_LIKER] += 1
    comments: list[Comment] = []
    for by, body in _COMMENT.findall(written):
        said = [without_written_cues(f[1]) if (f := tag.search(body)) else "" for tag in (_JA, _ZH)]
        if by.strip() in known and all(said):
            comments.append(Comment(known[by.strip()], *said))
        else:
            degraded[BROKEN_COMMENT] += 1
    most_likes, most_comments = _most(material.birthday)
    if len(likes) > most_likes:
        degraded[LIKES_OVER] = len(likes) - most_likes
    if len(comments) > most_comments:
        degraded[COMMENTS_OVER] = len(comments) - most_comments
    return Post(ja, zh, place, likes[:most_likes], comments[:most_comments], dict(degraded))
