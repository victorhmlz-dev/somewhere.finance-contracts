import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import { getAddress, parseEther, parseUnits, zeroAddress } from "viem";

const { viem, networkHelpers } = await network.create();
const publicClient = await viem.getPublicClient();

const DEAD = "0x000000000000000000000000000000000000dEaD";
const HOUR = 3600n;
const DAY = 24n * HOUR;
const MONTH = 30n * DAY;
const GRACE_PERIOD = 7n * DAY;
const BPS = 10_000n;
const STATUS = { Upcoming: 0, Live: 1, Succeeded: 2, Failed: 3, Finalized: 4, Cancelled: 5 };

const FEE_BPS = 50; // 0.5%
const LIQUIDITY_BPS = 7000; // 70%
const TOTAL_SUPPLY = parseEther("1000000");
const CREATOR_ALLOCATION = parseEther("10000"); // 1%
const TOKENS_FOR_SALE = ((TOTAL_SUPPLY - CREATOR_ALLOCATION) * BPS) / 17_000n;

// The stablecoin has 6 decimals: nothing in the sale may assume 18.
const usd = (amount: string) => parseUnits(amount, 6);
const SOFT_CAP = usd("2000");
const HARD_CAP = usd("10000");
const MIN_SOFT_CAP_USD = usd("100");
const MIN_SOFT_CAP_NATIVE = parseEther("0.01");

const NO_PROOF = { tier: 0, expiresAt: 0n, signature: "0x" as `0x${string}` };

const sameAddress = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

