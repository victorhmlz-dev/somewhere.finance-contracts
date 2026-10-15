// Fills the local chain (`npm run node`) with a launchpad and a few launches
// in different states, to develop the back and the front against.
//
//   npm run node          (in one terminal, leave it running)
//   npm run demo:local    (in another)
//
// Everything here is throwaway: the exchange is the test double and the
// accounts are the public ones every Hardhat node starts with.
import { network } from "hardhat";
import { parseEther } from "viem";

const { viem, networkHelpers } = await network.create();
const publicClient = await viem.getPublicClient();
const [deployer, creator, alice, bob] = await viem.getWalletClients();

const weth = await viem.deployContract("MockWETH");
const dexFactory = await viem.deployContract("MockFactory");
const launchpad = await viem.deployContract("Launchpad", [
  deployer.account.address,
  dexFactory.address,
  weth.address,
  deployer.account.address,
  50,
]);
const deployBlock = await publicClient.getBlockNumber();

const HOUR = 3600n;
const DAY = 24n * HOUR;

async function createLaunch(
  name: string,
  symbol: string,
  startsIn: bigint,
  changes: { hardCap?: bigint; liquidityBps?: number; vestingTranches?: number } = {},
) {
  const now = BigInt(await networkHelpers.time.latest());
  const launchId = await launchpad.read.launchCount();
  await launchpad.write.createLaunch(
    [
      {
        name,
        symbol,
        totalSupply: parseEther("1000000"),
        softCap: parseEther("2"),
        hardCap: changes.hardCap ?? parseEther("10"),
        minContribution: 0n,
        maxContribution: parseEther("6"),
        startTime: now + startsIn,
        endTime: now + startsIn + 7n * DAY,
        creatorAllocationBps: 100,
        liquidityBps: changes.liquidityBps ?? 7000,
        vestingTranches: changes.vestingTranches ?? 3,
      },
    ],
    { account: creator.account },
  );
  const launch = await launchpad.read.getLaunch([launchId]);
  return {
    startTime: now + startsIn,
    sale: await viem.getContractAt("TokenSale", launch.sale),
  };
}

// 1. Sold out, listed, and partly claimed.
const listed = await createLaunch("Void Token", "VOID", 5n, { vestingTranches: 12 });
await networkHelpers.time.increaseTo(listed.startTime);
await listed.sale.write.contribute({ account: alice.account, value: parseEther("6") });
await listed.sale.write.contribute({ account: bob.account, value: parseEther("4") });
await listed.sale.write.finalize();
await listed.sale.write.claim({ account: alice.account });

// 2. Live, about a third of the way.
const live = await createLaunch("Fauna Token", "FAUNA", 5n, {
  hardCap: parseEther("20"),
  liquidityBps: 8500,
});
await networkHelpers.time.increaseTo(live.startTime);
await live.sale.write.contribute({ account: alice.account, value: parseEther("4.5") });
await live.sale.write.contribute({ account: bob.account, value: parseEther("2") });

// 3. Upcoming: opens in two days.
await createLaunch("Neon Credits", "NEON", 2n * DAY);

// 4. Cancelled by its creator before it opened.
const cancelled = await createLaunch("Drift Coin", "DRIFT", 3n * DAY);
await cancelled.sale.write.cancel({ account: creator.account });

console.log("Launchpad deployed at", launchpad.address);
console.log("\nTo index it, add this line to the .env of somewhere.finance-back:\n");
console.log(
  `CHAINS=${JSON.stringify([
    {
      key: "local",
      family: "evm",
      chainId: 31337,
      name: "Local",
      nativeCurrency: { symbol: "ETH", name: "Ether", decimals: 18 },
      rpcUrl: "http://127.0.0.1:8545",
      launchpad: launchpad.address,
      startBlock: Number(deployBlock),
      confirmations: 0,
    },
  ])}`,
);
