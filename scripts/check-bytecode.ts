// Checks that the contract deployed at an address is exactly the code in this repository.
// Elyscan cannot verify sources yet, so this is how anyone can confirm what is deployed.
//
// Usage: npx hardhat compile && npx tsx scripts/check-bytecode.ts <address>   (RPC_URL overrides the Elysium RPC)
import { readFileSync } from "node:fs";
import { createPublicClient, http, isAddress } from "viem";

const address = process.argv[2];
if (!address || !isAddress(address)) {
  console.error("Usage: npx tsx scripts/check-bytecode.ts <address>");
  process.exit(1);
}

const artifact = JSON.parse(
  readFileSync("artifacts/contracts/TokenLocker.sol/TokenLocker.json", "utf8"),
);
const client = createPublicClient({ transport: http(process.env.RPC_URL ?? "https://rpc.elyscan.live") });
const onchain = (await client.getCode({ address })) ?? "0x";
const local: string = artifact.deployedBytecode;

if (onchain === "0x") {
  console.error(`No contract at ${address}`);
  process.exit(1);
}
if (onchain.toLowerCase() === local.toLowerCase()) {
  console.log(`MATCH: ${address} runs exactly the TokenLocker code from this repository.`);
} else {
  console.error(`MISMATCH: on-chain code differs from this repository (${(onchain.length - 2) / 2} vs ${(local.length - 2) / 2} bytes).`);
  process.exit(1);
}
