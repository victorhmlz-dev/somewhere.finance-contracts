// Fills the local chain (`npm run node`) with a v2 and a v3 launchpad and a
// few launches in different states, to develop the back and the front against.
//
//   npm run node          (in one terminal, leave it running)
//   npm run demo:local    (in another)
//
// Everything here is throwaway: the exchange is the test double and the
// accounts are the public ones every Hardhat node starts with.
import { network } from "hardhat";
import { parseEther, parseUnits } from "viem";

const { viem, networkHelpers } = await network.create();
const publicClient = await viem.getPublicClient();
const wallets = await viem.getWalletClients();
const [deployer, creator, alice, bob] = wallets;

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

// The v3 launchpad, next to the v2 one: launches paired with any asset it
// allows. Here, a test dollar with 6 decimals and the native currency.
const v3Block = await publicClient.getBlockNumber();
const saleImplementation = await viem.deployContract("TokenSaleV3");
const vestingImplementation = await viem.deployContract("CreatorVestingV3");
const launchpadV3 = await viem.deployContract("LaunchpadV3", [
  deployer.account.address,
  dexFactory.address,
  weth.address,
  saleImplementation.address,
  vestingImplementation.address,
  deployer.account.address,
  50,
]);
const dollar = await viem.deployContract("MockStablecoin");
const usd = (amount: string) => parseUnits(amount, 6);
await launchpadV3.write.setQuoteAsset([dollar.address, true, usd("10")]);
await launchpadV3.write.setQuoteAsset([weth.address, true, parseEther("0.01")]);
// Every test account gets test dollars to buy with from the browser
for (const wallet of wallets) {
  await dollar.write.mint([wallet.account.address, usd("100000")]);
}

async function createV3Launch(
  name: string,
  symbol: string,
  quoteAsset: `0x${string}`,
  startsIn: bigint,
  caps: { softCap: bigint; hardCap: bigint },
) {
  const now = BigInt(await networkHelpers.time.latest());
  const launchId = await launchpadV3.read.launchCount();
  await launchpadV3.write.createLaunch(
    [
      {
        name,
        symbol,
        totalSupply: parseEther("1000000"),
        quoteAsset,
        softCap: caps.softCap,
        hardCap: caps.hardCap,
        minContribution: 0n,
        maxContribution: 0n,
        startTime: now + startsIn,
        endTime: now + startsIn + 7n * DAY,
        creatorAllocationBps: 100,
        liquidityBps: 7000,
        vestingTranches: 3,
        requiredTier: 0,
      },
    ],
    { account: creator.account },
  );
  const launch = await launchpadV3.read.getLaunch([launchId]);
  return {
    startTime: now + startsIn,
    sale: await viem.getContractAt("TokenSaleV3", launch.sale),
  };
}

// 5. Paired with the test dollar, live.
const dollarLaunch = await createV3Launch("Orbit Token", "ORBIT", dollar.address, 5n, {
  softCap: usd("2000"),
  hardCap: usd("10000"),
});
await networkHelpers.time.increaseTo(dollarLaunch.startTime);
for (const [wallet, amount] of [
  [alice, usd("3000")],
  [bob, usd("1500")],
] as const) {
  await dollar.write.approve([dollarLaunch.sale.address, amount], { account: wallet.account });
  await dollarLaunch.sale.write.contribute([amount, { tier: 0, expiresAt: 0n, signature: "0x" }], {
    account: wallet.account,
  });
}

// 6. Paired with the native currency on v3, upcoming.
await createV3Launch("Pulse Token", "PULSE", weth.address, 2n * DAY, {
  softCap: parseEther("2"),
  hardCap: parseEther("10"),
});

console.log("Launchpad v2 deployed at", launchpad.address);
console.log("Launchpad v3 deployed at", launchpadV3.address);
console.log("Test dollar (MUSD, 6 decimals) at", dollar.address);
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
      launchpads: [
        { address: launchpad.address, version: 2, startBlock: Number(deployBlock) },
        { address: launchpadV3.address, version: 3, startBlock: Number(v3Block) },
      ],
      assets: [
        { address: dollar.address, kind: "stablecoin", issuer: "Somewhere test", canFreeze: false },
      ],
      confirmations: 0,
    },
  ])}`,
);
