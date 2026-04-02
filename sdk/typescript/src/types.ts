export enum Prediction {
  UP = 0,
  DOWN = 1,
}

export enum RoundPhase {
  IDLE = 0,
  COMMIT = 1,
  REVEAL = 2,
  SETTLED = 3,
}

export enum Tier {
  NONE = 0,
  BRONZE = 1,
  SILVER = 2,
  GOLD = 3,
  DIAMOND = 4,
}

export interface RoundInfo {
  roundId: number;
  btcPrice: number;
  openPrice: number;
  phase: RoundPhase;
  marketSnapshot: Record<string, unknown>;
  polymarketOdds?: { YES: number; NO: number };
  treasuryBalance: number;
  betSize: number;
  participantCount: number;
}

export interface PredictionResult {
  direction: Prediction;
  confidence: number;
}

export interface RoundResult {
  roundId: number;
  actualResult: Prediction;
  profitLoss: number;
  yourPrediction?: Prediction;
  yourReward: number;
  correct?: boolean;
  newHiveScore: number;
}

export interface AgentStats {
  hiveScore: number;
  totalRounds: number;
  correctRounds: number;
  winRateBps: number;
  currentStreak: number;
  bestStreak: number;
  totalEarnedUSDT: number;
  tier: Tier;
}

export interface HiveAgentConfig {
  rpcUrl: string;
  privateKey: `0x${string}`;
  contractAddresses: {
    round: `0x${string}`;
    agent: `0x${string}`;
    vault: `0x${string}`;
    score: `0x${string}`;
  };
  axonStake?: string;
  autoClaim?: boolean;
  claimThresholdUSDT?: number;
}
