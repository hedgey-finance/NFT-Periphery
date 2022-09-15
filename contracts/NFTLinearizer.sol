// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import './libraries/TransferHelper.sol';
import './interfaces/INFT.sol';
import './libraries/NFTHelper.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/// @title NFTLinearizer is a contract that takes a locked token call from another Hedgey OTC or Swap contract
/// and breaks up the single unlock date into monthly unlock dates

contract NFTLinearizer {
  using SafeERC20 for IERC20;

  uint256 constant MONTH = 648000; // approx 30 days assuming 4 seconds per block - 60 * 60 * 24 * 30 / 4
  address public nft;
  uint8 public periods;

  constructor(
    address _nft,
    uint8 _periods,
  ) {
    nft = _nft;
    periods = _periods;
  }

  // this is called to this contract for the NFT Locking mechanism
  function splitAndMintNFTs(
    address holder,
    uint256 amount,
    address token,
    uint256 unlockDate
  ) internal {
    uint256 splitAmount = amount / periods;
    uint256 newUnlock = unlockDate;
    IERC20(token).safeIncreaseAllowance(nft, amount);
    for (uint8 i; i < periods; i++) {
      INFT(nft).createNFT(holder, splitAmount, token, newUnlock);
      newUnlock += 30 days;
    }
  }

  // function called by the dao swap contract
  function createNFT(
    address holder,
    uint256 amount,
    address token,
    uint256 unlockDate
  ) external {
    //pull in the funds
    TransferHelper.transferTokens(token, msg.sender, address(this), amount);
    //internal function to breakup and mint NFTs
    splitAndMintNFTs(holder, amount, token, unlockDate);
  }
}
