import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import { parseEther, zeroAddress } from "viem";

const { viem, networkHelpers } = await network.create();
const publicClient = await viem.getPublicClient();

const DEAD = "0x000000000000000000000000000000000000dEaD";
const HOUR = 3600n;
const DAY = 24n * HOUR;
const MONTH = 30n * DAY;
const GRACE_PERIOD = 7n * DAY;
const BPS = 10_000n;
const STATUS = { Upcoming: 0, Live: 1, Succeeded: 2, Failed: 3, Finalized: 4 };

const FEE_BPS = 50; // 0.5%
const LIQUIDITY_BPS = 7000; // 70%
const TOTAL_SUPPLY = parseEther("1000000");
const CREATOR_ALLOCATION = parseEther("10000"); // 1%
// 1 part for the sale and 0.7 parts for the liquidity reserve.
const TOKENS_FOR_SALE = ((TOTAL_SUPPLY - CREATOR_ALLOCATION) * BPS) / 17_000n;
const SOFT_CAP = parseEther("2");
const HARD_CAP = parseEther("10");

const sqrt = (value: bigint) => {
  let root = BigInt(Math.floor(Math.sqrt(Number(value))));
  while (root * root > value) root -= 1n;
  while ((root + 1n) * (root + 1n) <= value) root += 1n;
  return root;
};

const sameAddress = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

const nativeBalance = (address: `0x${string}`) => publicClient.getBalance({ address });

