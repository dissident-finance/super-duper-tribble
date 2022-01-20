pragma solidity 0.5.16;

interface DistController {
  function distSpeeds(address _distToken) external view returns (uint256);
  function claimDist(address[] calldata holders, address[] calldata distTokens) external;
  function getAllMarkets() external view returns (address[] memory);
  function _addDistMarkets(address[] calldata) external;
  function _supportMarkets(address[] calldata) external;
  function _setPriceOracle(address) external;
  function admin() external view returns(address);
}
