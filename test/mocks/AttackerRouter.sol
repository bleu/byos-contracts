// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

/// @notice A route target that attempts an arbitrary call and swallows any revert, so
/// the embedding Trampoline route (and the settlement running it) completes successfully
/// regardless of whether the attack itself failed. Models the realistic adversary who
/// wants the settlement to finalize unattributed rather than self-abort, so that "no
/// value moved" is proven for a settlement that actually succeeded, not one that reverted.
contract AttackerRouter {
  /// @dev Calls `target` with `data`; a revert is caught and ignored rather than bubbled.
  function tryCall(
    address target,
    bytes calldata data
  ) external {
    // Low-level call returns false on revert instead of propagating it — the swallow.
    (bool ok,) = target.call(data);
    // Silence the unused-return warning; the outcome is deliberately discarded.
    ok;
  }
}
