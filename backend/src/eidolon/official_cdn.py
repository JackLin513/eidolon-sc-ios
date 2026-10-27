"""The game's own asset server, which the ShinyColorsDB mirror copies its scripts and
stands from, byte for byte (ADR-0032): where the mirror asks for a file it cannot give.

A file is not under its path but under a hash of it, and its JSON and atlases are
gzipped and XORed with a key the game ships with; images are served as they are. The
gzip stream is never finished: it stops at a flush (`00 00 ff ff`), with no last block
and no checksum, so a file is whole when it ends there. The server does not need a
file's version from the game's asset map (`?v=` only busts caches: it always serves the
latest), and answers a path it has no file for with the game's page, as HTML, rather
than a 404.
"""

import hashlib
import zlib
from pathlib import PurePosixPath

ASSETS_URL = "https://shinycolors.enza.fun/assets"
XOR_KEY = b"B'KYWL[DI\\vqUIyw_we_are_hiring_https://knocknote.co.jp"
_ENCRYPTED = (".json", ".atlas")
_FLUSHED = b"\x00\x00\xff\xff"


def asset_url(path: str) -> str:
    """Where the server keeps the file at `path`, e.g. `json/produce_events/100100101.json`."""
    file = PurePosixPath(path.strip("/"))
    salt = file.stem[0] + file.stem[-1]
    return f"{ASSETS_URL}/{hashlib.sha256(f'{salt}/assets/{file}'.encode()).hexdigest()}"


def decode(path: str, content: bytes) -> bytes:
    """The file at `path` as the server sent it, decrypted if it is one it encrypts.
    Raises ValueError if it does not decrypt, or was cut short."""
    if not path.endswith(_ENCRYPTED):
        return content
    compressed = xor(content)
    gunzip = zlib.decompressobj(zlib.MAX_WBITS | 16)
    try:
        decoded = gunzip.decompress(compressed) + gunzip.flush()
    except zlib.error as e:
        raise ValueError(f"{path}：解不开（{e}）") from e
    if not gunzip.eof and not compressed.endswith(_FLUSHED):
        raise ValueError(f"{path}：只收到了一部分")
    return decoded


def xor(content: bytes) -> bytes:
    size = len(content)
    key = (XOR_KEY * (size // len(XOR_KEY) + 1))[:size]
    # As one big integer: a Spine skeleton runs to megabytes, byte by byte would take seconds.
    return (int.from_bytes(content) ^ int.from_bytes(key)).to_bytes(size)
