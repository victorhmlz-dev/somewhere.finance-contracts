import { configVariable, defineConfig } from "hardhat/config";
import hardhatToolboxViem from "@nomicfoundation/hardhat-toolbox-viem";

// RPC URLs and private keys are never written here. Set them with
// `npx hardhat keystore set <NAME>` (encrypted on disk) or as environment
// variables. They are only read when a command uses that network.

// Testnet wallets, in this order. The first one deploys and is the default
// sender of every transaction; the other two play users when a launch is
// tried out by hand: one contributes, the other checks limits and refunds.
// The same keys work on every EVM testnet. What goes between the quotes is
// the NAME under which each private key is stored in the keystore, never a
// key or an address. The public address of each wallet is in its comment.
const testnetAccounts = [
  configVariable("DEPLOYER_PRIVATE_KEY"), // brave: 0xe7002ce14a6f77d2c1db1333DD565e27D773925D
  configVariable("TEST_WALLET_1_PRIVATE_KEY"), // chrome: 0x3EC3A76DAE95ec7f7126049e7ABEa474404fc319
  configVariable("TEST_WALLET_2_PRIVATE_KEY"), // opera: 0x53C46Bc3c1936E5153ec189A520492E1eEdb3CFB
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
    // The chain started by `npx hardhat node`, for developing the back and
    // the front. It uses the node's own funded accounts.
    localhost: {
      type: "http",
      chainType: "l1",
      url: "http://127.0.0.1:8545",
    },
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
