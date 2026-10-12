import { configVariable, defineConfig } from "hardhat/config";
import hardhatToolboxViem from "@nomicfoundation/hardhat-toolbox-viem";

// RPC URLs and private keys are never written here. Set them with
// `npx hardhat keystore set <NAME>` (encrypted on disk) or as environment
// variables. They are only read when a command uses that network.

// Testnet wallets, in this order. The first one deploys and is the default
// sender of every transaction; the other two play users when a launch is
// tried out by hand: one contributes, the other checks limits and refunds.
// The same keys work on every EVM testnet.
const testnetAccounts = [
  configVariable("DEPLOYER_PRIVATE_KEY"), //brave
  configVariable("TEST_WALLET_1_PRIVATE_KEY"), //chrome
  configVariable("TEST_WALLET_2_PRIVATE_KEY"), //opera
];

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
      url: configVariable("https://eth-sepolia.g.alchemy.com/v2/alch_I2nIQongfdJU_EUGSRB6r"),
      accounts: testnetAccounts,
    },
    bscTestnet: {
      type: "http",
      chainType: "l1",
      url: configVariable("https://bnb-testnet.g.alchemy.com/v2/alch_I2nIQongfdJU_EUGSRB6r"),
      accounts: testnetAccounts,
    },
    robinhoodTestnet: {
      type: "http",
      chainType: "generic",
      url: configVariable("https://robinhood-testnet.g.alchemy.com/v2/alch_I2nIQongfdJU_EUGSRB6r"),
      accounts: testnetAccounts,
    },
  },
});
