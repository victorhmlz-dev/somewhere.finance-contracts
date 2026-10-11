import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import { parseEther, zeroAddress } from "viem";

const { viem, networkHelpers } = await network.create();
const publicClient = await viem.getPublicClient();

const DEAD = "0x000000000000000000000000000000000000dEaD";
const HOUR = 3600n;
const DAY = 24n * HOUR;
const STATUS = { Upcoming: 0, Live: 1, Succeeded: 2, Failed: 3, Finalized: 4 };

const FEE_BPS = 200; // 2%
const TOTAL_SUPPLY = parseEther("1000000");
const CREATOR_ALLOCATION = parseEther("10000"); // 1%
const TOKENS_FOR_SALE = parseEther("495000"); // half of the other 99%
const SOFT_CAP = parseEther("2");
const HARD_CAP = parseEther("10");

const sqrt = (value: bigint) => {
  let root = BigInt(Math.floor(Math.sqrt(Number(value))));
  while (root * root > value) root -= 1n;
  while ((root + 1n) * (root + 1n) <= value) root += 1n;
  return root;
};

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
      creatorAllocationBps: 100,
      softCap: SOFT_CAP,
      hardCap: HARD_CAP,
      startTime,
      endTime: startTime + 7n * DAY,
    };
  }

  /** A launchpad with one launch that has not started yet. */
  async function deployLaunch() {
    const base = await deployLaunchpad();
    const params = await defaultParams();
    await base.launchpad.write.createLaunch([params], {
      account: base.creator.account,
    });
    const launch = await base.launchpad.read.getLaunch([0n]);
    const token = await viem.getContractAt("LaunchToken", launch.token);
    const sale = await viem.getContractAt("TokenSale", launch.sale);
    return { ...base, params, token, sale };
  }

  /** The same launch, already accepting contributions. */
  async function deployLiveLaunch() {
    const launch = await deployLaunch();
    await networkHelpers.time.increaseTo(launch.params.startTime);
    return launch;
  }

  describe("creating a launch", () => {
    it("splits the supply between creator, sale and liquidity, all held by the sale", async () => {
      const { launchpad, token, sale, creator, feeWallet, weth, dexFactory, params } =
        await networkHelpers.loadFixture(deployLaunch);

      assert.equal(await token.read.name(), "Void Token");
      assert.equal(await token.read.symbol(), "VOID");
      assert.equal(await token.read.totalSupply(), TOTAL_SUPPLY);
      assert.equal(await token.read.balanceOf([sale.address]), TOTAL_SUPPLY);
      assert.equal(await token.read.balanceOf([launchpad.address]), 0n);

      assert.equal(await sale.read.creatorAllocation(), CREATOR_ALLOCATION);
      assert.equal(await sale.read.tokensForSale(), TOKENS_FOR_SALE);
      assert.equal(await sale.read.softCap(), SOFT_CAP);
      assert.equal(await sale.read.hardCap(), HARD_CAP);
      assert.equal(await sale.read.startTime(), params.startTime);
      assert.equal(await sale.read.endTime(), params.endTime);
      assert.equal(await sale.read.feeBps(), FEE_BPS);
      assert.equal(
        (await sale.read.creator()).toLowerCase(),
        creator.account.address.toLowerCase(),
      );
      assert.equal(
        (await sale.read.feeRecipient()).toLowerCase(),
        feeWallet.account.address.toLowerCase(),
      );
      assert.equal((await sale.read.weth()).toLowerCase(), weth.address.toLowerCase());
      assert.equal(
        (await sale.read.dexFactory()).toLowerCase(),
        dexFactory.address.toLowerCase(),
      );
      assert.equal(await sale.read.status(), STATUS.Upcoming);

      assert.equal(await launchpad.read.launchCount(), 1n);
      const launch = await launchpad.read.getLaunch([0n]);
      assert.equal(launch.creator.toLowerCase(), creator.account.address.toLowerCase());
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
      assert.deepEqual(event.args.params, params);
      assert.equal(event.args.tokensForSale, TOKENS_FOR_SALE);
      assert.equal(event.args.creatorAllocation, CREATOR_ALLOCATION);
      assert.equal(event.args.feeBps, FEE_BPS);
    });

    it("lets a creator take nothing", async () => {
      const { launchpad, creator } = await networkHelpers.loadFixture(deployLaunchpad);
      const params = { ...(await defaultParams()), creatorAllocationBps: 0 };

      await launchpad.write.createLaunch([params], { account: creator.account });

      const launch = await launchpad.read.getLaunch([0n]);
      const sale = await viem.getContractAt("TokenSale", launch.sale);
      assert.equal(await sale.read.creatorAllocation(), 0n);
      assert.equal(await sale.read.tokensForSale(), TOTAL_SUPPLY / 2n);
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

    const invalidLaunches: [string, string, (p: Awaited<ReturnType<typeof defaultParams>>) => object][] = [
      ["an empty name", "EmptyName", () => ({ name: "" })],
      ["an empty symbol", "EmptyName", () => ({ symbol: "" })],
      ["no supply", "InvalidTotalSupply", () => ({ totalSupply: 0n })],
      ["an absurd supply", "InvalidTotalSupply", () => ({ totalSupply: 10n ** 33n + 1n })],
      ["a supply too small for its hard cap", "InvalidTotalSupply", () => ({ totalSupply: HARD_CAP })],
      ["no soft cap", "InvalidCaps", () => ({ softCap: 0n })],
      ["a soft cap above the hard cap", "InvalidCaps", () => ({ softCap: HARD_CAP + 1n })],
      ["a start in the past", "InvalidSchedule", (p) => ({ startTime: p.startTime - 2n * HOUR })],
      ["a start too far ahead", "InvalidSchedule", (p) => ({ startTime: p.startTime + 91n * DAY, endTime: p.startTime + 92n * DAY })],
      ["an end before the start", "InvalidSchedule", (p) => ({ endTime: p.startTime })],
      ["a sale longer than 30 days", "InvalidSchedule", (p) => ({ endTime: p.startTime + 30n * DAY + 1n })],
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

      const balanceBefore = await publicClient.getBalance({ address: bob.account.address });
      const hash = await sale.write.contribute({
        account: bob.account,
        value: parseEther("6"),
      });
      const receipt = await publicClient.getTransactionReceipt({ hash });
      const balanceAfter = await publicClient.getBalance({ address: bob.account.address });

      const gasPaid = receipt.gasUsed * receipt.effectiveGasPrice;
      assert.equal(balanceBefore - balanceAfter - gasPaid, parseEther("4"));
      assert.equal(await sale.read.contributions([bob.account.address]), parseEther("4"));
      assert.equal(await sale.read.totalRaised(), HARD_CAP);
      assert.equal(await publicClient.getBalance({ address: sale.address }), HARD_CAP);

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
  });

  describe("a sale that sells out", () => {
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

    it("lets anyone list the token, with the liquidity locked forever", async () => {
      const { sale, token, weth, dexFactory, creator, feeWallet, stranger } =
        await networkHelpers.loadFixture(deploySoldOutLaunch);
      const feeBalanceBefore = await publicClient.getBalance({
        address: feeWallet.account.address,
      });

      await sale.write.finalize({ account: stranger.account });

      const fee = parseEther("0.2"); // 2% of 10
      const liquidityNative = parseEther("9.8");
      const liquidityTokens = (TOKENS_FOR_SALE * 98n) / 100n;

      assert.equal(await sale.read.status(), STATUS.Finalized);
      const pairAddress = await dexFactory.read.getPair([token.address, weth.address]);
      assert.notEqual(pairAddress, zeroAddress);
      assert.equal(await sale.read.pair(), pairAddress);
      const pair = await viem.getContractAt("MockPair", pairAddress);

      // Everything raised, minus the fee, is in the pool with its tokens.
      assert.equal(await weth.read.balanceOf([pairAddress]), liquidityNative);
      assert.equal(await token.read.balanceOf([pairAddress]), liquidityTokens);
      assert.equal(await publicClient.getBalance({ address: sale.address }), 0n);

      // Every pool token belongs to an address nobody controls.
      assert.equal(
        await pair.read.balanceOf([DEAD]),
        sqrt(liquidityNative * liquidityTokens),
      );
      assert.equal(await pair.read.balanceOf([DEAD]), await pair.read.totalSupply());
      assert.equal(await pair.read.balanceOf([sale.address]), 0n);
      assert.equal(await pair.read.balanceOf([creator.account.address]), 0n);

      // The creator gets 1% and the platform its fee; nothing else leaves.
      assert.equal(await token.read.balanceOf([creator.account.address]), CREATOR_ALLOCATION);
      assert.equal(
        (await publicClient.getBalance({ address: feeWallet.account.address })) -
          feeBalanceBefore,
        fee,
      );

      // What is left in the sale is exactly what contributors bought.
      assert.equal(await token.read.balanceOf([sale.address]), TOKENS_FOR_SALE);
      // The liquidity tokens that the fee left without a pair are burned.
      assert.equal(
        await token.read.balanceOf([DEAD]),
        TOTAL_SUPPLY - CREATOR_ALLOCATION - TOKENS_FOR_SALE - liquidityTokens,
      );
    });

    it("lists the token at the price contributors paid", async () => {
      const { sale, token, weth } = await networkHelpers.loadFixture(deploySoldOutLaunch);

      await sale.write.finalize();

      const pair = await sale.read.pair();
      const poolTokens = await token.read.balanceOf([pair]);
      const poolNative = await weth.read.balanceOf([pair]);
      // tokens per wei in the pool == tokens per wei in the sale
      assert.equal(poolTokens * HARD_CAP, TOKENS_FOR_SALE * poolNative);
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
      await viem.assertions.emitWithArgs(
        sale.write.claim({ account: alice.account }),
        sale,
        "Claimed",
        [alice.account.address, aliceTokens],
      );
      await sale.write.claim({ account: bob.account });

      assert.equal(await token.read.balanceOf([alice.account.address]), aliceTokens);
      assert.equal(
        await token.read.balanceOf([bob.account.address]),
        (TOKENS_FOR_SALE * 4n) / 10n,
      );
      assert.equal(await token.read.balanceOf([sale.address]), 0n);

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
      const { sale, alice } = await networkHelpers.loadFixture(deploySoldOutLaunch);
      await sale.write.finalize();

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
      assert.equal(await weth.read.balanceOf([pairAddress]), parseEther("10.8"));
      assert.equal(await pair.read.balanceOf([stranger.account.address]), 0n);
      assert.equal(await pair.read.balanceOf([DEAD]), await pair.read.totalSupply());
    });
  });

  describe("a sale that ends between its soft and hard cap", () => {
    it("lists what was sold and burns the rest", async () => {
      const { sale, token, weth, alice, creator, params } =
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
      const liquidityTokens = (tokensSold * 98n) / 100n;
      const pair = await sale.read.pair();
      assert.equal(await weth.read.balanceOf([pair]), parseEther("3.92"));
      assert.equal(await token.read.balanceOf([pair]), liquidityTokens);
      assert.equal(await token.read.balanceOf([creator.account.address]), CREATOR_ALLOCATION);
      assert.equal(await token.read.balanceOf([sale.address]), tokensSold);
      assert.equal(
        await token.read.balanceOf([DEAD]),
        TOTAL_SUPPLY - CREATOR_ALLOCATION - tokensSold - liquidityTokens,
      );

      await sale.write.claim({ account: alice.account });
      assert.equal(await token.read.balanceOf([alice.account.address]), tokensSold);
      assert.equal(await token.read.balanceOf([sale.address]), 0n);
    });
  });

  describe("a sale that ends below its soft cap", () => {
    it("lists nothing and gives every contributor a full refund", async () => {
      const { sale, token, weth, dexFactory, alice, bob, creator, params } =
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

      const balanceBefore = await publicClient.getBalance({ address: alice.account.address });
      const hash = await sale.write.refund({ account: alice.account });
      const receipt = await publicClient.getTransactionReceipt({ hash });
      const balanceAfter = await publicClient.getBalance({ address: alice.account.address });
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
      assert.equal(await publicClient.getBalance({ address: sale.address }), 0n);
      await viem.assertions.revertWithCustomError(
        sale.write.refund({ account: alice.account }),
        sale,
        "NothingToClaim",
      );

      // No pool, no tokens for the creator: the token never circulates.
      assert.equal(await dexFactory.read.getPair([token.address, weth.address]), zeroAddress);
      assert.equal(await token.read.balanceOf([creator.account.address]), 0n);
      assert.equal(await token.read.balanceOf([sale.address]), TOTAL_SUPPLY);
    });
  });

  describe("the platform", () => {
    it("can change the fee of future launches only, up to 5%", async () => {
      const { launchpad, sale, owner, creator } =
        await networkHelpers.loadFixture(deployLaunch);

      await viem.assertions.revertWithCustomError(
        launchpad.write.setFee([501], { account: owner.account }),
        launchpad,
        "FeeTooHigh",
      );
      await viem.assertions.emitWithArgs(
        launchpad.write.setFee([500], { account: owner.account }),
        launchpad,
        "FeeUpdated",
        [500],
      );

      await launchpad.write.createLaunch([await defaultParams()], {
        account: creator.account,
      });
      const newLaunch = await launchpad.read.getLaunch([1n]);
      const newSale = await viem.getContractAt("TokenSale", newLaunch.sale);
      assert.equal(await newSale.read.feeBps(), 500);
      assert.equal(await sale.read.feeBps(), FEE_BPS);
    });

    it("charges nothing when the fee is zero", async () => {
      const { launchpad, weth, owner, creator, alice, feeWallet } =
        await networkHelpers.loadFixture(deployLaunchpad);
      await launchpad.write.setFee([0], { account: owner.account });
      const params = await defaultParams();
      await launchpad.write.createLaunch([params], { account: creator.account });
      const launch = await launchpad.read.getLaunch([0n]);
      const sale = await viem.getContractAt("TokenSale", launch.sale);
      const token = await viem.getContractAt("LaunchToken", launch.token);
      const feeBalanceBefore = await publicClient.getBalance({
        address: feeWallet.account.address,
      });

      await networkHelpers.time.increaseTo(params.startTime);
      await sale.write.contribute({ account: alice.account, value: HARD_CAP });
      await sale.write.finalize();

      const pair = await sale.read.pair();
      assert.equal(await weth.read.balanceOf([pair]), HARD_CAP);
      // Sale and liquidity match in full, so nothing is burned.
      assert.equal(await token.read.balanceOf([pair]), TOKENS_FOR_SALE);
      assert.equal(await token.read.balanceOf([DEAD]), 0n);
      assert.equal(
        await publicClient.getBalance({ address: feeWallet.account.address }),
        feeBalanceBefore,
      );
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
