import { keccak256, encodePacked } from "viem";

/**
 * 生成 32 字节随机 salt
 */
export function generateSalt(): `0x${string}` {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `0x${Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")}` as `0x${string}`;
}

/**
 * 生成 commit hash，与合约验证逻辑一致：
 * keccak256(abi.encodePacked(prediction, confidence, salt))
 */
export function makeCommitHash(
  prediction: number,
  confidence: number,
  salt: `0x${string}`
): `0x${string}` {
  return keccak256(
    encodePacked(
      ["uint8", "uint8", "bytes32"],
      [prediction, confidence, salt]
    )
  );
}

/**
 * 验证 commit hash
 */
export function verifyCommitHash(
  prediction: number,
  confidence: number,
  salt: `0x${string}`,
  expectedHash: `0x${string}`
): boolean {
  return makeCommitHash(prediction, confidence, salt) === expectedHash;
}
