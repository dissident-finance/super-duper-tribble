pragma solidity 0.5.16;

interface AToken {
  function getIncentivesController() external view returns (address);
  function redeem(uint256 amount) external;
  function burn(address user, address receiverOfUnderlying, uint256 amount, uint256 index) external;
  function balanceOf(address account) external view returns (uint256);
}
