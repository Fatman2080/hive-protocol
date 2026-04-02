import {
  createPublicClient,
  createWalletClient,
  http,
  type PublicClient,
  type WalletClient,
  type Chain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import type {
  HiveAgentConfig,
  PredictionResult,
  RoundInfo,
  RoundResult,
  RoundPhase,
  Prediction,
} from "./types";
import { generateSalt, makeCommitHash } from "./crypto";

const axonChain: Chain = {
  id: 8210,
  name: "Axon Mainnet",
  nativeCurrency: { name: "AXON", symbol: "AXON", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://mainnet-rpc.axonchain.ai/"] },
  },
};

type PredictFn = (roundInfo: RoundInfo) => PredictionResult | Promise<PredictionResult>;
type ResultFn = (result: RoundResult) => void | Promise<void>;

/**
 * HiveAgent — TypeScript SDK 核心类
 *
 * ```ts
 * const agent = new HiveAgent({ rpcUrl, privateKey, contractAddresses });
 * await agent.register();
 *
 * agent.onNewRound(async (round) => {
 *   return { direction: Prediction.UP, confidence: 70 };
 * });
 *
 * agent.start();
 * ```
 */
export class HiveAgent {
  private publicClient: PublicClient;
  private walletClient: WalletClient;
  private config: HiveAgentConfig;
  private predictFn?: PredictFn;
  private resultFn?: ResultFn;
  private running = false;
  private lastRoundId = 0;
  private pendingReveal?: {
    roundId: number;
    prediction: number;
    confidence: number;
    salt: `0x${string}`;
  };

  public readonly address: `0x${string}`;

  constructor(config: HiveAgentConfig) {
    this.config = config;
    const account = privateKeyToAccount(config.privateKey);
    this.address = account.address;

    this.publicClient = createPublicClient({
      chain: { ...axonChain, rpcUrls: { default: { http: [config.rpcUrl] } } },
      transport: http(config.rpcUrl),
    });

    this.walletClient = createWalletClient({
      account,
      chain: { ...axonChain, rpcUrls: { default: { http: [config.rpcUrl] } } },
      transport: http(config.rpcUrl),
    });
  }

  /**
   * 注册预测回调
   */
  onNewRound(fn: PredictFn): void {
    this.predictFn = fn;
  }

  /**
   * 注册结算结果回调
   */
  onRoundResult(fn: ResultFn): void {
    this.resultFn = fn;
  }

  /**
   * 注册并质押
   */
  async register(): Promise<void> {
    console.log(`[HiveAgent] Registering ${this.address.slice(0, 10)}...`);
    // TODO: 调用 HiveAgent.register(axonAmount)
    console.log("[HiveAgent] Registered successfully");
  }

  /**
   * 启动 Agent 主循环
   */
  async start(pollIntervalMs = 5000): Promise<void> {
    if (!this.predictFn) {
      throw new Error("No prediction function registered. Call onNewRound() first.");
    }

    this.running = true;
    console.log(`[HiveAgent] Agent ${this.address.slice(0, 10)}... started`);

    while (this.running) {
      try {
        await this.pollRound();
      } catch (err) {
        console.error("[HiveAgent] Poll error:", err);
      }
      await this.sleep(pollIntervalMs);
    }
  }

  /**
   * 停止 Agent
   */
  stop(): void {
    this.running = false;
  }

  /**
   * 查询战绩
   */
  async getStats(): Promise<{ hiveScore: number; pending: number }> {
    // TODO: 从链上读取
    return { hiveScore: 50, pending: 0 };
  }

  // ─── Private ───────────────────────────────────────

  private async pollRound(): Promise<void> {
    // TODO: 读取链上 currentRoundId 和 round data
    // 这里是占位逻辑，实际需要调用合约
    const currentRoundId = 0; // await publicClient.readContract(...)

    if (currentRoundId === 0 || currentRoundId === this.lastRoundId) {
      return;
    }

    // const roundData = await this.publicClient.readContract(...)
    // if (phase === COMMIT) this.handleCommit(...)
    // if (phase === SETTLED) this.handleSettled(...)
  }

  private async handleCommit(roundId: number, roundInfo: RoundInfo): Promise<void> {
    if (!this.predictFn) return;

    const result = await this.predictFn(roundInfo);

    if (result.confidence < 1 || result.confidence > 100) {
      console.error(`[HiveAgent] Invalid confidence ${result.confidence}, skipping`);
      return;
    }

    const salt = generateSalt();
    const commitHash = makeCommitHash(result.direction, result.confidence, salt);

    console.log(
      `[HiveAgent] Round ${roundId}: committing ${result.direction === 0 ? "UP" : "DOWN"} ` +
        `confidence=${result.confidence}`
    );

    // TODO: 发送 commit 交易
    // await this.walletClient.writeContract({
    //   address: this.config.contractAddresses.round,
    //   abi: HiveRoundABI,
    //   functionName: "commit",
    //   args: [BigInt(roundId), commitHash],
    // });

    this.pendingReveal = {
      roundId,
      prediction: result.direction,
      confidence: result.confidence,
      salt,
    };
  }

  private async handleReveal(): Promise<void> {
    if (!this.pendingReveal) return;

    const { roundId, prediction, confidence, salt } = this.pendingReveal;

    console.log(`[HiveAgent] Round ${roundId}: revealing`);

    // TODO: 发送 reveal 交易
    // await this.walletClient.writeContract({
    //   address: this.config.contractAddresses.round,
    //   abi: HiveRoundABI,
    //   functionName: "reveal",
    //   args: [BigInt(roundId), prediction, confidence, salt],
    // });

    this.pendingReveal = undefined;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
