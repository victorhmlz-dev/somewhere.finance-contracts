// Allows, on a deployed v3 launchpad, the quote assets listed in
// ignition/parameters/<deployment id>-quote-assets.json, each with its
// minimum raise. Sends one transaction per asset that is not already set as
// listed, from the network's first account, which must be the launchpad's
// owner. Running it twice changes nothing the second time.
//
//   npx hardhat run scripts/allow-quote-assets.ts --network sepolia
//
// The launchpad is the one Ignition recorded under the deployment id, by
// default "<network>-v3" (ignition/deployments/sepolia-v3/). Another id can
// be given in the DEPLOYMENT_ID environment variable.
import { readFile } from "node:fs/promises";
import { network } from "hardhat";
import { getAddress } from "viem";

type QuoteAssetEntry = { label: string; asset: string; minSoftCap: string };

const connection = await network.create();
const { viem, networkName } = connection;
const deploymentId = process.env.DEPLOYMENT_ID || `${networkName}-v3`;

const deployed = JSON.parse(
  await readFile(`ignition/deployments/${deploymentId}/deployed_addresses.json`, "utf8"),
) as Record<string, string>;
const launchpadAddress = deployed["LaunchpadV3#LaunchpadV3"];
if (!launchpadAddress) throw new Error(`No LaunchpadV3 in deployment ${deploymentId}`);

const { quoteAssets } = JSON.parse(
  await readFile(`ignition/parameters/${deploymentId}-quote-assets.json`, "utf8"),
) as { quoteAssets: QuoteAssetEntry[] };

const launchpad = await viem.getContractAt("LaunchpadV3", getAddress(launchpadAddress));
const publicClient = await viem.getPublicClient();
const [sender] = await viem.getWalletClients();
const owner = await launchpad.read.owner();
if (getAddress(owner) !== getAddress(sender.account.address)) {
  throw new Error(`${sender.account.address} is not the owner of the launchpad (${owner})`);
}

console.log(`Launchpad v3 on ${networkName}: ${launchpad.address}`);
for (const entry of quoteAssets) {
  const asset = getAddress(entry.asset);
  const minSoftCap = BigInt(entry.minSoftCap);
  const [allowed, current] = await launchpad.read.quoteAssets([asset]);
  if (allowed && current === minSoftCap) {
    console.log(`  ${entry.label}: already allowed, minimum ${minSoftCap}`);
    continue;
  }
  const hash = await launchpad.write.setQuoteAsset([asset, true, minSoftCap]);
  await publicClient.waitForTransactionReceipt({ hash });
  console.log(`  ${entry.label}: allowed, minimum ${minSoftCap} (${hash})`);
}
