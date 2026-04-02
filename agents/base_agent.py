"""Agent 基类 — 提供公共配置和日志"""

import os
import logging
import sys

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)

COMMON_CONFIG = {
    "rpc_url": os.environ.get("RPC_URL", "https://mainnet-rpc.axonchain.ai/"),
    "contract_addresses": {
        "round": os.environ.get("HIVE_ROUND_ADDRESS", "0x" + "0" * 40),
        "agent": os.environ.get("HIVE_AGENT_ADDRESS", "0x" + "0" * 40),
        "vault": os.environ.get("HIVE_VAULT_ADDRESS", "0x" + "0" * 40),
        "score": os.environ.get("HIVE_SCORE_ADDRESS", "0x" + "0" * 40),
    },
}


def make_agent(key_env: str, stake: int = 100):
    """创建并注册一个 HiveAgent 实例"""
    from hive_protocol import HiveAgent

    pk = os.environ.get(key_env)
    if not pk:
        raise EnvironmentError(f"Missing env var: {key_env}")

    agent = HiveAgent(
        private_key=pk,
        **COMMON_CONFIG,
    )
    agent.register(stake_axon=stake)
    return agent
