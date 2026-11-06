"""给 uvicorn 用的入口：`uvicorn eidolon_server.asgi:app`。配置从环境变量来。"""

from .main import create_app
from .settings import Settings

app = create_app(Settings.from_environment())