describe("Launchpad v3", () => {
  async function deployLaunchpad() {
    const [owner, creator, alice, bob, feeWallet, stranger, attestor] =
      await viem.getWalletClients();
    const weth = await viem.deployContract("MockWETH");
    const dexFactory = await viem.deployContract("MockFactory");
    const saleImplementation = await viem.deployContract("TokenSaleV3");
    const vestingImplementation = await viem.deployContract("CreatorVestingV3");
    const launchpad = await viem.deployContract("LaunchpadV3", [
      owner.account.address,
      dexFactory.address,
      weth.address,
      saleImplementation.address,
      vestingImplementation.address,
      feeWallet.account.address,
      FEE_BPS,
    ]);
    const stablecoin = await viem.deployContract("MockStablecoin");
    const stock = await viem.deployContract("MockIssuerToken");
    await launchpad.write.setQuoteAsset([stablecoin.address, true, MIN_SOFT_CAP_USD]);
    await launchpad.write.setQuoteAsset([weth.address, true, MIN_SOFT_CAP_NATIVE]);
    await launchpad.write.setQuoteAsset([stock.address, true, parseEther("1")]);

    for (const wallet of [alice, bob]) {
      await stablecoin.write.mint([wallet.account.address, usd("100000")]);
      await stock.write.mint([wallet.account.address, parseEther("100000")]);
    }

    return {
      launchpad,
      saleImplementation,
      vestingImplementation,
      weth,
      dexFactory,
      stablecoin,
      stock,
      owner,
      creator,
      alice,
      bob,
      feeWallet,
      stranger,
      attestor,
    };
  }
  type Base = Awaited<ReturnType<typeof deployLaunchpad>>;

  async function defaultParams(quoteAsset: `0x${string}`) {
    const startTime = BigInt(await networkHelpers.time.latest()) + HOUR;
    return {
      name: "Void Token",
      symbol: "VOID",
      totalSupply: TOTAL_SUPPLY,
      quoteAsset,
      softCap: SOFT_CAP,
      hardCap: HARD_CAP,
      minContribution: 0n,
      maxContribution: 0n,
      startTime,
      endTime: startTime + 7n * DAY,
      creatorAllocationBps: 100,
      liquidityBps: LIQUIDITY_BPS,
      vestingTranches: 3,
      requiredTier: 0,
    };
  }
  type Params = Awaited<ReturnType<typeof defaultParams>>;

  /** Creates a launch and returns its three contracts. */
  async function createLaunch(base: Base, changes: Partial<Params> = {}) {
    const params = { ...(await defaultParams(base.stablecoin.address)), ...changes };
    const launchId = await base.launchpad.read.launchCount();
    await base.launchpad.write.createLaunch([params], { account: base.creator.account });
    const launch = await base.launchpad.read.getLaunch([launchId]);
    return {
      launchId,
      params,
      token: await viem.getContractAt("LaunchToken", launch.token),
      sale: await viem.getContractAt("TokenSaleV3", launch.sale),
      vesting: await viem.getContractAt("CreatorVestingV3", launch.vesting),
    };
  }
  type Launch = Awaited<ReturnType<typeof createLaunch>>;

  /** Approves and contributes `amount` of the stablecoin from `wallet`. */
  async function contributeUsd(
    base: Base,
    launch: Launch,
    wallet: Base["alice"],
    amount: bigint,
  ) {
    await base.stablecoin.write.approve([launch.sale.address, amount], {
      account: wallet.account,
    });
    return launch.sale.write.contribute([amount, NO_PROOF], { account: wallet.account });
  }

  /** A launch paired with the stablecoin, not started yet. */
  async function deployUsdLaunch() {
    const base = await deployLaunchpad();
    return { ...base, ...(await createLaunch(base)) };
  }

  /** The same, live. */
  async function deployLiveUsdLaunch() {
    const launch = await deployUsdLaunch();
    await networkHelpers.time.increaseTo(launch.params.startTime);
    return launch;
  }

  /** The same, sold out: Alice put 6,000 and Bob 4,000. */
  async function deploySoldOutUsdLaunch() {
    const launch = await deployLiveUsdLaunch();
    await contributeUsd(launch, launch, launch.alice, usd("6000"));
    await contributeUsd(launch, launch, launch.bob, usd("4000"));
    return launch;
  }

  /** A launch paired with the native currency, live. */
  async function deployLiveNativeLaunch() {
    const base = await deployLaunchpad();
    const launch = await createLaunch(base, {
      quoteAsset: base.weth.address,
      softCap: parseEther("2"),
      hardCap: parseEther("10"),
    });
    await networkHelpers.time.increaseTo(launch.params.startTime);
    return { ...base, ...launch };
  }

  /** A launch paired with a token whose issuer can pause, block and burn,
   * with Alice and Bob in for 6 and 4 of a 20 hard cap, so it does not sell
   * out and ends at `endTime`. */
  async function deployStockLaunchWithContributions() {
    const base = await deployLaunchpad();
    const launch = await createLaunch(base, {
      quoteAsset: base.stock.address,
      softCap: parseEther("5"),
      hardCap: parseEther("20"),
    });
    await networkHelpers.time.increaseTo(launch.params.startTime);
    for (const [wallet, amount] of [
      [base.alice, parseEther("6")],
      [base.bob, parseEther("4")],
    ] as const) {
      await base.stock.write.approve([launch.sale.address, amount], { account: wallet.account });
      await launch.sale.write.contribute([amount, NO_PROOF], { account: wallet.account });
    }
    return { ...base, ...launch };
  }

  describe("creating a launch", () => {
    it("deploys the sale and the vesting as clones, set up for the chosen asset", async () => {
      const { launchpad, sale, vesting, token, stablecoin, creator, saleImplementation } =
        await networkHelpers.loadFixture(deployUsdLaunch);

      assert.equal(await token.read.balanceOf([sale.address]), TOTAL_SUPPLY);
      assert.ok(sameAddress(await sale.read.quoteAsset(), stablecoin.address));
      assert.ok(sameAddress(await sale.read.launchpad(), launchpad.address));
      assert.ok(sameAddress(await sale.read.vesting(), vesting.address));
      assert.equal(await sale.read.tokensForSale(), TOKENS_FOR_SALE);
      assert.equal(await sale.read.creatorAllocation(), CREATOR_ALLOCATION);
      assert.equal(await sale.read.hardCap(), HARD_CAP);
      assert.equal(await sale.read.feeBps(), FEE_BPS);
      assert.equal(await sale.read.status(), STATUS.Upcoming);
      assert.ok(sameAddress(await vesting.read.sale(), sale.address));
      assert.ok(sameAddress(await vesting.read.quoteAsset(), stablecoin.address));
      assert.ok(sameAddress(await vesting.read.beneficiary(), creator.account.address));

      // A minimal clone: 45 bytes that delegate to the implementation.
      const code = await publicClient.getCode({ address: sale.address });
      assert.equal(code?.length, 2 + 45 * 2);
      assert.ok(code?.toLowerCase().includes(saleImplementation.address.slice(2).toLowerCase()));

      const launch = await launchpad.read.getLaunch([0n]);
      assert.ok(sameAddress(launch.quoteAsset, stablecoin.address));
    });

    it("announces the launch with its quote asset", async () => {
      const { launchpad, stablecoin, creator } = await networkHelpers.loadFixture(deployLaunchpad);
      const params = await defaultParams(getAddress(stablecoin.address));

      await launchpad.write.createLaunch([params], { account: creator.account });

      const [event] = await launchpad.getEvents.LaunchCreated();
      assert.equal(event.args.launchId, 0n);
      assert.deepEqual(event.args.params, params);
      assert.equal(event.args.tokensForSale, TOKENS_FOR_SALE);
    });

    it("never lets anyone set up a sale, a vesting or an implementation twice", async () => {
      const { sale, vesting, saleImplementation, vestingImplementation, stranger } =
        await networkHelpers.loadFixture(deployUsdLaunch);
      const config = {
        token: stranger.account.address,
        quoteAsset: stranger.account.address,
        creator: stranger.account.address,
        dexFactory: stranger.account.address,
        weth: stranger.account.address,
        vestingImplementation: stranger.account.address,
        tokensForSale: 1n,
        creatorAllocation: 0n,
        softCap: 1n,
        hardCap: 1n,
        minContribution: 0n,
        maxContribution: 0n,
        startTime: 0n,
        endTime: 0n,
        liquidityBps: 0,
        feeBps: 0,
        vestingTranches: 3,
        requiredTier: 0,
      };

      for (const target of [sale, saleImplementation]) {
        await viem.assertions.revertWithCustomError(
          target.write.initialize([config], { account: stranger.account }),
          target,
          "InvalidInitialization",
        );
      }
      const me = stranger.account.address;
      for (const target of [vesting, vestingImplementation]) {
        await viem.assertions.revertWithCustomError(
          target.write.initialize([me, me, me, me, 3], { account: stranger.account }),
          target,
          "InvalidInitialization",
        );
      }
    });
  });

  describe("allowed quote assets", () => {
    it("refuses an asset the launchpad does not allow", async () => {
      const base = await networkHelpers.loadFixture(deployLaunchpad);
      const other = await viem.deployContract("MockStablecoin");

      await viem.assertions.revertWithCustomError(
        createLaunch(base, { quoteAsset: other.address }),
        base.launchpad,
        "QuoteAssetNotAllowed",
      );
    });

    it("applies each asset's own minimum raise", async () => {
      const base = await networkHelpers.loadFixture(deployLaunchpad);

      await viem.assertions.revertWithCustomError(
        createLaunch(base, { softCap: MIN_SOFT_CAP_USD - 1n }),
        base.launchpad,
        "InvalidCaps",
      );
      const { sale } = await createLaunch(base, { softCap: MIN_SOFT_CAP_USD });
      assert.equal(await sale.read.softCap(), MIN_SOFT_CAP_USD);
    });

    it("lets only the owner change the list, and never touches launches already created", async () => {
      const base = await networkHelpers.loadFixture(deployLaunchpad);
      const { launchpad, stablecoin, stranger } = base;
      const launch = await createLaunch(base);

      await viem.assertions.revertWithCustomError(
        launchpad.write.setQuoteAsset([stablecoin.address, false, 0n], {
          account: stranger.account,
        }),
        launchpad,
        "OwnableUnauthorizedAccount",
      );
      await viem.assertions.emitWithArgs(
        launchpad.write.setQuoteAsset([stablecoin.address, false, 0n]),
        launchpad,
        "QuoteAssetUpdated",
        [stablecoin.address, false, 0n],
      );

      await viem.assertions.revertWithCustomError(
        createLaunch(base, { symbol: "OTHER" }),
        launchpad,
        "QuoteAssetNotAllowed",
      );
      // The launch created before keeps working with it.
      await networkHelpers.time.increaseTo(launch.params.startTime);
      await contributeUsd(base, launch, base.alice, usd("500"));
      assert.equal(await launch.sale.read.totalRaised(), usd("500"));
    });

    it("refuses an address with no contract and an allowed asset with no minimum", async () => {
      const { launchpad, stablecoin, stranger } = await networkHelpers.loadFixture(deployLaunchpad);

      await viem.assertions.revertWithCustomError(
        launchpad.write.setQuoteAsset([stranger.account.address, true, 1n]),
        launchpad,
        "InvalidQuoteAsset",
      );
      await viem.assertions.revertWithCustomError(
        launchpad.write.setQuoteAsset([stablecoin.address, true, 0n]),
        launchpad,
        "InvalidQuoteAsset",
      );
    });
  });

  describe("tickers", () => {
    it("accepts only 1 to 10 characters from A-Z and 0-9", async () => {
      const base = await networkHelpers.loadFixture(deployLaunchpad);

      for (const symbol of ["", "void", "VOId", "VO ID", "VOID-2", "ABCDEFGHIJK", "VØID"]) {
        await viem.assertions.revertWithCustomError(
          createLaunch(base, { symbol }),
          base.launchpad,
          "InvalidSymbol",
        );
        assert.equal(await base.launchpad.read.isTickerAvailable([symbol]), false);
      }
      await createLaunch(base, { symbol: "ABCDEFGHI0" });
    });

    it("keeps a ticker for one launch at a time", async () => {
      const base = await networkHelpers.loadFixture(deployLaunchpad);
      assert.equal(await base.launchpad.read.isTickerAvailable(["VOID"]), true);

      await createLaunch(base);

      assert.equal(await base.launchpad.read.isTickerAvailable(["VOID"]), false);
      await viem.assertions.revertWithCustomError(
        createLaunch(base),
        base.launchpad,
        "TickerTaken",
      );
    });

    it("frees the ticker of a cancelled launch, for anyone to reuse", async () => {
      const launch = await networkHelpers.loadFixture(deployUsdLaunch);
      const { launchpad, sale, creator, stranger } = launch;

      await viem.assertions.revertWithCustomError(
        launchpad.write.releaseTicker([0n], { account: stranger.account }),
        launchpad,
        "TickerInUse",
      );
      await sale.write.cancel({ account: creator.account });
      await viem.assertions.emitWithArgs(
        launchpad.write.releaseTicker([0n], { account: stranger.account }),
        launchpad,
        "TickerReleased",
        [0n, "VOID"],
      );

      assert.equal(await launchpad.read.isTickerAvailable(["VOID"]), true);
      await createLaunch(launch);
      // Released once; the old launch cannot free the new launch's ticker.
      await viem.assertions.revertWithCustomError(
        launchpad.write.releaseTicker([0n]),
        launchpad,
        "TickerInUse",
      );
    });

    it("frees the ticker of a failed launch, never of a live or listed one", async () => {
      const launch = await networkHelpers.loadFixture(deployLiveUsdLaunch);
      const { launchpad, sale, params } = launch;

      await viem.assertions.revertWithCustomError(
        launchpad.write.releaseTicker([0n]),
        launchpad,
        "TickerInUse",
      );
      await networkHelpers.time.increaseTo(params.endTime);
      assert.equal(await sale.read.status(), STATUS.Failed);
      await launchpad.write.releaseTicker([0n]);
      assert.equal(await launchpad.read.isTickerAvailable(["VOID"]), true);

      const listed = await networkHelpers.loadFixture(deploySoldOutUsdLaunch);
      await listed.sale.write.finalize();
      await viem.assertions.revertWithCustomError(
        listed.launchpad.write.releaseTicker([0n]),
        listed.launchpad,
        "TickerInUse",
      );
    });
  });

  describe("official tokens", () => {
    it("tells its own tokens from any other", async () => {
      const { launchpad, token, sale, stablecoin } =
        await networkHelpers.loadFixture(deployUsdLaunch);

      assert.equal(await launchpad.read.isOfficial([token.address]), true);
      assert.ok(sameAddress(await launchpad.read.saleOf([token.address]), sale.address));
      assert.equal(await launchpad.read.isOfficial([stablecoin.address]), false);
      assert.equal(await launchpad.read.saleOf([stablecoin.address]), zeroAddress);
    });
  });

  describe("a launch paired with a stablecoin", () => {
    it("takes only the part of an approved amount that fits", async () => {
      const launch = await networkHelpers.loadFixture(deployLiveUsdLaunch);
      const { sale, stablecoin, alice, bob } = launch;

      await contributeUsd(launch, launch, alice, usd("7000"));
      await stablecoin.write.approve([sale.address, usd("5000")], { account: bob.account });
      await viem.assertions.emitWithArgs(
        sale.write.contribute([usd("5000"), NO_PROOF], { account: bob.account }),
        sale,
        "Contributed",
        [bob.account.address, usd("3000"), HARD_CAP],
      );

      assert.equal(await stablecoin.read.balanceOf([sale.address]), HARD_CAP);
      assert.equal(await stablecoin.read.balanceOf([bob.account.address]), usd("97000"));
      assert.equal(await stablecoin.read.allowance([bob.account.address, sale.address]), usd("2000"));
      assert.equal(await sale.read.status(), STATUS.Succeeded);
    });

    it("accepts an EIP-2612 permit instead of a separate approval", async () => {
      const launch = await networkHelpers.loadFixture(deployLiveUsdLaunch);
      const { sale, stablecoin, alice } = launch;
      const amount = usd("1500");
      const deadline = BigInt(await networkHelpers.time.latest()) + HOUR;

      const signature = await alice.signTypedData({
        domain: {
          name: "Mock Dollar",
          version: "1",
          chainId: await publicClient.getChainId(),
          verifyingContract: stablecoin.address,
        },
        types: {
          Permit: [
            { name: "owner", type: "address" },
            { name: "spender", type: "address" },
            { name: "value", type: "uint256" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint256" },
          ],
        },
        primaryType: "Permit",
        message: {
          owner: alice.account.address,
          spender: sale.address,
          value: amount,
          nonce: 0n,
          deadline,
        },
      });
      const r = `0x${signature.slice(2, 66)}` as `0x${string}`;
      const s = `0x${signature.slice(66, 130)}` as `0x${string}`;
      const v = Number.parseInt(signature.slice(130, 132), 16);

      await sale.write.contributeWithPermit([amount, deadline, v, r, s, NO_PROOF], {
        account: alice.account,
      });

      assert.equal(await sale.read.contributions([alice.account.address]), amount);
    });

    it("refuses the native currency", async () => {
      const { sale, alice } = await networkHelpers.loadFixture(deployLiveUsdLaunch);

      await viem.assertions.revertWithCustomError(
        sale.write.contributeNative([NO_PROOF], { account: alice.account, value: 1n }),
        sale,
        "NativeNotAccepted",
      );
      await viem.assertions.revertWithCustomError(
        alice.sendTransaction({ to: sale.address, value: 1n }),
        sale,
        "NativeNotAccepted",
      );
    });

    it("lists the token against the stablecoin and splits the raise in it", async () => {
      const launch = await networkHelpers.loadFixture(deploySoldOutUsdLaunch);
      const { sale, token, vesting, stablecoin, dexFactory, stranger } = launch;

      await sale.write.finalize({ account: stranger.account });

      const fee = (HARD_CAP * BigInt(FEE_BPS)) / BPS;
      const liquidityQuote = (HARD_CAP * BigInt(LIQUIDITY_BPS)) / BPS;
      const creatorQuote = HARD_CAP - liquidityQuote - fee;
      const tokensSold = TOKENS_FOR_SALE;
      const liquidityTokens = (tokensSold * BigInt(LIQUIDITY_BPS)) / BPS;

      const pair = await dexFactory.read.getPair([token.address, stablecoin.address]);
      assert.ok(sameAddress(pair, await sale.read.pair()));
      assert.equal(await stablecoin.read.balanceOf([pair]), liquidityQuote);
      assert.equal(await token.read.balanceOf([pair]), liquidityTokens);
      const lp = await viem.getContractAt("MockPair", pair);
      assert.equal(await lp.read.balanceOf([sale.address]), 0n);
      assert.ok((await lp.read.balanceOf([DEAD])) > 0n);

      assert.equal(await stablecoin.read.balanceOf([vesting.address]), creatorQuote);
      assert.equal(await vesting.read.totalQuote(), creatorQuote);
      assert.equal(await vesting.read.totalTokens(), CREATOR_ALLOCATION);
      assert.equal(await sale.read.feeOwed(), fee);
      // The sale keeps exactly the fee and what contributors can claim.
      assert.equal(await stablecoin.read.balanceOf([sale.address]), fee);
      assert.equal(await token.read.balanceOf([sale.address]), tokensSold);
    });

    it("lets contributors claim, the platform collect and the creator vest, all in the stablecoin", async () => {
      const launch = await networkHelpers.loadFixture(deploySoldOutUsdLaunch);
      const { sale, token, vesting, stablecoin, alice, bob, creator, feeWallet } = launch;
      await sale.write.finalize();

      await sale.write.claim({ account: alice.account });
      await sale.write.claim({ account: bob.account });
      assert.equal(
        await token.read.balanceOf([alice.account.address]),
        (usd("6000") * TOKENS_FOR_SALE) / HARD_CAP,
      );

      const fee = (HARD_CAP * BigInt(FEE_BPS)) / BPS;
      await sale.write.collectFee();
      assert.equal(await stablecoin.read.balanceOf([feeWallet.account.address]), fee);

      await networkHelpers.time.increase(3n * MONTH);
      await vesting.write.release();
      assert.equal(
        await stablecoin.read.balanceOf([creator.account.address]),
        await vesting.read.totalQuote(),
      );
      assert.equal(await token.read.balanceOf([creator.account.address]), CREATOR_ALLOCATION);
    });

    it("refunds every contributor in full when the sale fails", async () => {
      const launch = await networkHelpers.loadFixture(deployLiveUsdLaunch);
      const { sale, stablecoin, alice, params } = launch;
      await contributeUsd(launch, launch, alice, usd("1000"));
      await networkHelpers.time.increaseTo(params.endTime);

      await viem.assertions.emitWithArgs(
        sale.write.refund({ account: alice.account }),
        sale,
        "Refunded",
        [alice.account.address, usd("1000"), usd("1000")],
      );
      assert.equal(await stablecoin.read.balanceOf([alice.account.address]), usd("100000"));
    });

    it("refuses a token that delivers less than was sent", async () => {
      const base = await networkHelpers.loadFixture(deployLaunchpad);
      const feeToken = await viem.deployContract("MockFeeToken");
      // Allowed by mistake: the sale still protects itself.
      await base.launchpad.write.setQuoteAsset([feeToken.address, true, parseEther("1")]);
      const launch = await createLaunch(base, {
        quoteAsset: feeToken.address,
        softCap: parseEther("1"),
        hardCap: parseEther("10"),
      });
      await feeToken.write.mint([base.alice.account.address, parseEther("5")]);
      await networkHelpers.time.increaseTo(launch.params.startTime);
      await feeToken.write.approve([launch.sale.address, parseEther("5")], {
        account: base.alice.account,
      });

      await viem.assertions.revertWithCustomError(
        launch.sale.write.contribute([parseEther("5"), NO_PROOF], { account: base.alice.account }),
        launch.sale,
        "UnsupportedQuoteAsset",
      );
    });
  });

  describe("a launch paired with the native currency", () => {
    it("takes the native currency, wraps it and sends back what does not fit", async () => {
      const launch = await networkHelpers.loadFixture(deployLiveNativeLaunch);
      const { sale, weth, alice } = launch;

      const before = await publicClient.getBalance({ address: alice.account.address });
      const hash = await sale.write.contributeNative([NO_PROOF], {
        account: alice.account,
        value: parseEther("12"),
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      const gas = receipt.gasUsed * receipt.effectiveGasPrice;

      assert.equal(await sale.read.contributions([alice.account.address]), parseEther("10"));
      assert.equal(await weth.read.balanceOf([sale.address]), parseEther("10"));
      assert.equal(
        await publicClient.getBalance({ address: alice.account.address }),
        before - parseEther("10") - gas,
      );
    });

    it("also takes the wrapped token directly", async () => {
      const launch = await networkHelpers.loadFixture(deployLiveNativeLaunch);
      const { sale, weth, bob } = launch;
      await weth.write.deposit({ account: bob.account, value: parseEther("3") });
      await weth.write.approve([sale.address, parseEther("3")], { account: bob.account });

      await sale.write.contribute([parseEther("3"), NO_PROOF], { account: bob.account });

      assert.equal(await sale.read.totalRaised(), parseEther("3"));
    });

    it("refunds in the native currency, or in the wrapped token to whoever cannot receive it", async () => {
      const launch = await networkHelpers.loadFixture(deployLiveNativeLaunch);
      const { sale, weth, alice, params } = launch;
      const refuser = await viem.deployContract("NativeRefuser");
      // 1.5 in all, below the minimum of 2: the sale fails.
      await sale.write.contributeNative([NO_PROOF], { account: alice.account, value: parseEther("1") });
      await refuser.write.contributeNative([sale.address], { value: parseEther("0.5") });
      await networkHelpers.time.increaseTo(params.endTime);

      const before = await publicClient.getBalance({ address: alice.account.address });
      const hash = await sale.write.refund({ account: alice.account });
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      assert.equal(
        await publicClient.getBalance({ address: alice.account.address }),
        before + parseEther("1") - receipt.gasUsed * receipt.effectiveGasPrice,
      );

      await refuser.write.refund([sale.address]);
      assert.equal(await weth.read.balanceOf([refuser.address]), parseEther("0.5"));
    });

    it("pays the creator's vesting in the native currency", async () => {
      const launch = await networkHelpers.loadFixture(deployLiveNativeLaunch);
      const { sale, vesting, alice, creator } = launch;
      await sale.write.contributeNative([NO_PROOF], { account: alice.account, value: parseEther("10") });
      await sale.write.finalize();
      await networkHelpers.time.increase(3n * MONTH);

      const before = await publicClient.getBalance({ address: creator.account.address });
      await vesting.write.release({ account: alice.account });

      assert.equal(
        await publicClient.getBalance({ address: creator.account.address }),
        before + (await vesting.read.totalQuote()),
      );
    });
  });

  describe("an asset whose issuer can pause, block and burn", () => {
    it("only delays a listing while paused, and turns it into refunds if the pause lasts", async () => {
      const launch = await networkHelpers.loadFixture(deployStockLaunchWithContributions);
      const { sale, stock, alice, params } = launch;
      await networkHelpers.time.increaseTo(params.endTime);
      assert.equal(await sale.read.status(), STATUS.Succeeded);

      await stock.write.setPaused([true]);
      await viem.assertions.revertWith(sale.write.finalize(), "PAUSED");

      await networkHelpers.time.increase(GRACE_PERIOD);
      assert.equal(await sale.read.status(), STATUS.Failed);
      await viem.assertions.revertWith(sale.write.refund({ account: alice.account }), "PAUSED");
      assert.equal(await sale.read.contributions([alice.account.address]), parseEther("6"));

      await stock.write.setPaused([false]);
      await sale.write.refund({ account: alice.account });
      assert.equal(await stock.read.balanceOf([alice.account.address]), parseEther("100000"));
    });

    it("keeps a blocked contributor's problem to that contributor", async () => {
      const launch = await networkHelpers.loadFixture(deployStockLaunchWithContributions);
      const { sale, stock, alice, bob, params } = launch;
      await networkHelpers.time.increaseTo(params.endTime + GRACE_PERIOD);
      await stock.write.setBlocked([alice.account.address, true]);

      await viem.assertions.revertWith(sale.write.refund({ account: alice.account }), "BLOCKED");
      await sale.write.refund({ account: bob.account });

      assert.equal(await stock.read.balanceOf([bob.account.address]), parseEther("100000"));
    });

    it("shares a burn by the issuer among every refund instead of listing", async () => {
      const launch = await networkHelpers.loadFixture(deployStockLaunchWithContributions);
      const { sale, stock, alice, bob, params } = launch;
      // The issuer takes 2.5 of the 10 the sale holds.
      await stock.write.adminBurn([sale.address, parseEther("2.5")]);
      await networkHelpers.time.increaseTo(params.endTime);

      await viem.assertions.revertWithCustomError(sale.write.finalize(), sale, "QuoteShortfall");
      await networkHelpers.time.increase(GRACE_PERIOD);

      await viem.assertions.emitWithArgs(
        sale.write.refund({ account: bob.account }),
        sale,
        "Refunded",
        [bob.account.address, parseEther("4"), parseEther("3")],
      );
      await viem.assertions.emitWithArgs(
        sale.write.refund({ account: alice.account }),
        sale,
        "Refunded",
        [alice.account.address, parseEther("6"), parseEther("4.5")],
      );
      // Both got 75%, and nothing is left behind.
      assert.equal(await stock.read.balanceOf([sale.address]), 0n);
    });
  });

  describe("verification tiers", () => {
    const TYPES = {
      Attestation: [
        { name: "account", type: "address" },
        { name: "tier", type: "uint8" },
        { name: "expiresAt", type: "uint64" },
      ],
    } as const;

    async function deployTieredLaunch() {
      const base = await deployLaunchpad();
      await base.launchpad.write.setAttestor([base.attestor.account.address]);
      const launch = await createLaunch(base, { requiredTier: 2 });
      await networkHelpers.time.increaseTo(launch.params.startTime);
      return { ...base, ...launch };
    }

    async function proofFor(
      launch: Awaited<ReturnType<typeof deployTieredLaunch>>,
      signer: Base["attestor"],
      account: `0x${string}`,
      tier: number,
      expiresAt: bigint,
    ) {
      const signature = await signer.signTypedData({
        domain: {
          name: "Somewhere Launchpad",
          version: "3",
          chainId: await publicClient.getChainId(),
          verifyingContract: launch.launchpad.address,
        },
        types: TYPES,
        primaryType: "Attestation",
        message: { account, tier, expiresAt },
      });
      return { tier, expiresAt, signature };
    }

    it("cannot require a tier while nobody can sign one", async () => {
      const base = await networkHelpers.loadFixture(deployLaunchpad);

      await viem.assertions.revertWithCustomError(
        createLaunch(base, { requiredTier: 1 }),
        base.launchpad,
        "NoAttestor",
      );
    });

    it("takes contributions only with a valid statement of a high enough tier", async () => {
      const launch = await networkHelpers.loadFixture(deployTieredLaunch);
      const { sale, stablecoin, alice, bob, attestor, stranger } = launch;
      const amount = usd("500");
      await stablecoin.write.approve([sale.address, amount * 10n], { account: alice.account });
      const now = BigInt(await networkHelpers.time.latest());
      const contribute = (proof: typeof NO_PROOF) =>
        sale.write.contribute([amount, proof], { account: alice.account });
      const me = alice.account.address;

      for (const proof of [
        NO_PROOF,
        await proofFor(launch, attestor, me, 1, now + HOUR), // tier too low
        await proofFor(launch, attestor, me, 2, now - 1n), // expired
        await proofFor(launch, stranger, me, 2, now + HOUR), // not the attestor
        await proofFor(launch, attestor, bob.account.address, 2, now + HOUR), // someone else's
      ]) {
        await viem.assertions.revertWithCustomError(contribute(proof), sale, "NotVerified");
      }

      await contribute(await proofFor(launch, attestor, me, 3, now + HOUR));
      assert.equal(await sale.read.contributions([me]), amount);
    });

    it("stops taking statements from an attestor the platform removed", async () => {
      const launch = await networkHelpers.loadFixture(deployTieredLaunch);
      const { launchpad, sale, stablecoin, alice, attestor } = launch;
      const now = BigInt(await networkHelpers.time.latest());
      const proof = await proofFor(launch, attestor, alice.account.address, 2, now + DAY);
      await stablecoin.write.approve([sale.address, usd("500")], { account: alice.account });

      await launchpad.write.setAttestor([zeroAddress]);

      await viem.assertions.revertWithCustomError(
        sale.write.contribute([usd("500"), proof], { account: alice.account }),
        sale,
        "NotVerified",
      );
    });
  });

  describe("cancelling", () => {
    it("lets only the creator cancel before the sale opens, burning the supply", async () => {
      const launch = await networkHelpers.loadFixture(deployUsdLaunch);
      const { sale, token, creator, stranger } = launch;

      await viem.assertions.revertWithCustomError(
        sale.write.cancel({ account: stranger.account }),
        sale,
        "NotCreator",
      );
      await viem.assertions.emitWithArgs(
        sale.write.cancel({ account: creator.account }),
        sale,
        "Cancelled",
        [TOTAL_SUPPLY],
      );
      assert.equal(await token.read.balanceOf([DEAD]), TOTAL_SUPPLY);
      assert.equal(await sale.read.status(), STATUS.Cancelled);
    });
  });
});
