import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

// Deploys the v3 launchpad of one chain: the sale and vesting implementations
// every launch is cloned from, and the launchpad itself. Every value comes
// from a parameters file (see ignition/parameters/example-v3.json), because
// the exchange and the wrapped native currency are different contracts on
// each chain.
//
// No asset is allowed as a quote asset after deploying: the owner allows each
// one, with its minimum raise, with `setQuoteAsset`. The owner should be a
// multisig before any mainnet deployment.
export default buildModule("LaunchpadV3", (m) => {
  const owner = m.getParameter<string>("owner");
  const dexFactory = m.getParameter<string>("dexFactory");
  const weth = m.getParameter<string>("weth");
  const feeRecipient = m.getParameter<string>("feeRecipient");
  const feeBps = m.getParameter<number>("feeBps");

  const saleImplementation = m.contract("TokenSaleV3");
  const vestingImplementation = m.contract("CreatorVestingV3");
  const launchpad = m.contract("LaunchpadV3", [
    owner,
    dexFactory,
    weth,
    saleImplementation,
    vestingImplementation,
    feeRecipient,
    feeBps,
  ]);

  return { launchpad, saleImplementation, vestingImplementation };
});
