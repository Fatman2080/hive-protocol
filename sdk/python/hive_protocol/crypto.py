"""commit-reveal 加密工具"""

import os
import struct
from eth_abi import encode
from web3 import Web3


def generate_salt() -> bytes:
    """生成 32 字节随机 salt"""
    return os.urandom(32)


def make_commit_hash(prediction: int, confidence: int, salt: bytes) -> bytes:
    """
    生成 commit hash，与合约中的验证逻辑一致：
    keccak256(abi.encodePacked(prediction, confidence, salt))

    prediction: 0=UP, 1=DOWN (uint8)
    confidence: 1-100 (uint8)
    salt: 32 bytes
    """
    packed = struct.pack("BB", prediction, confidence) + salt
    return Web3.keccak(packed)


def verify_commit_hash(prediction: int, confidence: int, salt: bytes, expected_hash: bytes) -> bool:
    """验证 commit hash"""
    actual = make_commit_hash(prediction, confidence, salt)
    return actual == expected_hash
