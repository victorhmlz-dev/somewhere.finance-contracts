import { configVariable, defineConfig } from "hardhat/config";
import hardhatToolboxViem from "@nomicfoundation/hardhat-toolbox-viem";

// RPC URLs and the deployer key are never written here. Set them with
// `npx hardhat keystore set <NAME>` (encrypted on disk) or as environment
// variables. They are only read when a command uses that network.
export default defineConfig({
  plugins: [hardhatToolboxViem],
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
    },
    bscTestnet: {
      type: "http",
      chainType: "l1",
      url: configVariable("BSC_TESTNET_RPC_URL"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
    },
    robinhoodTestnet: {
      type: "http",
      chainType: "generic",
      url: configVariable("ROBINHOOD_TESTNET_RPC_URL"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
    },
  },
});
