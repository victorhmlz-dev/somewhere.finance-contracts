import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

// Deploys the launchpad of one chain. Every value comes from a parameters
// file (see ignition/parameters/example.json), because the exchange and the
// wrapped native currency are different contracts on each chain.
export default buildModule("Launchpad", (m) => {
  const owner = m.getParameter<string>("owner");
  const dexFactory = m.getParameter<string>("dexFactory");
  const weth = m.getParameter<string>("weth");
  const feeRecipient = m.getParameter<string>("feeRecipient");
  const feeBps = m.getParameter<number>("feeBps");

  const launchpad = m.contract("Launchpad", [owner, dexFactory, weth, feeRecipient, feeBps]);

  return { launchpad };
});