describe("Launchpad", () => {
  async function deployLaunchpad() {
    const [owner, creator, alice, bob, feeWallet, stranger] =
      await viem.getWalletClients();
    const weth = await viem.deployContract("MockWETH");
    const dexFactory = await viem.deployContract("MockFactory");
    const launchpad = await viem.deployContract("Launchpad", [
      owner.account.address,
      dexFactory.address,
      weth.address,
      feeWallet.account.address,
      FEE_BPS,
    ]);
    return { launchpad, weth, dexFactory, owner, creator, alice, bob, feeWallet, stranger };
  }

  async function defaultParams() {
    const startTime = BigInt(await networkHelpers.time.latest()) + HOUR;
    return {
      name: "Void Token",
      symbol: "VOID",
      totalSupply: TOTAL_SUPPLY,
      softCap: SOFT_CAP,
      hardCap: HARD_CAP,
      minContribution: 0n,
      maxContribution: 0n,
      startTime,
      endTime: startTime + 7n * DAY,
      creatorAllocationBps: 100,
      liquidityBps: LIQUIDITY_BPS,
      vestingTranches: 3,
    };
  }
  type Params = Awaited<ReturnType<typeof defaultParams>>;

  /** Creates a launch on `launchpad` and returns its three contracts. */
  async function createLaunch(
    launchpad: Awaited<ReturnType<typeof deployLaunchpad>>["launchpad"],
    creator: Awaited<ReturnType<typeof deployLaunchpad>>["creator"],
    changes: Partial<Params> = {},
  ) {
    const params = { ...(await defaultParams()), ...changes };
    const launchId = await launchpad.read.launchCount();
    await launchpad.write.createLaunch([params], { account: creator.account });
    const launch = await launchpad.read.getLaunch([launchId]);
    return {
      params,
      token: await viem.getContractAt("LaunchToken", launch.token),
      sale: await viem.getContractAt("TokenSale", launch.sale),
      vesting: await viem.getContractAt("CreatorVesting", launch.vesting),
    };
  }

  /** A launchpad with one launch that has not started yet. */
  async function deployLaunch() {
    const base = await deployLaunchpad();
    return { ...base, ...(await createLaunch(base.launchpad, base.creator)) };
  }

  /** The same launch, already accepting contributions. */
  async function deployLiveLaunch() {
    const launch = await deployLaunch();
    await networkHelpers.time.increaseTo(launch.params.startTime);
    return launch;
  }

  /** The same launch with its hard cap reached: Alice put 6 and Bob 4. */
  async function deploySoldOutLaunch() {
    const launch = await deployLiveLaunch();
    await launch.sale.write.contribute({
      account: launch.alice.account,
      value: parseEther("6"),
    });
    await launch.sale.write.contribute({
      account: launch.bob.account,
      value: parseEther("4"),
    });
    return launch;
  }

  /** The same launch, listed on the exchange. */
  async function deployFinalizedLaunch() {
    const launch = await deploySoldOutLaunch();
    await launch.sale.write.finalize({ account: launch.stranger.account });
    const listedAt = BigInt(await networkHelpers.time.latest());
    return { ...launch, listedAt };
  }

  describe("creating a launch", () => {
    it("splits the supply between creator, sale and liquidity, all held by the sale", async () => {
      const { launchpad, token, sale, vesting, creator, weth, dexFactory, params } =
        await networkHelpers.loadFixture(deployLaunch);

      assert.equal(await token.read.name(), "Void Token");
      assert.equal(await token.read.symbol(), "VOID");
      assert.equal(await token.read.totalSupply(), TOTAL_SUPPLY);
      assert.equal(await token.read.balanceOf([sale.address]), TOTAL_SUPPLY);
      assert.equal(await token.read.balanceOf([launchpad.address]), 0n);

      assert.equal(await sale.read.creatorAllocation(), CREATOR_ALLOCATION);
      assert.equal(await sale.read.tokensForSale(), TOKENS_FOR_SALE);
      // Sale, liquidity reserve and creator allocation fit in the supply.
      const liquidityReserve = (TOKENS_FOR_SALE * BigInt(LIQUIDITY_BPS)) / BPS;
      assert.ok(TOKENS_FOR_SALE + liquidityReserve + CREATOR_ALLOCATION <= TOTAL_SUPPLY);

      assert.equal(await sale.read.softCap(), SOFT_CAP);
      assert.equal(await sale.read.hardCap(), HARD_CAP);
      assert.equal(await sale.read.startTime(), params.startTime);
      assert.equal(await sale.read.endTime(), params.endTime);
      assert.equal(await sale.read.liquidityBps(), LIQUIDITY_BPS);
      assert.equal(await sale.read.feeBps(), FEE_BPS);
      assert.ok(sameAddress(await sale.read.creator(), creator.account.address));
      assert.ok(sameAddress(await sale.read.launchpad(), launchpad.address));
      assert.ok(sameAddress(await sale.read.weth(), weth.address));
      assert.ok(sameAddress(await sale.read.dexFactory(), dexFactory.address));
      assert.ok(sameAddress(await sale.read.vesting(), vesting.address));
      assert.equal(await sale.read.status(), STATUS.Upcoming);

      assert.ok(sameAddress(await vesting.read.beneficiary(), creator.account.address));
      assert.ok(sameAddress(await vesting.read.sale(), sale.address));
      assert.ok(sameAddress(await vesting.read.token(), token.address));
      assert.equal(await vesting.read.trancheCount(), 3);
      assert.equal(await vesting.read.startTime(), 0n);

      assert.equal(await launchpad.read.launchCount(), 1n);
      const launch = await launchpad.read.getLaunch([0n]);
      assert.ok(sameAddress(launch.creator, creator.account.address));
    });

    it("announces the launch with everything an indexer needs", async () => {
      const { launchpad, creator } = await networkHelpers.loadFixture(deployLaunchpad);
      const params = await defaultParams();

      await launchpad.write.createLaunch([params], { account: creator.account });

      const [event] = await launchpad.getEvents.LaunchCreated();
      const launch = await launchpad.read.getLaunch([0n]);
      assert.equal(event.args.launchId, 0n);
      assert.equal(event.args.token, launch.token);
      assert.equal(event.args.sale, launch.sale);
      assert.equal(event.args.vesting, launch.vesting);
      assert.deepEqual(event.args.params, params);
      assert.equal(event.args.tokensForSale, TOKENS_FOR_SALE);
      assert.equal(event.args.creatorAllocation, CREATOR_ALLOCATION);
      assert.equal(event.args.feeBps, FEE_BPS);
    });

    it("lets a creator take no tokens and send everything but the fee to liquidity", async () => {
      const { launchpad, creator } = await networkHelpers.loadFixture(deployLaunchpad);

      const { sale } = await createLaunch(launchpad, creator, {
        creatorAllocationBps: 0,
        liquidityBps: 9950,
      });

      assert.equal(await sale.read.creatorAllocation(), 0n);
      assert.equal(await sale.read.liquidityBps(), 9950);
      assert.equal(await sale.read.tokensForSale(), (TOTAL_SUPPLY * BPS) / 19_950n);
    });

    it("never lets a creator keep more than 1% of the supply", async () => {
      const { launchpad } = await networkHelpers.loadFixture(deployLaunchpad);
      const params = { ...(await defaultParams()), creatorAllocationBps: 101 };

      await viem.assertions.revertWithCustomError(
        launchpad.write.createLaunch([params]),
        launchpad,
        "CreatorAllocationTooHigh",
      );
    });

    it("never lets less than 70% of the raise go to liquidity", async () => {
      const { launchpad } = await networkHelpers.loadFixture(deployLaunchpad);
      const params = { ...(await defaultParams()), liquidityBps: 6999 };

      await viem.assertions.revertWithCustomError(
        launchpad.write.createLaunch([params]),
        launchpad,
        "InvalidLiquidityShare",
      );
    });

    it("never lets the creator be paid in fewer than three monthly tranches", async () => {
      const { launchpad } = await networkHelpers.loadFixture(deployLaunchpad);
      const params = { ...(await defaultParams()), vestingTranches: 2 };

      await viem.assertions.revertWithCustomError(
        launchpad.write.createLaunch([params]),
        launchpad,
        "InvalidVesting",
      );
    });

    const invalidLaunches: [string, string, (p: Params) => Partial<Params>][] = [
      ["an empty name", "EmptyName", () => ({ name: "" })],
      ["an empty symbol", "EmptyName", () => ({ symbol: "" })],
      ["a supply under 1,000 tokens", "InvalidTotalSupply", () => ({ totalSupply: parseEther("1000") - 1n })],
      ["an absurd supply", "InvalidTotalSupply", () => ({ totalSupply: 10n ** 33n + 1n })],
      ["a supply too small for its hard cap", "InvalidTotalSupply", () => ({ totalSupply: parseEther("1000"), hardCap: parseEther("1000") })],
      ["a soft cap under 0.01", "InvalidCaps", () => ({ softCap: parseEther("0.01") - 1n })],
      ["a soft cap above the hard cap", "InvalidCaps", () => ({ softCap: HARD_CAP + 1n })],
      ["a wallet minimum above the hard cap", "InvalidContributionLimits", () => ({ minContribution: HARD_CAP + 1n })],
      ["a wallet maximum under the wallet minimum", "InvalidContributionLimits", () => ({ minContribution: parseEther("1"), maxContribution: parseEther("0.5") })],
      ["a start in the past", "InvalidSchedule", (p) => ({ startTime: p.startTime - 2n * HOUR })],
      ["a start too far ahead", "InvalidSchedule", (p) => ({ startTime: p.startTime + 91n * DAY, endTime: p.startTime + 92n * DAY })],
      ["an end before the start", "InvalidSchedule", (p) => ({ endTime: p.startTime })],
      ["a sale longer than 30 days", "InvalidSchedule", (p) => ({ endTime: p.startTime + 30n * DAY + 1n })],
      ["liquidity and fee adding up to more than the raise", "InvalidLiquidityShare", () => ({ liquidityBps: 9951 })],
      ["a vesting longer than 48 months", "InvalidVesting", () => ({ vestingTranches: 49 })],
    ];
    for (const [label, error, change] of invalidLaunches) {
      it(`rejects ${label}`, async () => {
        const { launchpad } = await networkHelpers.loadFixture(deployLaunchpad);
        const params = await defaultParams();

        await viem.assertions.revertWithCustomError(
          launchpad.write.createLaunch([{ ...params, ...change(params) }]),
          launchpad,
          error,
        );
      });
    }
  });

  describe("contributing", () => {
    it("accepts contributions only while the sale is live", async () => {
      const { sale, alice, params } = await networkHelpers.loadFixture(deployLaunch);
      const contribute = () =>
        sale.write.contribute({ account: alice.account, value: parseEther("1") });

      await viem.assertions.revertWithCustomError(contribute(), sale, "SaleNotLive");

      await networkHelpers.time.increaseTo(params.startTime);
      assert.equal(await sale.read.status(), STATUS.Live);
      await viem.assertions.emitWithArgs(contribute(), sale, "Contributed", [
        alice.account.address,
        parseEther("1"),
        parseEther("1"),
      ]);
      assert.equal(await sale.read.contributions([alice.account.address]), parseEther("1"));
      assert.equal(await sale.read.totalRaised(), parseEther("1"));

      await networkHelpers.time.increaseTo(params.endTime);
      await viem.assertions.revertWithCustomError(contribute(), sale, "SaleNotLive");
    });

    it("counts a plain transfer to the sale as a contribution", async () => {
      const { sale, alice } = await networkHelpers.loadFixture(deployLiveLaunch);

      await alice.sendTransaction({ to: sale.address, value: parseEther("3") });

      assert.equal(await sale.read.contributions([alice.account.address]), parseEther("3"));
    });

    it("rejects an empty contribution", async () => {
      const { sale, alice } = await networkHelpers.loadFixture(deployLiveLaunch);

      await viem.assertions.revertWithCustomError(
        sale.write.contribute({ account: alice.account, value: 0n }),
        sale,
        "NothingToContribute",
      );
    });

    it("sends back what does not fit under the hard cap and ends the sale", async () => {
      const { sale, alice, bob } = await networkHelpers.loadFixture(deployLiveLaunch);
      await sale.write.contribute({ account: alice.account, value: parseEther("6") });

      const balanceBefore = await nativeBalance(bob.account.address);
      const hash = await sale.write.contribute({
        account: bob.account,
        value: parseEther("6"),
      });
      const receipt = await publicClient.getTransactionReceipt({ hash });
      const balanceAfter = await nativeBalance(bob.account.address);

      const gasPaid = receipt.gasUsed * receipt.effectiveGasPrice;
      assert.equal(balanceBefore - balanceAfter - gasPaid, parseEther("4"));
      assert.equal(await sale.read.contributions([bob.account.address]), parseEther("4"));
      assert.equal(await sale.read.totalRaised(), HARD_CAP);
      assert.equal(await nativeBalance(sale.address), HARD_CAP);

      assert.equal(await sale.read.status(), STATUS.Succeeded);
      await viem.assertions.revertWithCustomError(
        sale.write.contribute({ account: alice.account, value: 1n }),
        sale,
        "SaleNotLive",
      );
    });

    it("fails the whole contribution when the leftover cannot be sent back", async () => {
      const { sale } = await networkHelpers.loadFixture(deployLiveLaunch);
      const contributor = await viem.deployContract("RejectsNative");

      await viem.assertions.revertWith(
        contributor.write.contribute([sale.address], { value: HARD_CAP + 1n }),
        "contribute failed",
      );
      assert.equal(await sale.read.totalRaised(), 0n);
    });

    it("holds each wallet to the maximum of the sale", async () => {
      const { launchpad, creator, alice, bob } =
        await networkHelpers.loadFixture(deployLaunchpad);
      const { sale, params } = await createLaunch(launchpad, creator, {
        maxContribution: parseEther("3"),
      });
      await networkHelpers.time.increaseTo(params.startTime);

      await sale.write.contribute({ account: alice.account, value: parseEther("2") });
      // Only 1 more fits for Alice; the other 4 come back.
      await sale.write.contribute({ account: alice.account, value: parseEther("5") });
      assert.equal(await sale.read.contributions([alice.account.address]), parseEther("3"));
      assert.equal(await nativeBalance(sale.address), parseEther("3"));

      await viem.assertions.revertWithCustomError(
        sale.write.contribute({ account: alice.account, value: parseEther("1") }),
        sale,
        "NothingToContribute",
      );
      // The limit is per wallet: Bob still has his own room.
      await sale.write.contribute({ account: bob.account, value: parseEther("3") });
      assert.equal(await sale.read.totalRaised(), parseEther("6"));
    });

    it("holds each wallet to the minimum of the sale, except to fill it", async () => {
      const { launchpad, creator, alice, bob } =
        await networkHelpers.loadFixture(deployLaunchpad);
      const { sale, params } = await createLaunch(launchpad, creator, {
        minContribution: parseEther("1"),
      });
      await networkHelpers.time.increaseTo(params.startTime);

      await viem.assertions.revertWithCustomError(
        sale.write.contribute({ account: alice.account, value: parseEther("0.99") }),
        sale,
        "BelowMinContribution",
      );
      await sale.write.contribute({ account: alice.account, value: parseEther("1") });
      // The minimum is on what a wallet has put in total, so topping up is free.
      await sale.write.contribute({ account: alice.account, value: parseEther("0.5") });

      // 8.5 are left; once only 0.5 remain, that last bit is accepted.
      await sale.write.contribute({ account: alice.account, value: parseEther("8") });
      await sale.write.contribute({ account: bob.account, value: parseEther("0.5") });
      assert.equal(await sale.read.contributions([bob.account.address]), parseEther("0.5"));
      assert.equal(await sale.read.status(), STATUS.Succeeded);
    });
  });

  describe("a sale that sells out", () => {
    it("splits the raise: 70% to locked liquidity, the fee aside, the rest to vesting", async () => {
      const { sale, token, weth, dexFactory, vesting, creator, feeWallet, stranger } =
        await networkHelpers.loadFixture(deploySoldOutLaunch);
      const creatorBalanceBefore = await nativeBalance(creator.account.address);
      const feeBalanceBefore = await nativeBalance(feeWallet.account.address);

      await sale.write.finalize({ account: stranger.account });

      const fee = parseEther("0.05"); // 0.5% of 10
      const liquidityNative = parseEther("7"); // 70% of 10
      const creatorNative = parseEther("2.95"); // the rest
      const liquidityTokens = (TOKENS_FOR_SALE * BigInt(LIQUIDITY_BPS)) / BPS;

      assert.equal(await sale.read.status(), STATUS.Finalized);
      const pairAddress = await dexFactory.read.getPair([token.address, weth.address]);
      assert.notEqual(pairAddress, zeroAddress);
      assert.equal(await sale.read.pair(), pairAddress);
      const pair = await viem.getContractAt("MockPair", pairAddress);

      // The liquidity is in the pool, with tokens at the price of the sale.
      assert.equal(await weth.read.balanceOf([pairAddress]), liquidityNative);
      assert.equal(await token.read.balanceOf([pairAddress]), liquidityTokens);

      // Every pool token belongs to an address nobody controls.
      assert.equal(
        await pair.read.balanceOf([DEAD]),
        sqrt(liquidityNative * liquidityTokens),
      );
      assert.equal(await pair.read.balanceOf([DEAD]), await pair.read.totalSupply());
      assert.equal(await pair.read.balanceOf([sale.address]), 0n);
      assert.equal(await pair.read.balanceOf([creator.account.address]), 0n);

      // The creator's proceeds and tokens are in the vesting, not in a wallet.
      assert.equal(await nativeBalance(vesting.address), creatorNative);
      assert.equal(await token.read.balanceOf([vesting.address]), CREATOR_ALLOCATION);
      assert.equal(await nativeBalance(creator.account.address), creatorBalanceBefore);
      assert.equal(await token.read.balanceOf([creator.account.address]), 0n);

      // The fee waits in the sale; it is not pushed to anyone.
      assert.equal(await sale.read.feeOwed(), fee);
      assert.equal(await nativeBalance(sale.address), fee);
      assert.equal(await nativeBalance(feeWallet.account.address), feeBalanceBefore);

      // What is left in the sale is exactly what contributors bought.
      assert.equal(await token.read.balanceOf([sale.address]), TOKENS_FOR_SALE);
      assert.equal(
        await token.read.balanceOf([DEAD]),
        TOTAL_SUPPLY - CREATOR_ALLOCATION - TOKENS_FOR_SALE - liquidityTokens,
      );

      const [event] = await sale.getEvents.Finalized();
      assert.equal(event.args.liquidityNative, liquidityNative);
      assert.equal(event.args.liquidityTokens, liquidityTokens);
      assert.equal(event.args.creatorNative, creatorNative);
      assert.equal(event.args.fee, fee);
    });

    it("lists the token at the price contributors paid", async () => {
      const { sale, token, weth } = await networkHelpers.loadFixture(deployFinalizedLaunch);

      const pair = await sale.read.pair();
      const poolTokens = await token.read.balanceOf([pair]);
      const poolNative = await weth.read.balanceOf([pair]);
      // tokens per wei in the pool == tokens per wei in the sale, up to the
      // one unit that rounding down can take from the pool.
      const difference = TOKENS_FOR_SALE * poolNative - poolTokens * HARD_CAP;
      assert.ok(difference >= 0n && difference < HARD_CAP);
    });

    it("gives each contributor their share, once", async () => {
      const { sale, token, alice, bob, stranger } =
        await networkHelpers.loadFixture(deploySoldOutLaunch);

      await viem.assertions.revertWithCustomError(
        sale.write.claim({ account: alice.account }),
        sale,
        "SaleNotFinalized",
      );
      await sale.write.finalize();

      const aliceTokens = (TOKENS_FOR_SALE * 6n) / 10n;
      const bobTokens = (TOKENS_FOR_SALE * 4n) / 10n;
      await viem.assertions.emitWithArgs(
        sale.write.claim({ account: alice.account }),
        sale,
        "Claimed",
        [alice.account.address, aliceTokens],
      );
      await sale.write.claim({ account: bob.account });

      assert.equal(await token.read.balanceOf([alice.account.address]), aliceTokens);
      assert.equal(await token.read.balanceOf([bob.account.address]), bobTokens);
      // Only what rounding down left behind stays in the sale.
      assert.equal(
        await token.read.balanceOf([sale.address]),
        TOKENS_FOR_SALE - aliceTokens - bobTokens,
      );
      assert.ok((await token.read.balanceOf([sale.address])) < 2n);

      await viem.assertions.revertWithCustomError(
        sale.write.claim({ account: alice.account }),
        sale,
        "NothingToClaim",
      );
      await viem.assertions.revertWithCustomError(
        sale.write.claim({ account: stranger.account }),
        sale,
        "NothingToClaim",
      );
    });

    it("cannot be finalized twice, refunded or contributed to afterwards", async () => {
      const { sale, alice } = await networkHelpers.loadFixture(deployFinalizedLaunch);

      await viem.assertions.revertWithCustomError(
        sale.write.finalize(),
        sale,
        "SaleNotSucceeded",
      );
      await viem.assertions.revertWithCustomError(
        sale.write.refund({ account: alice.account }),
        sale,
        "SaleNotFailed",
      );
      await viem.assertions.revertWithCustomError(
        sale.write.contribute({ account: alice.account, value: 1n }),
        sale,
        "SaleNotLive",
      );
      // Not even long after: a finalized sale never goes back to failed.
      await networkHelpers.time.increase(365n * DAY);
      assert.equal(await sale.read.status(), STATUS.Finalized);
      await viem.assertions.revertWithCustomError(
        sale.write.refund({ account: alice.account }),
        sale,
        "SaleNotFailed",
      );
    });

    it("still lists when somebody created and unbalanced the pair beforehand", async () => {
      const { sale, token, weth, dexFactory, stranger } =
        await networkHelpers.loadFixture(deploySoldOutLaunch);
      // The attack that blocks launches funded through the exchange router.
      await dexFactory.write.createPair([token.address, weth.address], {
        account: stranger.account,
      });
      const pairAddress = await dexFactory.read.getPair([token.address, weth.address]);
      const pair = await viem.getContractAt("MockPair", pairAddress);
      await weth.write.deposit({ account: stranger.account, value: parseEther("1") });
      await weth.write.transfer([pairAddress, parseEther("1")], {
        account: stranger.account,
      });
      await pair.write.sync({ account: stranger.account });

      await sale.write.finalize();

      assert.equal(await sale.read.status(), STATUS.Finalized);
      assert.equal(await sale.read.pair(), pairAddress);
      // The attacker only gave their own money away to the locked pool.
      assert.equal(await weth.read.balanceOf([pairAddress]), parseEther("8"));
      assert.equal(await pair.read.balanceOf([stranger.account.address]), 0n);
      assert.equal(await pair.read.balanceOf([DEAD]), await pair.read.totalSupply());
    });
  });

  describe("the platform fee", () => {
    it("is collected by anyone, for whoever the launchpad names, once", async () => {
      const { sale, feeWallet, stranger } =
        await networkHelpers.loadFixture(deployFinalizedLaunch);
      const balanceBefore = await nativeBalance(feeWallet.account.address);

      await viem.assertions.emitWithArgs(
        sale.write.collectFee({ account: stranger.account }),
        sale,
        "FeeCollected",
        [feeWallet.account.address, parseEther("0.05")],
      );

      assert.equal(
        (await nativeBalance(feeWallet.account.address)) - balanceBefore,
        parseEther("0.05"),
      );
      assert.equal(await sale.read.feeOwed(), 0n);
      assert.equal(await nativeBalance(sale.address), 0n);
      await viem.assertions.revertWithCustomError(
        sale.write.collectFee(),
        sale,
        "NothingToCollect",
      );
    });

    it("cannot be collected before the sale is finalized", async () => {
      const { sale } = await networkHelpers.loadFixture(deploySoldOutLaunch);

      await viem.assertions.revertWithCustomError(
        sale.write.collectFee(),
        sale,
        "NothingToCollect",
      );
    });

    it("never blocks a launch when its recipient cannot be paid", async () => {
      const { launchpad, sale, token, vesting, owner, alice, feeWallet } =
        await networkHelpers.loadFixture(deploySoldOutLaunch);
      const brokenRecipient = await viem.deployContract("RejectsNative");
      await launchpad.write.setFeeRecipient([brokenRecipient.address], {
        account: owner.account,
      });

      // Listing, claims and vesting go ahead regardless.
      await sale.write.finalize();
      await sale.write.claim({ account: alice.account });
      assert.equal(
        await token.read.balanceOf([alice.account.address]),
        (TOKENS_FOR_SALE * 6n) / 10n,
      );
      assert.notEqual(await vesting.read.startTime(), 0n);

      // Only the collection fails, and the fee stays safe until it is fixed.
      await viem.assertions.revertWithCustomError(
        sale.write.collectFee(),
        sale,
        "NativeTransferFailed",
      );
      assert.equal(await sale.read.feeOwed(), parseEther("0.05"));

      await launchpad.write.setFeeRecipient([feeWallet.account.address], {
        account: owner.account,
      });
      const balanceBefore = await nativeBalance(feeWallet.account.address);
      await sale.write.collectFee();
      assert.equal(
        (await nativeBalance(feeWallet.account.address)) - balanceBefore,
        parseEther("0.05"),
      );
    });
  });

  describe("the creator's vesting", () => {
    const TOTAL_NATIVE = parseEther("2.95");

    it("starts when the token is listed and pays nothing that day", async () => {
      const { vesting, listedAt } = await networkHelpers.loadFixture(deployFinalizedLaunch);

      assert.equal(await vesting.read.startTime(), listedAt);
      assert.equal(await vesting.read.totalNative(), TOTAL_NATIVE);
      assert.equal(await vesting.read.totalTokens(), CREATOR_ALLOCATION);
      assert.equal(await vesting.read.tranchesVested(), 0n);
      assert.deepEqual(await vesting.read.releasable(), [0n, 0n]);
      await viem.assertions.revertWithCustomError(
        vesting.write.release(),
        vesting,
        "NothingToRelease",
      );

      const [event] = await vesting.getEvents.VestingStarted();
      assert.deepEqual(event.args, {
        startTime: listedAt,
        trancheCount: 3,
        totalNative: TOTAL_NATIVE,
        totalTokens: CREATOR_ALLOCATION,
      });
    });

    it("unlocks one tranche every 30 days, to the second", async () => {
      const { vesting, listedAt } = await networkHelpers.loadFixture(deployFinalizedLaunch);

      await networkHelpers.time.increaseTo(listedAt + MONTH - 1n);
      assert.equal(await vesting.read.tranchesVested(), 0n);

      await networkHelpers.time.increaseTo(listedAt + MONTH);
      assert.equal(await vesting.read.tranchesVested(), 1n);
      assert.deepEqual(await vesting.read.releasable(), [
        TOTAL_NATIVE / 3n,
        CREATOR_ALLOCATION / 3n,
      ]);

      await networkHelpers.time.increaseTo(listedAt + 2n * MONTH - 1n);
      assert.equal(await vesting.read.tranchesVested(), 1n);
      await networkHelpers.time.increaseTo(listedAt + 2n * MONTH);
      assert.equal(await vesting.read.tranchesVested(), 2n);

      await networkHelpers.time.increaseTo(listedAt + 3n * MONTH);
      assert.equal(await vesting.read.tranchesVested(), 3n);
      // It stops at the last tranche.
      await networkHelpers.time.increaseTo(listedAt + 40n * MONTH);
      assert.equal(await vesting.read.tranchesVested(), 3n);
      assert.deepEqual(await vesting.read.releasable(), [TOTAL_NATIVE, CREATOR_ALLOCATION]);
    });

    it("pays the creator, whoever asks, and never the same tranche twice", async () => {
      const { vesting, token, creator, stranger, listedAt } =
        await networkHelpers.loadFixture(deployFinalizedLaunch);
      const balanceBefore = await nativeBalance(creator.account.address);

      await networkHelpers.time.increaseTo(listedAt + MONTH);
      await viem.assertions.emitWithArgs(
        vesting.write.release({ account: stranger.account }),
        vesting,
        "Released",
        [TOTAL_NATIVE / 3n, CREATOR_ALLOCATION / 3n, 1n],
      );
      assert.equal(
        (await nativeBalance(creator.account.address)) - balanceBefore,
        TOTAL_NATIVE / 3n,
      );
      assert.equal(
        await token.read.balanceOf([creator.account.address]),
        CREATOR_ALLOCATION / 3n,
      );
      assert.equal(await token.read.balanceOf([stranger.account.address]), 0n);
      await viem.assertions.revertWithCustomError(
        vesting.write.release({ account: stranger.account }),
        vesting,
        "NothingToRelease",
      );

      // Two tranches at once, with what rounding left behind in the last one.
      await networkHelpers.time.increaseTo(listedAt + 3n * MONTH);
      await vesting.write.release({ account: stranger.account });
      assert.equal(
        (await nativeBalance(creator.account.address)) - balanceBefore,
        TOTAL_NATIVE,
      );
      assert.equal(
        await token.read.balanceOf([creator.account.address]),
        CREATOR_ALLOCATION,
      );
      assert.equal(await nativeBalance(vesting.address), 0n);
      assert.equal(await token.read.balanceOf([vesting.address]), 0n);
    });

    it("can only be started by its sale, and only once", async () => {
      const { vesting, sale, stranger } =
        await networkHelpers.loadFixture(deployFinalizedLaunch);

      await viem.assertions.revertWithCustomError(
        vesting.write.start([0n], { account: stranger.account, value: 1n }),
        vesting,
        "OnlySale",
      );

      await networkHelpers.impersonateAccount(sale.address);
      await networkHelpers.setBalance(sale.address, parseEther("1"));
      await viem.assertions.revertWithCustomError(
        vesting.write.start([0n], { account: sale.address }),
        vesting,
        "AlreadyStarted",
      );
    });

    it("pays a longer schedule in as many tranches as the creator chose", async () => {
      const { launchpad, creator, alice } = await networkHelpers.loadFixture(deployLaunchpad);
      const { sale, vesting, params } = await createLaunch(launchpad, creator, {
        vestingTranches: 12,
      });
      await networkHelpers.time.increaseTo(params.startTime);
      await sale.write.contribute({ account: alice.account, value: HARD_CAP });
      await sale.write.finalize();
      const listedAt = BigInt(await networkHelpers.time.latest());

      await networkHelpers.time.increaseTo(listedAt + 5n * MONTH);
      assert.equal(await vesting.read.tranchesVested(), 5n);
      assert.deepEqual(await vesting.read.releasable(), [
        (TOTAL_NATIVE * 5n) / 12n,
        (CREATOR_ALLOCATION * 5n) / 12n,
      ]);
    });
  });

  describe("a sale that ends between its soft and hard cap", () => {
    it("lists what was sold and burns the rest", async () => {
      const { sale, token, weth, vesting, alice, params } =
        await networkHelpers.loadFixture(deployLiveLaunch);
      await sale.write.contribute({ account: alice.account, value: parseEther("4") });

      await viem.assertions.revertWithCustomError(
        sale.write.finalize(),
        sale,
        "SaleNotSucceeded",
      );
      await networkHelpers.time.increaseTo(params.endTime);
      assert.equal(await sale.read.status(), STATUS.Succeeded);
      await sale.write.finalize();

      const tokensSold = (TOKENS_FOR_SALE * 4n) / 10n;
      const liquidityTokens = (tokensSold * BigInt(LIQUIDITY_BPS)) / BPS;
      const pair = await sale.read.pair();
      assert.equal(await weth.read.balanceOf([pair]), parseEther("2.8"));
      assert.equal(await token.read.balanceOf([pair]), liquidityTokens);
      assert.equal(await sale.read.feeOwed(), parseEther("0.02"));
      assert.equal(await nativeBalance(vesting.address), parseEther("1.18"));
      assert.equal(await token.read.balanceOf([vesting.address]), CREATOR_ALLOCATION);
      assert.equal(await token.read.balanceOf([sale.address]), tokensSold);
      assert.equal(
        await token.read.balanceOf([DEAD]),
        TOTAL_SUPPLY - CREATOR_ALLOCATION - tokensSold - liquidityTokens,
      );

      await sale.write.claim({ account: alice.account });
      assert.equal(await token.read.balanceOf([alice.account.address]), tokensSold);
      assert.equal(await token.read.balanceOf([sale.address]), 0n);
    });

    it("succeeds with exactly the soft cap and fails one wei below it", async () => {
      const { launchpad, creator, alice } = await networkHelpers.loadFixture(deployLaunchpad);
      const exact = await createLaunch(launchpad, creator);
      const short = await createLaunch(launchpad, creator);
      await networkHelpers.time.increaseTo(short.params.startTime);
      await exact.sale.write.contribute({ account: alice.account, value: SOFT_CAP });
      await short.sale.write.contribute({ account: alice.account, value: SOFT_CAP - 1n });

      await networkHelpers.time.increaseTo(short.params.endTime);

      assert.equal(await exact.sale.read.status(), STATUS.Succeeded);
      assert.equal(await short.sale.read.status(), STATUS.Failed);
    });
  });

  describe("a sale that ends below its soft cap", () => {
    it("lists nothing, charges nothing and gives every contributor a full refund", async () => {
      const { sale, token, weth, dexFactory, vesting, alice, bob, creator, params } =
        await networkHelpers.loadFixture(deployLiveLaunch);
      await sale.write.contribute({ account: alice.account, value: parseEther("1") });
      await sale.write.contribute({ account: bob.account, value: parseEther("0.5") });

      await viem.assertions.revertWithCustomError(
        sale.write.refund({ account: alice.account }),
        sale,
        "SaleNotFailed",
      );
      await networkHelpers.time.increaseTo(params.endTime);
      assert.equal(await sale.read.status(), STATUS.Failed);

      await viem.assertions.revertWithCustomError(
        sale.write.finalize(),
        sale,
        "SaleNotSucceeded",
      );
      await viem.assertions.revertWithCustomError(
        sale.write.claim({ account: alice.account }),
        sale,
        "SaleNotFinalized",
      );
      await viem.assertions.revertWithCustomError(
        sale.write.collectFee(),
        sale,
        "NothingToCollect",
      );

      const balanceBefore = await nativeBalance(alice.account.address);
      const hash = await sale.write.refund({ account: alice.account });
      const receipt = await publicClient.getTransactionReceipt({ hash });
      const balanceAfter = await nativeBalance(alice.account.address);
      assert.equal(
        balanceAfter - balanceBefore + receipt.gasUsed * receipt.effectiveGasPrice,
        parseEther("1"),
      );

      await viem.assertions.emitWithArgs(
        sale.write.refund({ account: bob.account }),
        sale,
        "Refunded",
        [bob.account.address, parseEther("0.5")],
      );
      assert.equal(await nativeBalance(sale.address), 0n);
      await viem.assertions.revertWithCustomError(
        sale.write.refund({ account: alice.account }),
        sale,
        "NothingToClaim",
      );

      // No pool, no vesting, nothing for the creator: the token never circulates.
      assert.equal(await dexFactory.read.getPair([token.address, weth.address]), zeroAddress);
      assert.equal(await vesting.read.startTime(), 0n);
      assert.equal(await token.read.balanceOf([creator.account.address]), 0n);
      assert.equal(await token.read.balanceOf([sale.address]), TOTAL_SUPPLY);
    });
  });

  describe("a successful sale that cannot be listed", () => {
    /** A sold-out sale on an exchange that refuses to create the pair. */
    async function deployUnlistableLaunch() {
      const [owner, creator, alice, bob, feeWallet] = await viem.getWalletClients();
      const weth = await viem.deployContract("MockWETH");
      const dexFactory = await viem.deployContract("RefusingFactory");
      const launchpad = await viem.deployContract("Launchpad", [
        owner.account.address,
        dexFactory.address,
        weth.address,
        feeWallet.account.address,
        FEE_BPS,
      ]);
      const launch = await createLaunch(launchpad, creator);
      await networkHelpers.time.increaseTo(launch.params.startTime);
      await launch.sale.write.contribute({ account: alice.account, value: parseEther("6") });
      await launch.sale.write.contribute({ account: bob.account, value: parseEther("4") });
      const soldOutAt = BigInt(await networkHelpers.time.latest());
      return { ...launch, alice, bob, soldOutAt };
    }

    it("turns into a failed sale after the grace period, with full refunds", async () => {
      const { sale, alice, bob, soldOutAt } =
        await networkHelpers.loadFixture(deployUnlistableLaunch);

      await viem.assertions.revertWith(sale.write.finalize(), "PAIR_CREATION_DISABLED");
      assert.equal(await sale.read.status(), STATUS.Succeeded);

      // Until the grace period is over the sale can still be listed, so no refunds.
      await networkHelpers.time.increaseTo(soldOutAt + GRACE_PERIOD - 2n);
      await viem.assertions.revertWithCustomError(
        sale.write.refund({ account: alice.account }),
        sale,
        "SaleNotFailed",
      );

      await networkHelpers.time.increaseTo(soldOutAt + GRACE_PERIOD);
      assert.equal(await sale.read.status(), STATUS.Failed);
      await viem.assertions.emitWithArgs(
        sale.write.refund({ account: alice.account }),
        sale,
        "Refunded",
        [alice.account.address, parseEther("6")],
      );
      await sale.write.refund({ account: bob.account });
      assert.equal(await nativeBalance(sale.address), 0n);
      assert.equal(await sale.read.feeOwed(), 0n);
    });

    it("cannot be listed once refunds are open", async () => {
      const { sale, alice } = await networkHelpers.loadFixture(deploySoldOutLaunch);
      const soldOutAt = await sale.read.hardCapReachedAt();

      // Nothing wrong with the exchange here: simply nobody finalized in time.
      await networkHelpers.time.increaseTo(soldOutAt + GRACE_PERIOD);
      assert.equal(await sale.read.status(), STATUS.Failed);
      await sale.write.refund({ account: alice.account });

      await viem.assertions.revertWithCustomError(
        sale.write.finalize(),
        sale,
        "SaleNotSucceeded",
      );
    });

    it("counts the grace period from the end of a sale that did not sell out", async () => {
      const { sale, alice, params } = await networkHelpers.loadFixture(deployLiveLaunch);
      await sale.write.contribute({ account: alice.account, value: parseEther("4") });

      await networkHelpers.time.increaseTo(params.endTime + GRACE_PERIOD - 1n);
      assert.equal(await sale.read.status(), STATUS.Succeeded);
      await networkHelpers.time.increaseTo(params.endTime + GRACE_PERIOD);
      assert.equal(await sale.read.status(), STATUS.Failed);
    });
  });

  describe("the platform", () => {
    it("can change the fee of future launches only, never above 1%", async () => {
      const { launchpad, sale, owner, creator } =
        await networkHelpers.loadFixture(deployLaunch);

      await viem.assertions.revertWithCustomError(
        launchpad.write.setFee([101], { account: owner.account }),
        launchpad,
        "FeeTooHigh",
      );
      await viem.assertions.emitWithArgs(
        launchpad.write.setFee([100], { account: owner.account }),
        launchpad,
        "FeeUpdated",
        [100],
      );

      const newLaunch = await createLaunch(launchpad, creator);
      assert.equal(await newLaunch.sale.read.feeBps(), 100);
      assert.equal(await sale.read.feeBps(), FEE_BPS);
    });

    it("cannot be deployed with a fee above 1%", async () => {
      const { weth, dexFactory, owner, feeWallet } =
        await networkHelpers.loadFixture(deployLaunchpad);

      await assert.rejects(
        viem.deployContract("Launchpad", [
          owner.account.address,
          dexFactory.address,
          weth.address,
          feeWallet.account.address,
          101,
        ]),
      );
    });

    it("charges nothing when the fee is zero", async () => {
      const { launchpad, weth, owner, creator, alice } =
        await networkHelpers.loadFixture(deployLaunchpad);
      await launchpad.write.setFee([0], { account: owner.account });
      const { sale, vesting, params } = await createLaunch(launchpad, creator);

      await networkHelpers.time.increaseTo(params.startTime);
      await sale.write.contribute({ account: alice.account, value: HARD_CAP });
      await sale.write.finalize();

      assert.equal(await weth.read.balanceOf([await sale.read.pair()]), parseEther("7"));
      assert.equal(await nativeBalance(vesting.address), parseEther("3"));
      assert.equal(await sale.read.feeOwed(), 0n);
      assert.equal(await nativeBalance(sale.address), 0n);
    });

    it("keeps its settings out of reach of anyone but the owner", async () => {
      const { launchpad, owner, stranger } = await networkHelpers.loadFixture(deployLaunchpad);

      await viem.assertions.revertWithCustomError(
        launchpad.write.setFee([0], { account: stranger.account }),
        launchpad,
        "OwnableUnauthorizedAccount",
      );
      await viem.assertions.revertWithCustomError(
        launchpad.write.setFeeRecipient([stranger.account.address], {
          account: stranger.account,
        }),
        launchpad,
        "OwnableUnauthorizedAccount",
      );
      await viem.assertions.revertWithCustomError(
        launchpad.write.setFeeRecipient([zeroAddress], { account: owner.account }),
        launchpad,
        "ZeroAddress",
      );
    });
  });
});
