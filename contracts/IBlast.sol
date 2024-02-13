// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
interface IBlast {
  // Note: the full interface for IBlast can be found below
  function configureClaimableGas() external;
  function claimAllGas(address contractAddress, address recipient) external returns (uint256);
}