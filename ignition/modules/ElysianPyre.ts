import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { parseEther } from "viem";

// Parameters can be overridden with: --parameters ignition/parameters.json
export default buildModule("ElysianPyreModule", (m) => {
  const deployer = m.getAccount(0);
  const owner = m.getParameter("owner", deployer);
  const feeRecipient = m.getParameter("feeRecipient", deployer);
  const fee = m.getParameter("fee", parseEther("0.1"));

  const pyre = m.contract("ElysianPyre", [owner, feeRecipient, fee]);
  return { pyre };
});
