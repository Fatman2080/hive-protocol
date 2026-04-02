"""链上合约交互封装"""

import json
from pathlib import Path
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

# ABI 路径（从 Foundry 编译产物加载）
ABI_DIR = Path(__file__).parent.parent.parent.parent / "contracts" / "out"


def load_abi(contract_name: str) -> list:
    """从 Foundry out/ 目录加载 ABI"""
    abi_path = ABI_DIR / f"{contract_name}.sol" / f"{contract_name}.json"
    if not abi_path.exists():
        raise FileNotFoundError(f"ABI not found: {abi_path}. Run `forge build` first.")
    with open(abi_path) as f:
        artifact = json.load(f)
    return artifact["abi"]


class HiveContracts:
    """蜂巢合约集合——封装所有链上交互"""

    def __init__(self, rpc_url: str, private_key: str, addresses: dict):
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        self.w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
        self.account = self.w3.eth.account.from_key(private_key)

        self.round_contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(addresses["round"]),
            abi=load_abi("HiveRound"),
        )
        self.agent_contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(addresses["agent"]),
            abi=load_abi("HiveAgent"),
        )
        self.vault_contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(addresses["vault"]),
            abi=load_abi("HiveVault"),
        )
        self.score_contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(addresses["score"]),
            abi=load_abi("HiveScore"),
        )

    def _send_tx(self, fn):
        """构建、签名、发送交易"""
        tx = fn.build_transaction({
            "from": self.account.address,
            "nonce": self.w3.eth.get_transaction_count(self.account.address),
            "gas": 500_000,
            "gasPrice": self.w3.eth.gas_price,
        })
        signed = self.account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)
        return receipt

    # ─── 注册 ─────────────────────────────────────────

    def register(self, axon_amount: int):
        """注册并质押 AXON"""
        return self._send_tx(
            self.agent_contract.functions.register(axon_amount)
        )

    # ─── 预测 ─────────────────────────────────────────

    def commit(self, round_id: int, commit_hash: bytes):
        """提交加密预测"""
        return self._send_tx(
            self.round_contract.functions.commit(round_id, commit_hash)
        )

    def reveal(self, round_id: int, prediction: int, confidence: int, salt: bytes):
        """揭示预测"""
        return self._send_tx(
            self.round_contract.functions.reveal(round_id, prediction, confidence, salt)
        )

    # ─── 领取 ─────────────────────────────────────────

    def claim(self):
        """领取 USDT 奖励"""
        return self._send_tx(
            self.vault_contract.functions.claim()
        )

    # ─── 只读查询 ──────────────────────────────────────

    def get_current_round_id(self) -> int:
        return self.round_contract.functions.currentRoundId().call()

    def get_round(self, round_id: int) -> dict:
        data = self.round_contract.functions.getRound(round_id).call()
        return {
            "phase": data[0],
            "open_price": data[1],
            "close_price": data[2],
            "up_weight": data[3],
            "down_weight": data[4],
            "participant_count": data[5],
            "bet_amount": data[6],
            "profit_loss": data[7],
            "start_time": data[8],
        }

    def get_score(self, address: str) -> int:
        return self.score_contract.functions.getScore(
            Web3.to_checksum_address(address)
        ).call()

    def get_pending_reward(self, address: str) -> int:
        return self.vault_contract.functions.pendingReward(
            Web3.to_checksum_address(address)
        ).call()

    def get_treasury_balance(self) -> int:
        return self.vault_contract.functions.treasuryBalance().call()

    def is_active(self, address: str) -> bool:
        return self.agent_contract.functions.isActive(
            Web3.to_checksum_address(address)
        ).call()
