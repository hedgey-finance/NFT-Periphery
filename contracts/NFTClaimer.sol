// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import './libraries/TransferHelper.sol';
import './libraries/NFTHelper.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';

/// @title NFTClaimer is a contract built on top of the Hedgeys NFTs that allows someone to setup a whitelist
/// whereupon anyone within that whitelist can claim tokens
/// @dev there is an admin for each unique claim set
contract NFTClaimer is ReentrancyGuard {
  /// @notice id counts the batches that hold tokens to be claimed
  uint256 public batchId;

  struct Batch {
    address admin;
    address token;
    uint256 remainingAmount;
    uint256 tokensPerNFT;
    uint256 unlockDate;
    address nftLocker;
    address tokenGate;
  }

  mapping(uint256 => Batch) public batches;
  mapping(uint256 => mapping(address => bool)) public batchWhiteList;
  mapping(uint256 => mapping(address => bool)) public claimed;

  /// events
  event BatchCreated(
    uint256 id,
    address admin,
    address token,
    uint256 totalAmount,
    uint256 tokensPerNFT,
    uint256 unlockDate,
    address nftLocker,
    address tokenGate
  );
  event Claimed(uint256 id, address claimer, uint256 amountRemaining);
  event BatchCancelled(uint256 id);

  /// @notice function to create a batch
  function createBatch(
    address token,
    uint256 totalAmount,
    uint256 tokensPerNFT,
    uint256 unlockDate,
    address nftLocker,
    address[] memory whitelist,
    address tokenGate
  ) external nonReentrant {
    require(token != address(0), 'token zero address');
    require(nftLocker != address(0), 'nft zero address');
    require(unlockDate > block.timestamp, 'unlock in the past');
    require(totalAmount % tokensPerNFT == 0, 'mod error');
    TransferHelper.transferTokens(token, msg.sender, address(this), totalAmount);
    if (whitelist.length > 0) {
      for (uint256 i; i < whitelist.length; i++) {
        batchWhiteList[batchId][whitelist[i]] = true;
      }
    }
    batches[batchId++] = Batch(msg.sender, token, totalAmount, tokensPerNFT, unlockDate, nftLocker, tokenGate);
    emit BatchCreated(batchId - 1, msg.sender, token, totalAmount, tokensPerNFT, unlockDate, nftLocker, tokenGate);
  }

  /// @notice function for batch admin to add additional ppl to the whitelist
  function addtoWhiteList(uint256 _batchId, address[] memory whitelist) external {
    Batch memory batch = batches[_batchId];
    require(msg.sender == batch.admin, 'only admin');
    require(whitelist.length > 0, 'no addresses');
    for (uint256 i; i < whitelist.length; i++) {
      batchWhiteList[_batchId][whitelist[i]] = true;
    }
  }

  /// @notice function for batch admin to remove ppl to the whitelist
  function removeFromWhiteList(uint256 _batchId, address[] memory whitelist) external {
    Batch memory batch = batches[_batchId];
    require(msg.sender == batch.admin, 'only admin');
    require(whitelist.length > 0, 'no addresses');
    for (uint256 i; i < whitelist.length; i++) {
      batchWhiteList[_batchId][whitelist[i]] = false;
    }
  }

  function claim(uint256 _batchId) external nonReentrant {
    Batch memory batch = batches[_batchId];
    require(batch.remainingAmount > 0, 'nothing left');
    require(batchWhiteList[_batchId][msg.sender] || isTokenOwner(batch.tokenGate, msg.sender), 'not on the whitelist');
    require(!claimed[_batchId][msg.sender], 'already claimed');
    claimed[_batchId][msg.sender] = true;
    batch.remainingAmount -= batch.tokensPerNFT;
    if (batch.remainingAmount == 0) {
      delete batches[_batchId];
      emit BatchCancelled(_batchId);
    } else {
      batches[_batchId].remainingAmount = batch.remainingAmount;
    }
    NFTHelper.lockTokens(batch.nftLocker, msg.sender, batch.token, batch.tokensPerNFT, batch.unlockDate);
    emit Claimed(_batchId, msg.sender, batch.remainingAmount);
  }

  function cancelBatch(uint256 _batchId) external nonReentrant {
    Batch memory batch = batches[_batchId];
    require(msg.sender == batch.admin, 'only admin');
    delete batches[_batchId];
    TransferHelper.withdrawTokens(batch.token, batch.admin, batch.remainingAmount);
    emit BatchCancelled(_batchId);
  }

  function isTokenOwner(address token, address buyer) public view returns (bool isOwner) {
    if (IERC721(token).balanceOf(buyer) > 0) isOwner = true;
  }
}
