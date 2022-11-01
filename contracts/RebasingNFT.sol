// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import '@openzeppelin/contracts/utils/Counters.sol';
import '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import './libraries/TransferHelper.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title An NFT representation of ownership of time locked tokens
 * @notice The time locked tokens are redeemable by the owner of the NFT
 * @notice The NFT is basic ERC721 with an ownable usage to ensure only a single owner call mint new NFTs
 * @notice it uses the Enumerable extension to allow for easy lookup to pull balances of one account for multiple NFTs
 */
contract Rebase_Hedgeys is ERC721Enumerable, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using Counters for Counters.Counter;
  Counters.Counter private _tokenIds;

  /// @dev baseURI is the URI directory where the metadata is stored
  string private baseURI;
  /// @dev admin for setting the baseURI;
  address private admin;

  /// @dev the Future is the storage in a struct of the tokens that are time locked
  /// @dev the Future contains the information about the amount of tokens, the underlying token address (asset), and the date in which they are unlocked
  struct Future {
    uint256 shares;
    address token;
    uint256 unlockDate;
  }

  /// @dev mapping from token to shares based on the amount deposited
  mapping(address => uint256) public totalShares;

  /// @dev this maping maps the _tokenIDs from Counters to a Future struct. the same _tokenIDs that is set for the NFT id is mapped to the futures
  mapping(uint256 => Future) public futures;

  /// @dev mapping as an easy way to store the total shares owned by an individual address accross multiple nfts
  /// useful for voting mechanisms. 
  /// maps from holder address to token address, to total shares owned
  mapping(address => mapping(address => uint256)) public holderTokenShares;

  ///@notice Events when a new NFT (future) is created and one with a Future is redeemed (burned)
  event NFTCreated(uint256 id, address holder, uint256 amount, uint256 shares, address token, uint256 unlockDate);
  event NFTRedeemed(uint256 id, address holder, uint256 amount, uint256 shares, address token, uint256 unlockDate);
  event URISet(string newURI);

  constructor(string memory name, string memory symbol) ERC721(name, symbol) {
    admin = msg.sender;
  }

  function createNFT(
    address holder,
    uint256 amount,
    address token,
    uint256 unlockDate
  ) external nonReentrant returns (uint256) {
    _tokenIds.increment();
    uint256 newItemId = _tokenIds.current();
    uint256 prevShares = totalShares[token];
    TransferHelper.transferTokens(token, msg.sender, address(this), amount);
    uint256 newBalance = IERC20(token).balanceOf(address(this));
    uint256 _totalShares;
    if (prevShares == 0) {
        _totalShares = 1e18;
    } else {
        uint256 ownership = amount * 1e19 / newBalance;
        _totalShares = (prevShares * 1e19) / (1e19 - ownership);
    }
    
    uint256 sharesIssued = _totalShares - prevShares;
    totalShares[token] = _totalShares;
    futures[newItemId] = Future(sharesIssued, token, unlockDate);
    _safeMint(holder, newItemId);
    holderTokenShares[msg.sender][token] += sharesIssued;
    emit NFTCreated(newItemId, holder, amount, sharesIssued, token, unlockDate);
    return newItemId;
  }

  /// @dev internal function used by the standard ER721 function tokenURI to retrieve the baseURI privately held to visualize and get the metadata
  function _baseURI() internal view override returns (string memory) {
    return baseURI;
  }

  /// @notice function to set the base URI after the contract has been launched, only once - this is done by the admin
  /// @notice there is no actual on-chain functions that require this URI to be anything beyond a blank string ("")
  /// @param _uri is the new baseURI for the metadata
  function updateBaseURI(string memory _uri) external {
    /// @dev this function can only be called by the admin
    require(msg.sender == admin, 'NFT02');
    /// @dev update the baseURI with the new _uri
    baseURI = _uri;
    /// @dev delete the admin
    delete admin;
    /// @dev emit event of the update uri
    emit URISet(_uri);
  }

  /// @notice this is the external function that actually redeems an NFT position
  /// @notice returns true if the function is successful
  /// @dev this function calls the _redeemFuture(...) internal function which handles the requirements and checks
  function redeemNFT(uint256 _id) external nonReentrant returns (bool) {
    /// @dev calls the internal _redeemNFT function that performs various checks to ensure that only the owner of the NFT can redeem their NFT and Future position
    _redeemNFT(msg.sender, _id);
    return true;
  }

  /**
   * @notice This internal function, called by redeemNFT to physically burn the NFT and redeem their Future position which distributes the locked tokens to its owner
   * @dev this function does five things: 1) Checks to ensure only the owner of the NFT can call this function
   * @dev 2) it checks that the tokens can actually be unlocked based on the time from the expiration
   * @dev 3) it burns the NFT - removing it from storage entirely
   * @dev 4) it also deletes the futures struct from storage so that nothing can be redeemed from that storage index again
   * @dev 5) it withdraws the tokens that have been locked - delivering them to the current owner of the NFT
   * @param _holder is the owner of the NFT calling the function
   * @param _id is the unique id of the NFT and unique id of the Future struct
   */
  function _redeemNFT(address _holder, uint256 _id) internal {
    /// @dev ensure that only the owner of the NFT can call this function
    require(ownerOf(_id) == _holder, 'NFT03');
    /// @dev pull the future data from storage and keep in memory to check requirements and disribute tokens
    Future memory future = futures[_id];
    /// @dev ensure that the unlockDate is in the past compared to block.timestamp
    /// @dev ensure that the future has not been redeemed already and that the amount is greater than 0
    require(future.unlockDate < block.timestamp && future.shares > 0, 'NFT04');
    /// @dev calculate amount owed
    uint256 balance = getBalanceFromShares(future.shares, future.token);
    /// @dev reduce the total share count by the shares in the future
    totalShares[future.token] -= future.shares;
    /// @dev reduce the view function of the users total shares
    holderTokenShares[_holder][future.token] -= future.shares;
    /// @dev emit an event of the redemption, the id of the NFt and details of the future (locked tokens)  - needs to happen before we delete the future struct and burn the NFT
    emit NFTRedeemed(_id, _holder, balance, future.shares, future.token, future.unlockDate);
    /// @dev burn the NFT
    _burn(_id);
    /// @dev delete the futures struct so that the owner cannot call this function again
    delete futures[_id];
    /// @dev physically deliver the tokens to the NFT owner
    TransferHelper.withdrawTokens(future.token, _holder, balance);
  }

  function getBalanceFromShares(uint256 shares, address token) public view returns (uint256 balance) {
    uint256 tokenBalance = IERC20(token).balanceOf(address(this));
    uint256 _totalShares = totalShares[token];
    balance = (tokenBalance * ((shares * 1e19)/ _totalShares)) / 10e18;
  }

  function tokenBalanceOf(address holder, address token) public view returns (uint256 balance) {
    uint256 shares = holderTokenShares[holder][token];
    balance = getBalanceFromShares(shares, token);
  }
}
