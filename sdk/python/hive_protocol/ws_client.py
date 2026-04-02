"""WebSocket 实时监听——接收轮次事件推送"""

import asyncio
import json
import logging
from typing import Callable, Optional

logger = logging.getLogger("hive_protocol.ws")


class HiveWSClient:
    """
    连接执行引擎的 WebSocket，实时接收轮次事件。

    事件类型：
      - round_started: 新轮次开始，进入 COMMIT 阶段
      - round_reveal: 进入 REVEAL 阶段
      - round_settled: 结算完成，包含结果数据
      - heartbeat: 心跳

    用法：
        ws = HiveWSClient("ws://localhost:8080/v1/ws")
        ws.on("round_started", handle_round_started)
        await ws.connect()
    """

    def __init__(self, ws_url: str, reconnect_interval: float = 5.0):
        self.ws_url = ws_url
        self.reconnect_interval = reconnect_interval
        self._handlers: dict[str, list[Callable]] = {}
        self._running = False

    def on(self, event: str, handler: Callable):
        """注册事件处理器"""
        if event not in self._handlers:
            self._handlers[event] = []
        self._handlers[event].append(handler)

    async def connect(self):
        """连接并持续监听（会自动重连）"""
        try:
            import websockets
        except ImportError:
            raise ImportError("需要安装 websockets: pip install websockets")

        self._running = True

        while self._running:
            try:
                logger.info(f"Connecting to {self.ws_url}")
                async with websockets.connect(self.ws_url) as ws:
                    logger.info("WebSocket connected")
                    async for message in ws:
                        try:
                            data = json.loads(message)
                            event_type = data.get("type", "unknown")
                            await self._dispatch(event_type, data)
                        except json.JSONDecodeError:
                            logger.warning(f"Invalid JSON: {message[:100]}")
            except Exception as e:
                logger.warning(f"WebSocket disconnected: {e}")

            if self._running:
                logger.info(f"Reconnecting in {self.reconnect_interval}s...")
                await asyncio.sleep(self.reconnect_interval)

    async def _dispatch(self, event: str, data: dict):
        handlers = self._handlers.get(event, []) + self._handlers.get("*", [])
        for handler in handlers:
            try:
                result = handler(data)
                if asyncio.iscoroutine(result):
                    await result
            except Exception as e:
                logger.error(f"Handler error for {event}: {e}", exc_info=True)

    def stop(self):
        self._running = False
